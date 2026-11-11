import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 每日自动备份：到期判断、7 份修剪、校验失败不留文件、不同前缀互不误删。
final class DailyBackupTests: XCTestCase {
  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-daily-backup-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-daily-state-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(directory)
  }

  /// 状态跟着数据目录走：每个测试用自己的临时目录，互不传染。
  private func makePreferences(at location: LocalDatabaseLocation) -> DailyBackupPreferences {
    DailyBackupPreferences(directoryURL: location.directoryURL)
  }

  private func makeDatabase(at location: LocalDatabaseLocation) throws {
    let database = try LocalDatabase.open(at: location)
    try database.close()
  }

  private func store(_ location: LocalDatabaseLocation) -> DatabaseBackupStore {
    DatabaseBackupStore(location: location)
  }

  @discardableResult
  private func writeStub(_ name: String, in directory: URL, at date: Date) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data("stub".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
  }

  // MARK: - 到期判断

  func testDefaultsToEnabledAndBecomesDueAfterADay() throws {
    try withTemporaryDirectory { directory in
      let preferences = DailyBackupPreferences(directoryURL: directory)
      let now = Date(timeIntervalSince1970: 1_700_000_000)

      XCTAssertTrue(preferences.isEnabled, "没设过开关时默认开启")
      XCTAssertNil(preferences.lastSuccessAt)
      XCTAssertTrue(preferences.isDue(now: now), "从没备份过就该备份")

      preferences.recordSuccess(at: now)
      XCTAssertEqual(
        preferences.lastSuccessAt?.timeIntervalSince1970 ?? 0,
        now.timeIntervalSince1970,
        accuracy: 0.001
      )
      XCTAssertFalse(
        preferences.isDue(now: now.addingTimeInterval(DailyBackupPreferences.interval - 1)),
        "还差一秒没满 24 小时，不该再备一份"
      )
      XCTAssertTrue(
        preferences.isDue(now: now.addingTimeInterval(DailyBackupPreferences.interval)),
        "满 24 小时就是到期"
      )
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(DailyBackupPreferences.fileName).path
        ),
        "状态要落在数据目录里的小文件上"
      )
    }
  }

  func testDisabledSkipsEvenWhenDue() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      preferences.isEnabled = false

      let result = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: Date(timeIntervalSince1970: 1_700_000_000))

      XCTAssertEqual(result, .disabled)
      XCTAssertEqual(try store(location).backups().count, 0)
      XCTAssertNil(preferences.lastSuccessAt)
    }
  }

  func testSecondRunWithinADayIsNotDue() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let service = DailyBackupService(location: location, preferences: preferences)
      let now = Date(timeIntervalSince1970: 1_700_000_000)

      guard case .succeeded = service.runIfDue(now: now) else {
        return XCTFail("第一次到期应该备份成功")
      }
      XCTAssertEqual(try store(location).backups().filter(\.isDaily).count, 1)

      XCTAssertEqual(service.runIfDue(now: now.addingTimeInterval(3_600)), .notDue)
      XCTAssertEqual(try store(location).backups().filter(\.isDaily).count, 1)
    }
  }

  func testBacksUpAgainAfterTwentyFourHours() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let service = DailyBackupService(location: location, preferences: preferences)
      let now = Date(timeIntervalSince1970: 1_700_000_000)

      guard case .succeeded = service.runIfDue(now: now) else {
        return XCTFail("第一次应该备份成功")
      }
      guard case .succeeded = service.runIfDue(now: now.addingTimeInterval(25 * 3_600)) else {
        return XCTFail("满 24 小时后应该再备一份")
      }
      XCTAssertEqual(try store(location).backups().filter(\.isDaily).count, 2)
    }
  }

  // MARK: - 文件名与列表识别

  func testDailyBackupHasItsOwnPrefixAndIsRecognizable() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)

      guard case let .succeeded(file) = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: Date(timeIntervalSince1970: 1_700_000_000))
      else { return XCTFail("应该备份成功") }

      XCTAssertTrue(file.isDaily)
      XCTAssertFalse(file.isAutomatic, "每日备份不是「升级前」那一类")
      XCTAssertTrue(file.name.hasPrefix("history-daily-"), "文件名要一眼看出是每日备份：\(file.name)")
      let listed = try store(location).backups()
      XCTAssertEqual(listed.count, 1)
      XCTAssertTrue(listed[0].isDaily)
      var readOnly = Configuration()
      readOnly.readonly = true
      let queue = try DatabaseQueue(path: file.url.path, configuration: readOnly)
      defer { try? queue.close() }
      let integrity = try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
      XCTAssertEqual(integrity, "ok", "写出来的备份本身要能打开且完整")
    }
  }

  // MARK: - 修剪

  func testPruneDailyKeepsSevenAndNeverTouchesOtherBackups() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let directory = store(location).directoryURL
      var date = Date(timeIntervalSince1970: 1_700_000_000)

      // 8 份旧的每日备份 + 每种非每日备份各一份。
      for _ in 0..<8 {
        try writeStub(DatabaseBackupStore.dailyFileName(at: date), in: directory, at: date)
        date = date.addingTimeInterval(3_600)
      }
      let upgradeName = DatabaseBackupStore.automaticFileName(schemaVersion: 22, at: date)
      let manualName = DatabaseBackupStore.manualFileName(at: date)
      let beforeRestoreName = DatabaseBackupStore.beforeRestoreFileName(at: date)
      try writeStub(upgradeName, in: directory, at: date)
      try writeStub(manualName, in: directory, at: date)
      try writeStub(beforeRestoreName, in: directory, at: date)

      guard case .succeeded = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: date.addingTimeInterval(3_600))
      else { return XCTFail("应该备份成功") }

      let remaining = try store(location).backups()
      XCTAssertEqual(remaining.filter(\.isDaily).count, 7, "每日备份只留最近 7 份")
      let names = Set(remaining.map(\.name))
      XCTAssertTrue(names.contains(upgradeName), "升级前备份不能被每日备份的修剪删掉")
      XCTAssertTrue(names.contains(manualName), "手动备份一份都不能删")
      XCTAssertTrue(names.contains(beforeRestoreName), "恢复前备份不能删")
      XCTAssertTrue(
        remaining.first { $0.name == beforeRestoreName }?.isBeforeRestore == true,
        "恢复前存的那份要能被设置页认出来，不能显示成「手动备份」"
      )
    }
  }

  func testUpgradePruneNeverTouchesDailyBackups() throws {
    try withTemporaryLocation { location in
      let directory = store(location).directoryURL
      var date = Date(timeIntervalSince1970: 1_700_000_000)
      for _ in 0..<5 {
        try writeStub(DatabaseBackupStore.automaticFileName(schemaVersion: 22, at: date), in: directory, at: date)
        date = date.addingTimeInterval(3_600)
      }
      for _ in 0..<2 {
        try writeStub(DatabaseBackupStore.dailyFileName(at: date), in: directory, at: date)
        date = date.addingTimeInterval(3_600)
      }

      _ = try store(location).pruneAutomaticBackups()

      let remaining = try store(location).backups()
      XCTAssertEqual(remaining.filter(\.isAutomatic).count, DatabaseBackupStore.retainedAutomaticBackupCount)
      XCTAssertEqual(remaining.filter(\.isDaily).count, 2, "升级前备份的 3 份上限不该动每日备份")
    }
  }

  // MARK: - 校验失败

  func testIntegrityFailureLeavesNoFileAndRecordsAReadableReason() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let directory = store(location).directoryURL
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let manualName = DatabaseBackupStore.manualFileName(at: date)
      try writeStub(manualName, in: directory, at: date)

      let service = DailyBackupService(
        location: location,
        preferences: preferences,
        verifyBackup: { _ in throw RepositoryFailure.integrityCheckFailed }
      )
      let result = service.runIfDue(now: date)

      guard case let .failed(reason) = result else {
        return XCTFail("校验没过不能算成功：\(result)")
      }
      XCTAssertTrue(reason.contains("校验"), "失败原因要说人话：\(reason)")

      let remaining = try store(location).backups()
      XCTAssertEqual(remaining.filter(\.isDaily).count, 0, "校验没过的文件不能留着冒充好备份")
      XCTAssertTrue(remaining.contains { $0.name == manualName }, "失败时也不该动旧的手动备份")
      let partials = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
        .filter { $0.hasSuffix(".partial") } ?? []
      XCTAssertTrue(partials.isEmpty, "临时文件也要清掉：\(partials)")

      XCTAssertNil(preferences.lastSuccessAt)
      XCTAssertEqual(preferences.lastFailureReason, reason)
      XCTAssertNotNil(preferences.lastFailureAt)
    }
  }

  func testVerifiedBackupOpensAndHasTheDatabaseContent() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      _ = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-09-01T00:00:00Z",
          idempotencyKey: "daily-backup-content",
          origin: .manualLink,
          url: "https://example.test/daily",
          title: "每日备份里应该在",
          platform: "generic",
          method: "rendered_dom",
          text: "每日备份里应该在的正文",
          completeness: "complete",
          capturedAt: "2026-09-01T00:00:00Z",
          sourceLabel: "浏览器扩展"
        ),
        receivedAtMilliseconds: 1_000
      ))
      try repository.database.close()

      let preferences = makePreferences(at: location)
      guard case let .succeeded(file) = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: Date(timeIntervalSince1970: 1_700_000_000))
      else { return XCTFail("应该备份成功") }

      var readOnly = Configuration()
      readOnly.readonly = true
      let queue = try DatabaseQueue(path: file.url.path, configuration: readOnly)
      defer { try? queue.close() }
      try queue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks"), 1)
        XCTAssertEqual(
          try String.fetchOne(db, sql: "SELECT title FROM content_snapshots"),
          "每日备份里应该在"
        )
      }
    }
  }

  // MARK: - 状态跟着数据目录走（隔离调试版不碰真实 App）

  func testIsolatedDataDirectoryKeepsItsOwnBackupState() throws {
    try withTemporaryDirectory { realDirectory in
      try withTemporaryDirectory { isolatedDirectory in
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let real = DailyBackupPreferences(directoryURL: realDirectory)
        real.isEnabled = false
        real.recordSuccess(at: date)

        let isolated = DailyBackupPreferences(directoryURL: isolatedDirectory)
        XCTAssertTrue(isolated.isEnabled, "另一个数据目录没关过开关，不能读到真实 App 的设置")
        XCTAssertNil(isolated.lastSuccessAt, "另一个数据目录不能假装已经备份过")
        XCTAssertTrue(isolated.isDue(now: date.addingTimeInterval(60)), "没备份过就该备份")
        XCTAssertFalse(real.isEnabled, "隔离目录写状态不能反过来改真实目录")

        // 反过来也一样：隔离目录写成功，不影响真实目录。
        isolated.recordSuccess(at: date.addingTimeInterval(120))
        XCTAssertEqual(real.lastSuccessAt?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)
      }
    }
  }

  func testCorruptStateFileFallsBackToDefaultsInsteadOfBlockingBackup() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      try Data("not json".utf8).write(to: preferences.fileURL)

      XCTAssertTrue(preferences.isEnabled)
      XCTAssertNil(preferences.lastSuccessAt)
      XCTAssertNil(preferences.lastFailureReason)

      guard case .succeeded = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: Date(timeIntervalSince1970: 1_700_000_000))
      else { return XCTFail("状态文件坏了不该让备份停摆") }
      XCTAssertEqual(preferences.lastSuccessAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
    }
  }

  // MARK: - 崩溃遗留的临时文件

  func testStaleDailyPartialsAreRemovedBeforeBackup() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let directory = store(location).directoryURL
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let date = Date(timeIntervalSince1970: 1_700_000_000)

      let stale = [
        "history-daily-20200101-000000.sqlite.partial",
        "history-daily-20200101-000000.sqlite.partial-journal",
        "history-daily-20200101-000000.sqlite.partial-wal",
        "history-daily-20200101-000000.sqlite.partial-shm",
        "history-daily-20200101-000000-2.sqlite.partial",
      ]
      let untouched = [
        "history-manual-20200101-000000.sqlite.partial",
        "notes.sqlite.partial",
        "history-daily-broken.sqlite.partial",
      ]
      for name in stale + untouched {
        try Data("leftover".utf8).write(to: directory.appendingPathComponent(name))
      }

      guard case .succeeded = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: date)
      else { return XCTFail("应该备份成功") }

      let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
      for name in stale {
        XCTAssertFalse(remaining.contains(name), "崩溃遗留的临时文件要清掉：\(name)")
      }
      for name in untouched {
        XCTAssertTrue(remaining.contains(name), "格式不对的临时文件一律不碰：\(name)")
      }
    }
  }

  // MARK: - 退出取消

  func testCancellationLeavesNoBackupAndNoSuccessTime() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      // 第 1 次检查通过（还没开始写），第 2 次已经写完拷贝，这时取消。
      let probe = BackupCancellationProbe(cancelAfter: 1)

      let result = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: date, isCancelled: { probe.next() })

      XCTAssertEqual(result, .cancelled)
      XCTAssertEqual(try store(location).backups().filter(\.isDaily).count, 0, "取消后不能留下正式备份")
      let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store(location).directoryURL.path))?
        .filter { $0.contains(".partial") } ?? []
      XCTAssertTrue(leftovers.isEmpty, "取消后也不该留下半成品：\(leftovers)")
      XCTAssertNil(preferences.lastSuccessAt, "取消不能记成功，否则下次启动会以为今天已经备份过")
      XCTAssertNil(preferences.lastFailureAt, "取消不是失败，不该在设置页报一次错")
      XCTAssertTrue(preferences.isDue(now: date.addingTimeInterval(60)), "下次启动还应该补上")
    }
  }

  // MARK: - 备份不触发迁移

  func testDailyBackupDoesNotMigrateAnOlderDatabase() throws {
    try withTemporaryLocation { location in
      let oldVersion = 22
      try makeOldDatabase(at: location, version: oldVersion)
      let preferences = makePreferences(at: location)
      let date = Date(timeIntervalSince1970: 1_700_000_000)

      guard case .succeeded = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: date)
      else { return XCTFail("旧版本的库也应该能备份") }

      let queue = try DatabaseQueue(path: location.databaseURL.path)
      defer { try? queue.close() }
      try queue.read { db in
        XCTAssertEqual(
          try Int.fetchOne(db, sql: "PRAGMA user_version"),
          oldVersion,
          "每日备份不能趁机升级 schema：恢复旧备份后到重启前，用户选的还是那份旧备份"
        )
      }
      XCTAssertEqual(try store(location).backups().filter(\.isAutomatic).count, 0, "更不该顺手写升级前备份")
    }
  }

  func testDailyBackupWorksWhileTheAppHasTheDatabaseOpen() throws {
    try withTemporaryLocation { location in
      // App 运行时的形态：连接池开着（WAL 模式，-shm 在旁边）。
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let preferences = makePreferences(at: location)

      guard case let .succeeded(file) = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: Date(timeIntervalSince1970: 1_700_000_000))
      else { return XCTFail("数据库开着的时候每日备份也要能读") }

      try DatabaseMaintenance.verifyBackupFile(at: file.url)

      // 成功后备份目录里不能留 `.partial` 及其 -shm/-wal/-journal。
      let names = try FileManager.default.contentsOfDirectory(atPath: store(location).directoryURL.path)
      XCTAssertEqual(names.filter { $0.contains(".partial") }, [])
    }
  }

  // MARK: - 修剪只认完整文件名

  func testPruneIgnoresMalformedDailyNames() throws {
    try withTemporaryLocation { location in
      try makeDatabase(at: location)
      let preferences = makePreferences(at: location)
      let directory = store(location).directoryURL
      var date = Date(timeIntervalSince1970: 1_700_000_000)

      for _ in 0..<8 {
        try writeStub(DatabaseBackupStore.dailyFileName(at: date), in: directory, at: date)
        date = date.addingTimeInterval(3_600)
      }
      let malformed = [
        "history-daily-notatimestamp.sqlite",
        "history-daily-20200101.sqlite",
        "history-daily-20200101-0000.sqlite",
        "history-daily-2020010-000000.sqlite",
        "history-daily-20200101-000000-abc.sqlite",
        "history-daily-20200101-000000-.sqlite",
      ]
      for name in malformed {
        try writeStub(name, in: directory, at: date.addingTimeInterval(600))
      }

      guard case .succeeded = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(now: date.addingTimeInterval(3_600))
      else { return XCTFail("应该备份成功") }

      let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
      XCTAssertEqual(
        remaining.filter { DatabaseBackupStore.isDailyFileName($0) }.count,
        DatabaseBackupStore.retainedDailyBackupCount,
        "格式完整的每日备份只留 7 份"
      )
      for name in malformed {
        XCTAssertTrue(remaining.contains(name), "名字格式不对的文件不该被当成每日备份删掉：\(name)")
      }
    }
  }

  // MARK: - 夹具

  @discardableResult
  private func makeOldDatabase(at location: LocalDatabaseLocation, version: Int) throws -> String {
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    let id = UUID().uuidString.lowercased()
    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try MigrationFixture.apply(upTo: version, in: db)
      try db.execute(
        sql: """
          INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite)
          VALUES (?, 'https://example.test/old', 1, 1000, 1000, 0)
          """,
        arguments: [id]
      )
      try db.execute(
        sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
            title, platform, capture_method, completeness, body_text, character_count, body_sha256,
            source_label, used_cookie
          ) VALUES (?, ?, 1, 1000, 1000, 'page', 'https://example.test/old', '旧库里的标题', 'generic',
                    'rendered_dom', 'complete', '旧库里的正文', 6, ?, '浏览器扩展', 0)
          """,
        arguments: [UUID().uuidString.lowercased(), id, String(repeating: "a", count: 64)]
      )
    }
    try queue.close()
    return id
  }
}

/// `isCancelled` 按调用次数返回：数到第 N 次之后开始「已取消」。
///
/// 备份里的检查点顺序是「开始前 → 拷贝完 → 校验完，改名之前」，用次数才能
/// 稳定地测到「写到一半被取消」这一支，而不是一开始就取消。
private final class BackupCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private let cancelAfter: Int

  init(cancelAfter: Int) {
    self.cancelAfter = cancelAfter
  }

  func next() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return calls > cancelAfter
  }
}
