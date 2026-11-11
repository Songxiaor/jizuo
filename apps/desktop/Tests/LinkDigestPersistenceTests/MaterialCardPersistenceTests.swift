import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 素材卡（Migration025）：升级、升级前备份、读写、随内容删除。全部用隔离临时目录，不碰真实库。
final class MaterialCardPersistenceTests: XCTestCase {
  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-material-card-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  private func seedTask(at location: LocalDatabaseLocation, version: Int) throws -> String {
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    let id = UUID().uuidString.lowercased()
    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try MigrationFixture.apply(upTo: version, in: db)
      try db.execute(
        sql: """
          INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite)
          VALUES (?, 'https://example.test/video', 1, 1000, 1000, 0)
          """,
        arguments: [id]
      )
    }
    try queue.close()
    return id
  }

  private func sampleCard(live: Bool = true) -> MaterialCard {
    MaterialCard(
      speaker: "一位独立开发者", viewpoints: ["先跑通链路", "再优化最慢的一段"], hook: "开头直接抛出反常识的结论",
      quotes: ["把复杂的事情讲清楚"], isLiveSpeaker: live, liveSpeakerReason: "全程出镜讲解"
    )
  }

  func testUpgradeFrom24CreatesMaterialCardTableAfterAutomaticBackup() throws {
    try withTemporaryLocation { location in
      let taskID = try seedTask(at: location, version: 24)
      XCTAssertEqual(Migration025.schemaVersion, LocalDatabase.latestSchemaVersion)

      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      XCTAssertEqual(database.accessMode, .writable)

      // 升级前备份存在，且还是 v24（没有素材卡表）。
      let backups = try DatabaseBackupStore(location: location).backups()
      XCTAssertEqual(backups.count, 1, "升级前必须留下一份备份")
      let backup = try XCTUnwrap(backups.first)
      XCTAssertTrue(backup.name.hasPrefix("history-v24-"), backup.name)
      var readOnly = Configuration()
      readOnly.readonly = true
      let old = try DatabaseQueue(path: backup.url.path, configuration: readOnly)
      defer { try? old.close() }
      try old.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 24)
        XCTAssertFalse(try db.tableExists("task_material_cards"))
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM tasks"), taskID)
      }

      // 升级后：版本到 25、新表在、旧数据在、外键检查干净。
      try database.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 25)
        XCTAssertTrue(try db.tableExists("task_material_cards"))
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM tasks"), taskID)
        XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
      }
    }
  }

  func testSaveLoadRoundTripAndUpsertKeepsCreationTime() throws {
    try withTemporaryLocation { location in
      let id = try seedTask(at: location, version: 24)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let taskID = try XCTUnwrap(TaskID(id))

      XCTAssertNil(try repository.loadMaterialCard(taskID: taskID))
      try repository.saveMaterialCard(TaskMaterialCardRecord(
        taskID: taskID, card: sampleCard(), liveSpeakerTagApplied: true,
        provider: "configured_provider", model: "mock-model",
        promptTokens: 1200, completionTokens: 180, totalTokens: 1380,
        createdAtMilliseconds: 5_000, updatedAtMilliseconds: 5_000
      ))
      let loaded = try XCTUnwrap(try repository.loadMaterialCard(taskID: taskID))
      XCTAssertEqual(loaded.card, sampleCard())
      XCTAssertTrue(loaded.liveSpeakerTagApplied)
      XCTAssertFalse(loaded.liveSpeakerTagSuppressed)
      XCTAssertEqual(loaded.model, "mock-model")
      XCTAssertEqual(loaded.totalTokens, 1380)
      XCTAssertEqual(try repository.materialCardTaskIDs(), [taskID])

      try repository.saveMaterialCard(TaskMaterialCardRecord(
        taskID: taskID, card: sampleCard(live: false), liveSpeakerTagSuppressed: true,
        createdAtMilliseconds: 9_000, updatedAtMilliseconds: 9_000
      ))
      let updated = try XCTUnwrap(try repository.loadMaterialCard(taskID: taskID))
      XCTAssertFalse(updated.card.isLiveSpeaker)
      XCTAssertTrue(updated.liveSpeakerTagSuppressed)
      XCTAssertEqual(updated.createdAtMilliseconds, 5_000, "再生成不改首次创建时间")
      XCTAssertEqual(updated.updatedAtMilliseconds, 9_000)
    }
  }

  func testSavingForMissingTaskIsRejected() throws {
    try withTemporaryLocation { location in
      _ = try seedTask(at: location, version: 24)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let ghost = try XCTUnwrap(TaskID(UUID().uuidString.lowercased()))
      XCTAssertThrowsError(try repository.saveMaterialCard(TaskMaterialCardRecord(
        taskID: ghost, card: sampleCard(), createdAtMilliseconds: 1, updatedAtMilliseconds: 1
      )))
    }
  }

  func testMaterialCardIsDeletedWithItsItem() throws {
    try withTemporaryLocation { location in
      let id = try seedTask(at: location, version: 24)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let taskID = try XCTUnwrap(TaskID(id))
      try repository.saveMaterialCard(TaskMaterialCardRecord(
        taskID: taskID, card: sampleCard(), createdAtMilliseconds: 1, updatedAtMilliseconds: 1
      ))
      try repository.database.write { db in
        try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
      }
      XCTAssertNil(try repository.loadMaterialCard(taskID: taskID))
      try repository.database.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_material_cards"), 0, "素材卡要随内容一起删")
      }
    }
  }
}
