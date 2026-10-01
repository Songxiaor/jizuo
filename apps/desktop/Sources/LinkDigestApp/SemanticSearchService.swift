import Foundation
import LinkDigestAdapters
import LinkDigestCore
import Observation

/// 「按意思搜」（2026-09-29）：模型下载、全库索引、查询的调度。
///
/// - 默认关。用户在设置里打开时才下载模型（约 91MB），装好后给全库建索引。
/// - 索引是 App 数据目录下单独的一个文件，不改主数据库；删掉会自动重建。
/// - 不挂钩每一处写入：启动后、以及每次搜索前，若距上次核对超过一分钟就补一遍
///   （只重算新存或改过的条目，按 `updatedAtMilliseconds` 判断）。
@MainActor
@Observable
final class SemanticSearchService {
  enum State: Equatable {
    case off
    case downloading(Double)
    case loading
    case indexing(done: Int, total: Int)
    case ready(count: Int)
    case failed(String)
  }

  static let enabledKey = "semanticSearch.enabled"
  /// 候选先多取一些，套用当前筛选、去掉关键词已命中的，再截到界面要的条数。
  /// 门槛按全库实测定（2026-09-29，1,366 条）：对题的多在第一名往下 0.05 以内，
  /// 再往后就开始混进只沾一点边的；整体低于 0.48 的基本是硬凑。
  nonisolated static let candidateLimit = 40
  nonisolated static let minimumScore: Float = 0.48
  nonisolated static let relativeWindow: Float = 0.05

  private(set) var state: State = .off
  private(set) var isEnabled: Bool

  private let modelDirectory: URL
  private let indexURL: URL
  private let defaults: UserDefaults
  private var history: HistoryApplicationService?
  private let engine = SemanticSearchEngine()
  private var lastReconciledAt: Date?
  private var workTask: Task<Void, Never>?

  init(
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LinkDigest", isDirectory: true),
    defaults: UserDefaults = .standard
  ) {
    modelDirectory = root.appendingPathComponent("Models/\(EmbeddingModelInstaller.modelID)", isDirectory: true)
    indexURL = root.appendingPathComponent("SemanticIndex/\(EmbeddingModelInstaller.modelID).ldsi")
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.enabledKey)
  }

  /// 历史库打开之后调用（只读库也可以：建索引只读不写）。开着就在后台装载并补索引。
  func configure(history: HistoryApplicationService?) {
    self.history = history
    startIfEnabled()
  }

  var isReady: Bool { if case .ready = state { true } else { false } }

  private func startIfEnabled() {
    guard isEnabled, history != nil else { return }
    prepare()
  }

  func enable() {
    isEnabled = true
    defaults.set(true, forKey: Self.enabledKey)
    prepare()
  }

  func disable() {
    isEnabled = false
    defaults.set(false, forKey: Self.enabledKey)
    workTask?.cancel()
    workTask = nil
    state = .off
  }

  /// 失败后再试一次。
  func retry() { prepare() }

  /// 与查询意思最接近的条目（相似度从高到低）。没就绪时返回空，不阻塞搜索。
  func search(_ query: String) async -> [(taskID: TaskID, score: Float)] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isReady, !text.isEmpty else { return [] }
    reconcileIfStale()
    let ranked = await engine.query(
      SemanticDocumentText.queryInstruction + text,
      limit: Self.candidateLimit, minimumScore: Self.minimumScore, relativeWindow: Self.relativeWindow
    )
    return ranked.compactMap { item in TaskID(item.taskID).map { ($0, item.score) } }
  }

  /// 距上次核对超过一分钟才补一遍，避免每敲一个字都扫全库。
  func reconcileIfStale() {
    guard isReady, workTask == nil else { return }
    if let last = lastReconciledAt, Date().timeIntervalSince(last) < 60 { return }
    workTask = Task { [weak self] in
      await self?.reconcile()
      self?.workTask = nil
    }
  }

  private func prepare() {
    workTask?.cancel()
    workTask = Task { [weak self] in
      guard let self else { return }
      await self.installAndLoad()
      if case .failed = self.state { self.workTask = nil; return }
      await self.reconcile()
      self.workTask = nil
    }
  }

  private func installAndLoad() async {
    let installer = EmbeddingModelInstaller(directory: modelDirectory)
    if !installer.isInstalled {
      state = .downloading(0)
      do {
        try await installer.install { fraction in
          Task { @MainActor [weak self] in
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(fraction)
          }
        }
      } catch {
        state = .failed(Self.message(for: error))
        return
      }
    }
    guard !Task.isCancelled, isEnabled else { return }
    state = .loading
    do {
      let count = try await engine.load(modelDirectory: modelDirectory, indexURL: indexURL)
      state = .ready(count: count)
    } catch {
      state = .failed("模型文件读不出来，点「重试」会重新下载。")
      try? FileManager.default.removeItem(at: modelDirectory)
    }
  }

  private func reconcile() async {
    guard let history, isEnabled else { return }
    let before = state
    let count = await engine.reconcile(history: history, indexURL: indexURL) { done, total in
      Task { @MainActor [weak self] in
        guard let self, self.isEnabled else { return }
        // 只在真有要算的内容时才显示进度，平常的补一遍不闪状态。
        if total > 0, done < total { self.state = .indexing(done: done, total: total) }
      }
    }
    guard isEnabled, !Task.isCancelled else { return }
    lastReconciledAt = Date()
    if let count { state = .ready(count: count) } else if case .ready = before { state = before }
  }

  private static func message(for error: Error) -> String {
    switch error as? EmbeddingModelInstaller.InstallError {
    case .checksumMismatch?: return "下载的模型文件校验不通过，已删除。点「重试」重新下载。"
    // 原因（服务器状态码、系统错误）只进日志，界面只给下一步（2026-10-01）。
    case let .downloadFailed(reason)?:
      AppLog.error(.storage, "embedding_model_download_failed", code: "EMBEDDING_DOWNLOAD_FAILED", ["reason": reason])
      return "模型没下载下来。检查网络后点「重试」。"
    case nil:
      AppLog.error(.storage, "embedding_model_install_failed", code: "EMBEDDING_INSTALL_FAILED", ["error": String(describing: error)])
      return "模型没下载下来。检查网络和磁盘空间后点「重试」。"
    }
  }
}

/// 模型与索引都在这里，离开主线程。建索引时每算一条让出一次，查询可以插进来。
actor SemanticSearchEngine {
  private var embedder: BGETextEmbedder?
  private var index = SemanticIndex(modelID: EmbeddingModelInstaller.modelID, dimension: BGETextEmbedder.dimension)

  func load(modelDirectory: URL, indexURL: URL) throws -> Int {
    embedder = try BGETextEmbedder(directory: modelDirectory)
    if let data = try? Data(contentsOf: indexURL),
       let stored = try? SemanticIndex(data: data),
       stored.modelID == EmbeddingModelInstaller.modelID, stored.dimension == BGETextEmbedder.dimension {
      index = stored
    }
    return index.entries.count
  }

  /// 补齐索引：算新存或改过的，删掉已不在库里的。返回索引条数；读库失败返回 nil。
  func reconcile(
    history: HistoryApplicationService,
    indexURL: URL,
    progress: @Sendable (Int, Int) -> Void
  ) async -> Int? {
    guard let embedder else { return nil }
    var rows: [HistoryRowProjection] = []
    var cursor: HistoryPageCursor?
    let filter = HistoryListFilter(includesNotes: true)
    repeat {
      guard let page = try? history.historyPage(limit: 500, after: cursor, filter: filter) else { return nil }
      rows += page.rows
      cursor = page.nextCursor
    } while cursor != nil

    let live = Set(rows.map(\.taskID.rawValue))
    var changed = false
    for stale in index.entries.keys where !live.contains(stale) {
      index.remove(stale)
      changed = true
    }
    let pending = rows.filter { index.entries[$0.taskID.rawValue]?.updatedAtMilliseconds != $0.updatedAtMilliseconds }
    progress(0, pending.count)
    for (offset, row) in pending.enumerated() {
      if Task.isCancelled { break }
      let text = SemanticDocumentText.make(title: row.title, sourcePreview: row.sourcePreview, artifactPreview: row.artifactPreview)
      if !text.isEmpty {
        index.set(row.taskID.rawValue, .init(updatedAtMilliseconds: row.updatedAtMilliseconds, vector: embedder.embed(text)))
        changed = true
      }
      if (offset + 1) % 50 == 0 {
        progress(offset + 1, pending.count)
        save(to: indexURL)
      }
      await Task.yield()
    }
    progress(pending.count, pending.count)
    if changed { save(to: indexURL) }
    return index.entries.count
  }

  func query(_ text: String, limit: Int, minimumScore: Float, relativeWindow: Float) -> [(taskID: String, score: Float)] {
    guard let embedder, !index.entries.isEmpty else { return [] }
    return index.ranked(query: embedder.embed(text), limit: limit, minimumScore: minimumScore, relativeWindow: relativeWindow)
  }

  private func save(to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? index.encoded().write(to: url, options: .atomic)
  }
}
