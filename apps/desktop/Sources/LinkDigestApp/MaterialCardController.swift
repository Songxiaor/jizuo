import Foundation
import Observation
import LinkDigestCore

/// 「视频转写后自动做素材卡」的开关。默认关；存在 UserDefaults（界面偏好，不是资料）。
struct MaterialCardPreferences {
  static let autoKey = "materialCard.autoAfterTranscript"
  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var autoAfterTranscript: Bool {
    get { defaults.bool(forKey: Self.autoKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.autoKey) }
  }
}

/// 谁触发了转写完成。**只有** `manualSingle`（用户在阅读页点「转写」，单条）可能带出自动素材卡；
/// 批量入口（博主页批量、导入后队列、MCP 批量/加链接）一律不触发，哪怕开关是开的。
enum TranscriptionOrigin: Equatable, Sendable {
  case manualSingle
  case batchOrQueue
  case agent
}

/// 素材卡的流程控制：单条手动生成、转写后自动生成、批量补做。
///
/// 安全顺序写死在这里：
/// 1. 只读状态不生成；
/// 2. 发模型前过数据去向确认（`ModelCallGate`）：手动/批量会问；自动路径**不会替用户确认**，没确认过就不做；
/// 3. 批量：先给估算（条数、文字量），用户确认后才跑；逐条串行、可停止；每条只试一次，不重试；
///    连续失败 3 次或遇到密钥/网络/服务拒绝就整批停下，不继续烧钱。
@MainActor
@Observable
final class MaterialCardController {
  enum ItemState: Equatable {
    case idle
    case needsConsent(host: String, model: String)
    case working
    case failed(String)
  }

  struct BatchEstimate: Equatable {
    let count: Int
    let characters: Int
    /// 输入 token 粗估（系统提示 + 转写稿，按中文 1 字约 1 token）。
    let estimatedInputTokens: Int
    /// 输出 token 粗估（每张卡约 300）。
    let estimatedOutputTokens: Int
    /// 需要先确认数据去向时有值。
    let needsConsent: (host: String, model: String)?

    static func == (lhs: BatchEstimate, rhs: BatchEstimate) -> Bool {
      lhs.count == rhs.count && lhs.characters == rhs.characters
        && lhs.estimatedInputTokens == rhs.estimatedInputTokens
        && lhs.needsConsent?.host == rhs.needsConsent?.host && lhs.needsConsent?.model == rhs.needsConsent?.model
    }
  }

  enum BatchState: Equatable {
    case idle
    case estimating
    case estimate(BatchEstimate)
    case running(done: Int, total: Int, failed: Int)
    case finished(String)
    case failed(String)
  }

  static let consecutiveFailureLimit = 3
  static let estimatedOutputTokensPerCard = 300

  private(set) var itemStates: [TaskID: ItemState] = [:]
  private(set) var records: [TaskID: TaskMaterialCardRecord] = [:]
  private(set) var batchState: BatchState = .idle
  /// 调用模型的次数（测试断言「批量不触发」用）。
  private(set) var generationAttempts = 0

  var autoAfterTranscript: Bool {
    get { preferences.autoAfterTranscript }
    set { preferences.autoAfterTranscript = newValue }
  }

  private let service: MaterialCardService
  private let gate: ModelCallGate
  private let isReadOnly: () -> Bool
  private let preferences: MaterialCardPreferences
  private let didChange: (TaskID) -> Void
  private var itemTasks: [TaskID: Task<Void, Never>] = [:]
  private var batchTask: Task<Void, Never>?
  private var pendingBatch: [MaterialCardCandidate] = []

  init(
    service: MaterialCardService,
    gate: ModelCallGate,
    isReadOnly: @escaping () -> Bool,
    preferences: MaterialCardPreferences = MaterialCardPreferences(),
    didChange: @escaping (TaskID) -> Void = { _ in }
  ) {
    self.service = service
    self.gate = gate
    self.isReadOnly = isReadOnly
    self.preferences = preferences
    self.didChange = didChange
  }

  func state(for taskID: TaskID) -> ItemState { itemStates[taskID] ?? .idle }
  func record(for taskID: TaskID) -> TaskMaterialCardRecord? { records[taskID] }

  var isBatchActive: Bool {
    switch batchState {
    case .estimating, .running: true
    default: false
    }
  }

  // MARK: 读取

  func load(taskID: TaskID) async {
    let store = service.store
    let loaded = await Task.detached(priority: .userInitiated) { (try? store.loadMaterialCard(taskID: taskID)) ?? nil }.value
    records[taskID] = loaded
  }

  // MARK: 单条手动

  /// 按钮不能点的原因；可以点返回 nil。
  func unavailableReason(taskID: TaskID, hasTranscript: Bool) -> String? {
    if isReadOnly() { return "这份历史当前只能浏览" }
    if state(for: taskID) == .working { return "正在生成素材卡…" }
    if isBatchActive { return "正在批量生成，请先等它结束或停止" }
    if !hasTranscript { return "还没有转写稿：先转写，再做素材卡" }
    return nil
  }

  func generate(taskID: TaskID) {
    guard !isReadOnly() else { itemStates[taskID] = .failed(MaterialCardError.readOnly.userMessage); return }
    guard itemStates[taskID] != .working, !isBatchActive else { return }
    itemTasks[taskID]?.cancel()
    itemStates[taskID] = .working
    itemTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      switch await self.gate.status() {
      case .allowed:
        await self.run(taskID: taskID)
      case let .needsConfirmation(host, model):
        self.itemStates[taskID] = .needsConsent(host: host, model: model)
      case let .unavailable(message):
        self.itemStates[taskID] = .failed(message)
      }
    }
  }

  /// 用户在界面上确认「把这条转写稿发给 host」之后。
  func confirmConsent(taskID: TaskID) {
    guard case let .needsConsent(host, model) = state(for: taskID) else { return }
    itemStates[taskID] = .working
    itemTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      // 确认的是弹窗里展示的 host+model：这期间换了服务商/模型就作废，重新弹窗，不发送。
      guard await self.gate.confirm(host, model) else {
        switch await self.gate.status() {
        case .allowed: await self.run(taskID: taskID)
        case let .needsConfirmation(newHost, newModel): self.itemStates[taskID] = .needsConsent(host: newHost, model: newModel)
        case let .unavailable(message): self.itemStates[taskID] = .failed(message)
        }
        return
      }
      await self.run(taskID: taskID)
    }
  }

  func cancel(taskID: TaskID) {
    itemTasks[taskID]?.cancel()
    itemTasks[taskID] = nil
    itemStates[taskID] = .idle
  }

  private func run(taskID: TaskID) async {
    generationAttempts += 1
    do {
      let record = try await service.generate(taskID: taskID)
      records[taskID] = record
      itemStates[taskID] = .idle
      didChange(taskID)
    } catch is CancellationError {
      itemStates[taskID] = .idle
    } catch {
      itemStates[taskID] = .failed(Self.message(for: error))
    }
    itemTasks[taskID] = nil
  }

  // MARK: 转写完成后自动

  /// 转写完成时由 HistoryViewModel 调一次。**只有**单条手动转写 + 开关打开 + 数据去向已确认
  /// + 还没有卡 + 非只读，才会调用模型；其余一律什么都不做。
  func transcriptionCompleted(taskID: TaskID, origin: TranscriptionOrigin) {
    guard origin == .manualSingle, autoAfterTranscript, !isReadOnly(), !isBatchActive,
          itemStates[taskID] == nil || itemStates[taskID] == .idle else { return }
    itemStates[taskID] = .working
    itemTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      // 自动路径不替用户确认数据去向：没确认过就安静地放弃，用户可以手动点按钮。
      guard case .allowed = await self.gate.status() else { self.itemStates[taskID] = .idle; return }
      let store = self.service.store
      let existing = await Task.detached { (try? store.loadMaterialCard(taskID: taskID)) ?? nil }.value
      guard existing == nil else { self.itemStates[taskID] = .idle; return }
      await self.run(taskID: taskID)
    }
  }

  // MARK: 批量补做

  /// 第一步：只数数、估算，不调模型。
  func prepareBatch() {
    guard !isReadOnly() else { batchState = .failed(MaterialCardError.readOnly.userMessage); return }
    guard !isBatchActive else { return }
    batchState = .estimating
    batchTask = Task { [weak self] in
      guard let self else { return }
      let store = self.service.store
      let candidates = await Task.detached(priority: .userInitiated) { (try? store.materialCardCandidates()) ?? [] }.value
      guard !candidates.isEmpty else {
        self.pendingBatch = []
        self.batchState = .finished("没有需要补做的视频：已转写的视频都有素材卡了。")
        return
      }
      let consent: (host: String, model: String)?
      switch await self.gate.status() {
      case .allowed: consent = nil
      case let .needsConfirmation(host, model): consent = (host, model)
      case let .unavailable(message):
        self.batchState = .failed(message)
        return
      }
      self.pendingBatch = candidates
      self.batchState = .estimate(self.makeEstimate(candidates, consent: consent))
    }
  }

  func dismissBatch() {
    guard !isBatchActive else { return }
    pendingBatch = []
    batchState = .idle
  }

  /// 第二步：用户看完估算、点了确认。逐条串行，可停。
  func confirmBatch() {
    guard case let .estimate(estimate) = batchState, !isReadOnly() else { return }
    let queue = pendingBatch
    pendingBatch = []
    batchState = .running(done: 0, total: queue.count, failed: 0)
    batchTask = Task { [weak self] in
      guard let self else { return }
      if let shown = estimate.needsConsent {
        guard await self.gate.confirm(shown.host, shown.model) else {
          // 估算弹出后换了服务商/模型：作废确认，回到估算页重新确认，一条都不发。
          await self.refreshEstimateAfterProviderChange(queue: queue)
          return
        }
      }
      var done = 0, failed = 0, consecutiveFailures = 0
      var stopReason: String?
      for candidate in queue {
        if Task.isCancelled || self.isReadOnly() { stopReason = "已停止。"; break }
        self.generationAttempts += 1
        do {
          let record = try await self.service.generate(taskID: candidate.taskID)
          self.records[candidate.taskID] = record
          self.didChange(candidate.taskID)
          consecutiveFailures = 0
        } catch is CancellationError {
          stopReason = "已停止。"
          break
        } catch {
          failed += 1
          consecutiveFailures += 1
          if Self.isFatal(error) { stopReason = Self.message(for: error); break }
          if consecutiveFailures >= Self.consecutiveFailureLimit {
            stopReason = "连续 \(Self.consecutiveFailureLimit) 条失败，已停下，没有再试。"
            break
          }
        }
        done += 1
        self.batchState = .running(done: done, total: queue.count, failed: failed)
      }
      let made = done - failed
      let tail = stopReason.map { " \($0)" } ?? ""
      self.batchState = .finished("已生成 \(max(made, 0)) 张素材卡，失败 \(failed) 条。\(tail)")
    }
  }

  /// 确认作废后：按当前服务商重新出估算（带新的 host/model），让用户重新确认。
  private func refreshEstimateAfterProviderChange(queue: [MaterialCardCandidate]) async {
    switch await gate.status() {
    case let .unavailable(message):
      batchState = .failed(message)
    case let .needsConfirmation(host, model):
      pendingBatch = queue
      batchState = .estimate(makeEstimate(queue, consent: (host, model)))
    case .allowed:
      pendingBatch = queue
      batchState = .estimate(makeEstimate(queue, consent: nil))
    }
  }

  private func makeEstimate(_ candidates: [MaterialCardCandidate], consent: (host: String, model: String)?) -> BatchEstimate {
    let characters = candidates.reduce(0) { $0 + min($1.transcriptCharacters, MaterialCardPrompt.transcriptCharacterLimit) }
    let systemTokens = PromptSizeEstimator.estimatedTokens(MaterialCardPrompt.system)
    return BatchEstimate(
      count: candidates.count, characters: characters,
      estimatedInputTokens: characters + systemTokens * candidates.count,
      estimatedOutputTokens: Self.estimatedOutputTokensPerCard * candidates.count,
      needsConsent: consent
    )
  }

  func stopBatch() {
    batchTask?.cancel()
  }

  // MARK: 错误

  private static func isFatal(_ error: Error) -> Bool {
    if let failure = error as? TranscriptTidyError {
      return failure != .emptyTranscript
    }
    if let failure = error as? MaterialCardError { return failure != .invalidResponse && failure != .emptyTranscript }
    return false
  }

  static func message(for error: Error) -> String {
    if let failure = error as? MaterialCardError { return failure.userMessage }
    if let failure = error as? TranscriptTidyError { return failure.userMessage }
    return "素材卡没能保存，请重试。"
  }
}
