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
  /// 是不是「升级前自动存的那种」。只有这种会被 `pruneAutomaticBackups` 清理。
  public let isAutomatic: Bool
  /// 是不是「每日自动」那一类。它有自己的 7 份上限，和升级前备份互不干涉。
  public let isDaily: Bool
  /// 是不是「恢复备份之前先存的那份」。它也是用户看得见的备份记录，
  /// 设置页要按「恢复前备份」显示，不能一律叫「手动备份」。
  public let isBeforeRestore: Bool

  public var id: String { url.path }
  public var name: String { url.lastPathComponent }

  public init(
    url: URL,
    createdAt: Date,
    byteCount: Int64,
    isAutomatic: Bool,
    isDaily: Bool = false,
    isBeforeRestore: Bool = false
  ) {
    self.url = url
    self.createdAt = createdAt
    self.byteCount = byteCount
    self.isAutomatic = isAutomatic
    self.isDaily = isDaily
    self.isBeforeRestore = isBeforeRestore
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
  /// 每日自动备份保留的份数。一周的量，够回退到「前几天突然发现不对」的那个点。
  public static let retainedDailyBackupCount = 7

  private static let automaticPrefix = "history-v"
  private static let dailyPrefix = "history-daily-"
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

  /// 每日自动备份的独立前缀。刻意不叫 `history-v…`：升级前备份的 3 份上限
  /// 只会修剪 `history-v` 开头的文件，两类备份的生命周期互不干扰。
  public static func dailyFileName(at date: Date) -> String {
    "\(dailyPrefix)\(timestamp(date))\(suffix)"
  }

  /// 名字是不是一份**格式完整**的每日备份：`history-daily-<yyyyMMdd-HHmmss>[-N].sqlite`。
  ///
  /// 修剪只认这个格式。以前按「前缀 + .sqlite」判断，`history-daily-备份.sqlite`
  /// 这种用户自己改过名的文件也会被算进 7 份里，数量一到就被删掉。
  public static func isDailyFileName(_ name: String) -> Bool {
    guard name.hasPrefix(dailyPrefix), name.hasSuffix(suffix) else { return false }
    let core = name.dropFirst(dailyPrefix.count).dropLast(suffix.count)
    let parts = core.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else { return false }
    let stamp = parts[0]
    let time = parts[1]
    guard stamp.count == 8, stamp.allSatisfy({ $0.isNumber }) else { return false }
    guard time.count == 6, time.allSatisfy({ $0.isNumber }) else { return false }
    if parts.count == 3 {
      guard !parts[2].isEmpty, parts[2].allSatisfy({ $0.isNumber }) else { return false }
    }
    return true
  }

  /// 崩溃遗留的写备份临时文件：`…sqlite.partial`，以及 SQLite 可能顺带留下的
  /// `-journal`/`-wal`/`-shm`。只认每日备份的完整名字，别的一概不碰。
  static func isDailyPartialArtifactName(_ name: String) -> Bool {
    if let base = partialBase(of: name) {
      return isDailyFileName(base)
    }
    return false
  }

  private static func partialBase(of name: String) -> String? {
    let partialSuffix = "\(suffix).partial"
    for companion in ["", "-journal", "-wal", "-shm"] where name.hasSuffix(partialSuffix + companion) {
      return String(name.dropLast((partialSuffix + companion).count)) + suffix
    }
    return nil
  }

  /// 清掉上次崩溃留下的每日备份临时文件。返回删掉的文件。
  ///
  /// 只匹配每日备份的完整文件名格式（含 `-N` 那种重名后缀），备份目录里别的
  /// 文件——用户自己放的东西、手动备份的临时文件——一律不动。
  @discardableResult
  public func removeStaleDailyPartials() -> [URL] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directoryURL.path) else { return [] }
    var removed: [URL] = []
    for name in names where Self.isDailyPartialArtifactName(name) {
      let url = directoryURL.appendingPathComponent(name)
      do {
        try manager.removeItem(at: url)
        removed.append(url)
      } catch {
        continue
      }
    }
    return removed
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
        let name = url.lastPathComponent
        return DatabaseBackupFile(
          url: url,
          createdAt: values?.contentModificationDate ?? .distantPast,
          byteCount: Int64(values?.fileSize ?? 0),
          isAutomatic: name.hasPrefix(Self.automaticPrefix),
          isDaily: Self.isDailyFileName(name),
          isBeforeRestore: name.hasPrefix(Self.beforeRestorePrefix)
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
    try prune(where: \.isAutomatic, keeping: limit)
  }

  /// 只清每日自动备份，手动备份、升级前备份和恢复前备份一份都不碰。
  @discardableResult
  public func pruneDailyBackups(keeping limit: Int = retainedDailyBackupCount) throws -> [URL] {
    try prune(where: \.isDaily, keeping: limit)
  }

  private func prune(where matches: (DatabaseBackupFile) -> Bool, keeping limit: Int) throws -> [URL] {
    let candidates = try backups().filter(matches)
    guard candidates.count > max(0, limit) else { return [] }
    var removed: [URL] = []
    for file in candidates.dropFirst(max(0, limit)) {
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
    return try Self.describe(url, isAutomatic: false)
  }

  /// 每日自动备份：只读打开当前库做一份拷贝，写完先校验再改名成正式文件。
  ///
  /// **刻意不走 `LocalDatabase.open`**。那条路径在库版本落后时会在打开过程中升级
  /// schema；恢复旧备份后到重启之前，定时备份若走它，就会在后台把刚恢复的库升了级，
  /// 用户还没重启，磁盘上的「恢复结果」已经不是他选的那份备份了。每日备份只需要读，
  /// 所以这里用只读连接：不改 schema、不做平台分类重算，也不留写锁。
  ///
  /// 写的是 `.sqlite.partial` 临时文件：中途失败、App 被杀、被取消或校验没过时，
  /// 删掉的是这份临时文件，备份列表里不会出现一个「看起来像备份、其实打不开」的文件。
  /// `verify` 参数只给测试注入失败用，正常走 `verifyBackup(at:)`。
  public static func dailyBackup(
    at location: LocalDatabaseLocation,
    now: Date = Date(),
    dependencies: PersistenceDependencies = .live,
    verify: ((URL) throws -> Void)? = nil,
    isCancelled: () -> Bool = { false }
  ) throws -> DatabaseBackupFile {
    let store = DatabaseBackupStore(location: location)
    let url = try uniqueDailyURL(store: store, now: now)
    let temporaryURL = url.appendingPathExtension("partial")
    removePartialArtifacts(at: temporaryURL)
    do {
      try dependencies.beforeBackup()
      let source = try openReadOnlySource(at: location, dependencies: dependencies)
      defer { try? source.close() }
      _ = try copy(from: source, to: temporaryURL, dependencies: dependencies)
      if isCancelled() { throw CancellationError() }
      if let verify { try verify(temporaryURL) } else { try verifyBackupFile(at: temporaryURL) }
      if isCancelled() { throw CancellationError() }
      try FileManager.default.moveItem(at: temporaryURL, to: url)
      // 改名只带走主文件；校验时 SQLite 留下的 `.partial-shm` 等要在这里清掉。
      removePartialArtifacts(at: temporaryURL)
    } catch {
      removePartialArtifacts(at: temporaryURL)
      throw error
    }
    return try describe(url, isAutomatic: false, isDaily: true)
  }

  /// 同一秒里跑两次时避免撞名：`history-daily-时间戳-2.sqlite`。
  private static func uniqueDailyURL(store: DatabaseBackupStore, now: Date) throws -> URL {
    let base = store.url(forFileName: DatabaseBackupStore.dailyFileName(at: now))
    var candidate = base
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = store.url(
        forFileName: base.deletingPathExtension().lastPathComponent + "-\(index).sqlite"
      )
      index += 1
    }
    return candidate
  }

  /// 只读打开当前库。WAL 库的只读连接要求旁边已有 `-shm`；单独拷来的
  /// `history.sqlite` 没有它，先用普通连接读一次版本号让 SQLite 建出来
  /// （只建共享内存文件，不改任何表），再走只读。
  private static func openReadOnlySource(
    at location: LocalDatabaseLocation,
    dependencies: PersistenceDependencies
  ) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(2)
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
    do {
      return try dependencies.openReadOnly(location.databaseURL.path, configuration)
    } catch {
      guard !FileManager.default.fileExists(atPath: location.sharedMemoryURL.path) else {
        throw RepositoryFailure.unavailable
      }
      do {
        let primer = try DatabaseQueue(path: location.databaseURL.path)
        _ = try primer.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        try primer.close()
      } catch {
        throw RepositoryFailure.unavailable
      }
      do {
        return try dependencies.openReadOnly(location.databaseURL.path, configuration)
      } catch {
        throw RepositoryFailure.unavailable
      }
    }
  }

  /// 把只读来源整库拷进 `backupURL`，并转成自包含的 DELETE 日志模式。
  private static func copy(
    from source: DatabaseQueue,
    to backupURL: URL,
    dependencies: PersistenceDependencies
  ) throws -> HistoryTableCounts {
    do {
      guard !FileManager.default.fileExists(atPath: backupURL.path) else {
        throw RepositoryFailure.invalidInput
      }
      try dependencies.createDirectory(backupURL.deletingLastPathComponent())
      let destination = try DatabaseQueue(path: backupURL.path)
      do {
        try source.backup(to: destination)
        try destination.writeWithoutTransaction { db in
          let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
          guard mode?.lowercased() == "delete" else { throw RepositoryFailure.unavailable }
        }
        let value = try destination.read(readTableCounts)
        try destination.close()
        return value
      } catch is CancellationError {
        try? destination.close()
        throw CancellationError()
      } catch {
        try? destination.close()
        throw error
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as RepositoryFailure {
      throw failure
    } catch {
      throw RepositoryFailure.unavailable
    }
  }

  private static func removePartialArtifacts(at url: URL) {
    for companion in ["", "-journal", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + companion)
    }
  }

  /// 校验一份备份文件本身能打开且内容完整。校验不通过就抛
  /// `integrityCheckFailed`，调用方负责删掉不合格的文件。
  public func verifyBackup(at url: URL) throws {
    try Self.verifyBackupFile(at: url)
  }

  static func verifyBackupFile(at url: URL) throws {
    do {
      var readOnly = Configuration()
      readOnly.readonly = true
      let queue = try DatabaseQueue(path: url.path, configuration: readOnly)
      do {
        let integrity = try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
        try queue.close()
        guard integrity == "ok" else { throw RepositoryFailure.integrityCheckFailed }
      } catch {
        try? queue.close()
        throw error
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
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
    return try Self.describe(url, isAutomatic: false, isBeforeRestore: true)
  }

  private static func describe(
    _ url: URL,
    isAutomatic: Bool,
    isDaily: Bool = false,
    isBeforeRestore: Bool = false
  ) throws -> DatabaseBackupFile {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return DatabaseBackupFile(
      url: url,
      createdAt: values?.contentModificationDate ?? Date(),
      byteCount: Int64(values?.fileSize ?? 0),
      isAutomatic: isAutomatic,
      isDaily: isDaily,
      isBeforeRestore: isBeforeRestore
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
