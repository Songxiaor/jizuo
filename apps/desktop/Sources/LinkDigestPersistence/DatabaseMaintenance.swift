import Foundation
import GRDB
import LinkDigestCore

public struct DatabaseCheckpoint: Codable, Sendable, Equatable {
  public let busy: Int
  public let logFrames: Int
  public let checkpointedFrames: Int
  public init(busy: Int, logFrames: Int, checkpointedFrames: Int) { self.busy = busy; self.logFrames = logFrames; self.checkpointedFrames = checkpointedFrames }
}

public struct HistoryTableCounts: Codable, Sendable, Equatable {
  public let tasks: Int
  public let snapshots: Int
  public let deliveries: Int
  public let runs: Int
  public let artifacts: Int
  public init(tasks: Int, snapshots: Int, deliveries: Int, runs: Int, artifacts: Int) {
    self.tasks = tasks; self.snapshots = snapshots; self.deliveries = deliveries; self.runs = runs; self.artifacts = artifacts
  }
}

/// 备份目录里的一份文件。
public struct DatabaseBackupFile: Sendable, Equatable, Identifiable {
  public let url: URL
  public let createdAt: Date
  public let byteCount: Int64
  /// 是不是「升级前自动存的那种」。只有这种会被数量上限清理。
  public let isAutomatic: Bool

  public var id: String { url.path }
  public var name: String { url.lastPathComponent }

  public init(url: URL, createdAt: Date, byteCount: Int64, isAutomatic: Bool) {
    self.url = url
    self.createdAt = createdAt
    self.byteCount = byteCount
    self.isAutomatic = isAutomatic
  }
}

/// `<数据目录>/backups/` 的命名、列举和清理。
///
/// 自动备份和手动备份分开命名，因为它们的生命周期不同：自动备份是升级留下的
/// 保险绳，只保留最近几份；手动备份是用户自己按下的，一份都不该被程序删掉。
public struct DatabaseBackupStore: Sendable {
  public static let directoryName = "backups"
  /// 升级前自动备份保留的份数。
  ///
  /// 3 份的理由：一份能救最近一次升级，多留两份是给「升级后过了几天才发现不对」
  /// 留的余量。再多只是占着和主库同量级的磁盘，而更老的备份对应的是更老的
  /// schema，恢复回去也要再升一次级，价值递减得很快。
  public static let retainedAutomaticBackupCount = 3

  private static let automaticPrefix = "history-v"
  private static let manualPrefix = "history-manual-"
  private static let beforeRestorePrefix = "history-before-restore-"
  private static let suffix = ".sqlite"

  public let directoryURL: URL

  public init(location: LocalDatabaseLocation) {
    directoryURL = location.directoryURL.appendingPathComponent(Self.directoryName, isDirectory: true)
  }

  public init(directoryURL: URL) { self.directoryURL = directoryURL }

  /// 时间戳用本地时间的 `yyyyMMdd-HHmmss`：按字典序排就是按时间排，
  /// 用户在 Finder 里也能直接读出来是哪天的。
  public static func timestamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02d-%02d%02d%02d",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
    )
  }

  public static func automaticFileName(schemaVersion: Int, at date: Date) -> String {
    "\(automaticPrefix)\(schemaVersion)-\(timestamp(date))\(suffix)"
  }

  public static func manualFileName(at date: Date) -> String {
    "\(manualPrefix)\(timestamp(date))\(suffix)"
  }

  public static func beforeRestoreFileName(at date: Date) -> String {
    "\(beforeRestorePrefix)\(timestamp(date))\(suffix)"
  }

  public func url(forFileName name: String) -> URL {
    directoryURL.appendingPathComponent(name)
  }

  /// 目录里现有的备份，新的在前。目录不存在时返回空数组而不是抛错——
  /// 「还没备份过」是正常状态，不该让设置页进错误分支。
  public func backups() throws -> [DatabaseBackupFile] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directoryURL.path) else { return [] }
    let entries: [URL]
    do {
      entries = try manager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    } catch { throw RepositoryFailure.unavailable }
    return entries
      .filter { $0.lastPathComponent.hasSuffix(Self.suffix) }
      .compactMap { url -> DatabaseBackupFile? in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return DatabaseBackupFile(
          url: url,
          createdAt: values?.contentModificationDate ?? .distantPast,
          byteCount: Int64(values?.fileSize ?? 0),
          isAutomatic: url.lastPathComponent.hasPrefix(Self.automaticPrefix)
        )
      }
      .sorted { left, right in
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.name > right.name
      }
  }

  /// 只清自动备份，且只在超出上限时清。手动备份和恢复前存的那份一律不动。
  @discardableResult
  public func pruneAutomaticBackups(keeping limit: Int = retainedAutomaticBackupCount) throws -> [URL] {
    let automatic = try backups().filter(\.isAutomatic)
    guard automatic.count > max(0, limit) else { return [] }
    var removed: [URL] = []
    for file in automatic.dropFirst(max(0, limit)) {
      do {
        try FileManager.default.removeItem(at: file.url)
        removed.append(file.url)
      } catch {
        // 删不掉一份旧备份不该让打开数据库失败：它只是占地方，不影响正确性。
        continue
      }
    }
    return removed
  }
}

public struct DatabaseMaintenance: Sendable {
  private let database: LocalDatabase
  public init(database: LocalDatabase) { self.database = database }

  public var backupStore: DatabaseBackupStore { DatabaseBackupStore(location: database.location) }

  /// 「立即备份」：存进 `backups/`，返回刚写好的那份。
  public func backupToStore(now: Date = Date()) throws -> DatabaseBackupFile {
    let store = backupStore
    let url = store.url(forFileName: DatabaseBackupStore.manualFileName(at: now))
    _ = try backup(to: url)
    return try describe(url, isAutomatic: false)
  }

  /// 从备份整库写回当前库。
  ///
  /// 走 SQLite 的在线备份 API 直接写进**当前打开的**库，而不是移动文件：App 运行
  /// 期间 `LocalDatabase` 的连接池一直开着，把文件从底下换掉是那种「本机看着好了、
  /// 换台机器 WAL 就对不上」的做法。
  ///
  /// 写回前先把当前库另存一份（返回的就是它）：选错备份文件是完全可能发生的，
  /// 而没有这一步就回不来了。
  ///
  /// 写完仍然要求重启 App——进程里已经加载的页面、缓存和视图模型仍是旧内容。
  @discardableResult
  public func restoreInPlace(from backupURL: URL, now: Date = Date()) throws -> DatabaseBackupFile {
    do {
      try database.dependencies.beforeRestore()
      guard FileManager.default.fileExists(atPath: backupURL.path) else { throw RepositoryFailure.invalidInput }
      let safetyCopy = try backupBeforeRestore(now: now)

      var readOnly = Configuration()
      readOnly.readonly = true
      readOnly.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
      let source = try database.dependencies.openReadOnly(backupURL.path, readOnly)
      let integrity = try source.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
      let expected = try source.read(readTableCounts)
      guard integrity == "ok" else {
        try? source.close()
        throw RepositoryFailure.integrityCheckFailed
      }
      do {
        try database.restoreDestination(from: source)
        try source.close()
      } catch {
        try? source.close()
        throw error
      }
      let actual = try database.read(readTableCounts)
      guard actual == expected else { throw RepositoryFailure.integrityCheckFailed }
      return safetyCopy
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  private func backupBeforeRestore(now: Date) throws -> DatabaseBackupFile {
    let store = backupStore
    let url = store.url(forFileName: DatabaseBackupStore.beforeRestoreFileName(at: now))
    _ = try backup(to: url)
    return try describe(url, isAutomatic: false)
  }

  private func describe(_ url: URL, isAutomatic: Bool) throws -> DatabaseBackupFile {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return DatabaseBackupFile(
      url: url,
      createdAt: values?.contentModificationDate ?? Date(),
      byteCount: Int64(values?.fileSize ?? 0),
      isAutomatic: isAutomatic
    )
  }

  public func integrityCheck() throws -> String {
    try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
  }

  public func counts() throws -> HistoryTableCounts {
    try database.read(readTableCounts)
  }

  public func passiveCheckpoint() throws -> DatabaseCheckpoint { try checkpoint("PASSIVE") }
  public func truncateCheckpoint() throws -> DatabaseCheckpoint { try checkpoint("TRUNCATE") }

  public func backup(to backupURL: URL) throws -> HistoryTableCounts {
    do {
      try database.dependencies.beforeBackup()
      guard !FileManager.default.fileExists(atPath: backupURL.path) else { throw RepositoryFailure.invalidInput }
      try database.dependencies.createDirectory(backupURL.deletingLastPathComponent())
      let destination = try DatabaseQueue(path: backupURL.path)
      do {
        try database.backupSource(to: destination)
        try destination.writeWithoutTransaction { db in
          let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
          guard mode?.lowercased() == "delete" else { throw RepositoryFailure.unavailable }
        }
        let value = try destination.read(readTableCounts)
        try destination.close()
        return value
      } catch {
        try? destination.close()
        try? FileManager.default.removeItem(at: backupURL)
        throw error
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  public static func restore(from backupURL: URL, to location: LocalDatabaseLocation, dependencies: PersistenceDependencies = .live) throws -> LocalDatabase {
    do {
      try dependencies.beforeRestore()
      guard !FileManager.default.fileExists(atPath: location.databaseURL.path) else { throw RepositoryFailure.invalidInput }
      try dependencies.createDirectory(location.directoryURL)
      let stagingURL = location.directoryURL.appendingPathComponent(".restore-\(UUID().uuidString.lowercased()).sqlite")
      defer { try? FileManager.default.removeItem(at: stagingURL) }

      var readOnly = Configuration(); readOnly.readonly = true; readOnly.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
      let source = try dependencies.openReadOnly(backupURL.path, readOnly)
      let expected = try source.read(readTableCounts)
      let destination = try DatabaseQueue(path: stagingURL.path)
      try source.backup(to: destination)
      try source.close()
      try destination.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") }
      try destination.close()

      let verification = try dependencies.openReadOnly(stagingURL.path, readOnly)
      let integrity = try verification.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
      let actual = try verification.read(readTableCounts)
      let foreignKeyFailures = try verification.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
      try verification.close()
      guard integrity == "ok", expected == actual, foreignKeyFailures == 0 else { throw RepositoryFailure.integrityCheckFailed }

      try FileManager.default.moveItem(at: stagingURL, to: location.databaseURL)
      return try LocalDatabase.open(at: location, dependencies: dependencies)
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  private func checkpoint(_ mode: String) throws -> DatabaseCheckpoint {
    try database.writeWithoutTransaction { db in
      guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(\(mode))") else { throw RepositoryFailure.unavailable }
      return DatabaseCheckpoint(busy: row[0], logFrames: row[1], checkpointedFrames: row[2])
    }
  }
}

private func readTableCounts(_ db: Database) throws -> HistoryTableCounts {
  HistoryTableCounts(
    tasks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? 0,
    snapshots: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM content_snapshots") ?? 0,
    deliveries: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_deliveries") ?? 0,
    runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? 0,
    artifacts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts") ?? 0
  )
}
