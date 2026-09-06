import Foundation
import XCTest
import LinkDigestCore
import LinkDigestAdapters
import LinkDigestPersistence
import LinkDigestTransport
@testable import LinkDigestApp

@MainActor
final class MCPControllerTests: XCTestCase {
  func testPlatformAliasesAndStructuredTranscriptionStates() {
    XCTAssertEqual(MCPController.platformKey("twitter.com"), "x.com")
    XCTAssertEqual(MCPController.platformKey("www.douyin.com"), "douyin.com")
    XCTAssertEqual(MCPController.platformKey("linux.do"), "discourse")
    XCTAssertEqual(MCPController.platformKey("author.substack.com"), "substack.com")
    let completed = MCPController.transcriptionStatus(.idle, persisted: .completed)
    XCTAssertEqual(completed["status"] as? String, "completed")
    XCTAssertEqual(completed["is_terminal"] as? Bool, true)
    let interrupted = MCPController.transcriptionStatus(.idle, persisted: .running)
    XCTAssertEqual(interrupted["status"] as? String, "interrupted")
    XCTAssertEqual(interrupted["needs_user_action"] as? Bool, true)
    let waiting = MCPController.transcriptionStatus(.awaitingModelDownload, persisted: .pending)
    XCTAssertEqual(waiting["needs_user_action"] as? Bool, true)
    XCTAssertEqual(waiting["is_terminal"] as? Bool, false)
    XCTAssertEqual(MCPController.transcriptionStatus(.idle, persisted: nil)["status"] as? String, "no_local_media")
    XCTAssertEqual(MCPController.transcriptionStatus(.idle, persisted: .some(.none))["status"] as? String, "not_started")
  }

  func testPermissionsSearchAndMutationThroughRealLocalTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    let history = HistoryApplicationService(repository: repository)
    let document = CapturedDocument(createdAt: "2026-09-06T00:00:00Z", origin: .manualLink,
      url: "https://example.test/mcp-fixture", title: "MCP夹具", platform: "web", method: "fixture",
      text: "这是一段测试正文，不属于用户资料。", completeness: "complete", capturedAt: "2026-09-06T00:00:00Z", sourceLabel: "fixture")
    let id = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1)).taskID
    let suite = "mcp-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    // Keep the pathname below Darwin's 104 byte limit.
    let socket = "/tmp/mcp-\(UUID().uuidString.prefix(12)).sock"
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
    let manual = ManualLinkViewModel(captureService: .init(fetcher: MCPFixtureFetcher()))
    manual.configure(history: history, storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 2 }, captureSink: { _ in })
    model.configure(history: history, historyModel: historyModel, manual: manual, writable: true)
    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
      let request = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
      let data = await model.handle(request)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let disabled = try await call("jizuo_status")
    XCTAssertEqual(disabled["error"] as? String, "disabled")
    model.enabled = true
    let attrs = try FileManager.default.attributesOfItem(atPath: socket)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let request = Data("{\"name\":\"jizuo_status\",\"arguments\":{}}".utf8)
    let data = try await Task.detached { try UnixSocketClient.send(request, path: socket) }.value
    let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(status["connected"] as? Bool, true)
    let search = try await call("jizuo_search", ["query": "MCP夹具"])
    let rows = try XCTUnwrap(search["items"] as? [[String: Any]])
    XCTAssertEqual(rows.first?["task_id"] as? String, id.rawValue)
    XCTAssertNil(rows.first?["body"])
    XCTAssertEqual(rows.first?["platform"] as? String, "__misc__")
    XCTAssertEqual(rows.first?["platform_name"] as? String, "待分类")
    let denied = try await call("jizuo_add_tags", ["task_id": id.rawValue, "tags": ["MCP"]])
    XCTAssertEqual(denied["error"] as? String, "permission_required")
    XCTAssertTrue(try history.detail(taskID: id).tags.isEmpty)
    model.allowsChanges = true
    let tagged = try await call("jizuo_add_tags", ["task_id": id.rawValue, "tags": ["MCP"]])
    XCTAssertNil(tagged["error"])
    XCTAssertEqual(try history.detail(taskID: id).tags.map(\.name), ["MCP"])
    let submitted = try await call("jizuo_add_links", ["urls": ["https://example.org/mcp-short"]])
    XCTAssertEqual((submitted["items"] as? [[String: String]])?.first?["status"], "queued")
    for _ in 0..<100 {
      if manual.pendingCaptures.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let captured = try await call("jizuo_capture_status", ["urls": ["https://example.org/mcp-short"]])
    let capturedItem = try XCTUnwrap((captured["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(capturedItem["status"] as? String, "saved")
    XCTAssertEqual(capturedItem["saved"] as? Bool, true)
    XCTAssertEqual(capturedItem["download_status"] as? String, "not_requested")
    XCTAssertEqual(capturedItem["is_terminal"] as? Bool, true)
    let stats = try await call("jizuo_statistics")
    XCTAssertEqual(stats["total"] as? Int, 2)
    XCTAssertEqual(stats["category_count"] as? Int, 1)
    XCTAssertEqual(stats["known_platform_count"] as? Int, 0)
    let platforms = try XCTUnwrap(stats["platforms"] as? [[String: Any]])
    XCTAssertEqual(platforms.first?["count"] as? Int, 2)
    let unknown = try await call("jizuo_capture_status", ["urls": ["https://example.org/not-submitted"]])
    let unknownItem = try XCTUnwrap((unknown["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(unknownItem["is_terminal"] as? Bool, false)
    XCTAssertEqual(unknownItem["saved"] as? Bool, false)
    let capturedID = try XCTUnwrap((capturedItem["task_id"] as? String).flatMap(TaskID.init))
    XCTAssertEqual(try history.detail(taskID: capturedID).task.canonicalURL, "https://example.org/mcp-final")
    let repeated = try await call("jizuo_add_links", ["urls": ["https://example.org/mcp-short"]])
    XCTAssertEqual((repeated["items"] as? [[String: String]])?.first?["status"], "already_saved")
    let processingDenied = try await call("jizuo_transcribe", ["task_id": id.rawValue])
    XCTAssertEqual(processingDenied["error"] as? String, "permission_required")
    let read = try await call("jizuo_read", ["task_id": id.rawValue, "offset": 0, "limit": 4])
    XCTAssertEqual(read["body"] as? String, "这是一段")
    model.enabled = false
    XCTAssertFalse(UnixSocketClient.canConnect(path: socket))
    let revoked = try await call("jizuo_read", ["task_id": id.rawValue])
    XCTAssertEqual(revoked["error"] as? String, "disabled")
  }
}

private struct MCPFixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: URL(string: "https://example.org/mcp-final")!, html: "<article>MCP fixture article provides enough words to exercise the actual capture queue and persistence pipeline without contacting any website.</article>", contentType: "text/html")
  }
}
