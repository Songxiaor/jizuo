import Foundation
import XCTest
import Darwin
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 真机实录：拉一个正在播的抖音直播间，录 2 分多钟，中途杀一次 ffmpeg，
/// 验证重新取地址续录、分段合并、成品可完整解码。
///
/// 默认跳过（会跑 3–5 分钟、需要网络）。显式运行时：
/// `LINKDIGEST_RUN_LIVE_E2E=1 swift test --filter LiveRecordingE2ETests`
@MainActor
final class LiveRecordingE2ETests: XCTestCase {
  /// 抖音连续请求会弹验证码中间页时，用一份已解析好的房间快照跑「断线续录 + 合并」。
  /// 快照只含地址和档位，不含 Cookie；签名地址只在本进程内存里。
  @MainActor
  private final class StaticLiveRoomFetcher: LiveRoomFetching {
    let room: DouyinLiveRoom
    init(room: DouyinLiveRoom) { self.room = room }
    func fetchRoom(
      platform: LiveRecordingPlatform,
      pageURL: String,
      userAgent: String,
      referer: String
    ) async throws -> DouyinLiveRoom {
      room
    }
  }

  private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    func add(_ pid: Int32) { lock.withLock { pids.append(pid) } }
    var first: Int32? { lock.withLock { pids.first } }
    var count: Int { lock.withLock { pids.count } }
  }

  func testRecordsThroughOneDisconnectAndMergesPlayableFile() async throws {
    guard ProcessInfo.processInfo.environment["LINKDIGEST_RUN_LIVE_E2E"] == "1" else {
      throw XCTSkip("设 LINKDIGEST_RUN_LIVE_E2E=1 才跑真机实录")
    }
    let pageURL = ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_PAGE_URL"]
      ?? "https://live.douyin.com/427518068747"
    let ffmpeg = try FFmpegLocator.requireExecutable()
    let fetcher: any LiveRoomFetching = try Self.fetcherFromSnapshotIfRequested() ?? FallbackLiveRoomFetcher()
    let platform: LiveRecordingPlatform = XiaohongshuLivePageParser.roomID(fromPageURL: pageURL) != nil
      ? .xiaohongshu
      : .douyin
    let room = try await fetcher.fetchRoom(
      platform: platform,
      pageURL: pageURL,
      userAgent: LiveRecordingRequest.defaultUserAgent,
      referer: platform == .xiaohongshu
        ? "https://www.xiaohongshu.com/"
        : LiveRecordingRequest.defaultReferer
    )
    XCTAssertFalse(room.variants.isEmpty)
    let request = LiveRecordingRequest(
      requestId: UUID().uuidString,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      platform: platform,
      pageURL: pageURL,
      roomID: room.roomID,
      anchorName: room.anchorName,
      title: room.title,
      quality: .origin,
      variants: room.variants
    )
    guard request.selectedVariant() != nil else {
      throw XCTSkip("这场没有可用的原画 HLS 地址")
    }

    // 每次运行用独立子目录：之前固定用 /tmp/linkdigest-live-e2e 并在开头删除，
    // 第二次跑 E2E 会把上一次的产物一起清掉（2026-11-11 验收踩到）。
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let platformName = platform == .douyin ? "douyin" : "xiaohongshu"
    let root: URL = {
      if let override = ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_E2E_ROOT"],
         !override.trimmingCharacters(in: .whitespaces).isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
      }
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("linkdigest-live-e2e", isDirectory: true)
        .appendingPathComponent("\(platformName)-\(stamp)", isDirectory: true)
    }()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let preferences = LiveRecordingPreferences(
      defaults: UserDefaults(suiteName: "linkdigest.live.e2e")!,
      applicationSupportRoot: root
    )
    preferences.setDirectory(nil)

    let box = PIDBox()
    let controller = LiveRecordingController(
      preferences: preferences,
      ffmpegURL: ffmpeg,
      fetcher: fetcher,
      makeRunner: {
        let runner = FFmpegProcessRunner()
        runner.onLaunch = { pid in box.add(pid) }
        return runner
      }
    )
    guard case let .accepted(recordingID) = controller.start(request) else {
      return XCTFail("录制没有被受理")
    }

    // 录到 20 秒时人为杀掉第一个 ffmpeg，模拟断线。
    var killed = false
    // 断线重连要重新加载页面（小红书约 10–15 秒），多录一点，保证成片仍有 2 分钟以上。
    let recordDeadline = Date().addingTimeInterval(240)
    while Date() < recordDeadline {
      try await Task.sleep(for: .seconds(2))
      guard let item = controller.items.first(where: { $0.id == recordingID }) else {
        return XCTFail("录制条目消失了")
      }
      if case let .failed(message) = item.phase {
        return XCTFail("录制提前失败：\(message)")
      }
      if !killed, item.elapsed >= 20, let pid = box.first {
        killed = kill(pid, SIGTERM) == 0
        NSLog("live-e2e: killed ffmpeg pid \(pid) at \(Int(item.elapsed))s")
      }
      if item.elapsed >= 150 { break }
    }
    XCTAssertTrue(killed, "没有在录制中途杀到 ffmpeg")
    XCTAssertGreaterThanOrEqual(box.count, 2, "断线后应重新起一段 ffmpeg")

    controller.stop(recordingID)
    let finishDeadline = Date().addingTimeInterval(180)
    while Date() < finishDeadline {
      guard let item = controller.items.first(where: { $0.id == recordingID }) else { break }
      switch item.phase {
      case .completed, .failed:
        break
      default:
        try await Task.sleep(for: .seconds(2))
        continue
      }
      break
    }

    let item = try XCTUnwrap(controller.items.first(where: { $0.id == recordingID }))
    guard case .completed = item.phase else {
      return XCTFail("录制没有完成：\(item.phase) \(item.failureMessage ?? "")")
    }
    XCTAssertGreaterThanOrEqual(item.segmentCount, 2, "应至少包含断线前后的两段")
    let file = try XCTUnwrap(item.fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

    // 全片解码：0 错误才算成品可用。
    let decode = try runTool(
      executable: ffmpeg,
      arguments: ["-hide_banner", "-v", "error", "-i", file.path, "-f", "null", "-"]
    )
    XCTAssertEqual(decode.status, 0)
    // 小红书原画 FLV 的时间戳本身有重复（开发 B 的验证报告也记录了这一条），
    // 这是封装问题、不是解码错误；其余任何输出都算错误。
    let decodeErrors = decode.stderr
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .filter { !$0.contains("non monotonically increasing dts") }
    XCTAssertTrue(decodeErrors.isEmpty, "解码有错误：\(decodeErrors.joined(separator: "\n"))")

    let probe = try runTool(
      executable: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"),
      arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path]
    )
    XCTAssertEqual(probe.status, 0)
    let duration = Double(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    XCTAssertGreaterThan(duration, 120, "合并后应超过 2 分钟")
    NSLog("live-e2e: file=\(file.path) duration=\(duration) segments=\(item.segmentCount)")
  }

  @MainActor
  private static func fetcherFromSnapshotIfRequested() throws -> (any LiveRoomFetching)? {
    guard let path = ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_VARIANTS_JSON"] else { return nil }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let pageURL = object["pageURL"] as? String,
          let roomID = object["roomID"] as? String,
          let rows = object["variants"] as? [[String: Any]]
    else { throw LiveRoomFetchError.unavailable }
    let variants = rows.compactMap { row -> LiveStreamVariant? in
      guard let qualityRaw = row["quality"] as? String,
            let quality = LiveQuality(rawValue: qualityRaw),
            let containerRaw = row["container"] as? String,
            let container = LiveStreamContainer(rawValue: containerRaw),
            let url = row["url"] as? String
      else { return nil }
      return LiveStreamVariant(quality: quality, container: container, url: url)
    }
    let room = DouyinLiveRoom(
      pageURL: pageURL,
      roomID: roomID,
      anchorName: object["anchorName"] as? String,
      title: object["title"] as? String,
      variants: variants
    )
    return StaticLiveRoomFetcher(room: room)
  }

  private func runTool(executable: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // ffmpeg 输出可能很大，先读干管道再等退出，避免死锁。
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: outData, as: UTF8.self),
      String(decoding: errData, as: UTF8.self)
    )
  }
}
