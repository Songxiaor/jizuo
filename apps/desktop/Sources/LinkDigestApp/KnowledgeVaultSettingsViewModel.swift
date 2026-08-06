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

  @Published var isAutoSyncEnabled: Bool = true {
    didSet {
      guard isAutoSyncEnabled != oldValue else { return }
      store.isAutoSyncEnabled = isAutoSyncEnabled
    }
  }

  private let store: UserDefaultsKnowledgeVaultStore
  private var history: HistoryApplicationService?
  private var autoSyncTask: Task<Void, Never>?

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
    state = .idle
  }

  /// 把历史里所有抓取到的内容同步进知识库目录。
  ///
  /// 全程在主 actor 上跑：当前量级（几十条）下读库加渲染是毫秒级，为它引入
  /// 后台线程和一套 Sendable 约束不划算。条目涨到几千条时这里要改成后台执行，
  /// 判据是同步过程中窗口是否肉眼可见地卡住。
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
      try? await Task.sleep(for: .seconds(20))
      guard !Task.isCancelled else { return }
      await self?.performSync(reportingToUI: false)
    }
  }

  /// - Parameter reportingToUI: 手动同步要把进度和结果画出来；自动同步是背景
  ///   行为，不该在用户正看着设置页时突然改写上面的数字，所以只更新
  ///   「上次同步」时间，失败也只是安静地留在日志里。
  private func performSync(reportingToUI: Bool) async {
    // 手动同步进行中就让开：两个同步同时写一个目录，冲突判定会互相打架。
    if !reportingToUI, isRunning { return }
    guard let history else {
      if reportingToUI { state = .failed("历史还没准备好，请稍后重试。") }
      return
    }
    guard store.hasDirectory else {
      if reportingToUI { state = .failed("请先选择知识库文件夹。") }
      return
    }

    let lease: SecurityScopedURLLease
    do {
      guard let resolved = try store.directoryLease() else {
        if reportingToUI { state = .failed("请先选择知识库文件夹。") }
        return
      }
      lease = resolved
    } catch let error as KnowledgeVaultError {
      if reportingToUI { state = .failed(error.userMessage) }
      return
    } catch {
      if reportingToUI { state = .failed("无法访问知识库文件夹，请重新选择。") }
      return
    }
    // 租约要活到写完最后一个文件为止。
    defer { withExtendedLifetime(lease) {} }

    if reportingToUI { state = .running(done: 0, total: 0) }

    let taskIDs: [TaskID]
    do { taskIDs = try allTaskIDs(history) } catch {
      if reportingToUI { state = .failed("读取历史失败：\(error.localizedDescription)") }
      return
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
      if index % 10 == 0 {
        if reportingToUI { state = .running(done: index, total: taskIDs.count) }
        await Task.yield()
      }
    }

    let existing: [KnowledgeVaultExistingFile]
    do { existing = try KnowledgeVaultWriter.scan(directory: lease.url) } catch {
      if reportingToUI {
        state = .failed("无法读取知识库文件夹的现有文件：\(error.localizedDescription)")
      }
      return
    }

    let plan = KnowledgeVaultSync.plan(documents: documents, existing: existing)
    var report = KnowledgeVaultWriter.apply(plan, in: lease.url)
    report.failures.append(contentsOf: failures)

    // 自动同步没写任何东西时不更新「上次同步」时间：那一行是给用户看
    // 「我的素材新到什么时候」的，被一次没有产出的后台跑刷新掉就没意义了。
    if reportingToUI || report.touched > 0 {
      let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
      store.lastSyncMilliseconds = now
      lastSyncText = Self.formatted(milliseconds: now)
    }
    if reportingToUI { state = .finished(report) }
  }

  private func allTaskIDs(_ history: HistoryApplicationService) throws -> [TaskID] {
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
