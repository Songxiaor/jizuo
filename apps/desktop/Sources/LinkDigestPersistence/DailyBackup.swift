import Foundation
import LinkDigestCore

public extension Notification.Name {
  /// 每日自动备份跑完（成功或失败）时发一次。设置页据此刷新备份记录，
  /// 用户开着设置页时也不会看到过期的列表。
  static let dailyBackupDidFinish = Notification.Name("LinkDigestDailyBackupDidFinish")
}

/// 每日自动备份的用户偏好与「上次结果」。
///
/// 存成**数据目录里的一个小 JSON 文件**，而不是 UserDefaults：调试版用
/// `LINKDIGEST_…` 指向隔离数据目录时，UserDefaults 仍然属于同一个 App，
/// 两边会互相改写「上次成功时间」和开关——隔离启动会假装真实资料已经备份过，
/// 或者把用户关掉的开关又打开。状态跟着数据目录走，这个问题就不存在了。
///
/// 默认开启：文件不存在、读不出来或字段缺失时都按开启处理。
public struct DailyBackupPreferences: @unchecked Sendable {
  public static let fileName = "daily-backup-state.json"
  /// 两次成功备份之间至少隔一天。
  public static let interval: TimeInterval = 24 * 60 * 60

  /// 设置页和定时器各自构造一个实例，写的是同一个文件，所以锁按类型共用。
  private static let lock = NSLock()

  private struct State: Codable {
    var enabled: Bool?
    var lastSuccessAt: Double?
    var lastFailureAt: Double?
    var lastFailureReason: String?
  }

  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  public var fileURL: URL {
    directoryURL.appendingPathComponent(Self.fileName)
  }

  public var isEnabled: Bool {
    get { read().enabled ?? true }
    nonmutating set { update { $0.enabled = newValue } }
  }

  public var lastSuccessAt: Date? {
    read().lastSuccessAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
  }

  public var lastFailureAt: Date? {
    read().lastFailureAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
  }

  public var lastFailureReason: String? {
    let value = read().lastFailureReason
    return (value?.isEmpty ?? true) ? nil : value
  }

  /// 从来没有成功备份过，或者离上次成功满 24 小时，就该备份了。
  /// App 没开着的时间不算额外条件：下次打开时这里自然判定为到期。
  public func isDue(now: Date = Date()) -> Bool {
    guard let lastSuccessAt else { return true }
    return now.timeIntervalSince(lastSuccessAt) >= Self.interval
  }

  public func recordSuccess(at date: Date) {
    update {
      $0.lastSuccessAt = date.timeIntervalSince1970
      $0.lastFailureAt = nil
      $0.lastFailureReason = nil
    }
  }

  public func recordFailure(at date: Date, reason: String) {
    update {
      $0.lastFailureAt = date.timeIntervalSince1970
      $0.lastFailureReason = reason
    }
  }

  private func read() -> State {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return readUnlocked()
  }

  private func readUnlocked() -> State {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(State.self, from: data)
    else { return State() }
    return state
  }

  private func update(_ mutate: (inout State) -> Void) {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var state = readUnlocked()
    mutate(&state)
    guard let data = try? JSONEncoder().encode(state) else { return }
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // 状态文件写不进去时不让备份本身失败：最坏是下次多备一份，
      // 比因为记不下时间而完全停止备份要好。
    }
  }
}

/// 进程内「正在整库备份/恢复」的互斥标记。
///
/// 备份、恢复、数据库结构迁移都会整库读写；同时跑两份轻则白费磁盘，
/// 重则让恢复读到一半的备份。设置页的手动操作和每日备份都从这里过一道，
/// 抢不到就明确地说「正在备份」，不排队、不覆盖。
public enum DatabaseBackupActivity {
  private static let lock = NSLock()
  /// 由 `lock` 保护的进程内标记，Swift 6 检查器看不到锁的语义。
  nonisolated(unsafe) private static var isRunning = false

  public static func tryBegin() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isRunning else { return false }
    isRunning = true
    return true
  }

  public static func end() {
    lock.lock()
    isRunning = false
    lock.unlock()
  }
}

/// 手动备份/恢复撞上自动备份时抛这个，设置页据此给出「稍等一下」。
public struct DatabaseBackupBusyError: Error, Sendable {
  public init() {}
}

public enum DailyBackupResult: Sendable, Equatable {
  case disabled
  case notDue
  /// 手动备份/恢复正在跑；这次让路，下次检查再来。
  case busy
  /// 还没有资料库（全新安装），没什么可备份的。
  case noDatabase
  /// App 正在退出（或其他原因取消了定时器）。半成品已经删掉，不记成功也不记失败。
  case cancelled
  case succeeded(DatabaseBackupFile)
  case failed(reason: String)
}

/// 每日自动备份的执行体。同步、会读整库，调用方负责放到后台线程。
public struct DailyBackupService: Sendable {
  public let location: LocalDatabaseLocation
  public let preferences: DailyBackupPreferences
  /// 只给测试注入「校验失败」用。nil 时走 `DatabaseMaintenance.verifyBackup`。
  private let verifyOverride: (@Sendable (URL) throws -> Void)?

  public init(
    location: LocalDatabaseLocation,
    preferences: DailyBackupPreferences,
    verifyBackup: (@Sendable (URL) throws -> Void)? = nil
  ) {
    self.location = location
    self.preferences = preferences
    self.verifyOverride = verifyBackup
  }

  /// 跑一次到期检查并备份。
  ///
  /// `isCancelled` 由定时器传入：App 退出时定时器会停掉，备份在半路被取消就
  /// 删掉写了一半的文件，既不记成功也不记失败——否则下次启动会以为今天已经备份过。
  public func runIfDue(
    now: Date = Date(),
    isCancelled: () -> Bool = { false }
  ) -> DailyBackupResult {
    guard preferences.isEnabled else { return .disabled }
    guard preferences.isDue(now: now) else { return .notDue }
    guard FileManager.default.fileExists(atPath: location.databaseURL.path) else { return .noDatabase }
    guard DatabaseBackupActivity.tryBegin() else { return .busy }
    defer { DatabaseBackupActivity.end() }

    if isCancelled() { return .cancelled }

    do {
      let store = DatabaseBackupStore(location: location)
      try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
      // 上次崩溃留下的写备份临时文件：不清掉会一直占着和库同量级的磁盘。
      store.removeStaleDailyPartials()

      if let shortfall = diskShortfallDescription() {
        return recordFailure(
          "磁盘空间不够（\(shortfall)），这次没有备份。旧备份都还在，清理空间后会自动再试。",
          at: now
        )
      }

      let file = try DatabaseMaintenance.dailyBackup(
        at: location,
        now: now,
        verify: verifyOverride,
        isCancelled: isCancelled
      )
      // 取消可能刚好发生在备份写完、改名之前/之后：这一步之后才写成功时间。
      if isCancelled() {
        try? FileManager.default.removeItem(at: file.url)
        return .cancelled
      }

      // 修剪失败只影响占地方，不该把一次成功的备份记成失败。
      _ = try? store.pruneDailyBackups()
      preferences.recordSuccess(at: now)
      NotificationCenter.default.post(name: .dailyBackupDidFinish, object: nil)
      return .succeeded(file)
    } catch {
      if isCancelled() || error is CancellationError { return .cancelled }
      return recordFailure(Self.message(for: error), at: now)
    }
  }

  private func recordFailure(_ reason: String, at date: Date) -> DailyBackupResult {
    preferences.recordFailure(at: date, reason: reason)
    NotificationCenter.default.post(name: .dailyBackupDidFinish, object: nil)
    return .failed(reason: reason)
  }

  /// 留够「数据库本身的量级」的空间再动手。拿不到剩余空间时不去拦——
  /// 那种情况下真正的失败会由写文件那一步给出。
  ///
  /// 用 `volumeAvailableCapacity`（实际能写进去的空间），不用
  /// `…ForImportantUsage`：后者把系统「可清理」的缓存也算成可用，磁盘明明
  /// 快满了它也报好几 GB，备份写到一半才失败，还可能连累其他写入。
  private func diskShortfallDescription() -> String? {
    let values = try? location.directoryURL.resourceValues(
      forKeys: [.volumeAvailableCapacityKey]
    )
    guard let available = values?.volumeAvailableCapacity else { return nil }
    let free = Int64(available)
    let databaseBytes = [location.databaseURL, location.walURL].reduce(Int64(0)) { total, url in
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber else { return total }
      return total + size.int64Value
    }
    // 两份：备份本身 + SQLite 写备份时的临时开销；再加 20MB 垫底，避免把磁盘用到见底。
    let required = max(databaseBytes * 2, 20 * 1_024 * 1_024)
    guard free < required else { return nil }
    return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
  }

  public static func message(for error: Error) -> String {
    guard let failure = error as? RepositoryFailure else {
      return "这次自动备份没成功，下次打开汲作会再试。"
    }
    switch failure {
    case .readOnly:
      return "资料库现在是只读的，这次没有备份。"
    case .integrityCheckFailed:
      return "备份写完后校验没通过，这份文件没有保留；旧备份都还在。"
    case .invalidInput:
      return "备份文件重名，这次跳过了；下次会自动再试。"
    default:
      return "这次自动备份没成功，下次打开汲作会再试。"
    }
  }
}
