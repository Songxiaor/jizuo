import Foundation
import LinkDigestPersistence

/// 每日自动备份的定时器。
///
/// 只在汲作开着的时候工作：启动后先等两分钟（让首屏、历史库和升级迁移都落定），
/// 之后每三小时看一次「距上次成功备份是否满 24 小时」，满了才真的备份。
/// 汲作关着的时间不补算，下次打开时这条判断自然成立，补一次即可——没有常驻进程。
@MainActor
final class DailyBackupScheduler {
  /// 启动后先等一会儿：数据库结构迁移、首屏加载都在这期间完成。
  static let startupDelay: TimeInterval = 2 * 60
  /// 运行中多久检查一次。24 小时的期限用 3 小时的检查粒度兜住，最多晚 3 小时。
  static let checkInterval: TimeInterval = 3 * 60 * 60

  private let locationProvider: @Sendable () throws -> LocalDatabaseLocation
  private var loopTask: Task<Void, Never>?
  private var backupTask: Task<Void, Never>?

  init(locationProvider: @escaping @Sendable () throws -> LocalDatabaseLocation) {
    self.locationProvider = locationProvider
  }

  var isScheduled: Bool { loopTask != nil }

  func start() {
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.startupDelay))
      while !Task.isCancelled {
        await self?.checkOnce()
        try? await Task.sleep(for: .seconds(Self.checkInterval))
      }
    }
  }

  /// 停止：App 退出时调用。
  ///
  /// 除了停掉循环，还要取消**正在跑的那次备份**——它不在这个循环任务里
  /// （整库读写放到了独立的 detached 任务），只取消循环拦不住它。
  /// 备份侧看到取消会把写了一半的文件删掉，并且不记成功时间。
  func stop() {
    loopTask?.cancel()
    loopTask = nil
    backupTask?.cancel()
    backupTask = nil
  }

  /// 一次到期判断 + 备份。放到后台线程，整库读写不占主线程。
  func checkOnce() async {
    guard !Task.isCancelled else { return }
    guard let location = try? locationProvider() else { return }
    // 「上次成功时间」和开关跟着数据目录走：隔离数据目录的调试版不会读写
    // 真实 App 的备份状态。
    let preferences = DailyBackupPreferences(directoryURL: location.directoryURL)
    let task = Task.detached(priority: .utility) {
      _ = DailyBackupService(location: location, preferences: preferences)
        .runIfDue(isCancelled: { Task.isCancelled })
    }
    backupTask = task
    _ = await task.value
    backupTask = nil
  }
}
