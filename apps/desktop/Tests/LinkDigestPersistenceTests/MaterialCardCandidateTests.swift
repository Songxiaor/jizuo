import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 批量补做素材卡的候选名单（`materialCardCandidates`）：只收未删除、非草稿、有听写层、
/// 还没有素材卡、且最新一份听写稿 ≥ 80 字的条目；字数按最新一份算。临时库，不碰真实数据。
final class MaterialCardCandidateTests: XCTestCase {
  private var root: URL!
  private var repository: GRDBHistoryRepository!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/private/tmp/linkdigest-candidates-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
  }

  override func tearDownWithError() throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: 造数据

  @discardableResult
  private func insertTask(kind: String = "capture", deletedAt: Int64? = nil, createdAt: Int64 = 1_000) throws -> String {
    let id = UUID().uuidString.lowercased()
    try repository.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO tasks (id, canonical_url, canonicalization_version, content_kind,
                             created_at_ms, updated_at_ms, deleted_at_ms)
          VALUES (?, ?, 1, ?, ?, ?, ?)
          """,
        arguments: [id, "https://example.test/\(id)", kind, createdAt, createdAt, deletedAt]
      )
    }
    return id
  }

  /// 听写快照；`length` 是正文字符数，`sourceKind` 可换成别的层来验证筛选口径。
  private func insertSnapshot(taskID: String, length: Int, sequence: Int = 1, sourceKind: String = "local_transcription") throws {
    let text = String(repeating: "讲", count: length)
    let hex = String(sequence * 100_000 + length, radix: 16)
    let hash = String(repeating: "0", count: 64 - hex.count) + hex
    try repository.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO content_snapshots
            (id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
             platform, capture_method, completeness, body_text, character_count, body_sha256, source_label, used_cookie)
          VALUES (?, ?, ?, 1, 1, ?, 'https://example.test/x', NULL,
                  'web', 'fixture', 'complete', ?, ?, ?, 'fixture', 0)
          """,
        arguments: [UUID().uuidString.lowercased(), taskID, sequence, sourceKind, text, length, hash]
      )
    }
  }

  private func saveCard(_ taskID: String) throws {
    try repository.saveMaterialCard(.init(
      taskID: TaskID(taskID)!, card: MaterialCard(
        speaker: "a", viewpoints: [], hook: "", quotes: [], isLiveSpeaker: false, liveSpeakerReason: ""
      ),
      createdAtMilliseconds: 1, updatedAtMilliseconds: 1
    ))
  }

  private func candidateIDs() throws -> [String: Int] {
    Dictionary(uniqueKeysWithValues: try repository.materialCardCandidates().map { ($0.taskID.rawValue, $0.transcriptCharacters) })
  }

  // MARK: 用例

  func testOnlyEligibleTasksAreCandidates() throws {
    let eligible = try insertTask()
    try insertSnapshot(taskID: eligible, length: 500)

    let tooShort = try insertTask()
    try insertSnapshot(taskID: tooShort, length: MaterialCardPrompt.minimumTranscriptCharacters - 1)

    let noTranscript = try insertTask()

    let trashed = try insertTask(deletedAt: 9_000)
    try insertSnapshot(taskID: trashed, length: 500)

    let draft = try insertTask(kind: "draft")
    try insertSnapshot(taskID: draft, length: 500)

    let carded = try insertTask()
    try insertSnapshot(taskID: carded, length: 500)
    try saveCard(carded)

    let webOnly = try insertTask()
    try insertSnapshot(taskID: webOnly, length: 500, sourceKind: "web_capture")

    let candidates = try candidateIDs()
    XCTAssertEqual(candidates, [eligible: 500], "只有够长、有听写、没卡、没删、不是草稿的才算候选")
  }

  func testLatestTranscriptDecidesEligibilityAndCharacterCount() throws {
    // 最新一份太短 → 整条不算候选，哪怕更早那份够长。
    let latestShort = try insertTask()
    try insertSnapshot(taskID: latestShort, length: 500, sequence: 1)
    try insertSnapshot(taskID: latestShort, length: 10, sequence: 2)

    // 最新一份够长 → 按最新那份的字数报。
    let latestLong = try insertTask()
    try insertSnapshot(taskID: latestLong, length: 10, sequence: 1)
    try insertSnapshot(taskID: latestLong, length: 321, sequence: 2)

    XCTAssertEqual(try candidateIDs(), [latestLong: 321])
  }

  func testDeletingCardMakesTaskCandidateAgain() throws {
    let id = try insertTask()
    try insertSnapshot(taskID: id, length: 200)
    try saveCard(id)
    XCTAssertTrue(try candidateIDs().isEmpty, "已经做过卡的不再出现在批量里")

    try repository.deleteMaterialCard(taskID: TaskID(id)!)
    XCTAssertEqual(try candidateIDs(), [id: 200], "卡删了应该能重新补")
  }

  func testHardDeletedTaskLeavesNeitherCardNorCandidate() throws {
    let id = try insertTask()
    try insertSnapshot(taskID: id, length: 200)
    try saveCard(id)

    try repository.database.write { db in
      try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
    }
    XCTAssertTrue(try candidateIDs().isEmpty)
    XCTAssertTrue(try repository.materialCardTaskIDs().isEmpty, "素材卡随内容一起删")
  }
}
