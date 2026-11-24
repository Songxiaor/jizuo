import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 代抓会话簿：一次任务从打开标签、被扩展认领、送回内容，到失败/超时/取消的全过程。
@MainActor
final class BrowserCaptureRelayTests: XCTestCase {
  private final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var current: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
  }

  private func envelope(jobID: String, url: String = "https://www.douyin.com/video/7420000000000000001") throws -> CaptureWireEnvelope {
    let object: [String: Any] = [
      "version": 1,
      "requestId": "capture-\(jobID)",
      "createdAt": "2026-11-19T00:00:00Z",
      "captureJobID": jobID,
      "source": ["kind": "browser_capture", "url": url, "title": "示例作品", "platform": "douyin"],
      "capture": [
        "method": "rendered_dom", "text": "示例正文", "characterCount": 4,
        "completeness": "full_article", "capturedAt": "2026-11-19T00:00:00Z",
      ],
      "evidence": ["sourceLabel": "test", "usedCookie": false],
    ]
    return try CaptureWireEnvelope.decode(try JSONSerialization.data(withJSONObject: object))
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

  func testCapturedContentResumesTheWaitingCaptureAndJobIsOneShot() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true))
    let pendingID = UUID()
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/abc", pendingID: pendingID)
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: ["https://v.douyin.com/abc"], tabID: 7))

    XCTAssertTrue(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID)))
    let relayed = try await task.value
    XCTAssertEqual(relayed.document.url, "https://www.douyin.com/video/7420000000000000001")
    XCTAssertEqual(relayed.document.text, "示例正文")
    XCTAssertEqual(relay.activeJobCount, 0)

    // 同一个 job 只认一次：迟到的重复送回不能再唤走另一条排队。
    XCTAssertFalse(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID)))
  }

  func testClaimRequiresMatchingURL() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true))
    let pendingID = UUID()
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://www.xiaohongshu.com/explore/66aa00bb", pendingID: pendingID)
    }
    try await waitUntil { relay.waitingJobCount == 1 }

    XCTAssertNil(relay.claimJob(candidateURLs: ["https://www.xiaohongshu.com/explore/other"], tabID: 7))
    XCTAssertNil(relay.claimJob(candidateURLs: ["https://example.test/article"], tabID: 7))
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: [
      "https://www.xiaohongshu.com/discovery/item/66aa00bb?xsec_token=xyz",
    ], tabID: 7))
    XCTAssertTrue(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID, url: "https://www.xiaohongshu.com/discovery/item/66aa00bb")))
    _ = try await task.value
  }

  func testTimeoutWithoutAnyClaimBlamesTheExtension() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 0.15)
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://www.douyin.com/video/7420000000000000001", pendingID: UUID())
    }
    do {
      _ = try await task.value
      XCTFail("没有扩展来认领时应超时失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .extensionNotConnected)
    }
  }

  func testTimeoutAfterClaimBlamesThePage() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 0.15)
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://www.douyin.com/video/7420000000000000001", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    XCTAssertNotNil(relay.claimJob(candidateURLs: ["https://www.douyin.com/video/7420000000000000001"], tabID: 7))
    do {
      _ = try await task.value
      XCTFail("认领之后没有内容也应超时失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .timedOut)
    }
  }

  func testNoBrowserFailsImmediatelyWithoutOpeningAnything() async throws {
    let opens = SendableBox<Int>(0)
    let launcher = BrowserCaptureLauncher(
      homeRoot: URL(fileURLWithPath: "/nonexistent"),
      applicationRoots: [URL(fileURLWithPath: "/nonexistent")],
      open: { _, _ in
        opens.mutate { $0 += 1 }
        return true
      },
      forcedBrowser: nil
    )
    let relay = BrowserCaptureRelay(launcher: launcher)
    do {
      _ = try await relay.capture(urlString: "https://v.douyin.com/x", pendingID: UUID())
      XCTFail("没有浏览器应立刻失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .browserUnavailable)
    }
    XCTAssertEqual(opens.value, 0)
  }

  func testCancellingTheWaitingCaptureDropsTheJob() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true))
    let pendingID = UUID()
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/cancel", pendingID: pendingID)
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    relay.cancel(pendingID: pendingID)
    do {
      _ = try await task.value
      XCTFail("取消后应立刻结束")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .cancelled)
    }
    XCTAssertEqual(relay.activeJobCount, 0)
  }

  func testExpiredJobIsNotClaimable() async throws {
    let now = MutableNow(Date(timeIntervalSince1970: 1_000))
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 600, now: { now.current })
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/old", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    now.advance(BrowserCaptureRelay.jobLifetime + 1)
    XCTAssertNil(relay.claimJob(candidateURLs: ["https://v.douyin.com/old"], tabID: 7))
    do {
      _ = try await task.value
      XCTFail("过期任务应结束等待")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .timedOut)
    }
  }
  @MainActor
  func testOnlyTheAskingTabCanClaimTheJob() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true))
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/abc", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }

    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: ["https://v.douyin.com/abc"], tabID: 7))
    // 用户自己开着的同地址标签来问，不能拿到同一个 job——否则同一条会存两遍。
    XCTAssertNil(relay.claimJob(candidateURLs: ["https://v.douyin.com/abc"], tabID: 9))
    // 认领它的那个标签可以重试（抓取失败后再问一次）。
    XCTAssertEqual(relay.claimJob(candidateURLs: ["https://v.douyin.com/abc"], tabID: 7), jobID)

    XCTAssertTrue(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID)))
    _ = try await task.value
  }

  @MainActor
  func testHostsOutsideTheWhitelistFailFastWithoutOpeningATab() async throws {
    let opened = SendableBox<[String]>([])
    let launcher = BrowserCaptureLauncher(
      homeRoot: URL(fileURLWithPath: "/nonexistent"),
      applicationRoots: [URL(fileURLWithPath: "/nonexistent")],
      open: { _, url in
        opened.mutate { $0.append(url) }
        return true
      },
      forcedBrowser: .ego
    )
    let relay = BrowserCaptureRelay(launcher: launcher)
    do {
      _ = try await relay.capture(urlString: "https://example.test/private", pendingID: UUID())
      XCTFail("名单外的站点应立刻失败，不该开标签等超时")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .permissionMissing(host: "example.test"))
    }
    XCTAssertEqual(opened.value, [])
    XCTAssertEqual(relay.activeJobCount, 0)
  }

  @MainActor
  func testRelayTabIsOpenedWithTheMarkerSoTheExtensionCanRecogniseIt() async throws {
    let opened = SendableBox<[String]>([])
    let launcher = BrowserCaptureLauncher(
      homeRoot: URL(fileURLWithPath: "/nonexistent"),
      applicationRoots: [URL(fileURLWithPath: "/nonexistent")],
      open: { _, url in
        opened.mutate { $0.append(url) }
        return true
      },
      forcedBrowser: .ego
    )
    let relay = BrowserCaptureRelay(launcher: launcher)
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/abc", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    XCTAssertEqual(opened.value, ["https://v.douyin.com/abc#jizuo-relay"])
    let jobID = try XCTUnwrap(relay.claimJob(candidateURLs: ["https://v.douyin.com/abc"], tabID: 7))
    XCTAssertTrue(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID)))
    _ = try await task.value
  }

  @MainActor
  func testBlockedLandingOnBareXiaohongshuLinkBlamesTheMissingAccessToken() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 5)
    let task = Task { @MainActor in
      try await relay.capture(
        urlString: "https://www.xiaohongshu.com/explore/6af1824c000000003402b751",
        pendingID: UUID()
      )
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    let jobID = try XCTUnwrap(relay.claimJob(
      candidateURLs: ["https://www.xiaohongshu.com/explore/6af1824c000000003402b751"], tabID: 7
    ))
    XCTAssertTrue(relay.reportBlocked(
      jobID: jobID,
      reason: .noteUnavailable,
      finalURL: "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031"
    ))
    do {
      _ = try await task.value
      XCTFail("平台错误页应当立刻失败，而不是继续等待")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure, .blocked(.shareLinkMissingToken, landing: "www.xiaohongshu.com/404"))
      XCTAssertEqual(failure.code, "shareLinkMissingToken")
      XCTAssertEqual(failure.underlyingCaptureError, .shareLinkMissingToken)
      XCTAssertEqual(failure.underlyingCaptureError?.needsDifferentLink, true)
      XCTAssertTrue(failure.userMessage.contains("访问码"), failure.userMessage)
      XCTAssertFalse(failure.userMessage.contains("扩展没有连上"))
    }
    XCTAssertEqual(relay.activeJobCount, 0)
  }

  @MainActor
  func testBlockedLandingOnTokenisedLinkMeansTheNoteIsGone() {
    XCTAssertEqual(
      BrowserCaptureRelay.captureError(
        for: .noteUnavailable,
        jobURL: "https://www.xiaohongshu.com/explore/6af1824c000000003402b751?xsec_token=abc"
      ),
      .shareLinkExpired
    )
    XCTAssertEqual(
      BrowserCaptureRelay.captureError(
        for: .verificationRequired,
        jobURL: "https://www.douyin.com/video/7420000000000000001"
      ),
      .verificationRequired
    )
    XCTAssertEqual(
      BrowserCaptureRelay.captureError(for: .notFound, jobURL: "https://example.test/a"),
      .invalidPageResult
    )
  }

  @MainActor
  func testQueryWithoutMatchIsNotReportedAsExtensionUnreachable() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true), timeout: 0.15)
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/abc", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    // 扩展来问过（例如短链跳转后地址完全变了），但对不上这一单。
    XCTAssertNil(relay.claimJob(candidateURLs: ["https://www.douyin.com/video/999"], tabID: 7))
    do {
      _ = try await task.value
      XCTFail("应超时失败")
    } catch let failure as BrowserCaptureRelayFailure {
      XCTAssertEqual(failure.code, "browser_capture_target_unmatched")
      guard case let .targetNotMatched(landing) = failure else {
        return XCTFail("\(failure)")
      }
      XCTAssertEqual(landing, "www.douyin.com/video/999")
      XCTAssertTrue(failure.userMessage.contains("没有找到对应的抓取任务"))
      XCTAssertFalse(failure.userMessage.contains("扩展没有连上"))
    }
  }

  @MainActor
  func testMarkedRelayTabCanClaimTheSingleWaitingJobWhenRedirectsHideTheURL() async throws {
    let relay = BrowserCaptureRelay(launcher: .stub(available: true))
    let task = Task { @MainActor in
      try await relay.capture(urlString: "https://v.douyin.com/abc", pendingID: UUID())
    }
    try await waitUntil { relay.waitingJobCount == 1 }
    // 地址对不上、又是唯一的等待项：带标记的标签可以直接认领。
    let jobID = try XCTUnwrap(relay.claimJob(
      candidateURLs: ["https://www.douyin.com/video/7420000000000000001"],
      tabID: 7,
      allowsRelayTabFallback: true
    ))
    XCTAssertTrue(relay.deliver(jobID: jobID, envelope: try envelope(jobID: jobID)))
    _ = try await task.value
  }

}

/// 测试里从闭包改一个计数：Sendable 只要求线程安全，不要求不可变。
final class SendableBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
