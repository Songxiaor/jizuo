import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
@testable import LinkDigestCore
@testable import LinkDigestPersistence
import LinkDigestMCPKit

/// Agent 补下视频（2026-11-20）：库里登记了视频但文件被「转写后清理」删了、或从没下过，
/// 都要能从原链接重新下回来；本机文件真在的不重下。资料库与媒体都在临时目录，下载是替身。
@MainActor
final class MCPVideoRedownloadTests: XCTestCase {
  private var root: URL!
  private var repository: GRDBHistoryRepository!
  private var store: LocalMediaStore!
  private let bytes = Data("fake-douyin-mp4".utf8)

  override func setUp() async throws {
    try await super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-redownload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    store = LocalMediaStore(applicationSupportRoot: root)
  }

  override func tearDown() async throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func makeCapture() throws -> (TaskID, ContentSnapshotID) {
    let document = CapturedDocument(createdAt: "2026-11-20T00:00:00Z", origin: .manualLink,
      url: "https://www.douyin.com/video/7670917275737705743", title: "补下视频夹具", platform: "douyin", method: "fixture",
      text: "---\nauthor: 栖光\n---\n正文。", completeness: "complete", capturedAt: "2026-11-20T00:00:00Z", sourceLabel: "fixture")
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    return (accepted.taskID, accepted.snapshotID)
  }

  private func attachStoredVideo(taskID: TaskID, snapshotID: ContentSnapshotID) throws -> MediaAsset {
    let stored = try store.storeDetailed(data: bytes, preferredExtension: "mp4")
    let asset = MediaAsset(taskID: taskID, snapshotID: snapshotID, relativePath: stored.relativePath,
                           fileBookmark: stored.fileBookmark, contentSHA256: stored.sha256,
                           byteSize: Int64(bytes.count), platform: "douyin", createdAtMilliseconds: 2)
    try repository.attachMedia(.init(asset: asset))
    return asset
  }

  private func makeModel(downloads: RedownloadCounter) -> HistoryViewModel {
    let mediaStore = store!, data = bytes
    let model = HistoryViewModel(
      mediaStore: mediaStore,
      mediaDownloadOperation: { _, taskID, snapshotID, _ in
        downloads.increment()
        let stored = try mediaStore.storeDetailed(data: data, preferredExtension: "mp4")
        return MediaAsset(taskID: taskID, snapshotID: snapshotID, relativePath: stored.relativePath,
                          fileBookmark: stored.fileBookmark, contentSHA256: stored.sha256,
                          byteSize: Int64(data.count), platform: "douyin", createdAtMilliseconds: 3)
      }
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    return model
  }

  private func directDescriptor() -> MediaDescriptor {
    MediaDescriptor(kind: .directFile, pageURL: "https://www.douyin.com/video/7670917275737705743",
                    canonicalURL: "https://www.douyin.com/video/7670917275737705743", platform: "douyin",
                    ephemeralPlaybackURL: "https://v.example.test/video.mp4", mimeType: "video/mp4",
                    transcriptionCapability: .supported)
  }

  /// 文件被清理、库里还登记着：不能当成「本机有」，补下后文件回到 Media，同一视频不重复建行。
  func testDeletedFileIsReportedMissingAndRedownloaded() async throws {
    let (id, snapshot) = try makeCapture()
    let asset = try attachStoredVideo(taskID: id, snapshotID: snapshot)
    try FileManager.default.removeItem(at: store.absoluteURL(relativePath: asset.relativePath))
    let downloads = RedownloadCounter()
    let model = makeModel(downloads: downloads)
    XCTAssertFalse(model.hasLocalMediaFile(try repository.detail(taskID: id).media), "文件不在就不算本机有视频")

    var queued: [TaskID] = []
    model.onNewCapturedVideoNeedsTranscription = { queued.append($0) }
    var contexts: [HistoryViewModel.VideoSourceContext] = []
    let outcome = await model.redownloadVideoForAgent(taskID: id) { context in
      contexts.append(context); return self.directDescriptor()
    }

    XCTAssertEqual(outcome, .downloaded(needsTranscription: true))
    XCTAssertEqual(downloads.value, 1)
    XCTAssertEqual(contexts.first?.sourceURL, "https://www.douyin.com/video/7670917275737705743")
    XCTAssertEqual(contexts.first?.platform, "douyin")
    let media = try XCTUnwrap(try repository.detail(taskID: id).media)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.absoluteURL(relativePath: media.relativePath).path))
    XCTAssertTrue(model.hasLocalMediaFile(media))
    XCTAssertEqual(try repository.detail(taskID: id).mediaAssets.count, 1, "同一个视频重下不另建一行")
    XCTAssertEqual(queued, [id], "还没转写稿的，交给自动转写队列")
  }

  /// 本机文件真在：直接跳过，不去取直链、不下载。
  func testExistingFileIsSkipped() async throws {
    let (id, snapshot) = try makeCapture()
    _ = try attachStoredVideo(taskID: id, snapshotID: snapshot)
    let downloads = RedownloadCounter()
    let model = makeModel(downloads: downloads)
    var fetched = 0
    let outcome = await model.redownloadVideoForAgent(taskID: id) { _ in fetched += 1; return self.directDescriptor() }
    XCTAssertEqual(outcome, .alreadyLocal)
    XCTAssertEqual(fetched, 0)
    XCTAssertEqual(downloads.value, 0)
  }

  /// 当初没下视频（库里没有视频行）：同样能补下。
  func testRecordWithoutAnyVideoGetsDownloaded() async throws {
    let (id, _) = try makeCapture()
    let downloads = RedownloadCounter()
    let model = makeModel(downloads: downloads)
    XCTAssertNil(try repository.detail(taskID: id).media)
    let outcome = await model.redownloadVideoForAgent(taskID: id) { _ in self.directDescriptor() }
    XCTAssertEqual(outcome, .downloaded(needsTranscription: true))
    XCTAssertTrue(model.hasLocalMediaFile(try repository.detail(taskID: id).media))
  }

  /// 取直链失败、或给的不是能存的直链：如实报失败，不挂空记录。
  func testFetchFailureAndUnsavableStreamAreReported() async throws {
    let (id, _) = try makeCapture()
    let model = makeModel(downloads: RedownloadCounter())
    let failed = await model.redownloadVideoForAgent(taskID: id) { _ in throw SessionMediaRefreshError.networkOrParse }
    XCTAssertEqual(failed, .failed(SessionMediaRefreshError.networkOrParse.userMessage))
    let hls = await model.redownloadVideoForAgent(taskID: id) { _ in
      MediaDescriptor(kind: .hls, pageURL: "https://x.test", canonicalURL: "https://x.test", platform: "douyin",
                      ephemeralPlaybackURL: "https://x.test/a.m3u8", transcriptionCapability: .supported)
    }
    guard case .failed = hls else { return XCTFail("HLS 不能存到本机，应报失败") }
    XCTAssertNil(try repository.detail(taskID: id).media)
  }

  /// 批量：一条一条下，按结果记 status 和转写去向。
  func testBatchReportsEachItem() async throws {
    let a = TaskID(UUID()), b = TaskID(UUID()), c = TaskID(UUID()), d = TaskID(UUID())
    let batch = MCPVideoDownloadBatch(items: [
      .init(rawID: a.rawValue, taskID: a, status: .queued, message: ""),
      .init(rawID: "missing", taskID: nil, status: .failed, message: "记录不存在"),
      .init(rawID: b.rawValue, taskID: b, status: .queued, message: ""),
      .init(rawID: c.rawValue, taskID: c, status: .queued, message: ""),
      .init(rawID: d.rawValue, taskID: d, status: .queued, message: ""),
    ])
    var order: [TaskID] = []
    batch.start(autoTranscribe: true) { id in
      order.append(id)
      switch id {
      case a: return .downloaded(needsTranscription: false)
      case b: return .alreadyLocal
      case c: return .failed("链接失效")
      default: return .downloaded(needsTranscription: true)
      }
    }
    for _ in 0..<200 where batch.isActive { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(order, [a, b, c, d])
    let result = batch.result()
    XCTAssertEqual(result["is_terminal"] as? Bool, true)
    let items = try XCTUnwrap(result["items"] as? [[String: Any]])
    XCTAssertEqual(items.map { $0["status"] as? String }, ["downloaded", "failed", "already_local", "failed", "downloaded"])
    XCTAssertEqual(items.map { $0["transcription"] as? String }, ["already_transcribed", "none", "none", "none", "auto_queued"])
    XCTAssertEqual(items[3]["message"] as? String, "链接失效")
  }

  func testToolsAreRegistered() throws {
    XCTAssertNoThrow(try MCPTools.validate(name: "jizuo_download_videos", arguments: ["task_ids": (0..<20).map { "t\($0)" }]))
    XCTAssertThrowsError(try MCPTools.validate(name: "jizuo_download_videos", arguments: ["task_ids": (0..<21).map { "t\($0)" }]))
    XCTAssertThrowsError(try MCPTools.validate(name: "jizuo_download_videos_status", arguments: [:]))
  }
}

final class RedownloadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
