import Foundation
import XCTest
import LinkDigestCore
import LinkDigestAdapters
import LinkDigestMCPKit
import LinkDigestPersistence
import LinkDigestTransport
@testable import LinkDigestApp

/// MCP 的合集能力（2026-09-29）：`jizuo_collections` 列出合集，`jizuo_search` 的
/// `collection` 参数只取这个合集、按合集顺序。已有工具不带新参数时行为不变。
@MainActor
final class MCPCollectionToolTests: XCTestCase {
  func testResolveCollectionPrefersIDThenExactNameAndRefusesAmbiguousNames() throws {
    let first = HistoryCollectionSummary(id: CollectionID(UUID()), name: "Claude Code 教程", origin: .manual, folderPath: nil, itemCount: 1, createdAtMilliseconds: 1, updatedAtMilliseconds: 1)
    let twinA = HistoryCollectionSummary(id: CollectionID(UUID()), name: "杂项", origin: .manual, folderPath: nil, itemCount: 0, createdAtMilliseconds: 2, updatedAtMilliseconds: 2)
    let twinB = HistoryCollectionSummary(id: CollectionID(UUID()), name: "杂项", origin: .importedFolder, folderPath: "/x", itemCount: 0, createdAtMilliseconds: 3, updatedAtMilliseconds: 3)
    let all = [first, twinA, twinB]
    XCTAssertEqual(try MCPController.resolveCollection(first.id.rawValue.uppercased(), in: all), first)
    XCTAssertEqual(try MCPController.resolveCollection(" Claude Code 教程 ", in: all), first)
    XCTAssertEqual(try MCPController.resolveCollection("claude code 教程", in: all), first)
    XCTAssertEqual(try MCPController.resolveCollection(twinB.id.rawValue, in: all), twinB)
    XCTAssertThrowsError(try MCPController.resolveCollection("杂项", in: all)) {
      XCTAssertEqual(($0 as? MCPFailure)?.code, "ambiguous_collection")
    }
    XCTAssertThrowsError(try MCPController.resolveCollection("没有这个", in: all)) {
      XCTAssertEqual(($0 as? MCPFailure)?.code, "collection_not_found")
    }
  }

  func testCollectionsToolAndCollectionSearchFollowCollectionOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-collection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    let history = HistoryApplicationService(repository: repository)
    func capture(_ slug: String, at milliseconds: Int64) throws -> TaskID {
      try repository.acceptCapture(.init(document: CapturedDocument(
        createdAt: "2026-09-06T00:00:00Z", idempotencyKey: "mcp-collection-\(slug)", origin: .manualLink,
        url: "https://example.test/\(slug)", title: "第\(slug)讲", platform: "web", method: "fixture",
        text: "合集测试正文 \(slug)", completeness: "complete", capturedAt: "2026-09-06T00:00:00Z", sourceLabel: "fixture"
      ), receivedAtMilliseconds: milliseconds)).taskID
    }
    let a = try capture("a", at: 1), b = try capture("b", at: 2), c = try capture("c", at: 3), d = try capture("d", at: 4)
    let outsider = try capture("outsider", at: 5)
    let tutorial = try repository.createCollection(name: "Claude Code 教程")
    try repository.addTasks([c, a, b, d], toCollection: tutorial.id)
    let other = try repository.createCollection(name: "空合集")
    try repository.moveToTrash(taskIDs: [b])

    let suite = "mcp-collection-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let socket = "/tmp/mcpc-\(UUID().uuidString.prefix(12)).sock"
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
    let manual = ManualLinkViewModel(captureService: .init(fetcher: MCPCollectionFixtureFetcher()))
    manual.configure(history: history, storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 2 }, captureSink: { _ in })
    model.configure(history: history, historyModel: historyModel, manual: manual, writable: true)
    model.enabled = true
    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
      let request = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
      let data = await model.handle(request)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func ids(_ response: [String: Any]) -> [String] {
      ((response["items"] as? [[String: Any]]) ?? []).compactMap { $0["task_id"] as? String }
    }

    // 1. 列出合集：id、名称、条数（回收站里的不算）、来源。只读，不需要任何写权限。
    let listed = try await call("jizuo_collections")
    XCTAssertNil(listed["error"])
    let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
    XCTAssertEqual(items.compactMap { $0["collection_id"] as? String }, [tutorial.id.rawValue, other.id.rawValue])
    XCTAssertEqual(items.first?["name"] as? String, "Claude Code 教程")
    XCTAssertEqual(items.first?["count"] as? Int, 3)
    XCTAssertEqual(items.first?["origin"] as? String, "manual")

    // 2. 按名称取合集：按合集顺序，不含回收站里的，也不含合集外的。
    let byName = try await call("jizuo_search", ["collection": "Claude Code 教程"])
    XCTAssertEqual(ids(byName), [c, a, d].map(\.rawValue))
    XCTAssertEqual((byName["collection"] as? [String: Any])?["collection_id"] as? String, tutorial.id.rawValue)
    // 条目字段和原来一样。
    let first = try XCTUnwrap((byName["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(first.keys), ["task_id", "title", "url", "source_host", "platform", "platform_name", "tags", "used", "ownership"])

    // 3. 按 id 分页：游标带着合集位置，一页一页接得上。
    let page1 = try await call("jizuo_search", ["collection": tutorial.id.rawValue, "limit": 2])
    XCTAssertEqual(ids(page1), [c, a].map(\.rawValue))
    let cursor = try XCTUnwrap(page1["next_cursor"] as? String)
    let page2 = try await call("jizuo_search", ["collection": tutorial.id.rawValue, "limit": 2, "cursor": cursor])
    XCTAssertEqual(ids(page2), [d.rawValue])
    XCTAssertTrue(page2["next_cursor"] is NSNull)

    // 4. 合集内再按关键词找。
    let keyword = try await call("jizuo_search", ["collection": "Claude Code 教程", "query": "正文 d"])
    XCTAssertEqual(ids(keyword), [d.rawValue])

    // 5. 找不到、游标对不上，都给出明确的错误。
    let missing = try await call("jizuo_search", ["collection": "不存在的合集"])
    XCTAssertEqual(missing["error"] as? String, "collection_not_found")
    let plainPage = try await call("jizuo_search", ["limit": 1])
    let plainCursor = try XCTUnwrap(plainPage["next_cursor"] as? String)
    let mismatched = try await call("jizuo_search", ["collection": tutorial.id.rawValue, "cursor": plainCursor])
    XCTAssertEqual(mismatched["error"] as? String, "invalid_cursor")

    // 6. 不带 collection 时行为不变：还是按存入时间倒序、全库。
    let plain = try await call("jizuo_search")
    XCTAssertEqual(ids(plain), [outsider, d, c, a].map(\.rawValue))
    XCTAssertNil(plain["collection"])
  }
}

private struct MCPCollectionFixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: url, html: "<article>fixture</article>", contentType: "text/html")
  }
}
