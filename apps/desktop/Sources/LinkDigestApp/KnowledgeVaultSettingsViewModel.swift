import AppKit
import Combine
import LinkDigestAdapters
import LinkDigestCore

@MainActor
final class KnowledgeVaultSettingsViewModel: ObservableObject {
  enum State: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(KnowledgeVaultSyncReport)
    case failed(String)
  }

  @Published private(set) var directoryPath: String?
  @Published private(set) var state: State = .idle
  @Published private(set) var lastSyncText: String?
  @Published private(set) var lastAutoSyncFailureMessage: String?

  @Published var isAutoSyncEnabled: Bool = true {
    didSet {
      guard isAutoSyncEnabled != oldValue else { return }
      store.isAutoSyncEnabled = isAutoSyncEnabled
      if !isAutoSyncEnabled {
        autoSyncTask?.cancel()
        autoSyncTask = nil
      }
    }
  }

  private let store: UserDefaultsKnowledgeVaultStore
  private var history: HistoryApplicationService?
  private var autoSyncTask: Task<Void, Never>?
  /// 同一时刻只允许一次同步写目录（手动或自动）；后来的排队等前一次写完。
  private var isSyncing = false
  private var syncWaiters: [CheckedContinuation<Void, Never>] = []
  static var autoSyncDelaySeconds: Double = 20

  init(store: UserDefaultsKnowledgeVaultStore) {
    self.store = store
    // 直接写 backing store：走 published 属性会触发 didSet 再原样写回一遍。
    _isAutoSyncEnabled = Published(initialValue: store.isAutoSyncEnabled)
    load()
  }

  var hasDirectory: Bool { store.hasDirectory }

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  var canSync: Bool { history != nil && hasDirectory && !isRunning }

  /// 历史服务要等 App bootstrap 完才有，和别的设置页一样后接。
  func configure(history: HistoryApplicationService?) {
    self.history = history
  }

  func load() {
    directoryPath = store.displayPath()
    lastSyncText = store.lastSyncMilliseconds.map(Self.formatted(milliseconds:))
    // 上次选的目录还在不在，要现场问一次。目录被删或被搬走时，这里就该
    // 报出来，而不是等用户点了同步才失败。
    if store.hasDirectory {
      do {
        _ = try store.directoryLease()
      } catch let error as KnowledgeVaultError {
        state = .failed(error.userMessage)
      } catch {
        state = .failed("无法读取知识库文件夹，请重新选择。")
      }
    }
  }

  func applySelection(_ url: URL?) {
    guard let url else { return }
    do {
      try store.saveDirectory(url)
      directoryPath = url.path
      lastAutoSyncFailureMessage = nil
      state = .idle
    } catch let error as KnowledgeVaultError {
      state = .failed(error.userMessage)
    } catch {
      state = .failed("无法保存这个文件夹，请重试。")
    }
  }

  func clearDirectory() {
    store.clearDirectory()
    directoryPath = nil
    lastSyncText = nil
    lastAutoSyncFailureMessage = nil
    state = .idle
  }

  /// 把历史里所有抓取到的内容同步进知识库目录。
  ///
  /// 读库、渲染、扫目录、写文件都在后台线程跑（2026-09-24）。原来全程在主 actor 上：
  /// 库里有一千三百多条时，每抓一条新内容 20 秒后都要在主线程上把整库导出一遍、
  /// 再把目录里每个文件读一遍，这期间滑动和点击都会卡。主 actor 上只留状态更新。
  func sync() async {
    await performSync(reportingToUI: true)
  }

  /// 抓到新内容后排一次自动同步。
  ///
  /// 延迟合并：抓一批内容会连着触发很多次，每次都同步等于把整个目录反复扫。
  /// 等安静下来再跑一次，抓 10 条和抓 1 条的代价一样。
  func scheduleAutoSync() {
    guard isAutoSyncEnabled, store.hasDirectory else { return }
    autoSyncTask?.cancel()
    autoSyncTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.autoSyncDelaySeconds))
      guard !Task.isCancelled else { return }
      await self?.performSync(reportingToUI: false)
    }
  }

  /// - Parameter reportingToUI: 手动同步要把进度和结果画出来；自动同步是背景
  ///   行为，不改写手动同步的进度卡，但失败必须留下可见、可重试的状态。
  private func performSync(reportingToUI: Bool) async {
    // 手动同步进行中就让开：两个同步同时写一个目录，冲突判定会互相打架。
    if !reportingToUI, isRunning || isSyncing { return }
    // 手动同步撞上正在跑的自动同步：等它写完再开始，不并发写同一个目录。
    await acquireSyncSlot()
    defer { releaseSyncSlot() }
    guard let history else {
      reportFailure("历史还没准备好，请稍后重试。", reportingToUI: reportingToUI)
      return
    }
    guard store.hasDirectory else {
      reportFailure("请先选择知识库文件夹。", reportingToUI: reportingToUI)
      return
    }

    let lease: SecurityScopedURLLease
    do {
      guard let resolved = try store.directoryLease() else {
        reportFailure("请先选择知识库文件夹。", reportingToUI: reportingToUI)
        return
      }
      lease = resolved
    } catch let error as KnowledgeVaultError {
      reportFailure(error.userMessage, reportingToUI: reportingToUI)
      return
    } catch {
      reportFailure("无法访问知识库文件夹，请重新选择。", reportingToUI: reportingToUI)
      return
    }
    // 租约要活到写完最后一个文件为止。
    defer { withExtendedLifetime(lease) {} }

    if reportingToUI { state = .running(done: 0, total: 0) }

    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
      guard reportingToUI else { return }
      Task { @MainActor [weak self] in
        guard let self, case .running = self.state else { return }
        self.state = .running(done: done, total: total)
      }
    }
    let outcome = await Task.detached(priority: reportingToUI ? .userInitiated : .utility) {
      Self.runSync(history: history, directory: lease.url, progress: progress)
    }.value

    let report: KnowledgeVaultSyncReport
    switch outcome {
    case let .failure(message):
      reportFailure(message, reportingToUI: reportingToUI)
      return
    case let .success(value):
      report = value
    }

    // 自动同步没写任何东西时不更新「上次同步」时间：那一行是给用户看
    // 「我的素材新到什么时候」的，被一次没有产出的后台跑刷新掉就没意义了。
    if reportingToUI || report.touched > 0 {
      let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
      store.lastSyncMilliseconds = now
      lastSyncText = Self.formatted(milliseconds: now)
    }
    if reportingToUI {
      state = .finished(report)
      lastAutoSyncFailureMessage = nil
    } else if report.failures.isEmpty {
      lastAutoSyncFailureMessage = nil
    } else {
      lastAutoSyncFailureMessage = "自动同步有 \(report.failures.count) 条内容未能写入；请点“同步到知识库”查看详情并重试。"
    }
  }

  private func acquireSyncSlot() async {
    while isSyncing {
      await withCheckedContinuation { syncWaiters.append($0) }
    }
    isSyncing = true
  }

  private func releaseSyncSlot() {
    isSyncing = false
    let waiters = syncWaiters
    syncWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func reportFailure(_ message: String, reportingToUI: Bool) {
    if reportingToUI {
      state = .failed(message)
    } else {
      lastAutoSyncFailureMessage = "自动同步失败：\(message)"
    }
  }

  private enum SyncOutcome: Sendable {
    case success(KnowledgeVaultSyncReport)
    case failure(String)
  }

  /// 同步的重活：整库导出、渲染、扫目录、写文件。不碰任何界面状态，在后台线程跑。
  nonisolated private static func runSync(
    history: HistoryApplicationService,
    directory: URL,
    progress: @Sendable (Int, Int) -> Void
  ) -> SyncOutcome {
    let taskIDs: [TaskID]
    do { taskIDs = try allTaskIDs(history) } catch {
      return .failure("读取历史失败：\(error.localizedDescription)")
    }

    var documents: [KnowledgeVaultDocument] = []
    var failures: [KnowledgeVaultFailureEntry] = []
    for (index, taskID) in taskIDs.enumerated() {
      do {
        let projection = try history.exportProjection(taskID: taskID)
        // 笔记、稿件、成品留在汲作里，不进知识库。
        guard KnowledgeVaultRenderer.isSyncable(projection) else { continue }
        documents.append(KnowledgeVaultRenderer.render(projection))
      } catch {
        failures.append(
          .init(filename: taskID.rawValue, message: "读取失败：\(error.localizedDescription)")
        )
      }
      if index % 20 == 0 { progress(index, taskIDs.count) }
    }

    let existing: [KnowledgeVaultExistingFile]
    do { existing = try KnowledgeVaultWriter.scan(directory: directory) } catch {
      return .failure("无法读取知识库文件夹的现有文件：\(error.localizedDescription)")
    }

    let plan = KnowledgeVaultSync.plan(documents: documents, existing: existing)
    var report = KnowledgeVaultWriter.apply(plan, in: directory)
    report.failures.append(contentsOf: failures)
    return .success(report)
  }

  nonisolated private static func allTaskIDs(_ history: HistoryApplicationService) throws -> [TaskID] {
    var ids: [TaskID] = []
    var cursor: HistoryPageCursor?
    // 分页读完整个历史。上限只是防御：真出现环状游标时不至于转不出来。
    for _ in 0..<1_000 {
      let page = try history.historyPage(limit: 200, after: cursor)
      ids.append(contentsOf: page.rows.map(\.taskID))
      guard let next = page.nextCursor else { break }
      cursor = next
    }
    return ids
  }

  private static func formatted(milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}
