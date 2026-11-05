import Foundation
import XCTest
import LinkDigestCore
import LinkDigestAdapters
import LinkDigestMCPKit
import LinkDigestPersistence
@testable import LinkDigestApp

/// 2026-11-05：给 MCP 补齐「读元数据、整理、编辑」这批小工具。
/// 这组测试在真实临时库上走一遍读写，确认不是只在协议层列了个名字。
@MainActor
final class MCPNewToolsTests: XCTestCase {
  func testMetadataFiltersAndMutations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-new-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    let history = HistoryApplicationService(repository: repository)

    func capture(_ slug: String, _ url: String, _ title: String, _ text: String, at milliseconds: Int64) throws -> TaskID {
      try repository.acceptCapture(.init(document: CapturedDocument(
        createdAt: "2026-09-06T00:00:00Z", idempotencyKey: "mcp-new-\(slug)", origin: .manualLink,
        url: url, title: title, platform: "web", method: "fixture",
        text: text, completeness: "complete", capturedAt: "2026-09-06T00:00:00Z", sourceLabel: "fixture"
      ), receivedAtMilliseconds: milliseconds)).taskID
    }

    let xPost = try capture("x", "https://x.com/someone/status/1", "X 帖子", "这是一条外部帖子", at: 1)
    let web = try capture("web", "https://example.test/article", "网页", "这是一篇网页", at: 2)
    _ = try repository.addTags(["观点"], to: xPost)
    try repository.setFavorite(true, for: xPost)

    let suite = "mcp-new-tools-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let socket = "/tmp/mcpn-\(UUID().uuidString.prefix(12)).sock"
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
    let manual = ManualLinkViewModel(captureService: .init(fetcher: MCPNewToolsFixtureFetcher()))
    manual.configure(history: history, storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 2 }, captureSink: { _ in })
    model.configure(history: history, historyModel: historyModel, manual: manual, writable: true)
    model.allowsChanges = true
    model.allowsProcessing = true
    model.enabled = true

    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
      let request = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
      let data = await model.handle(request)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // 1. 读元数据：标题、标签、素材类型、归属、收藏都读得到。
    let record = try await call("jizuo_get_record", ["task_id": xPost.rawValue])
    XCTAssertNil(record["error"])
    XCTAssertEqual(record["title"] as? String, "X 帖子")
    XCTAssertEqual((record["tags"] as? [Any])?.compactMap { $0 as? String }, ["观点"])
    XCTAssertEqual(record["material_type"] as? String, "观点")
    XCTAssertEqual(record["ownership"] as? String, "外部")
    XCTAssertEqual(record["favorite"] as? Bool, true)
    XCTAssertEqual(record["has_summary"] as? Bool, false)
    XCTAssertEqual(record["platform"] as? String, "x.com")

    // 2. 按平台、按标签筛选：走 HistoryListFilter 的 hosts / tagNormalizedNames。
    // 平台接受 status 里的原值，也接受「x」这种简写。
    let byPlatform = try await call("jizuo_search", ["platform": "x"])
    XCTAssertEqual((byPlatform["items"] as? [[String: Any]])?.compactMap { $0["task_id"] as? String }, [xPost.rawValue])
    let byCanonical = try await call("jizuo_search", ["platform": "x.com"])
    XCTAssertEqual((byCanonical["items"] as? [[String: Any]])?.compactMap { $0["task_id"] as? String }, [xPost.rawValue])
    let byTag = try await call("jizuo_search", ["tag": "观点"])
    XCTAssertEqual((byTag["items"] as? [[String: Any]])?.compactMap { $0["task_id"] as? String }, [xPost.rawValue])
    let badPlatform = try await call("jizuo_search", ["platform": "  "])
    XCTAssertEqual(badPlatform["error"] as? String, "invalid_platform")

    // 3. 改一条：标题、归属、素材类型。素材类型是普通标签，换新的要摘掉旧的。
    let updated = try await call("jizuo_update_record", [
      "task_id": xPost.rawValue, "title": "新标题", "ownership": "自有", "material_type": "数据",
    ])
    XCTAssertNil(updated["error"])
    XCTAssertEqual((updated["updated"] as? [Any])?.compactMap { $0 as? String }, ["title", "ownership", "material_type"])
    let afterUpdate = try await call("jizuo_get_record", ["task_id": xPost.rawValue])
    XCTAssertEqual(afterUpdate["title"] as? String, "新标题")
    XCTAssertEqual(afterUpdate["ownership"] as? String, "自有")
    XCTAssertEqual(afterUpdate["material_type"] as? String, "数据")
    XCTAssertEqual(Set(((afterUpdate["tags"] as? [Any]) ?? []).compactMap { $0 as? String }), ["数据", "自有"])

    // 4. 写笔记：replace 后再 append。
    _ = try await call("jizuo_write_note", ["task_id": xPost.rawValue, "body": "第一行"])
    _ = try await call("jizuo_write_note", ["task_id": xPost.rawValue, "body": "第二行", "mode": "append"])
    let savedNote = (try history.annotationStore?.loadNote(taskID: xPost)) ?? nil
    XCTAssertEqual(savedNote, "第一行\n\n第二行")

    // 5. 合集：建、加、改名、挪、移出、删。
    let created = try await call("jizuo_collections_manage", ["action": "create", "name": "测试合集"])
    let collectionID = try XCTUnwrap(created["collection_id"] as? String)
    let added = try await call("jizuo_collections_manage", [
      "action": "add_items", "collection": collectionID, "task_ids": [xPost.rawValue, web.rawValue],
    ])
    XCTAssertEqual(added["added"] as? Int, 2)
    _ = try await call("jizuo_collections_manage", ["action": "rename", "collection": collectionID, "name": "改名合集"])
    _ = try await call("jizuo_collections_manage", [
      "action": "move_items", "collection": collectionID, "task_ids": [web.rawValue], "anchor_task_id": nil,
    ])
    let removed = try await call("jizuo_collections_manage", [
      "action": "remove_items", "collection": collectionID, "task_ids": [web.rawValue],
    ])
    XCTAssertEqual(removed["removed"] as? Int, 1)
    let listed = try await call("jizuo_collections")
    let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first { $0["collection_id"] as? String == collectionID })
    XCTAssertEqual(item["name"] as? String, "改名合集")
    XCTAssertEqual(item["count"] as? Int, 1)
    _ = try await call("jizuo_collections_manage", ["action": "delete", "collection": collectionID])
    let afterDelete = try await call("jizuo_collections")
    XCTAssertFalse(((afterDelete["items"] as? [[String: Any]]) ?? []).contains { $0["collection_id"] as? String == collectionID })

    // 6. 标签：加、改名、合并、删除、从某条移除。
    _ = try await call("jizuo_add_tags", ["task_id": web.rawValue, "tags": ["临时"]])
    let renamed = try await call("jizuo_tags_manage", ["action": "rename", "tag": "临时", "name": "改名"])
    XCTAssertEqual(renamed["tag"] as? String, "改名")
    let merged = try await call("jizuo_tags_manage", ["action": "merge", "tags": ["改名"], "name": "合并"])
    XCTAssertEqual(merged["tag"] as? String, "合并")
    // 合并出来的标签还挂在 web 上，这时删除它：关联一起去掉，条目标签里不再有它。
    let deleted = try await call("jizuo_tags_manage", ["action": "delete", "tag": "合并"])
    XCTAssertNil(deleted["error"])
    let webRecord = try await call("jizuo_get_record", ["task_id": web.rawValue])
    XCTAssertFalse(((webRecord["tags"] as? [Any]) ?? []).compactMap { $0 as? String }.contains("合并"))
    // 从某条移除单个标签。
    _ = try await call("jizuo_add_tags", ["task_id": web.rawValue, "tags": ["移除我"]])
    _ = try await call("jizuo_tags_manage", ["action": "remove_from_record", "task_id": web.rawValue, "tag": "移除我"])
    let afterRemove = try await call("jizuo_get_record", ["task_id": web.rawValue])
    XCTAssertFalse(((afterRemove["tags"] as? [Any]) ?? []).compactMap { $0 as? String }.contains("移除我"))

    // 7. 按博主列作品。
    let identity = try XCTUnwrap(CreatorIdentity(platform: "x.com", authorID: "someone"))
    let command = try XCTUnwrap(UpsertCreatorCommand(
      identity: identity, profileURL: "https://x.com/someone", displayName: "某人", nowMilliseconds: 10
    ))
    let creator = try repository.upsertCreator(command)
    try repository.attachCreatorWork(creatorID: creator.id, taskID: xPost)
    let works = try await call("jizuo_list_works", ["creator_id": creator.id.rawValue])
    XCTAssertEqual((works["items"] as? [[String: Any]])?.compactMap { $0["task_id"] as? String }, [xPost.rawValue])
  }
}

private struct MCPNewToolsFixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: url, html: "<article>fixture</article>", contentType: "text/html")
  }
}
