import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore
import LinkDigestTransport

/// 代抓三条接线的端到端式测试：扩展消息 → 接收器 → 会话簿。
///
/// 这里故意不复刻入口的闭包，而是直接用生产同一份 `BrowserCaptureRelayWiring`。
/// 之前真机上漏传 `allowsRelayTabFallback` 没被任何测试发现，正是因为接线只存在于
/// App 入口里。
@MainActor
final class BrowserCaptureRelayWiringTests: XCTestCase {
  private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CurrentCapture] = []
    func record(_ value: CurrentCapture) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
  }

  private func envelope(jobID: String) -> Data {
    let object: [String: Any] = [
      "version": 1,
      "requestId": "capture-1",
      "createdAt": "2026-11-19T00:00:00Z",
      "captureJobID": jobID,
      "source": ["kind": "browser_capture", "url": "https://www.zhihu.com/question/20899988", "title": "代抓", "platform": "generic"],
      "capture": [
        "method": "rendered_dom", "text": "正文", "characterCount": 2,
        "completeness": "full_article", "capturedAt": "2026-11-19T00:00:00Z",
      ],
      "evidence": ["sourceLabel": "test", "usedCookie": false],
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  private func jobQuery(urls: [String], tabID: Int, relayTab: Bool) -> Data {
    var object: [String: Any] = [
      "kind": "browserCaptureJob", "version": 1, "requestId": "q1", "tabID": tabID, "urls": urls,
    ]
    if relayTab { object["relayTab"] = true }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  private func receiver(
    relay: BrowserCaptureRelay,
    sink: @escaping @Sendable (CurrentCapture) async -> Void
  ) -> CaptureReceiver {
    CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: sink,
      browserCaptureJobSink: BrowserCaptureRelayWiring.jobSink(relay),
      browserCaptureDeliverySink: BrowserCaptureRelayWiring.deliverySink(relay),
      browserCaptureOutcomeSink: BrowserCaptureRelayWiring.outcomeSink(relay)
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return XCTFail("等待条件超时") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testJobRequestKeepsTheRelayTabFallbackFlagOnItsWayToClaim() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 60)
    let bare = "https://www.xiaohongshu.com/explore/6af1824c000000003402b751"
    let task = Task { @MainActor in try await relay.capture(urlString: bare, pendingID: UUID()) }
    try await waitUntil { relay.waitingJobCount == 1 }

    // 落地地址与登记的链接完全不同，只有 relayTab 标记能让它认领成功。
    let response = await receiver(relay: relay, sink: { _ in })
      .process(jobQuery(urls: ["https://www.xiaohongshu.com/404?source=/404"], tabID: 7, relayTab: true))
    guard case let .browserCaptureJob(version: 1, requestId: "q1", jobID) = response else {
      return XCTFail("回包不是任务查询：\(response)")
    }
    let claimed = try XCTUnwrap(jobID, "带 relayTab 标记的单任务应被认领（接线丢了参数就会是 nil）")

    // 收尾：让等待的抓取结束，避免测试残留。
    _ = relay.reportBlocked(
      jobID: claimed,
      reason: .noteUnavailable,
      finalURL: "https://www.xiaohongshu.com/404?source=/404"
    )
    do { _ = try await task.value } catch {}
  }

  func testOutcomeMessageFailsTheJobWithThePlatformError() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 60)
    let bare = "https://www.xiaohongshu.com/explore/6af1824c000000003402b751"
    let task = Task { @MainActor in try await relay.capture(urlString: bare, pendingID: UUID()) }
    try await waitUntil { relay.waitingJobCount == 1 }
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: [bare], tabID: 7))

    let message = try JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJobOutcome", "version": 1, "requestId": "o1", "jobID": jobID,
      "finalURL": "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031",
      "reason": "note_unavailable",
    ])
    let response = await receiver(relay: relay, sink: { _ in }).process(message)
    XCTAssertEqual(response, .browserCaptureJob(version: 1, requestId: "o1", jobID: nil))

    do {
      _ = try await task.value
      XCTFail("错误页回报后应立刻失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .blocked(.shareLinkMissingToken, landing: "www.xiaohongshu.com/404"))
      XCTAssertEqual(failure.code, "shareLinkMissingToken")
    }
  }

  func testDeliveryThroughWiringResumesTheCapture() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 60)
    let probe = Probe()
    let captureReceiver = receiver(relay: relay) { probe.record($0) }
    let bare = "https://www.xiaohongshu.com/explore/6af1824c000000003402b751"
    let task = Task { @MainActor in
      await MainActor.run { } // 保持主 actor 语义
      return try await relay.capture(urlString: bare, pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: [bare], tabID: 7))

    let response = await captureReceiver.process(envelope(jobID: jobID))
    guard case .taskAccepted = response else {
      return XCTFail("代抓内容应被受理：\(response)")
    }
    let relayed = try await task.value
    XCTAssertEqual(relayed.document.text, "正文")
    XCTAssertEqual(probe.count, 0, "内容由队列入库，接收器不再存一遍")
  }
}

/// 真机同款链路：Host 进程收到 `browserCaptureJobOutcome` 帧 → 转发给 App →
/// App 立刻按平台原因失败。Host 只在找不到可执行文件时跳过（xcodebuild 单独跑
/// App 测试时不构建它）。
@MainActor
final class BrowserCaptureOutcomeHostTests: XCTestCase {
  private func nativeHostExecutable() -> URL? {
    var candidates: [URL] = []
    if let raw = ProcessInfo.processInfo.environment["LINKDIGEST_NATIVE_HOST_PATH"] {
      candidates.append(URL(fileURLWithPath: raw))
    }
    candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("LinkDigestNativeHost"))
    candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("LinkDigestNativeHost"))
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    candidates.append(cwd.appendingPathComponent(".build/debug/LinkDigestNativeHost"))
    candidates.append(cwd.appendingPathComponent(".build/release/LinkDigestNativeHost"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// 真的起一个 Host 进程、把一帧喂给它，返回它转发给 App 的原始帧。
  ///
  /// Host 每支持一种消息都要单独放行；漏掉一种的症状是「另一方等到超时」，
  /// 只有把二进制真跑起来才能证明它认识这类消息。
  private func forwardThroughHost(_ frame: Data) throws -> Data {
    guard let host = nativeHostExecutable() else {
      throw XCTSkip("LinkDigestNativeHost 未构建，跳过 Host 端到端测试")
    }
    // Unix socket 路径上限约 104 字节：临时目录带 UUID 会超长，bind 到截断路径上
    // 后面取 socket 身份就失败（EIO）。生产也是短的 /tmp 路径，这里保持一致。
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("relay-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let socketPath = root.appendingPathComponent("app.sock").path

    let server = UnixSocketServer(path: socketPath)
    try server.start()
    defer { server.stop() }

    let process = Process()
    process.executableURL = host
    process.environment = [
      "LINKDIGEST_SOCKET_PATH": socketPath,
      "LINKDIGEST_TIMEOUT_SECONDS": "10",
    ]
    let stdout = Pipe()
    let stdin = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    process.standardInput = stdin
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    // Host 从 stdin 读一帧；没喂帧它就会读到 EOF 直接退出，连接永远不来。
    try ChromiumFramer.writeFrame(frame, to: stdin.fileHandleForWriting)
    try? stdin.fileHandleForWriting.close()

    let client = try server.accept(timeout: 20)
    let forwarded = try ChromiumFramer.readFrame(from: client, timeout: 10)
    let ack = try JSONEncoder().encode(
      NativeResponse.browserCaptureJob(version: 1, requestId: "ack", jobID: nil)
    )
    try ChromiumFramer.writeFrame(ack, to: client)
    try? client.close()
    process.waitUntilExit()
    return forwarded
  }

  func testHostForwardsTheJobQueryFrame() throws {
    let query = try JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJob", "version": 1, "requestId": "q1", "tabID": 7,
      "relayTab": true, "urls": ["https://v.douyin.com/abc"],
    ])
    let forwarded = try forwardThroughHost(query)
    XCTAssertEqual(try BrowserCaptureJobRequest.decode(forwarded)?.tabID, 7)
  }

  func testHostForwardsTheOutcomeFrameAndTheAppFailsTheJob() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 60)
    let bare = "https://www.xiaohongshu.com/explore/6af1824c000000003402b751"
    let task = Task { @MainActor in try await relay.capture(urlString: bare, pendingID: UUID()) }
    let deadline = Date().addingTimeInterval(3)
    while relay.waitingJobCount == 0 {
      if Date() > deadline { return XCTFail("代抓任务没有挂上等待") }
      try await Task.sleep(for: .milliseconds(10))
    }
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: [bare], tabID: 7))

    let frame = try JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJobOutcome", "version": 1, "requestId": "o1", "jobID": jobID,
      "finalURL": "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031",
      "reason": "note_unavailable",
    ])
    let body = try forwardThroughHost(frame)
    let outcome = try XCTUnwrap(try BrowserCaptureJobOutcomeRequest.decode(body),
                                "Host 转发上来的不是 outcome 帧")
    XCTAssertEqual(outcome.jobID, jobID)
    XCTAssertEqual(outcome.reason, .noteUnavailable)

    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in },
      browserCaptureJobSink: BrowserCaptureRelayWiring.jobSink(relay),
      browserCaptureDeliverySink: BrowserCaptureRelayWiring.deliverySink(relay),
      browserCaptureOutcomeSink: BrowserCaptureRelayWiring.outcomeSink(relay)
    )
    _ = await receiver.process(body)

    do {
      _ = try await task.value
      XCTFail("Host 送达 outcome 后，排队项应立即失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure.code, "shareLinkMissingToken")
      XCTAssertEqual(failure.underlyingCaptureError?.needsDifferentLink, true)
    }
  }
}
