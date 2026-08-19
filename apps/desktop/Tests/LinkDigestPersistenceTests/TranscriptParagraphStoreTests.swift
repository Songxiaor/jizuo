import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 转写稿分段时间的存取（Migration018）。
///
/// 这些事情错了都不会报错，只表现为「点了跳错地方」或者「点了没反应」——正是
/// 最难被发现的那一类，所以逐条钉死。
final class TranscriptParagraphStoreTests: XCTestCase {
  private func capture(_ tag: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-08-19T00:00:00Z",
      idempotencyKey: "transcript-paragraph-\(tag)",
      origin: .localTranscription,
      url: "https://example.test/\(tag)",
      title: "条目\(tag)",
      platform: "local_video",
      method: "speech_analyzer_local",
      text: "第一段\n\n第二段",
      completeness: "complete",
      capturedAt: "2026-08-19T00:00:00Z",
      sourceLabel: "本机视频转写")
  }

  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-transcript-paragraph-tests-\(UUID().uuidString)",
      isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(
      at: LocalDatabaseLocation(directoryURL: directory), dependencies: .live)
    defer { try? repository.database.close() }
    try body(repository)
  }

  private let sample = [
    TranscriptParagraph(startMilliseconds: 0, endMilliseconds: 2_200, text: "第一段"),
    TranscriptParagraph(startMilliseconds: 3_700, endMilliseconds: 5_000, text: "第二段"),
  ]

  func testParagraphsRoundTripInOrder() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("a"), receivedAtMilliseconds: 1))
      try repository.saveTranscriptParagraphs(sample, snapshotID: accepted.snapshotID.rawValue)
      let loaded = try repository.loadTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue)
      XCTAssertEqual(loaded, sample)
    }
  }

  /// 顺序按 ordinal，不按时间：识别结果偶尔给出时间相同的相邻段，靠时间排序
  /// 会让这两段随机换位，正文和锚点就对不上了。
  func testOrderFollowsOrdinalNotTime() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("b"), receivedAtMilliseconds: 1))
      let sameTime = [
        TranscriptParagraph(startMilliseconds: 1_000, endMilliseconds: 1_000, text: "先"),
        TranscriptParagraph(startMilliseconds: 1_000, endMilliseconds: 1_000, text: "后"),
      ]
      try repository.saveTranscriptParagraphs(sameTime, snapshotID: accepted.snapshotID.rawValue)
      XCTAssertEqual(
        try repository.loadTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue).map(\.text),
        ["先", "后"]
      )
    }
  }

  /// 覆盖式写入：重新转写之后不能留着上一次的尾巴。
  func testSavingAgainReplacesTheWholeSet() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("c"), receivedAtMilliseconds: 1))
      try repository.saveTranscriptParagraphs(sample, snapshotID: accepted.snapshotID.rawValue)
      let shorter = [TranscriptParagraph(startMilliseconds: 500, endMilliseconds: 900, text: "只剩一段")]
      try repository.saveTranscriptParagraphs(shorter, snapshotID: accepted.snapshotID.rawValue)
      XCTAssertEqual(
        try repository.loadTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue),
        shorter
      )
    }
  }

  /// 正文被改过之后分段作废：留着就会点一下跳错地方。
  func testDeleteRemovesTheAnchors() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("d"), receivedAtMilliseconds: 1))
      try repository.saveTranscriptParagraphs(sample, snapshotID: accepted.snapshotID.rawValue)
      try repository.deleteTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue)
      XCTAssertTrue(
        try repository.loadTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue).isEmpty
      )
    }
  }

  /// 没有分段的 snapshot 返回空数组而不是报错——在线转写和整理稿本来就没有。
  func testUnknownSnapshotReturnsEmpty() throws {
    try withRepository { repository in
      XCTAssertTrue(
        try repository.loadTranscriptParagraphs(snapshotID: UUID().uuidString.lowercased()).isEmpty
      )
    }
  }

  /// 挂到不存在的 snapshot 上必须被拒绝，否则会留下永远读不到的孤儿行。
  func testUnknownSnapshotRejectsWrites() throws {
    try withRepository { repository in
      XCTAssertThrowsError(
        try repository.saveTranscriptParagraphs(sample, snapshotID: UUID().uuidString.lowercased())
      )
    }
  }

  /// 条目删除后分段跟着走（外键 ON DELETE CASCADE）。
  func testDeletingTheTaskCascadesToParagraphs() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture("e"), receivedAtMilliseconds: 1))
      try repository.saveTranscriptParagraphs(sample, snapshotID: accepted.snapshotID.rawValue)
      try repository.deleteTask(taskID: accepted.taskID)
      XCTAssertTrue(
        try repository.loadTranscriptParagraphs(snapshotID: accepted.snapshotID.rawValue).isEmpty
      )
    }
  }
}
