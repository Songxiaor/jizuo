import Foundation
import XCTest
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestAdapters
@testable import LinkDigestApp

@MainActor
final class MCPTranscriptionBatchTests: XCTestCase {
  private func waitUntilTerminal(_ batch: MCPTranscriptionBatch) async throws {
    for _ in 0..<200 where batch.isActive { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(batch.isActive)
  }

  /// 一条一条转，结果按条记下；跳过的不送去转写，整批结束后回调一次。
  func testBatchRunsQueuedItemsInOrderAndReportsEachOutcome() async throws {
    let a = TaskID(UUID()), b = TaskID(UUID()), c = TaskID(UUID())
    let batch = MCPTranscriptionBatch(items: [
      .init(rawID: a.rawValue, taskID: a, status: .queued, message: ""),
      .init(rawID: "missing", taskID: nil, status: .skipped, message: "记录不存在"),
      .init(rawID: b.rawValue, taskID: b, status: .queued, message: ""),
      .init(rawID: c.rawValue, taskID: c, status: .queued, message: ""),
    ])
    var order: [TaskID] = [], finished = 0
    batch.start { id in
      order.append(id)
      switch id { case a: return .completed; case b: return .failed("坏文件"); default: return .alreadyTranscribed }
    } finished: { finished += 1 }
    try await waitUntilTerminal(batch)
    XCTAssertEqual(order, [a, b, c])
    XCTAssertEqual(finished, 1)
    let result = batch.result(HistoryViewModel())
    XCTAssertEqual(result["is_terminal"] as? Bool, true)
    let items = try XCTUnwrap(result["items"] as? [[String: Any]])
    XCTAssertEqual(items.map { $0["status"] as? String }, ["completed", "skipped", "failed", "skipped"])
    XCTAssertEqual(items[2]["message"] as? String, "坏文件")
    XCTAssertEqual((result["counts"] as? [String: Int])?["skipped"], 2)
  }

  /// 停止：正在转的那条收到取消，后面排着的标成 cancelled，不再送去转写。
  func testStopCancelsRunningItemAndLeavesTheRestUntouched() async throws {
    let a = TaskID(UUID()), b = TaskID(UUID())
    let batch = MCPTranscriptionBatch(items: [
      .init(rawID: a.rawValue, taskID: a, status: .queued, message: ""),
      .init(rawID: b.rawValue, taskID: b, status: .queued, message: ""),
    ])
    var started: [TaskID] = []
    batch.start { id in
      started.append(id)
      try? await Task.sleep(for: .seconds(30))
      return Task.isCancelled ? .cancelled : .completed
    } finished: {}
    for _ in 0..<100 where started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual((batch.result(HistoryViewModel())["items"] as? [[String: Any]])?.first?["status"] as? String, "running")
    batch.stop()
    try await waitUntilTerminal(batch)
    XCTAssertEqual(started, [a])
    let result = batch.result(HistoryViewModel())
    XCTAssertEqual(result["stopped"] as? Bool, true)
    XCTAssertEqual((result["items"] as? [[String: Any]])?.map { $0["status"] as? String }, ["cancelled", "cancelled"])
  }

  /// 走真实入口：没有本机音视频、记录不存在、重复的 ID 都在提交时跳过，整批立刻结束；查错 batch_id 报不存在。
  func testControllerSkipsItemsWithoutLocalMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-batch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    let history = HistoryApplicationService(repository: repository)
    let document = CapturedDocument(createdAt: "2026-10-29T00:00:00Z", origin: .manualLink,
      url: "https://example.test/mcp-batch", title: "批量转写夹具", platform: "web", method: "fixture",
      text: "测试正文。", completeness: "complete", capturedAt: "2026-10-29T00:00:00Z", sourceLabel: "fixture")
    let id = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1)).taskID
    let suite = "mcp-batch-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "mcp.enabled"); defaults.set(true, forKey: "mcp.processing")
    let socket = "/tmp/mcpb-\(UUID().uuidString.prefix(12)).sock"
    let model = MCPController(defaults: defaults, socketPath: socket)
    defer {
      model.enabled = false
      defaults.removePersistentDomain(forName: suite)
      try? repository.database.close()
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(atPath: socket + ".lock")
    }
    let historyModel = HistoryViewModel()
    historyModel.configure(history: history, isReadOnly: false, unavailableCode: nil)
    let manual = ManualLinkViewModel(captureService: .init(fetcher: BatchFixtureFetcher()))
    model.configure(history: history, historyModel: historyModel, manual: manual, writable: true)
    func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
      let data = await model.handle(try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments]))
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let submitted = try await call("jizuo_transcribe_batch", ["task_ids": [id.rawValue, "not-a-task", id.rawValue]])
    XCTAssertNil(submitted["error"])
    XCTAssertEqual(submitted["is_terminal"] as? Bool, true)
    let items = try XCTUnwrap(submitted["items"] as? [[String: Any]])
    XCTAssertEqual(items.map { $0["task_id"] as? String }, [id.rawValue, "not-a-task"])
    XCTAssertEqual(items.map { $0["status"] as? String }, ["skipped", "skipped"])
    let batchID = try XCTUnwrap(submitted["batch_id"] as? String)
    let status = try await call("jizuo_transcribe_batch_status", ["batch_id": batchID])
    XCTAssertEqual(status["batch_id"] as? String, batchID)
    let missing = try await call("jizuo_transcribe_batch_status", ["batch_id": "nope"])
    XCTAssertEqual(missing["error"] as? String, "batch_not_found")
  }

  /// capture_status 拿规范链接也能认出按带 xsec_token 的抓取链接排着的小红书作品。
  func testPendingCaptureMatchesCanonicalWorkURL() throws {
    let capture = "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000001?xsec_token=ABC&xsec_source=pc_user"
    let pending = ManualLinkViewModel.PendingCapture(id: UUID(), urlString: capture, phase: .queued)
    let canonical = try XCTUnwrap(URL(string: "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000001"))
    XCTAssertEqual(MCPController.pendingCapture(for: canonical, in: [pending])?.urlString, capture)
    let other = try XCTUnwrap(URL(string: "https://www.xiaohongshu.com/explore/6650a1b2c3d4e5f600000002"))
    XCTAssertNil(MCPController.pendingCapture(for: other, in: [pending]))
    XCTAssertNil(MCPController.pendingCapture(for: try XCTUnwrap(URL(string: "https://example.org/a")), in: [pending]))
  }

  /// 发现候选带上发布时间和互动数，没有的给 null，数字保持页面原样。
  func testDiscoveryItemCarriesMetadataAndNulls() throws {
    let candidate = DouyinProfileImportCandidate(
      workID: "w1", authorID: "a1", canonicalURL: "https://www.douyin.com/video/1", previewText: "标题",
      coverURL: URL(string: "https://p3-pc.douyinpic.com/c.jpeg"), publishedText: "3天前", wasAlreadySaved: false,
      likes: "1.2万", comments: "88")
    let item = MCPController.discoveryItem(candidate)
    XCTAssertEqual(item["likes"] as? String, "1.2万")
    XCTAssertEqual(item["comments"] as? String, "88")
    XCTAssertEqual(item["published_text"] as? String, "3天前")
    XCTAssertEqual(item["cover_url"] as? String, "https://p3-pc.douyinpic.com/c.jpeg")
    XCTAssertTrue(item["collects"] is NSNull)
    XCTAssertTrue(item["views"] is NSNull)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(item))
  }
}

private struct BatchFixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult { throw CocoaError(.featureUnsupported) }
}
