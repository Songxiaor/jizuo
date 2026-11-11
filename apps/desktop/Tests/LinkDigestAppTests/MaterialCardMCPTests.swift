import Foundation
import XCTest
import LinkDigestCore
import LinkDigestPersistence
@testable import LinkDigestApp

/// `jizuo_get_record` 新增 `material_card`：没有卡是 null，有卡带字段；原有字段不变。临时库，不碰真实数据。
@MainActor
final class MaterialCardMCPTests: XCTestCase {
  func testGetRecordCarriesMaterialCardAndKeepsExistingKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-card-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    let history = HistoryApplicationService(repository: repository)
    let taskID = try repository.acceptCapture(.init(document: CapturedDocument(
      createdAt: "2026-09-06T00:00:00Z", idempotencyKey: "mcp-card-1", origin: .manualLink,
      url: "https://example.test/video", title: "视频", platform: "web", method: "fixture",
      text: "正文", completeness: "complete", capturedAt: "2026-09-06T00:00:00Z", sourceLabel: "fixture"
    ), receivedAtMilliseconds: 1)).taskID

    let suite = "mcp-card-\(UUID().uuidString)"
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
    let manual = ManualLinkViewModel(captureService: .init(fetcher: MaterialCardMCPFixtureFetcher()))
    manual.configure(history: history, storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 2 }, captureSink: { _ in })
    model.configure(history: history, historyModel: historyModel, manual: manual, writable: true)
    model.enabled = true

    func record() async throws -> [String: Any] {
      let request = try JSONSerialization.data(withJSONObject: ["name": "jizuo_get_record", "arguments": ["task_id": taskID.rawValue]])
      let data = await model.handle(request)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let before = try await record()
    XCTAssertNil(before["error"])
    XCTAssertTrue(before["material_card"] is NSNull)
    XCTAssertEqual(before["title"] as? String, "视频", "老字段不受影响")
    XCTAssertNotNil(before["tags"])

    try repository.saveMaterialCard(.init(
      taskID: taskID,
      card: MaterialCard(speaker: "开发者", viewpoints: ["观点一"], hook: "钩子", quotes: ["金句一句话"], isLiveSpeaker: true, liveSpeakerReason: "出镜"),
      createdAtMilliseconds: 1, updatedAtMilliseconds: 5
    ))
    let after = try await record()
    let card = try XCTUnwrap(after["material_card"] as? [String: Any])
    XCTAssertEqual(card["speaker"] as? String, "开发者")
    XCTAssertEqual(card["quotes"] as? [String], ["金句一句话"])
    XCTAssertEqual(card["is_live_speaker"] as? Bool, true)
    XCTAssertEqual(after["title"] as? String, "视频")
  }
}

private struct MaterialCardMCPFixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: url, html: "<article>fixture</article>", contentType: "text/html")
  }
}
