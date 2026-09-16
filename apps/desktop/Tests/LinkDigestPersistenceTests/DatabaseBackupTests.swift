import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 升级前自动备份。
///
/// `backup(to:)` / `restore(from:to:)` 早就写好了，也有十几条测试——但 App 里
/// 一个调用方都没有。也就是说：升级数据库这件不可逆的事，一直是在没有任何
/// 退路的情况下做的。这一批测试钉的就是「那条退路真的在」。
final class DatabaseBackupTests: XCTestCase {
  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-backup-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  /// 造一个停在 `version` 的库，灌一条可辨认的记录。返回那条记录的 id。
  @discardableResult
  private func makeDatabase(at location: LocalDatabaseLocation, version: Int, marker: String) throws -> String {
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    let id = UUID().uuidString.lowercased()
    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try MigrationFixture.apply(upTo: version, in: db)
      try db.execute(
        sql: """
          INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite)
          VALUES (?, ?, 1, 1000, 1000, 0)
          """,
        arguments: [id, "https://example.test/\(marker)"]
      )
      try db.execute(
        sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
            title, platform, capture_method, completeness, body_text, character_count, body_sha256,
            source_label, used_cookie
          ) VALUES (?, ?, 1, 1000, 1000, 'page', ?, ?, 'generic', 'rendered_dom', 'complete', ?, ?, ?, '浏览器扩展', 0)
          """,
        arguments: [
          UUID().uuidString.lowercased(), id, "https://example.test/\(marker)",
          "标题 \(marker)", "正文 \(marker)", 6, String(repeating: "a", count: 64),
        ]
      )
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), version)
    }
    try queue.close()
    return id
  }

  private func store(_ location: LocalDatabaseLocation) -> DatabaseBackupStore {
    DatabaseBackupStore(location: location)
  }

  // MARK: - 升级前自动备份

  func testUpgradeWritesAnOpenableBackupOfTheOldDatabase() throws {
    try withTemporaryLocation { location in
      let taskID = try makeDatabase(at: location, version: 22, marker: "before-upgrade")

      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      XCTAssertEqual(database.accessMode, .writable)

      let backups = try store(location).backups()
      XCTAssertEqual(backups.count, 1, "升级前必须留下一份备份")
      let backup = try XCTUnwrap(backups.first)
      XCTAssertTrue(backup.isAutomatic)
      XCTAssertEqual(backup.name.hasPrefix("history-v22-"), true, "文件名要带得出旧版本号：\(backup.name)")
      XCTAssertGreaterThan(backup.byteCount, 0)

      // 备份本身要能打开，而且内容还是升级**之前**那一版。
      var readOnly = Configuration()
      readOnly.readonly = true
      let queue = try DatabaseQueue(path: backup.url.path, configuration: readOnly)
      defer { try? queue.close() }
      try queue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 22)
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM tasks"), taskID)
        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT integrity_check FROM pragma_integrity_check"), "ok")
        // 备份是单个自包含文件（DELETE 日志模式），拷走就能用。
        XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased(), "delete")
      }

      // 升完级，数据一条不少。
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.map(\.taskID.rawValue), [taskID])
    }
  }

  func testAlreadyCurrentDatabaseDoesNotAccumulateBackups() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location, version: 22, marker: "once")
      let first = try LocalDatabase.open(at: location)
      try first.close()
      XCTAssertEqual(try store(location).backups().count, 1)

      // 第二次打开时已经是最新版，不该再存一份——每次启动都备份会把磁盘吃光。
      let second = try LocalDatabase.open(at: location)
      try second.close()
      XCTAssertEqual(try store(location).backups().count, 1)
    }
  }

  func testAutomaticBackupsAreCappedAtThree() throws {
    try withTemporaryLocation { location in
      let directory = store(location).directoryURL
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // 先摆五份「旧的自动备份」和一份手动备份。
      var date = Date(timeIntervalSince1970: 1_700_000_000)
      for index in 0..<5 {
        let name = DatabaseBackupStore.automaticFileName(schemaVersion: 20 + index % 3, at: date)
        try Data("stub".utf8).write(to: directory.appendingPathComponent(name))
        try FileManager.default.setAttributes(
          [.modificationDate: date],
          ofItemAtPath: directory.appendingPathComponent(name).path
        )
        date = date.addingTimeInterval(3_600)
      }
      let manualName = DatabaseBackupStore.manualFileName(at: date)
      try Data("stub".utf8).write(to: directory.appendingPathComponent(manualName))

      XCTAssertEqual(try store(location).backups().count, 6)
      _ = try store(location).pruneAutomaticBackups()

      let remaining = try store(location).backups()
      XCTAssertEqual(remaining.filter(\.isAutomatic).count, DatabaseBackupStore.retainedAutomaticBackupCount)
      XCTAssertTrue(
        remaining.contains { $0.name == manualName },
        "手动备份是用户自己按下的，一份都不该被程序删掉"
      )
    }
  }

  func testUpgradePrunesOlderAutomaticBackups() throws {
    try withTemporaryLocation { location in
      let directory = store(location).directoryURL
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var date = Date(timeIntervalSince1970: 1_700_000_000)
      for index in 0..<4 {
        let url = directory.appendingPathComponent(
          DatabaseBackupStore.automaticFileName(schemaVersion: 18 + index, at: date)
        )
        try Data("stub".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        date = date.addingTimeInterval(3_600)
      }
      try makeDatabase(at: location, version: 22, marker: "prune")

      let database = try LocalDatabase.open(at: location)
      try database.close()

      // 4 份旧的 + 这次新存的 1 份 = 5，清理后只剩 3。
      XCTAssertEqual(try store(location).backups().filter(\.isAutomatic).count, 3)
    }
  }

  /// 升级失败时备份必须还在，而且只读降级要能说出它在哪。
  func testFailedMigrationKeepsTheBackupAndNamesItInTheReadOnlyHint() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location, version: 22, marker: "doomed")

      // 迁移提交前注入失败。
      let database = try LocalDatabase.open(at: location, dependencies: .failing(migration: true))
      defer { try? database.close() }

      guard case let .readOnly(reason) = database.accessMode else {
        return XCTFail("迁移失败必须降级成只读，而不是当作成功")
      }
      XCTAssertEqual(reason, .migrationFailed)

      let backups = try store(location).backups()
      XCTAssertEqual(backups.count, 1, "失败之后备份是唯一能拿回原始数据的东西，不能清掉")
      let backupURL = try XCTUnwrap(backups.first?.url)
      XCTAssertEqual(database.migrationBackupURL?.path, backupURL.path)
      let hint = try XCTUnwrap(database.readOnlyRecoveryHint)
      XCTAssertTrue(hint.contains(backupURL.path), "只读降级说明里要带上备份路径：\(hint)")

      // 库本身没被改坏，仍然停在旧版本。
      var readOnly = Configuration()
      readOnly.readonly = true
      let queue = try DatabaseQueue(path: location.databaseURL.path, configuration: readOnly)
      defer { try? queue.close() }
      try queue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 22)
      }
    }
  }

  /// 备份写不出来就**不升级**：没有退路时不做不可逆的改写。
  func testUpgradeIsSkippedWhenTheBackupCannotBeWritten() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location, version: 22, marker: "no-disk")
      // 备份目录建不出来（磁盘满、权限问题）——注入 createDirectory 失败。
      let database = try LocalDatabase.open(at: location, dependencies: .failing(createDirectory: true))
      defer { try? database.close() }
      guard case .readOnly = database.accessMode else {
        return XCTFail("拿不到备份时不该继续升级")
      }
      XCTAssertEqual(try store(location).backups().count, 0)
    }
  }

  // MARK: - 设置页的备份 / 恢复

  func testBackupNowAndRestoreRoundTrip() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      let first = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-09-01T00:00:00Z",
          idempotencyKey: "backup-round-trip",
          origin: .manualLink,
          url: "https://example.test/snapshot",
          title: "备份时就有的",
          platform: "generic",
          method: "rendered_dom",
          text: "备份时就有的正文",
          completeness: "complete",
          capturedAt: "2026-09-01T00:00:00Z",
          sourceLabel: "浏览器扩展"
        ),
        receivedAtMilliseconds: 1_000
      ))

      let maintenance = DatabaseMaintenance(database: repository.database)
      let snapshot = try maintenance.backupToStore()
      XCTAssertFalse(snapshot.isAutomatic)
      XCTAssertGreaterThan(snapshot.byteCount, 0)

      // 备份之后再存一条，然后恢复：新加的那条应该消失。
      let later = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-09-02T00:00:00Z",
          idempotencyKey: "after-backup",
          origin: .manualLink,
          url: "https://example.test/after",
          title: "备份之后才有的",
          platform: "generic",
          method: "rendered_dom",
          text: "备份之后才有的正文",
          completeness: "complete",
          capturedAt: "2026-09-02T00:00:00Z",
          sourceLabel: "浏览器扩展"
        ),
        receivedAtMilliseconds: 2_000
      ))
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.count, 2)

      let safety = try maintenance.restoreInPlace(from: snapshot.url)
      XCTAssertFalse(safety.isAutomatic)
      XCTAssertTrue(try store(location).backups().contains { $0.name == safety.name })

      let rows = try repository.historyPage(limit: 10, after: nil).rows.map(\.taskID)
      XCTAssertEqual(rows, [first.taskID])
      XCTAssertFalse(rows.contains(later.taskID))
      try? repository.database.close()
    }
  }

  func testRestoreRejectsAFileThatIsNotADatabase() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let junk = store(location).directoryURL.appendingPathComponent("history-manual-broken.sqlite")
      try FileManager.default.createDirectory(at: store(location).directoryURL, withIntermediateDirectories: true)
      try Data("这不是一个数据库".utf8).write(to: junk)

      XCTAssertThrowsError(try DatabaseMaintenance(database: repository.database).restoreInPlace(from: junk))
    }
  }

  func testBackupFileNamesSortChronologically() throws {
    let early = DatabaseBackupStore.automaticFileName(
      schemaVersion: 22, at: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let late = DatabaseBackupStore.automaticFileName(
      schemaVersion: 22, at: Date(timeIntervalSince1970: 1_700_090_000)
    )
    XCTAssertLessThan(early, late, "文件名按字典序排就应该等于按时间排")
  }
}
