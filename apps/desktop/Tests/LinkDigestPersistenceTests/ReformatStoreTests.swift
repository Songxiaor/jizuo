import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 整理排版产物的存取（Migration017 的 `task_reformats`，本次才接上代码）。
final class ReformatStoreTests: XCTestCase {
  private func capture(_ tag: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-08-19T00:00:00Z",
      idempotencyKey: "reformat-\(tag)",
      origin: .manualLink,
      url: "https://example.test/\(tag)",
      title: "条目\(tag)",
      platform: "generic",
      method: "rendered_dom",
      text: "原文正文，一段很长的没有小标题的文章。",
      completeness: "complete",
      capturedAt: "2026-08-19T00:00:00Z",
      sourceLabel: "手动链接")
  }

  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-reformat-tests-\(UUID().uuidString)",
      isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(
      at: LocalDatabaseLocation(directoryURL: directory), dependencies: .live)
    defer { try? repository.database.close() }
    try body(repository)
  }

  private func record(_ taskID: TaskID, body: String = "## 小标题\n\n原文正文。", partial: Bool = false)
    -> TaskReformatRecord {
    TaskReformatRecord(
      taskID: taskID, bodyText: body, isPartial: partial,
      provider: "configured_provider", model: "test-model",
      promptTokens: 10, completionTokens: 20, totalTokens: 30,
      createdAtMilliseconds: 1_000, updatedAtMilliseconds: 1_000
    )
  }

  func testReformatRoundTrips() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("a"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID))
      let loaded = try repository.loadReformat(taskID: accepted.taskID)
      XCTAssertEqual(loaded?.bodyText, "## 小标题\n\n原文正文。")
      XCTAssertEqual(loaded?.totalTokens, 30)
      XCTAssertEqual(loaded?.userEdited, false)
      XCTAssertEqual(loaded?.isPartial, false)
    }
  }

  /// 一条任务只留最新一份：重新重排是覆盖，不是追加。
  func testSavingAgainReplacesTheRecord() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("b"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID, body: "第一版"))
      try repository.saveReformat(record(accepted.taskID, body: "第二版"))
      XCTAssertEqual(try repository.loadReformat(taskID: accepted.taskID)?.bodyText, "第二版")
    }
  }

  /// 部分失败必须原样存下来，界面才能如实告诉用户「有几段没重排」。
  func testPartialFlagSurvivesRoundTrip() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("c"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID, partial: true))
      XCTAssertEqual(try repository.loadReformat(taskID: accepted.taskID)?.isPartial, true)
    }
  }

  /// 空产物不许落库：它会让界面出现一个空白的「重排」页，比没有这个功能更糟。
  func testEmptyBodyIsRejected() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("d"), receivedAtMilliseconds: 1))
      XCTAssertThrowsError(try repository.saveReformat(record(accepted.taskID, body: "   \n  ")))
    }
  }

  func testUnknownTaskIsRejected() throws {
    try withRepository { repository in
      let ghost = TaskID(UUID())
      XCTAssertThrowsError(try repository.saveReformat(record(ghost)))
    }
  }

  func testDeleteRemovesTheRecord() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("e"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID))
      try repository.deleteReformat(taskID: accepted.taskID)
      XCTAssertNil(try repository.loadReformat(taskID: accepted.taskID))
    }
  }

  /// 条目删除后产物跟着走，不留孤儿行。
  func testDeletingTheTaskCascades() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("f"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID))
      try repository.deleteTask(taskID: accepted.taskID)
      XCTAssertNil(try repository.loadReformat(taskID: accepted.taskID))
    }
  }

  /// 原文永不被重排覆盖——这是整个功能的前提。
  func testOriginalSnapshotIsUntouched() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("g"), receivedAtMilliseconds: 1))
      try repository.saveReformat(record(accepted.taskID, body: "## 重排后的样子"))
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.snapshots.last?.bodyText, "原文正文，一段很长的没有小标题的文章。")
    }
  }
}
