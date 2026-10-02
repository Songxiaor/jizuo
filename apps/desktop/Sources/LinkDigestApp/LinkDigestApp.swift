import AppKit
import Darwin
import SwiftUI
import Foundation
import Observation
import LinkDigestAdapters
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestTransport

public let linkDigestSocketPath = ProcessInfo.processInfo.environment["LINKDIGEST_SOCKET_PATH"] ?? "/tmp/linkdigest-\(getuid()).sock"

struct DataDestinationDisclosure: Identifiable, Equatable {
  let id: UUID
  let identity: DataDestinationIdentity
  let intent: RunIntentKind
  let title: String?

  init(identity: DataDestinationIdentity, intent: RunIntentKind, title: String?) {
    id = UUID()
    self.identity = identity
    self.intent = intent
    self.title = title
  }
}

private struct RunPreparationAttempt {
  let token: UUID
  let capture: CurrentCapture
  let intent: RunIntentKind
  let preferences: ModelPreferences
  let modelOverride: String?
  /// The stored profile identity protects against configuration races while
  /// `identity` is the model-specific destination the user actually sees.
  var authorizationIdentity: DataDestinationIdentity?
  var identity: DataDestinationIdentity?
  var disclosure: DataDestinationDisclosure?
}

private struct DisclosureIdentities {
  let authorizationIdentity: DataDestinationIdentity
  let displayIdentity: DataDestinationIdentity
}

enum BrowserReceiverState: Sendable, Equatable {
  case starting
  case ready
  case unavailable
}

enum ManualGenerationKind: Equatable {
  case summarize
  case translate
  case mindMap
}

struct ManualGenerationRequest: Equatable {
  let taskID: TaskID
  let kind: ManualGenerationKind
  let historyDetail: HistoryDetailProjection?
  let preferences: ModelPreferences
  let modelOverride: String?
}

/// 用 Observation 而不是 ObservableObject：视图只在自己读过的属性变化时重绘。
/// 原来任何一个属性变化都会让观察它的整棵历史窗口重排。
@MainActor
@Observable
final class AppViewModel {
  var connection = "等待扩展连接"
  private(set) var browserReceiverState: BrowserReceiverState = .starting
  private(set) var lastBrowserCaptureAt: Date?
  private(set) var currentCapture: CurrentCapture?
  /// 不走 Observation 的自动存储：写入统一走 `setRunState`（见其注释）。读取方
  /// 始终拿到最新值；只有状态真正切换时才发观察通知，流式纯增长拍点不发。
  @ObservationIgnored private var runStateStorage: RunState = .idle
  private(set) var runState: RunState {
    get { access(keyPath: \.runState); return runStateStorage }
    set { withMutation(keyPath: \.runState) { runStateStorage = newValue } }
  }
  /// 本次运行的计时起点，非活动态为 nil；由 `setRunState` 独家维护。
  ///
  /// 这是被观察的普通属性，但只在状态真正切换时才会被写——而那一刻本来就要
  /// 发观察通知，多这一次会在同一 runloop 里合并掉。流式纯增长的快路径绝不
  /// 触碰它，否则等于把 `setRunState` 费劲绕开的通知又从这里放回来。
  private(set) var runStartedAt: Date?
  /// 流式正文的热路径发布通道；与 runState 同步更新（见 setRunState）。
  let liveRunText = LiveRunTextModel()
  private(set) var activeRunTaskID: TaskID?
  private(set) var visibleRunTaskID: TaskID?
  private(set) var storageAvailability: StorageAvailability = .bootstrapping
  private(set) var dataDestinationDisclosure: DataDestinationDisclosure?
  private(set) var dataDestinationNotice: String?
  /// 通道忙时记下的手动总结/翻译/脑图。一次只跑一条，做完再接下一条。
  private(set) var queuedGenerations: [ManualGenerationRequest] = []
  /// 批量总结整批结束前不要把排队条目插进两条之间。
  /// 不被观察：它是调度用的内部闸门，界面不读它。
  @ObservationIgnored var defersQueuedGeneration = false
  /// 脑图不走模型通道，由历史页接手真正开跑。回调句柄不参与观察。
  @ObservationIgnored var startQueuedMindMap: (@MainActor (TaskID) -> Void)?

  @ObservationIgnored private var modelRunOrchestrator: ModelRunOrchestrator?
  private let configurationService: ProviderConfigurationService?
  private let consentStore: (any DataDestinationConsentStore)?
  private let makeRunID: @Sendable () -> RunID
  @ObservationIgnored private var visibleRunID: RunID?
  // 这两个决定「生成总结」按钮能不能点（runStartUnavailableReason 里的「正在准备发送…」），
  // 必须被界面观察到。原来标成 ObservationIgnored：没配模型时点一下，按钮画成灰的，
  // 准备结束清掉之后界面不重画，按钮就永远灰着（2026-10-02 新用户走查）。
  private var launchPendingRunID: RunID?
  @ObservationIgnored private var taskIDByRunID: [RunID: TaskID] = [:]
  private var preparationAttempt: RunPreparationAttempt?
  @ObservationIgnored private var queuedGenerationStartTask: Task<Void, Never>?
  @ObservationIgnored private var confirmingAttemptToken: UUID?

  init(
    modelRunOrchestrator: ModelRunOrchestrator? = nil,
    configurationService: ProviderConfigurationService? = nil,
    consentStore: (any DataDestinationConsentStore)? = nil,
    makeRunID: @escaping @Sendable () -> RunID = { RunID() }
  ) {
    self.modelRunOrchestrator = modelRunOrchestrator
    self.configurationService = configurationService
    self.consentStore = consentStore
    self.makeRunID = makeRunID
  }

  var envelope: CaptureEnvelopeV1? { currentCapture?.wireEnvelope }

  func installModelRunOrchestrator(_ value: ModelRunOrchestrator) {
    guard modelRunOrchestrator == nil else { return }
    modelRunOrchestrator = value
  }

  func setConnection(_ value: String) { connection = value }

  func setBrowserReceiverAvailable(_ available: Bool) {
    browserReceiverState = available ? .ready : .unavailable
  }

  func setStorageAvailability(_ value: StorageAvailability) {
    storageAvailability = value
  }

  func receive(_ value: CurrentCapture) {
    connection = "已连接"
    if value.wireEnvelope != nil || value.wireEnvelopeV2 != nil {
      lastBrowserCaptureAt = Date()
    }
    if let preparationAttempt,
       !matchesCurrentCapture(preparationAttempt.capture, value) {
      releasePreparation(ifOwner: preparationAttempt.token)
      dataDestinationNotice = "已收到新的页面，本次发送确认已取消。请重新选择总结或翻译。"
    }
    currentCapture = value
  }

  var canStartRun: Bool {
    runStartUnavailableReason(usingCurrentCapture: true, detail: nil) == nil
  }

  var canStopRun: Bool { runState.isActive }
  var runResultText: String { runState.outputText }

  func showsVisibleRun(for taskID: TaskID) -> Bool {
    visibleRunTaskID == taskID
  }

  func canStopVisibleRun(for taskID: TaskID) -> Bool {
    showsVisibleRun(for: taskID) && canStopRun
  }

  var storageStatusText: String {
    switch storageAvailability {
    case .bootstrapping:
      "正在准备资料库…"
    case .writable:
      "资料库可用"
    case let .unavailable(code):
      StorageErrorCatalog.presentation(for: code).visibleText
    }
  }

  var runStatusText: String {
    switch runState {
    case .idle:
      "尚未生成结果"
    case let .starting(intent):
      intent == .translate ? "正在开始翻译…" : "正在开始总结…"
    // 推理模型作答前会先想很久，这段静默必须让用户看见，否则和卡死没区别。
    case let .thinking(intent):
      intent == .translate ? "模型思考中…（尚未开始输出译文）" : "模型思考中…（尚未开始输出）"
    case .streaming:
      "正在生成…"
    case .stopping:
      "正在停止…"
    case .stopped:
      "用户已停止，结果不完整。"
    case .completed:
      "已完成"
    case let .incomplete(_, _, code):
      "结果不完整。\(V02ErrorCatalog.presentation(for: code).visibleText)"
    case let .failed(_, code):
      V02ErrorCatalog.presentation(for: code).visibleText
    case let .storageError(_, _, code):
      StorageErrorCatalog.presentation(for: code).visibleText
    }
  }

  var runHasFailure: Bool {
    switch runState {
    case .failed, .incomplete, .storageError:
      true
    case .idle, .starting, .thinking, .streaming, .stopping, .stopped, .completed:
      false
    }
  }

  func summarize(
    preferences: ModelPreferences = .default,
    modelOverride: String? = nil
  ) async {
    if let currentCapture,
       handledManualGenerationRequest(
        kind: .summarize,
        taskID: currentCapture.taskID,
        historyDetail: nil,
        preferences: preferences,
        modelOverride: modelOverride
      ) {
      return
    }
    await requestRun(intent: .summarize, preferences: preferences, modelOverride: modelOverride)
  }
  func translate(
    preferences: ModelPreferences = .default,
    modelOverride: String? = nil
  ) async {
    if let currentCapture,
       handledManualGenerationRequest(
        kind: .translate,
        taskID: currentCapture.taskID,
        historyDetail: nil,
        preferences: preferences,
        modelOverride: modelOverride
      ) {
      return
    }
    guard !isTranslationLanguageMatch(
      text: currentCapture?.document.text,
      outputLanguage: preferences.outputLanguage
    ) else {
      dataDestinationNotice = "原文已经是输出语言，不用翻译。"
      return
    }
    await requestRun(intent: .translate, preferences: preferences, modelOverride: modelOverride)
  }

  @discardableResult
  func summarize(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async -> Bool {
    if handledManualGenerationRequest(
      kind: .summarize,
      taskID: historyDetail.task.id,
      historyDetail: historyDetail,
      preferences: preferences,
      modelOverride: modelOverride
    ) {
      return didEngageModelRun
    }
    guard prepareHistoryCapture(historyDetail) else { return false }
    await requestRun(intent: .summarize, preferences: preferences, modelOverride: modelOverride)
    return didEngageModelRun
  }

  /// 自动队列需要知道这次是否真的占上模型通道。普通 summarize 保持原来的
  /// fire-and-observe API；这里返回 false 时，队列可以继续处理不依赖总结的步骤。
  func startAutomaticSummary(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async -> Bool {
    guard prepareHistoryCapture(historyDetail) else { return false }
    await requestRun(
      intent: .summarize,
      preferences: preferences,
      modelOverride: modelOverride
    )
    return didEngageModelRun
  }

  @discardableResult
  func translate(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async -> Bool {
    if handledManualGenerationRequest(
      kind: .translate,
      taskID: historyDetail.task.id,
      historyDetail: historyDetail,
      preferences: preferences,
      modelOverride: modelOverride
    ) {
      return didEngageModelRun
    }
    guard prepareHistoryCapture(historyDetail) else { return false }
    // 详情页门禁按分层快照判断；若这里仍用合并后的 currentCapture 正文，
    // 中文转写 + 英文配文会被误判为「已是中文」，按钮可点但翻译静默退出。
    guard LayeredSourceDocument.needsTranslation(
      from: historyDetail.snapshots,
      outputLanguage: preferences.outputLanguage
    ) else {
      dataDestinationNotice = "原文已经是输出语言，不用翻译。"
      return false
    }
    await requestRun(intent: .translate, preferences: preferences, modelOverride: modelOverride)
    return didEngageModelRun
  }

  private var didEngageModelRun: Bool {
    runState.isActive
      || isDataDestinationDisclosurePresented
      || isConfirmingDataDestinationDisclosure
      || launchPendingRunID != nil
  }

  func canStartRun(from detail: HistoryDetailProjection) -> Bool {
    runStartUnavailableReason(usingCurrentCapture: false, detail: detail) == nil
  }

  func isManualGenerationQueued(taskID: TaskID, kind: ManualGenerationKind) -> Bool {
    queuedGenerations.contains { $0.taskID == taskID && $0.kind == kind }
  }

  func hasQueuedGeneration(for taskID: TaskID) -> Bool {
    queuedGenerations.contains { $0.taskID == taskID }
  }

  /// 通道被别的条目占用时，这一条可以先排上，不必灰死。
  func canEnqueueManualGeneration(for taskID: TaskID) -> Bool {
    isGenerationChannelBusy && !isGenerationChannelHeld(by: taskID)
  }

  func enqueueOrCancelMindMapGeneration(taskID: TaskID) {
    if isManualGenerationQueued(taskID: taskID, kind: .mindMap) {
      queuedGenerations.removeAll { $0.taskID == taskID && $0.kind == .mindMap }
      return
    }
    guard canEnqueueManualGeneration(for: taskID) else { return }
    queuedGenerations.append(
      ManualGenerationRequest(
        taskID: taskID,
        kind: .mindMap,
        historyDetail: nil,
        preferences: .default,
        modelOverride: nil
      )
    )
  }

  func startNextQueuedGenerationIfIdle() async {
    guard !defersQueuedGeneration, !isGenerationChannelBusy else { return }
    guard !queuedGenerations.isEmpty else { return }
    let next = queuedGenerations.removeFirst()
    switch next.kind {
    case .summarize:
      if let detail = next.historyDetail {
        guard prepareHistoryCapture(detail) else {
          await startNextQueuedGenerationIfIdle()
          return
        }
      } else if currentCapture?.taskID != next.taskID {
        await startNextQueuedGenerationIfIdle()
        return
      }
      await requestRun(
        intent: .summarize,
        preferences: next.preferences,
        modelOverride: next.modelOverride
      )
    case .translate:
      if let detail = next.historyDetail {
        guard prepareHistoryCapture(detail) else {
          await startNextQueuedGenerationIfIdle()
          return
        }
      } else if currentCapture?.taskID != next.taskID {
        await startNextQueuedGenerationIfIdle()
        return
      }
      if isTranslationLanguageMatch(
        text: currentCapture?.document.text,
        outputLanguage: next.preferences.outputLanguage
      ) {
        dataDestinationNotice = "原文已经是输出语言，不用翻译。"
        await startNextQueuedGenerationIfIdle()
        return
      }
      await requestRun(
        intent: .translate,
        preferences: next.preferences,
        modelOverride: next.modelOverride
      )
    case .mindMap:
      startQueuedMindMap?(next.taskID)
    }
  }

  private var isGenerationChannelBusy: Bool {
    runState.isActive
      || launchPendingRunID != nil
      || preparationAttempt != nil
      || isDataDestinationDisclosurePresented
      || isConfirmingDataDestinationDisclosure
  }

  private func isGenerationChannelHeld(by taskID: TaskID) -> Bool {
    if activeRunTaskID == taskID { return true }
    if visibleRunTaskID == taskID, runState.isActive { return true }
    if let preparationAttempt, preparationAttempt.capture.taskID == taskID { return true }
    return false
  }

  private func handledManualGenerationRequest(
    kind: ManualGenerationKind,
    taskID: TaskID,
    historyDetail: HistoryDetailProjection?,
    preferences: ModelPreferences,
    modelOverride: String?
  ) -> Bool {
    if isManualGenerationQueued(taskID: taskID, kind: kind) {
      queuedGenerations.removeAll { $0.taskID == taskID && $0.kind == kind }
      return true
    }
    guard canEnqueueManualGeneration(for: taskID) else { return false }
    queuedGenerations.append(
      ManualGenerationRequest(
        taskID: taskID,
        kind: kind,
        historyDetail: historyDetail,
        preferences: preferences,
        modelOverride: modelOverride
      )
    )
    return true
  }

  private func scheduleQueuedGenerationStart() {
    queuedGenerationStartTask?.cancel()
    queuedGenerationStartTask = Task { [weak self] in
      await self?.startNextQueuedGenerationIfIdle()
    }
  }

  func canTranslate(preferences: ModelPreferences) -> Bool {
    translateUnavailableReason(
      usingCurrentCapture: true,
      detail: nil,
      preferences: preferences,
      preferencesReady: true
    ) == nil
  }

  func canTranslate(from detail: HistoryDetailProjection, preferences: ModelPreferences) -> Bool {
    translateUnavailableReason(
      usingCurrentCapture: false,
      detail: detail,
      preferences: preferences,
      preferencesReady: true
    ) == nil
  }

  func translationUnavailableReason(
    text: String?,
    outputLanguage: String
  ) -> String? {
    isTranslationLanguageMatch(text: text, outputLanguage: outputLanguage)
      ? "原文已经是输出语言，不用翻译。"
      : nil
  }

  func translationUnavailableReason(
    snapshots: [ContentSnapshot],
    outputLanguage: String
  ) -> String? {
    LayeredSourceDocument.needsTranslation(from: snapshots, outputLanguage: outputLanguage)
      ? nil
      : "原文已经是输出语言，不用翻译。"
  }

  /// 总结为什么现在不能点。可用时返回 nil。
  ///
  /// 判断和理由必须是同一份：按钮的 disabled 由本方法推导，不能再各写一套门禁。
  func summarizeUnavailableReason(
    usingCurrentCapture: Bool,
    detail: HistoryDetailProjection?,
    preferencesReady: Bool
  ) -> String? {
    if !preferencesReady { return "先在设置里配置模型" }
    return runStartUnavailableReason(usingCurrentCapture: usingCurrentCapture, detail: detail)
  }

  /// 翻译为什么现在不能点。可用时返回 nil。
  func translateUnavailableReason(
    usingCurrentCapture: Bool,
    detail: HistoryDetailProjection?,
    preferences: ModelPreferences,
    preferencesReady: Bool
  ) -> String? {
    if let reason = summarizeUnavailableReason(
      usingCurrentCapture: usingCurrentCapture,
      detail: detail,
      preferencesReady: preferencesReady
    ) {
      return reason
    }
    if usingCurrentCapture {
      return translationUnavailableReason(
        text: currentCapture?.document.text,
        outputLanguage: preferences.outputLanguage
      )
    }
    guard let detail else { return "还没有可发送的内容" }
    return LayeredSourceDocument.needsTranslation(
      from: detail.snapshots,
      outputLanguage: preferences.outputLanguage
    ) ? nil : "原文已经是输出语言，不用翻译。"
  }

  static let untranscribedRunReason = "还没转写：先点「转写」，有了文字稿再总结或翻译"

  /// `canStartRun` 的人话版。顺序按用户最可能先撞上的拦下来。
  func runStartUnavailableReason(
    usingCurrentCapture: Bool,
    detail: HistoryDetailProjection?
  ) -> String? {
    if !usingCurrentCapture {
      guard let detail else { return "还没有可发送的内容" }
      if detail.snapshots.isEmpty { return "这条没有可发送的正文" }
      if let body = detail.snapshots.last?.bodyText, LocalImportDocument.isUntranscribedPlaceholder(body) {
        return Self.untranscribedRunReason
      }
      if currentCapture?.taskID == detail.task.id {
        return runStartUnavailableReason(usingCurrentCapture: true, detail: nil)
      }
    }

    switch storageAvailability {
    case .writable:
      break
    case .bootstrapping:
      return "正在准备资料库…"
    case .unavailable:
      return storageStatusText
    }

    if modelRunOrchestrator == nil || configurationService == nil || consentStore == nil {
      return "模型服务尚未就绪"
    }

    if runState.isActive {
      let verb = runState.intent == .translate ? "翻译" : "总结"
      let runningID = activeRunTaskID ?? visibleRunTaskID
      if let runningID {
        let thisID = usingCurrentCapture ? currentCapture?.taskID : detail?.task.id
        if thisID == runningID {
          return "正在\(verb)这条，完成后可再做其他生成"
        }
      }
      return "正在\(verb)其他条目，完成后可再试"
    }

    if launchPendingRunID != nil || preparationAttempt != nil {
      return "正在准备发送…"
    }

    if usingCurrentCapture {
      guard let currentCapture else { return "还没有可发送的内容" }
      if currentCapture.document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "这条没有可发送的正文"
      }
      return nil
    }

    if detail?.snapshots.last?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      return "这条没有可发送的正文"
    }
    return nil
  }

  var isDataDestinationDisclosurePresented: Bool {
    dataDestinationDisclosure != nil
  }

  /// 撤销全部已记住的授权：发送目的地和三项能力一起清。
  ///
  /// 确认从「每次都问」改成「问一次就记住」之后，这条路是必需的——不然用户
  /// 点过的那一次就再也收不回来了。清完之后下一次发送会重新告知一遍。
  func revokeRememberedConsents() async -> Bool {
    CapabilityConsent.revokeAll()
    guard let consentStore else { return true }
    do {
      try await consentStore.forgetAll()
      return true
    } catch {
      return false
    }
  }

  var isConfirmingDataDestinationDisclosure: Bool {
    confirmingAttemptToken != nil
  }

  func cancelDataDestinationDisclosure() {
    guard confirmingAttemptToken == nil,
          let attempt = preparationAttempt,
          attempt.disclosure != nil
    else { return }
    releasePreparation(ifOwner: attempt.token)
  }

  func confirmDataDestinationDisclosure() async {
    guard confirmingAttemptToken == nil,
          let attempt = preparationAttempt,
          let identity = attempt.identity,
          let authorizationIdentity = attempt.authorizationIdentity,
          let disclosure = attempt.disclosure,
          disclosure.identity == identity,
          let consentStore
    else {
      return
    }
    confirmingAttemptToken = attempt.token
    var retainedBySheetOrLaunch = false
    defer {
      if confirmingAttemptToken == attempt.token {
        confirmingAttemptToken = nil
      }
      if !retainedBySheetOrLaunch {
        releasePreparation(ifOwner: attempt.token)
      }
    }

    guard preparationIsValid(attempt.token, capture: attempt.capture) else { return }

    var persistenceFailed = false
    do {
      try await consentStore.rememberConfirmation(for: identity)
    } catch {
      // This explicit confirmation authorizes this frozen request once. The
      // next request deliberately asks again because no durable record exists.
      persistenceFailed = true
    }

    guard !Task.isCancelled,
          preparationIsValid(attempt.token, capture: attempt.capture)
    else { return }

    clearDisclosure(ifOwner: attempt.token)
    if persistenceFailed {
      dataDestinationNotice = "已仅允许本次发送；无法记住确认记录，下次发送时会再次询问。"
    } else {
      dataDestinationNotice = nil
    }
    retainedBySheetOrLaunch = await authorizeAndLaunch(
      capture: attempt.capture,
      intent: attempt.intent,
      expectedIdentity: authorizationIdentity,
      token: attempt.token
    )
  }

  func stop() async {
    await modelRunOrchestrator?.stop()
  }

  private func requestRun(
    intent: RunIntentKind,
    preferences: ModelPreferences,
    modelOverride: String?
  ) async {
    guard
      canStartRun,
      let currentCapture,
      let consentStore
    else {
      return
    }
    let token = beginPreparation(
      for: currentCapture,
      intent: intent,
      preferences: preferences,
      modelOverride: modelOverride
    )
    var retainedBySheetOrLaunch = false
    defer {
      if !retainedBySheetOrLaunch {
        releasePreparation(ifOwner: token)
      }
    }

    do {
      guard let identities = try await loadDisclosureIdentities(
        intent: intent,
        preferences: preferences,
        modelOverride: modelOverride
      ) else {
        guard preparationIsValid(token, capture: currentCapture) else { return }
        dataDestinationNotice = V02ErrorCatalog.presentation(
          for: ModelRunErrorCode.modelNotConfigured.rawValue
        ).visibleText
        return
      }
      guard !Task.isCancelled,
            setPreparationIdentities(identities, ifOwner: token, capture: currentCapture)
      else { return }

      if try await consentStore.isConfirmed(for: identities.displayIdentity) {
        guard !Task.isCancelled,
              preparationIsValid(token, capture: currentCapture)
        else { return }
        retainedBySheetOrLaunch = await authorizeAndLaunch(
          capture: currentCapture,
          intent: intent,
          expectedIdentity: identities.authorizationIdentity,
          token: token
        )
      } else {
        guard !Task.isCancelled,
              preparationIsValid(token, capture: currentCapture)
        else { return }
        retainedBySheetOrLaunch = presentDisclosure(
          for: currentCapture,
          intent: intent,
          identity: identities.displayIdentity,
          token: token
        )
      }
    } catch let error as ProviderConfigurationError {
      guard preparationIsValid(token, capture: currentCapture) else { return }
      dataDestinationNotice = V02ErrorCatalog.presentation(for: error.rawValue).visibleText
    } catch {
      // A broken local consent record is never treated as permission.
      guard !Task.isCancelled,
            let identity = preparationAttempt?.identity,
            preparationIsValid(token, capture: currentCapture)
      else { return }
      dataDestinationNotice = "无法读取发送确认记录，本次需要重新确认。"
      retainedBySheetOrLaunch = presentDisclosure(
        for: currentCapture,
        intent: intent,
        identity: identity,
        token: token
      )
    }
  }

  private func prepareHistoryCapture(_ detail: HistoryDetailProjection) -> Bool {
    guard canStartRun(from: detail), let snapshot = detail.snapshots.last else { return false }
    // 配文和转写同时存在时，发给模型的是两层拼在一起的正文，不能只用 last。
    let composed = LayeredSourceDocument.modelInput(from: detail.snapshots)
    guard !composed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    // 缓存键必须带上**正文内容**，不能只看 snapshot 身份。
    //
    // `saveEditedSnapshotText` 走的是原地 UPDATE，snapshot id 不变。于是：对转写稿
    // 点总结（缓存下正文 T1）→ 发现错别字，用「编辑转写」改好保存（库里变成 T2，
    // id 不变）→ 再点总结或重新生成 → taskID 与 snapshotID 都相等，直接命中缓存，
    // 又把 T1 发给模型。用户改的字白改了，而界面上没有任何迹象。
    // 这直接违背「编辑转写」按钮说明里「保存后总结、翻译与导出都使用校对后的文本」
    // 那句承诺。
    //
    if currentCapture?.taskID == detail.task.id,
       currentCapture?.snapshotID == snapshot.id,
       currentCapture?.document.text == composed {
      return true
    }
    let formatter = ISO8601DateFormatter()
    let origin: CapturedDocument.Origin = {
      switch snapshot.sourceKind {
      case CapturedDocument.Origin.manualLink.rawValue: return .manualLink
      case CapturedDocument.Origin.localTranscription.rawValue: return .localTranscription
      case CapturedDocument.Origin.burnedInSubtitles.rawValue: return .burnedInSubtitles
      case CapturedDocument.Origin.localImport.rawValue: return .localImport
      default: return .browserCapture
      }
    }()
    let document = CapturedDocument(
      createdAt: formatter.string(
        from: Date(timeIntervalSince1970: Double(snapshot.envelopeCreatedAtMilliseconds) / 1_000)
      ),
      origin: origin,
      url: snapshot.sourceURL,
      title: snapshot.title,
      platform: snapshot.platform,
      method: snapshot.captureMethod,
      text: composed,
      characterCount: composed.unicodeScalars.count,
      completeness: snapshot.completeness,
      capturedAt: formatter.string(
        from: Date(timeIntervalSince1970: Double(snapshot.capturedAtMilliseconds) / 1_000)
      ),
      sourceLabel: snapshot.sourceLabel
    )
    currentCapture = CurrentCapture(
      document: document,
      taskID: detail.task.id,
      snapshotID: snapshot.id
    )
    connection = "资料库"
    return true
  }

  private func authorizeAndLaunch(
    capture: CurrentCapture,
    intent: RunIntentKind,
    expectedIdentity: DataDestinationIdentity,
    token: UUID
  ) async -> Bool {
    guard preparationIsValid(token, capture: capture), let configurationService else { return false }
    do {
      guard let authorization = try await configurationService.authorize(for: expectedIdentity) else {
        guard preparationIsValid(token, capture: capture) else { return false }
        dataDestinationNotice = V02ErrorCatalog.presentation(for: ModelRunErrorCode.modelNotConfigured.rawValue).visibleText
        return false
      }
      guard !Task.isCancelled, preparationIsValid(token, capture: capture) else { return false }
      return await launchRun(capture: capture, intent: intent, authorization: authorization, token: token)
    } catch let error as ProviderConfigurationError where error == .configurationChanged {
      guard preparationIsValid(token, capture: capture) else { return false }
      return await refreshDisclosureAfterConfigurationChange(capture: capture, intent: intent, token: token)
    } catch let error as ProviderConfigurationError {
      guard preparationIsValid(token, capture: capture) else { return false }
      dataDestinationNotice = V02ErrorCatalog.presentation(for: error.rawValue).visibleText
      return false
    } catch {
      guard preparationIsValid(token, capture: capture) else { return false }
      dataDestinationNotice = V02ErrorCatalog.presentation(for: ModelRunErrorCode.runFailed.rawValue).visibleText
      return false
    }
  }

  private func launchRun(
    capture: CurrentCapture,
    intent: RunIntentKind,
    authorization: ProviderAuthorization,
    token: UUID
  ) async -> Bool {
    guard preparationIsValid(token, capture: capture),
          !Task.isCancelled,
          storageAvailability.isWriteReady,
          !runState.isActive,
          launchPendingRunID == nil,
          let modelRunOrchestrator else { return false }

    let request = PersistentRunRequest(
      runID: makeRunID(),
      taskID: capture.taskID,
      snapshotID: capture.snapshotID,
      intent: intent,
      targetLanguage: attemptPreferences(for: token)?.outputLanguage,
      summaryPrompt: intent == .summarize ? attemptPreferences(for: token)?.summaryPrompt : nil,
      translationModel: intent == .translate ? attemptPreferences(for: token)?.translationModel : nil,
      modelOverride: attemptModelOverride(for: token),
      translationConcurrency: attemptPreferences(for: token)?.effectiveTranslationConcurrency
    )
    // Protect the real Task before createRun can block. First launch stays `.idle`
    // until createRun confirms `.starting`; a retry after stop/incomplete clears
    // the visible card immediately so old partial text does not look stuck.
    taskIDByRunID[request.runID] = request.taskID
    launchPendingRunID = request.runID
    activeRunTaskID = request.taskID
    if !runState.isActive, !runState.outputText.isEmpty {
      setRunState(.starting(intent: intent))
    }
    releasePreparation(ifOwner: token)
    await modelRunOrchestrator.start(
      request: request,
      capture: capture.document,
      authorization: authorization
    ) { [weak self] runID, state in
      await self?.receiveRunState(runID: runID, state: state)
    }
    clearLaunchPendingIfNeeded(runID: request.runID)
    return true
  }

  private func refreshDisclosureAfterConfigurationChange(
    capture: CurrentCapture,
    intent: RunIntentKind,
    token: UUID
  ) async -> Bool {
    do {
      guard let identities = try await loadDisclosureIdentities(
        intent: intent,
        preferences: attemptPreferences(for: token) ?? .default,
        modelOverride: attemptModelOverride(for: token)
      ) else {
        guard preparationIsValid(token, capture: capture) else { return false }
        dataDestinationNotice = V02ErrorCatalog.presentation(
          for: ModelRunErrorCode.modelNotConfigured.rawValue
        ).visibleText
        return false
      }
      guard !Task.isCancelled,
            setPreparationIdentities(identities, ifOwner: token, capture: capture)
      else { return false }
      let presented = presentDisclosure(
        for: capture,
        intent: intent,
        identity: identities.displayIdentity,
        token: token
      )
      if presented {
        dataDestinationNotice = "模型目的地已变化，请确认新的发送目的地。"
      }
      return presented
    } catch let error as ProviderConfigurationError {
      guard preparationIsValid(token, capture: capture) else { return false }
      dataDestinationNotice = V02ErrorCatalog.presentation(for: error.rawValue).visibleText
      return false
    } catch {
      guard preparationIsValid(token, capture: capture) else { return false }
      dataDestinationNotice = V02ErrorCatalog.presentation(
        for: ProviderConfigurationError.profileStoreReadFailed.rawValue
      ).visibleText
      return false
    }
  }

  private func loadDisclosureIdentities(
    intent: RunIntentKind,
    preferences: ModelPreferences,
    modelOverride: String?
  ) async throws -> DisclosureIdentities? {
    guard let configurationService else { return nil }
    do {
      guard let profile = try await configurationService.loadProfileForDisclosure() else { return nil }
      let authorizationIdentity = DataDestinationIdentity(profile: profile)
      let displayProfile: ProviderProfile
      if let selectedModel = (modelOverride ?? (intent == .translate ? preferences.translationModel : nil))?.trimmingCharacters(in: .whitespacesAndNewlines),
         !selectedModel.isEmpty {
        displayProfile = try profile.replacing(model: selectedModel)
      } else {
        displayProfile = profile
      }
      return DisclosureIdentities(
        authorizationIdentity: authorizationIdentity,
        displayIdentity: DataDestinationIdentity(profile: displayProfile)
      )
    } catch let error as ProviderConfigurationError {
      throw error
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
  }

  private func presentDisclosure(
    for capture: CurrentCapture,
    intent: RunIntentKind,
    identity: DataDestinationIdentity,
    token: UUID
  ) -> Bool {
    guard preparationIsValid(token, capture: capture),
          let attempt = preparationAttempt,
          attempt.intent == intent,
          attempt.identity == identity
    else { return false }
    let presentation = DataDestinationDisclosure(
      identity: identity,
      intent: intent,
      title: capture.document.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    var updatedAttempt = attempt
    updatedAttempt.disclosure = presentation
    preparationAttempt = updatedAttempt
    dataDestinationDisclosure = presentation
    return true
  }

  private func clearDisclosure(ifOwner token: UUID) {
    guard var attempt = preparationAttempt, attempt.token == token else { return }
    attempt.disclosure = nil
    preparationAttempt = attempt
    dataDestinationDisclosure = nil
  }

  private func beginPreparation(
    for capture: CurrentCapture,
    intent: RunIntentKind,
    preferences: ModelPreferences,
    modelOverride: String?
  ) -> UUID {
    let token = UUID()
    preparationAttempt = .init(
      token: token,
      capture: capture,
      intent: intent,
      preferences: preferences,
      modelOverride: modelOverride,
      authorizationIdentity: nil,
      identity: nil,
      disclosure: nil
    )
    return token
  }

  private func attemptPreferences(for token: UUID) -> ModelPreferences? {
    guard let attempt = preparationAttempt, attempt.token == token else { return nil }
    return attempt.preferences
  }

  private func attemptModelOverride(for token: UUID) -> String? {
    guard let attempt = preparationAttempt, attempt.token == token else { return nil }
    return attempt.modelOverride
  }

  private func releasePreparation(ifOwner token: UUID) {
    guard let attempt = preparationAttempt, attempt.token == token else { return }
    preparationAttempt = nil
    if dataDestinationDisclosure?.id == attempt.disclosure?.id {
      dataDestinationDisclosure = nil
    }
  }

  private func setPreparationIdentities(
    _ identities: DisclosureIdentities,
    ifOwner token: UUID,
    capture: CurrentCapture
  ) -> Bool {
    guard var attempt = preparationAttempt,
          attempt.token == token,
          matchesCurrentCapture(attempt.capture, capture),
          matchesCurrentCapture(capture, currentCapture)
    else { return false }
    attempt.authorizationIdentity = identities.authorizationIdentity
    attempt.identity = identities.displayIdentity
    preparationAttempt = attempt
    return true
  }

  private func preparationIsValid(_ token: UUID, capture: CurrentCapture) -> Bool {
    guard let attempt = preparationAttempt else { return false }
    return attempt.token == token
      && matchesCurrentCapture(attempt.capture, capture)
      && matchesCurrentCapture(capture, currentCapture)
  }

  private func matchesCurrentCapture(_ lhs: CurrentCapture, _ rhs: CurrentCapture?) -> Bool {
    guard let rhs else { return false }
    return lhs.taskID == rhs.taskID && lhs.snapshotID == rhs.snapshotID
  }

  private func isTranslationLanguageMatch(text: String?, outputLanguage: String) -> Bool {
    TranslationMatchCache.isMatch(text: text, outputLanguage: outputLanguage)
  }

  /// `runState` 唯一的写入口。流式生成每 80ms 就有一个「同 intent、正文
  /// 纯增长」的拍点——这种拍点不触发观察通知，正文只写进
  /// `liveRunText`，重绘收窄到显示它的叶子视图；其余任何变化（开始/思考/
  /// 停止/终态、intent 切换、清空）照常通知所有读过 `runState` 的视图。
  /// `runState` 本身每个拍点都会更新，读取方语义与 @Published 时代一致。
  private func setRunState(_ state: RunState) {
    // 同值拍点直接丢弃。推理模型的思考阶段每收到一个 delta 就报一次
    // `.thinking(intent:)`，而这个状态不带任何随 delta 变化的负载；照发
    // 观察通知等于让整棵历史窗口按 delta 速率重求值。实测一次
    // 翻译的思考阶段主线程 100% CPU、连续 23 秒几乎不出帧。
    guard state != runStateStorage else { return }
    // 计时起点只落在「非活动 → 活动」那一刻。活动态之间（starting → thinking →
    // streaming）不重置：读数要回答「我等了多久」，跟着阶段边界归零的话，思考
    // 四十秒后一进入流式就跳回 0.0s，反而像是刚才白跑了一次。
    let nextRunStartedAt: Date? = state.isActive
      ? (runStateStorage.isActive ? runStartedAt : Date())
      : nil
    if case let .streaming(intent, partialText) = state,
       case .streaming(let previousIntent, _) = runStateStorage,
       previousIntent == intent,
       !partialText.isEmpty {
      // 绕开 withMutation：值照常更新，但不通知。
      // 这条快路径两端都是 streaming，起点必然没变，所以这里不写 runStartedAt——
      // 它是被观察的属性，一次赋值就发一次通知，正是本路径要避开的东西。
      runStateStorage = state
      liveRunText.setText(partialText)
      return
    }
    withMutation(keyPath: \.runState) { runStateStorage = state }
    // 同值不写：活动态之间切换时起点没变，多一次赋值就多一次无谓的观察通知。
    if runStartedAt != nextRunStartedAt { runStartedAt = nextRunStartedAt }
    liveRunText.setText(state.outputText)
  }

  func receiveRunState(runID: RunID, state: RunState) {
    let wasLaunchPending = launchPendingRunID == runID
    if case .starting = state {
      if wasLaunchPending { launchPendingRunID = nil }
      visibleRunID = runID
      activeRunTaskID = taskIDByRunID[runID]
      visibleRunTaskID = taskIDByRunID[runID]
      setRunState(state)
      return
    }

    if case .storageError = state, wasLaunchPending || visibleRunID == nil {
      if wasLaunchPending { launchPendingRunID = nil }
      visibleRunID = runID
      visibleRunTaskID = taskIDByRunID[runID]
    }
    guard visibleRunID == runID else { return }
    if case let .storageError(_, _, code) = state {
      storageAvailability = .unavailable(code)
    }
    setRunState(state)
    if isTerminal(state) {
      activeRunTaskID = nil
      taskIDByRunID.removeValue(forKey: runID)
      scheduleQueuedGenerationStart()
    }
  }

  private func clearLaunchPendingIfNeeded(runID: RunID) {
    guard launchPendingRunID == runID else { return }
    launchPendingRunID = nil
    if activeRunTaskID == taskIDByRunID[runID] {
      activeRunTaskID = nil
    }
    taskIDByRunID.removeValue(forKey: runID)
    if case .starting = runState, visibleRunID != runID {
      setRunState(.idle)
    }
  }

  private func isTerminal(_ state: RunState) -> Bool {
    switch state {
    case .stopped, .completed, .incomplete, .failed, .storageError:
      true
    case .idle, .starting, .thinking, .streaming, .stopping:
      false
    }
  }
}

/// 接住 `linkdigest://` 的应用级入口。
///
/// 不用 `View.onOpenURL`：那个 modifier 挂在 `WindowGroup` 的内容里，SwiftUI
/// 会把每一个进来的 URL 当成「再开一个场景」的请求，于是从知识库点几次回链，
/// 桌面上就堆起几个汲作窗口。回链要做的事是「定位到已经开着的那个窗口里的
/// 某一条」，那是应用级事件，不该经过场景。
@MainActor
final class LinkDigestAppDelegate: NSObject, NSApplicationDelegate {
  private var handler: ((URL) -> Void)?
  /// App 冷启动时，系统可能在界面接好之前就把 URL 递进来。先存着，
  /// 等历史就绪再消费——否则那一次点击会静默丢失。
  private var pending: [URL] = []

  /// 汲作只有一个主窗口：系统默认的「显示标签页栏 / 显示所有标签页」只会在「显示」菜单里
  /// 占两行，点了还会多出一条空标签栏（2026-10-02 菜单走查）。
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func setHandler(_ handler: @escaping (URL) -> Void) {
    self.handler = handler
    let queued = pending
    pending = []
    for url in queued { handler(url) }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let handler else {
      pending.append(contentsOf: urls)
      return
    }
    for url in urls { handler(url) }
    reopenMainWindowIfClosed()
  }

  /// 主窗口被关掉后，点知识库里的回链原来「没反应」：定位做了，可是没有窗口可看
  /// （2026-09-29 发布前走查）。这时替用户把主窗口叫回来——等同于点一下 Dock 图标，
  /// SwiftUI 收到 reopen 会重建主窗口，新窗口读到的就是刚定位好的那一条。
  private func reopenMainWindowIfClosed() {
    let hasMainWindow = NSApp.windows.contains { window in
      window.isVisible && (window.identifier?.rawValue.hasPrefix(LinkDigestApp.mainWindowID) ?? false)
    }
    guard !hasMainWindow else {
      NSApp.activate()
      return
    }
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
  }
}

/// 开机或登录后系统恢复窗口时，有可能只恢复了「设置」窗口（2026-09-24 实测重启后
/// 就是这样）。资料库、浏览器接收、MCP 都挂在主窗口的启动任务上，主窗口不出来，
/// 这些服务就一个都没起，外部 Agent 和浏览器插件全部连不上。设置窗口在启动后
/// 几秒内出现、而主窗口还没做过启动时，替用户把主窗口打开。只管启动那一刻：
/// 之后用户自己关掉主窗口再开设置，不去打扰。
struct MainWindowLaunchGuard: ViewModifier {
  let isBootstrapped: () -> Bool
  @Environment(\.openWindow) private var openWindow
  static let processStart = Date()
  static let launchWindowSeconds: TimeInterval = 20

  func body(content: Content) -> some View {
    content.task {
      guard Date().timeIntervalSince(Self.processStart) < Self.launchWindowSeconds else { return }
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled, !isBootstrapped() else { return }
      openWindow(id: LinkDigestApp.mainWindowID)
    }
  }
}

@main struct LinkDigestApp: App {
  static let mainWindowID = "main"
  @NSApplicationDelegateAdaptor(LinkDigestAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: AppViewModel
  @State private var historyModel: HistoryViewModel
  @StateObject private var manualLink: ManualLinkViewModel
  @State private var providerSettings: ProviderSettingsViewModel
  @StateObject private var browserSupport: BrowserSupportViewModel
  @StateObject private var mediaStorageSettings: MediaStorageSettingsViewModel
  @StateObject private var knowledgeVaultSettings: KnowledgeVaultSettingsViewModel
  @State private var companionNoteSync = CompanionNoteSyncCoordinator()
  @StateObject private var sessionMediaPlayback: SessionMediaPlaybackController
  @StateObject private var localImport: LocalImportController
  @StateObject private var quickCapture = QuickCaptureController()
  @State private var didBootstrap = false
  /// 注入 `\.appTheme` 用。视图各自读 AppStorage 会重复三行样板，
  /// 而设置页那几个子视图当初就是因为拿不到主题才写死了 `.red`。
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  /// 用户指定的界面字体。空/theme 表示跟随主题。
  @AppStorage(UIFontSelection.storageKey) private var uiFontRaw = UIFontSelection.defaultStoredValue

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let mediaInventory: LateBoundMediaInventory
  /// 启动后按「转写后清理视频」规则扫一次用。
  private let mediaStore: LocalMediaStore?
  private let composition: AppComposition
  private let appUpdateController: AppUpdateController
  private let socketServerLifecycle: UnixSocketServerLifecycle
  private let applicationTerminationObserver: NSObjectProtocol
  private let terminationSignalSource: DispatchSourceSignal

  init() {
    // 记下进程启动时刻：`MainWindowLaunchGuard` 只在启动后那一小段时间里补开主窗口。
    _ = MainWindowLaunchGuard.processStart
    // 每次模型调用的成败都记到「模型可用状态」里，设置页据此提示已下架等问题。
    ModelHealthRegistry.installObservation()
    let appUpdateController = AppUpdateController()
    let applicationSupportRoot: AppComposition.ApplicationSupportRoot
    let imageCache: GitHubREADMEImageCache?
    let cacheRoot: URL?
    do {
      let root = try AppApplicationSupportRoot.resolve()
      applicationSupportRoot = { root }
      imageCache = .init(applicationSupportRoot: root)
      cacheRoot = root
    } catch {
      // Preserve the composition's structured storage-unavailable path rather
      // than letting an invalid debug smoke override crash the SwiftUI process.
      applicationSupportRoot = { throw RepositoryFailure.unavailable }
      imageCache = nil
      cacheRoot = nil
    }
    let configurationService: ProviderConfigurationService
    let provider: any ModelProvider
    let consentStore: any DataDestinationConsentStore
    let preferencesStore: any ModelPreferencesStore
    #if DEBUG
    if AppApplicationSupportRoot.shouldUseVisualFixture() {
      let fixture = DebugVisualFixture()
      configurationService = fixture.configurationService
      provider = fixture.provider
      consentStore = fixture.consentStore
      preferencesStore = fixture.preferencesStore
    } else {
      configurationService = ProviderConfigurationService(
        profileStore: UserDefaultsProviderProfileStore(),
        secretStore: KeychainSecretStore(),
        libraryStore: UserDefaultsModelLibraryStore()
      )
      let sessionConfiguration = URLSessionConfiguration.ephemeral
      sessionConfiguration.httpCookieStorage = nil
      sessionConfiguration.urlCache = nil
      provider = OpenAICompatibleProvider(
        session: URLSession(configuration: sessionConfiguration)
      )
      consentStore = UserDefaultsDataDestinationConsentStore()
      preferencesStore = UserDefaultsModelPreferencesStore()
    }
    // 整理、标题本地化、脑图三条路原来各自 new 一个服务实例（还用全局 URLSession）：
    // 「停止」停不掉它们，reasoning_effort 的降级记忆也互不相通。统一用主实例。
    let sharedTextProvider = (provider as? OpenAICompatibleProvider) ?? OpenAICompatibleProvider()
    #else
    configurationService = ProviderConfigurationService(
      profileStore: UserDefaultsProviderProfileStore(),
      secretStore: KeychainSecretStore(),
      libraryStore: UserDefaultsModelLibraryStore()
    )
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.urlCache = nil
    let sharedTextProvider = OpenAICompatibleProvider(
      session: URLSession(configuration: sessionConfiguration)
    )
    provider = sharedTextProvider
    consentStore = UserDefaultsDataDestinationConsentStore()
    preferencesStore = UserDefaultsModelPreferencesStore()
    #endif
    let model = AppViewModel(
      configurationService: configurationService,
      consentStore: consentStore
    )
    let manualResourceFetcher = ProxyAwareWebPageFetcher()
    let faviconCache = cacheRoot.map { WebsiteFaviconCache(applicationSupportRoot: $0) }
    let mediaStoragePreference = UserDefaultsMediaStoragePreferenceStore()
    // 在这里构造而不是等到下面接 StateObject：抓取回调（captureSink）要用它排
    // 自动同步，而那个闭包在此之后就定型了。
    let knowledgeVaultSettingsModel = KnowledgeVaultSettingsViewModel(
      store: UserDefaultsKnowledgeVaultStore()
    )
    let douyinWebCaptureService = DouyinWKWebViewCaptureService(
      dataStore: SiteSessionController.douyin.dataStore,
      userAgent: SiteSessionProfile.browserUserAgent
    )
    // 播放和转写共用同一个刷新服务：转写要单独问一次「只要音轨」的 playurl，
    // 复用同一份 Cookie 与选流诊断，避免两套并行的 B 站会话状态。
    let sessionMediaRefreshService = SessionMediaRefreshService(
      resources: manualResourceFetcher,
      bilibiliQuality: { mediaStoragePreference.bilibiliStreamQuality },
      bilibiliCookieHeader: {
        await SiteSessionController.bilibili.cookieHeader()
      },
      douyinRefresh: { sourceURL, author in
        guard let url = URL(string: sourceURL) else {
          throw SessionMediaRefreshError.unsupportedPlatform
        }
        let document = try await douyinWebCaptureService.capture(url: url)
        guard let media = document.media else {
          throw SessionMediaRefreshError.noPlayableMedia
        }
        return MediaDescriptor(
          kind: .directFile,
          pageURL: document.url,
          canonicalURL: document.url,
          platform: media.platform,
          ephemeralPlaybackURL: media.videoURL,
          posterURL: media.coverURL,
          durationSeconds: media.durationSeconds,
          author: media.author ?? author,
          transcriptionCapability: .supported,
          selectionReason: .singleCandidate,
          playbackState: .unknown
        )
      }
    )
    let sessionMediaPlaybackController = SessionMediaPlaybackController(
      preferenceStore: mediaStoragePreference,
      refreshService: sessionMediaRefreshService
    )
    let mediaStore = cacheRoot.map {
      LocalMediaStore(
        applicationSupportRoot: $0,
        storagePreference: mediaStoragePreference
      )
    }
    // 媒体目录治理（孤儿扫描、总容量淘汰）要知道库里认哪些文件。历史服务在
    // bootstrap 之后才有，所以先接一个「晚绑定」的清单来源；没绑上之前一律不删。
    let mediaInventory = LateBoundMediaInventory()
    mediaStore?.setInventoryProvider { try mediaInventory.inventory() }
    self.mediaInventory = mediaInventory
    self.mediaStore = mediaStore
    // Video downloads need a longer timeout than HTML capture (signed CDN objects).
    let mediaResourceFetcher = ProxyAwareWebPageFetcher(
      limits: .init(redirects: 4, responseBytes: LocalMediaStore.maxBytes, timeout: 120)
    )
    let mediaDownloader = mediaStore.map {
      VideoMediaDownloader(resources: mediaResourceFetcher, store: $0)
    }
    let transcriptionTempStore = cacheRoot.map {
      TranscriptionTempStore(
        applicationSupportRoot: $0,
        resources: mediaResourceFetcher
      )
    }
    // 清理转写临时目录是目录遍历加递归删除，原来在主线程同步做、窗口都还没出来。
    // 挪到后台；失败信息等历史模型建好后再送过去（见下方 reportTranscriptionCleanupFailure）。
    let startupTranscriptionCleanupFailure: String? = nil
    let githubAdapter = GitHubRepositorySourceAdapter(resources: manualResourceFetcher, imageCache: imageCache)
    let bilibiliAdapter = BilibiliSourceAdapter(
      fetcher: manualResourceFetcher,
      resources: manualResourceFetcher
    )
    // 抖音与小红书未登录时拿不到正文：服务端返回登录墙 / 风控页，而通用路径会把
    // 那个外壳当正文静默入库。用户在设置里登录后，抓取带上 App 自有会话的 Cookie
    // （隔离 WebKit 分区，不是系统浏览器的），才真去取正文；没登录则给出明确出口。
    let douyinAdapter = DouyinSourceAdapter(
      fetcher: manualResourceFetcher,
      resources: manualResourceFetcher,
      cookieHeader: { await SiteSessionController.douyin.cookieHeader() }
    )
    let xiaohongshuAdapter = XiaohongshuSourceAdapter(
      fetcher: manualResourceFetcher,
      resources: manualResourceFetcher,
      cookieHeader: { await SiteSessionController.xiaohongshu.cookieHeader() }
    )
    // Douyin is registered first so short links never fall into the generic HTML path.
    let historyModel = HistoryViewModel(
      imageCache: imageCache,
      imageResources: manualResourceFetcher,
      mediaStore: mediaStore,
      mediaDownloader: mediaDownloader,
      faviconCache: faviconCache,
      faviconResources: manualResourceFetcher,
      videoTranscriber: AppleSpeechVideoTranscriber(),
      subtitleReader: AppleVisionVideoSubtitleReader(),
      imageTextRecognizer: AppleVisionTextRecognizer(),
      // Router 按服务地址在「阶跃流式 SSE」和「通用 /audio/transcriptions」之间选，
      // 两条路径的接口形态不同（增量 vs 一次性返回），不能只换参数。
      onlineAudioTranscriber: OnlineAudioTranscriberRouter(
        configurationService: configurationService
      ),
      transcriptTidier: OpenAICompatibleTranscriptTidier(
        configurationService: configurationService,
        provider: sharedTextProvider
      ),
      titleLocalizer: OpenAICompatibleTitleLocalizer(
        configurationService: configurationService,
        provider: sharedTextProvider
      ),
      // 起草用用户自己装的 Claude Code。没装的话构造出来也无妨——
      // 它的 locateExecutable() 会返回 nil,那一步的入口说清楚缺什么。
      draftAgent: ClaudeCLIAgent(),
      mindMapExtractor: OpenAICompatibleMindMapExtractor(
        configurationService: configurationService,
        provider: sharedTextProvider
      ),
      transcriptionTempStore: transcriptionTempStore,
      transcriptionAudioTrackURL: { platform, pageURL in
        await sessionMediaRefreshService.transcriptionAudioTrackURL(
          platform: platform,
          sourceURL: pageURL
        )
      },
      livePlaybackTranscribe: { locale, stopSignal in
        AppAudioLiveTranscriber().transcribe(localeIdentifier: locale, stopSignal: stopSignal)
      },
      startupTranscriptionCleanupFailure: startupTranscriptionCleanupFailure
    )
    // 说话人分离：本机模型放在汲作自己的数据目录下，首次使用时下载。
    historyModel.localSpeakerDiarizer = LocalSpeakerDiarizer(
      modelsDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LinkDigest/Models/SpeakerDiarization", isDirectory: true)
    )
    historyModel.onlineSpeakerDiarizer = OnlineSpeakerDiarizer(configurationService: configurationService)
    var manualAdapters: [any SourceAdapting] = [douyinAdapter, xiaohongshuAdapter, bilibiliAdapter, githubAdapter]
    #if DEBUG
    if let fixtureRoot = ProfileImportBatchPipelineFixture.root {
      manualAdapters.insert(ProfileImportBatchFixtureAdapter(root: fixtureRoot), at: 0)
    }
    #endif
    let manualLink = ManualLinkViewModel(
      captureService: .init(
        fetcher: manualResourceFetcher,
        sourceAdapters: manualAdapters
      ),
      douyinCapture: douyinWebCaptureService,
      imageCache: imageCache,
      imageResources: manualResourceFetcher,
      xResolver: XTweetResolver(resources: manualResourceFetcher),
      onMediaCaptured: { media, taskID, snapshotID, pageURL in
        await historyModel.ingestCapturedMedia(
          media,
          taskID: taskID,
          snapshotID: snapshotID,
          pageURL: pageURL
        )
      },
      profileImportJournal: cacheRoot.map(ProfileImportBatchJournal.init(applicationSupportRoot:))
    )
    historyModel.beginBootstrapLoading()
    let nowMilliseconds: @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
    let socketServerLifecycle = UnixSocketServerLifecycle(
      path: linkDigestSocketPath,
      statusSink: { value in await model.setConnection(value) },
      availabilitySink: { available in await model.setBrowserReceiverAvailable(available) }
    )
    let serverStarter = makeUnixSocketServerStarter(lifecycle: socketServerLifecycle)
    let injectSmokeOpenFailure = AppApplicationSupportRoot.shouldInjectOpenFailure()
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: applicationSupportRoot,
      repositoryFactory: { location in
        if injectSmokeOpenFailure {
          throw RepositoryFailure.injectedFailure
        }
        let repository = try GRDBHistoryRepository.open(at: location)
        // 平台已是导航第一维度：清理历史上自动附加的平台同义标签。
        // 清理失败不阻塞打开历史库（显示层仍会过滤这些标签）。
        try? repository.removeLegacyPlatformTags()
        return repository
      },
      nowMilliseconds: nowMilliseconds,
      serverStarter: serverStarter,
      availabilitySink: { value in
        await model.setStorageAvailability(value)
      },
      captureSink: { value in
        // Publish + reveal first so CaptureReceiver can ACK the browser within the
        // extension's 10s native-message budget. Image downloads are fail-open and
        // must never sit on the socket response path (WeChat/X media often >10s).
        await model.receive(value)
        // Keep a process-only playable descriptor in the session LRU so switching
        // back within the capacity limit does not need a network refresh.
        await sessionMediaPlaybackController.rememberCurrentCapture(value)
        if value.navigationIntent == .reveal {
          await historyModel.reveal(taskID: value.taskID)
        }
        if let sourceURL = URL(string: value.document.url),
           let faviconURL = value.browserDeclaredFaviconURL {
          // 只排后台抓取，不占扩展 10 秒 ACK。URL 仍会在 App 侧重新走安全
          // 网络与图片字节校验；浏览器提供的只是页面声明候选。
          await historyModel.loadBrowserDeclaredFavicon(
            taskID: value.taskID,
            sourceURL: sourceURL,
            faviconURL: faviconURL
          )
        }
        // 新素材进库后排一次同步。只是排队（默认 20 秒后跑），不占这条
        // 必须在 10 秒内 ACK 浏览器的路径。
        await knowledgeVaultSettingsModel.scheduleAutoSync()
        Task { @MainActor in
          // 同上：译标题不受「跳过自动处理」影响。
          let preferences = (try? await preferencesStore.load()) ?? .default
          guard preferences.effectiveAutoLocalizeTitleNewCaptures else { return }
          historyModel.scheduleAutomaticTitleLocalization(
            taskID: value.taskID,
            title: value.document.title,
            body: value.document.text,
            outputLanguage: preferences.outputLanguage,
            model: nil
          )
        }
        // Video download starts immediately so signed URLs are not kept for later.
        // It runs off the native-message ACK path (same fail-open pattern as images).
        if value.shouldAutomaticallyPersistLegacyMedia {
          if let media = value.document.media {
            let taskID = value.taskID
            let snapshotID = value.snapshotID
            let pageURL = value.document.url
            Task { @MainActor in
              await historyModel.ingestCapturedMedia(
                media,
                taskID: taskID,
                snapshotID: snapshotID,
                pageURL: pageURL
              )
            }
          }
        } else if value.allowsAutomaticEnrichment,
                  mediaStoragePreference.autoSaveCapturedVideo,
                  let descriptor = value.mediaDescriptor,
                  let media = CurrentCaptureMediaPreview.favoriteMedia(descriptor) {
          let taskID = value.taskID
          let snapshotID = value.snapshotID
          let pageURL = value.document.url
          Task { @MainActor in
            await historyModel.autoSaveCapturedMedia(
              media,
              taskID: taskID,
              snapshotID: snapshotID,
              pageURL: pageURL
            )
          }
        }
        // X 用 MSE 播放，抓取侧只能拿到 blob: 地址，捕获结果因此停在「只能在原
        // 浏览器会话观看」。用嵌入式推文的公开端点换回真实直链 MP4，再交给既有
        // 的媒体管线。全程不带 cookie；解析失败就保持原来的诚实提示。
        if let descriptor = value.mediaDescriptor,
           descriptor.platform == "x",
           descriptor.kind == .browserSessionOnly,
           descriptor.failureReason == .blobOrMSE,
           let tweetID = XTweetResolver.tweetID(from: value.document.url) {
          let resolver = XTweetResolver(resources: manualResourceFetcher)
          let taskID = value.taskID
          let snapshotID = value.snapshotID
          let pageURL = value.document.url
          let author = descriptor.author
          Task { @MainActor in
            guard let media = await resolver.resolveVideo(tweetID: tweetID, author: author) else { return }
            await historyModel.ingestCapturedMedia(
              media,
              taskID: taskID,
              snapshotID: snapshotID,
              pageURL: pageURL
            )
          }
        }
        // Substantive WeChat articles keep their inline images even when they
        // also carry an embedded-video descriptor. Pure video captures do not.
        if let imageCache, RemoteMarkdownImageStagingPolicy.allows(value.document) {
          let markdown = value.document.text
          let captureID = value.document.requestID
          let taskID = value.taskID
          let snapshotID = value.snapshotID
          let resources = manualResourceFetcher
          Task {
            await imageCache.stageRemoteMarkdownImages(
              markdown: markdown,
              captureID: captureID,
              resources: resources
            )
            imageCache.promote(
              captureID: captureID,
              taskID: taskID,
              snapshotID: snapshotID
            )
            // Refresh the open detail only when this capture intentionally owns
            // navigation. A background profile item must not steal reading focus.
            if value.navigationIntent == .reveal {
              await historyModel.reveal(taskID: taskID)
            } else {
              await historyModel.historyMetadataChanged(taskID: taskID)
            }
          }
        }
      },
      // 收藏夹同步：扩展只交来一串推文 id，正文由公开端点逐条取回。受理必须
      // 立刻返回（扩展只有 10s 预算），真正的抓取在 App 的抓取队列里串行进行。
      bookmarksSink: { request in
        let outcome = await MainActor.run { manualLink.enqueueXBookmarks(request.tweetIDs) }
        return .init(queued: outcome.queued, skipped: outcome.skipped)
      },
      profileCandidatesSink: { request in
        let accepted = await MainActor.run { manualLink.presentProfileCandidates(request) }
        return .init(acceptedCount: accepted)
      },
      // 扩展弹窗查重与看进度：只读历史和此刻的运行状态。
      pageStatusSink: { request in
        let outputLanguage = (try? await preferencesStore.load())?.outputLanguage
          ?? ModelPreferences.default.outputLanguage
        return await historyModel.pageStatus(url: request.url, outputLanguage: outputLanguage)
      }
    ))

    self.configurationService = configurationService
    self.provider = provider
    self.composition = composition
    self.socketServerLifecycle = socketServerLifecycle
    self.applicationTerminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: nil
    ) { _ in
      socketServerLifecycle.stop()
      try? transcriptionTempStore?.cleanupAll()
    }
    let terminationSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    Darwin.signal(SIGTERM, SIG_IGN)
    terminationSignalSource.setEventHandler {
      socketServerLifecycle.stop()
      try? transcriptionTempStore?.cleanupAll()
      Darwin.signal(SIGTERM, SIG_DFL)
      _ = Darwin.kill(getpid(), SIGTERM)
    }
    terminationSignalSource.resume()
    self.terminationSignalSource = terminationSignalSource
    self.appUpdateController = appUpdateController
    _model = State(initialValue: model)
    // 按意思搜：没打开时只是一个空壳，不下载也不读库。
    historyModel.semanticSearch = SemanticSearchService()
    _historyModel = State(initialValue: historyModel)
    if let transcriptionTempStore {
      Task.detached(priority: .background) {
        do {
          try transcriptionTempStore.cleanupAll()
        } catch {
          let message = (error as? TranscriptionTempStoreError)?.userMessage
            ?? TranscriptionTempStoreError.unavailable.userMessage
          await MainActor.run { historyModel.reportTranscriptionCleanupFailure(message) }
        }
      }
    }
    _manualLink = StateObject(wrappedValue: manualLink)
    _localImport = StateObject(wrappedValue: LocalImportController(mediaStore: mediaStore, imageCache: imageCache))
    let providerSettings = ProviderSettingsViewModel(
      configurationService: configurationService,
      provider: provider,
      preferencesStore: preferencesStore
    )
    // 自动工序抄一份给浏览器扩展（Host 读）；只有 App 真身这样做。
    providerSettings.browserPreferencesMirror = .standard()
    _providerSettings = State(initialValue: providerSettings)
    _browserSupport = StateObject(
      wrappedValue: BrowserSupportViewModel(
        installer: try? BrowserSupportInstaller.appBundled(),
        deliveryLog: .standard(),
        applicationRoots: BrowserSupportBrowser.systemApplicationRoots(
          homeRoot: FileManager.default.homeDirectoryForCurrentUser)
      )
    )
    _mediaStorageSettings = StateObject(
      wrappedValue: MediaStorageSettingsViewModel(
        store: mediaStoragePreference,
        mediaStore: mediaStore,
        inventory: { try mediaInventory.inventory() }
      )
    )
    _knowledgeVaultSettings = StateObject(wrappedValue: knowledgeVaultSettingsModel)
    _sessionMediaPlayback = StateObject(wrappedValue: sessionMediaPlaybackController)
  }

  var body: some Scene {
    WindowGroup(ProductDisplay.name, id: LinkDigestApp.mainWindowID) {
      HistoryContentView(
        model: historyModel,
        appModel: model,
        manualLink: manualLink,
        providerSettings: providerSettings,
        browserSupport: browserSupport,
        sessionMediaPlayback: sessionMediaPlayback
      )
        .environmentObject(localImport)
        .localImportDropTarget(localImport)
        .sheet(isPresented: $localImport.isPresented) {
          LocalImportStatusSheet(controller: localImport)
        }
        .onReceive(NotificationCenter.default.publisher(for: .companionNoteSyncDidFinish)) { _ in
          historyModel.reload()
        }
        .task {
          manualLink.handleScenePhase(scenePhase)
          guard !didBootstrap else { return }
          didBootstrap = true
          var didConfigureHistory = false
          defer {
            if Task.isCancelled && !didConfigureHistory { didBootstrap = false }
          }
          // 读模型设置会碰钥匙串（上限 15 秒）；原来它串在打开历史库前面，钥匙串
          // 一慢首屏就一直是骨架屏。两件事互不依赖，并行。
          let settingsLoad = Task { await providerSettings.load() }
          if AppApplicationSupportRoot.shouldHoldHistoryLoading() {
            try? await Task.sleep(for: .seconds(10))
          }
          let result = await composition.bootstrap()
          historyModel.configure(
            history: result.history,
            isReadOnly: result.historyIsReadOnly,
            unavailableCode: result.historyUnavailableCode,
            readOnlyReason: result.historyReadOnlyReason,
            readOnlyRecoveryHint: result.historyReadOnlyRecoveryHint
          )
          didConfigureHistory = true
          historyModel.semanticSearch?.configure(history: result.history)
          await settingsLoad.value
          knowledgeVaultSettings.configure(history: result.history)
          mediaInventory.bind(result.history)
          // 阅读位置现在存在库里（Migration023）。接上之前详情页照常能开，
          // 只是拿不到上次读到哪——接上之后第一次打开就恢复了。
          // 这一步同时把 UserDefaults 里的旧进度搬进来并清掉旧键。
          ReadingPositionStore.configure(history: result.history)
          companionNoteSync.configure(history: result.history)
          // 手机同步这一版不提供，启动时就**不要连 iCloud**。
          //
          // 原来这里只看 `companionNoteSync.canSync`，而那个值最终来自
          // 「这次构建的签名有没有 iCloud 能力」——换成正式签名的那天，笔记就会
          // 在用户毫不知情、设置里也看不到这一栏的情况下开始上传。
          // 现在的判据是两件事同时成立：这一版对外提供，且用户自己打开过。
          if ExperimentalFeatures.isCompanionSyncEnabled(),
             result.availability.isWriteReady,
             result.history != nil,
             companionNoteSync.canSync {
            Task { await companionNoteSync.synchronize() }
          }
          // 嵌入播放器的身份数据每次启动清一次（Cookie / localStorage / IndexedDB），
          // 磁盘缓存保留。必须在这里而不是「第一次用到播放器时」：removeData 是异步
          // 落地，放在使用点会撞上正在使用同一个存储的播放器。
          Task { await YouTubeEmbedWebViewPool.wipeEmbedIdentityData() }
          // 回收站到期清理。放后台、不等它：首屏不该为「30 天前删掉的东西」等待。
          //
          // 每次启动跑一次就够——回收站是以天计的东西，没必要常驻定时器。
          if result.availability.isWriteReady, let history = result.history {
            Task.detached(priority: .background) {
              try? history.purgeTrash(olderThanDays: HistoryTrashPolicy.retentionDays)
            }
          }
          // 「转写后清理视频」按天数的规则也是以天计：每次启动扫一次。规则是「保留」时什么都不删。
          if result.availability.isWriteReady, result.history != nil, let mediaStore {
            Task.detached(priority: .background) {
              await TranscribedVideoCleaner.shared.run(mediaStore: mediaStore)
            }
          }
          // 历史就绪之后才接回链，冷启动时排队的那一个 URL 也在这里被消费。
          //
          // scheme 一注册，任何网页都能构造这样一个链接扔过来，所以这里只做
          // 「定位到某条历史」这一件没有副作用的事，且 id 必须是规范 UUID——
          // 解析不出来就当没发生，不提示、不新建、不写任何东西。
          appDelegate.setHandler { url in
            guard let taskID = KnowledgeVaultLink.digestID(from: url) else { return }
            historyModel.revealFromExternalLink(taskID: taskID)
          }
          if result.availability.isWriteReady, let history = result.history {
            manualLink.configure(
              history: history,
              storageWriteGate: result.storageWriteGate,
              nowMilliseconds: { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) },
              captureSink: { value in
                await model.receive(value)
                if value.navigationIntent == .reveal {
                  await historyModel.reveal(taskID: value.taskID)
                }
                await knowledgeVaultSettings.scheduleAutoSync()
                Task { @MainActor in
                  // 译标题不看 allowsAutomaticEnrichment：批量抓取主页、重复链接再抓一次
                  // 会关掉转写/总结这类重处理，但标题只发一句话，开关打开就该一视同仁。
                  // 队列本身串行，一次抓几十条也只是排队慢慢翻。
                  guard providerSettings.autoLocalizeTitleNewCaptures else { return }
                  historyModel.scheduleAutomaticTitleLocalization(
                    taskID: value.taskID,
                    title: value.document.title,
                    body: value.document.text,
                    outputLanguage: providerSettings.outputLanguage,
                    model: providerSettings.activeSummaryModelName
                  )
                }
              }
            )
            // 必须排在 manualLink.configure 之后：导入与快速记录都经它的 ingestor
            // 落库。先接上的话，菜单在那一刻读到「还不能导入」就一直灰着。
            localImport.configure(history: history, manualLink: manualLink, historyModel: historyModel)
            // 拖进一个文件夹：导完后按文件顺序自动建（或更新）同名合集（2026-09-29 合集第一期）。
            localImport.onFolderImported = { [weak historyModel] folderName, folderURL, orderedTaskIDs in
              historyModel?.handleImportedFolder(
                folderName: folderName, folderURL: folderURL, orderedTaskIDs: orderedTaskIDs
              )
            }
            quickCapture.configure(history: history, manualLink: manualLink, historyModel: historyModel)
          }
          #if DEBUG
          if result.availability.isWriteReady {
            ProfileImportBatchPipelineFixture.start(manualLink: manualLink, historyModel: historyModel)
            WorkGalleryAcceptanceFixture.show(manualLink: manualLink)
          }
          #endif
          if result.availability.isWriteReady, let history = result.history {
            let orchestrator = ModelRunOrchestrator(
              configurationService: configurationService,
              provider: provider,
              history: history,
              onHistoryMetadataChanged: { taskID in
                await historyModel.historyMetadataChanged(taskID: taskID)
              },
              onRunMetadataChanged: { taskID in
                await historyModel.historyMetadataChanged(taskID: taskID)
              },
              storageWriteGate: result.storageWriteGate
            )
            model.installModelRunOrchestrator(orchestrator)
          }
          MCPController.shared.configure(history: result.history, historyModel: historyModel, manual: manualLink,
                                         appModel: model, preferences: providerSettings, writable: result.availability.isWriteReady)
          if !result.serverStarted {
            model.setConnection("接收服务启动失败")
          }
          model.setBrowserReceiverAvailable(result.serverStarted)
        }
        .onChange(of: scenePhase) { _, phase in
          manualLink.handleScenePhase(phase)
        }
        // scenePhase does not change when the user switches apps on macOS, so
        // this is the notification that actually fires on "copy a link
        // elsewhere, come back to LinkDigest".
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          manualLink.handleApplicationDidBecomeActive()
        }
        // Without a floor the three-column layout collapses to the two sidebar
        // minimums plus a detail pane too narrow to read.
        .frame(
          minWidth: DesignTokens.Layout.windowMinWidth,
          minHeight: DesignTokens.Layout.windowMinHeight
        )
        .appThemeEnvironment(appearanceThemeRaw, uiFontRawValue: uiFontRaw)
    }
    .defaultSize(width: 1200, height: 760)
    // 启动时一定打开主窗口：资料库、浏览器接收服务、MCP 都在这个窗口的启动任务里接上。
    // 上次关掉窗口再退出时，系统会「恢复成没有窗口」，App 进程在、服务却一个都没起——
    // 外部 Agent 连 MCP 只拿到「未开启」（2026-09-24 实测）。
    .defaultLaunchBehavior(.presented)
    // 明确声明这个场景不接任何外部事件。不写这一条，SwiftUI 会把每个进来的
    // `linkdigest://` 当成「再开一个窗口」的请求自己消化掉，URL 根本到不了
    // AppDelegate——表现就是点一次回链多一个汲作窗口。
    .handlesExternalEvents(matching: [])
    .windowResizability(.contentMinSize)
    // 标题必须留着：试过 `showsTitle: false`，工具栏失去分栏锚点，右侧那组图标
    // 整体漂到列表列上方。「汲作」两个字落在列表列顶上是这一取舍的代价。
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      LinkDigestCommands(manualLink: manualLink, localImport: localImport, quickCapture: quickCapture)
      AppUpdateCommands(updater: appUpdateController.updaterController.updater)
    }

    Settings {
      // The window's size floor lives on ProviderSettingsView itself; adding a
      // second, smaller frame here would only be dead weight.
      ProviderSettingsView(
        model: providerSettings,
        appModel: model,
        browserSupport: browserSupport,
        mediaStorage: mediaStorageSettings,
        knowledgeVault: knowledgeVaultSettings,
        updater: appUpdateController.updaterController.updater,
        companionSync: companionNoteSync,
        historyModel: historyModel
      )
        .background(SettingsWindowResizer())
        .appThemeEnvironment(appearanceThemeRaw, uiFontRawValue: uiFontRaw)
        .modifier(MainWindowLaunchGuard(isBootstrapped: { didBootstrap }))
    }
    .windowResizability(.contentMinSize)
    // Hiding the toolbar outright also takes the titlebar (and the traffic
    // lights) with it, so this is as tight as the top can get.
    .windowToolbarStyle(.unifiedCompact(showsTitle: true))
  }
}

/// AppKit hands the Settings scene a window without `.resizable`, and
/// `windowResizability` does not override that, so the zoom button stays dead
/// and the window is pinned to its content size. Put the flag back on and lift
/// the size ceiling; the floor still comes from the SwiftUI content frame.
private struct SettingsWindowResizer: NSViewRepresentable {
  func makeCoordinator() -> SettingsWindowCentering { SettingsWindowCentering() }

  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    let centering = context.coordinator
    DispatchQueue.main.async {
      guard let window = probe.window else { return }
      window.styleMask.insert(.resizable)
      window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      centering.attach(to: window)
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 设置窗口每次打开都落在主窗口正中。
///
/// 系统会记住设置窗口上次的位置，而那个位置停在屏幕左上角（2026-09-24 Syc 反馈：
/// 每次点左下角「设置」都弹在最左上方，而不是在主页居中）。打开期间用户自己拖到
/// 别处就尊重他的位置，关掉再开才重新居中。
@MainActor
final class SettingsWindowCentering: NSObject {
  private weak var window: NSWindow?
  private var needsCentering = true

  func attach(to window: NSWindow) {
    guard self.window !== window else { return }
    self.window = window
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
    center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    centerIfNeeded()
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func windowDidBecomeKey(_: Notification) { centerIfNeeded() }
  @objc private func windowWillClose(_: Notification) { needsCentering = true }

  private func centerIfNeeded() {
    guard needsCentering, let window, window.isVisible else { return }
    needsCentering = false
    // 主窗口可能在外接屏上：按主窗口所在的屏幕收边，而不是设置窗口上次待的那块屏。
    let main = Self.mainWindow(excluding: window)
    window.setFrameOrigin(Self.centeredOrigin(for: window.frame.size, over: main?.frame, on: main?.screen ?? window.screen))
  }

  private static func mainWindow(excluding settings: NSWindow) -> NSWindow? {
    NSApp.windows.first {
      $0 !== settings && $0.isVisible && $0.canBecomeMain && $0.frame.height > 300
    }
  }

  /// 以主窗口中心为准；没有主窗口就以屏幕中心为准。结果收在屏幕可用区域内。
  static func centeredOrigin(for size: NSSize, over anchor: NSRect?, on screen: NSScreen?) -> NSPoint {
    let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let reference = anchor ?? visible
    var origin = NSPoint(x: reference.midX - size.width / 2, y: reference.midY - size.height / 2)
    origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
    origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
    return NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }
}

#if DEBUG
private final class DebugVisualFixture: @unchecked Sendable {
  let configurationService: ProviderConfigurationService
  let provider: any ModelProvider
  let consentStore: any DataDestinationConsentStore = DebugVisualConsentStore()
  let preferencesStore: any ModelPreferencesStore = DebugVisualPreferencesStore()

  init() {
    let profile = try! ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "Preview Model",
      secretReference: .init(rawValue: "debug-visual-reference")
    )
    configurationService = ProviderConfigurationService(
      profileStore: DebugVisualProfileStore(profile: profile),
      secretStore: DebugVisualSecretStore()
    )
    provider = DebugVisualProvider(
      result: ProcessInfo.processInfo.environment["LINKDIGEST_DEBUG_VISUAL_FIXTURE_RESULT"] == "failure"
        ? .failure
        : .success
    )
  }
}

private actor DebugVisualPreferencesStore: ModelPreferencesStore {
  private var value = try! ModelPreferences(
    summaryPrompt: "提炼核心结论、关键证据和可执行下一步。",
    targetLanguage: "简体中文"
  )
  func load() async throws -> ModelPreferences { value }
  func save(_ preferences: ModelPreferences) async throws { value = preferences }
}

private actor DebugVisualProfileStore: ProviderProfileStore {
  private let profile: ProviderProfile
  init(profile: ProviderProfile) { self.profile = profile }
  func load() async throws -> ProviderProfile? { profile }
  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor DebugVisualSecretStore: SecretStore {
  func save(_: String, for _: SecretReference) async throws {}
  func read(_: SecretReference) async throws -> String? { "not-a-real-key" }
  func contains(_: SecretReference) async throws -> Bool { true }
  func delete(_: SecretReference) async throws {}
}

private actor DebugVisualConsentStore: DataDestinationConsentStore {
  private var values: Set<DataDestinationIdentity> = []
  func isConfirmed(for identity: DataDestinationIdentity) async throws -> Bool { values.contains(identity) }
  func rememberConfirmation(for identity: DataDestinationIdentity) async throws { values.insert(identity) }
  func forgetAll() async throws { values.removeAll() }
}

private struct DebugVisualProvider: ModelProvider {
  enum Result { case success, failure }
  let result: Result

  func stream(
    profile _: ProviderProfile,
    apiKey _: String,
    intent _: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      switch result {
      case .success:
        continuation.yield(.delta("OK"))
        continuation.yield(.completed)
        continuation.finish()
      case .failure:
        continuation.finish(throwing: ModelProviderFailure(
          code: .authInvalid,
          retryable: false,
          hadOutput: false
        ))
      }
    }
  }
  func cancelActiveStreams() {}
}
#endif

/// App-level menu commands. ⌘N intentionally repurposes the default New Window
/// slot: LinkDigest is a single-window utility, and "add a link" is its primary
/// creation act.
private struct LinkDigestCommands: Commands {
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var localImport: LocalImportController
  @ObservedObject var quickCapture: QuickCaptureController
  /// 新建笔记的动作由承载列表的视图提供——只有它知道建完要选中哪一条。
  @FocusedValue(\.newNote) private var newNote
  @FocusedValue(\.todayNote) private var todayNote
  @FocusedValue(\.focusHistorySearch) private var focusHistorySearch
  @FocusedValue(\.toggleFavorite) private var toggleFavorite
  @FocusedValue(\.newCollection) private var newCollection
  @FocusedValue(\.goBack) private var goBack
  @FocusedValue(\.summarizeCurrent) private var summarizeCurrent
  @FocusedValue(\.translateCurrent) private var translateCurrent
  @AppStorage(ReadingFontSize.storageKey) private var readingFontSizeRaw = Double(ReadingFontSize.default)
  @AppStorage(ReadingLayoutWidth.storageKey) private var readingUsesWideLayout = false

  @Environment(\.openSettings) private var openSettings

  var body: some Commands {
    // 「关于汲作」原来是系统默认面板：只有图标和版本号，没有一句话介绍、没有官网（2026-10-02 发布前检查）。
    CommandGroup(replacing: .appInfo) {
      Button("关于\(ProductDisplay.name)") { AppAboutPanel.show() }
    }
    // 「帮助」原来只有系统默认的一项，点了提示找不到帮助（App 没有帮助手册）。
    // 指向官网的使用说明，反馈走设置里已有的「写邮件 + 导出诊断信息」。
    CommandGroup(replacing: .help) {
      Button("\(ProductDisplay.name)使用说明") { NSWorkspace.shared.open(AppAboutPanel.guideURL) }
      Button("常见问题") { NSWorkspace.shared.open(AppAboutPanel.faqURL) }
      Divider()
      Button("反馈问题…") {
        SettingsNavigationRequest.request("updates")
        openSettings()
      }
      Button("隐私说明") { NSWorkspace.shared.open(AppAboutPanel.privacyURL) }
    }
    CommandGroup(replacing: .newItem) {
      Button("添加链接…") { manualLink.open() }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!manualLink.canOpen)
      Button("从剪贴板添加链接") { manualLink.readClipboardAndOpen() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!manualLink.canOpen)
      // 写笔记要能一键起手：想记东西时最不该做的事就是先找按钮。
      // ⌘N 已给「添加链接」，所以用 ⌘⇧N。
      Button("新建笔记") { newNote?.run() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(newNote == nil)
      Button("今天的笔记") { todayNote?.run() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(todayNote == nil)
      // 快捷键是全局注册的（在别的 App 里也能按），这里只在标题里写出来，
      // 不再挂菜单快捷键，免得同一个组合键被触发两次。
      Button("快速记录（\(QuickCaptureController.shortcutDescription)）") { quickCapture.show() }
      Divider()
      // 不跟 canImport 绑 disabled（2026-09-23）：菜单栏的启用状态在 SwiftUI Commands 里
      // 不一定跟着刷新，实测启动后会一直灰着。改为常亮，未就绪时由控制器说明原因。
      Button("导入本地文件…") { localImport.chooseFiles() }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      Button("新建合集…") { newCollection?.run() }
        .disabled(newCollection == nil)
      Button("同步语音备忘录") { localImport.syncVoiceMemos() }
      Button("同步备忘录") { localImport.syncAppleNotes() }
    }
    CommandGroup(after: .textEditing) {
      Button("搜索历史") { focusHistorySearch?.run() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(focusHistorySearch == nil)
    }
    // ⇧⌘S / ⇧⌘E：汲作没有「存储为」，这两个组合在 macOS 菜单里都没被占（2026-10-02 查过）。
    CommandMenu("内容") {
      Button("生成总结") { summarizeCurrent?.run() }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(summarizeCurrent == nil)
      Button("翻译") { translateCurrent?.run() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(translateCurrent == nil)
    }
    // 阅读快捷键对齐 Tolaria：⌘D 收藏，⌘+ / ⌘− / ⌘0 调正文字号（2026-09-25）。
    // 字号直接写偏好，不依赖焦点：光标在侧栏时按也生效。
    CommandGroup(after: .toolbar) {
      // 卡片墙、博主页、专注阅读的「返回」原来只能用鼠标点左上角（2026-10-01 走查）。
      Button("返回") { goBack?.run() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(goBack == nil)
      Divider()
      Button("收藏 / 取消收藏") { toggleFavorite?.run() }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(toggleFavorite == nil)
      Divider()
      Button("放大正文字号") { setReadingFontSize(readingFontSizeRaw + Double(ReadingFontSize.step)) }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(readingFontSizeRaw >= Double(ReadingFontSize.maximum))
      Button("缩小正文字号") { setReadingFontSize(readingFontSizeRaw - Double(ReadingFontSize.step)) }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(readingFontSizeRaw <= Double(ReadingFontSize.minimum))
      Button("恢复默认字号") { readingFontSizeRaw = Double(ReadingFontSize.default) }
        .keyboardShortcut("0", modifiers: .command)
      // ⌥⌘\\：⌥⌘W 是系统「全部关闭」，按下去整个窗口没了（2026-09-25 实测）。
      Toggle("加宽正文", isOn: $readingUsesWideLayout)
        .keyboardShortcut("\\", modifiers: [.command, .option])
      Divider()
    }
  }

  private func setReadingFontSize(_ value: Double) {
    readingFontSizeRaw = min(max(value, Double(ReadingFontSize.minimum)), Double(ReadingFontSize.maximum))
  }
}


/// 视频清单的晚绑定来源：设置页和媒体库在 App 构造期就要拿到闭包，历史服务却要等
/// bootstrap。绑定前返回错误（而不是空清单）——空清单会把整个目录判成孤儿。
final class LateBoundMediaInventory: @unchecked Sendable {
  private let lock = NSLock()
  private var history: HistoryApplicationService?

  func bind(_ history: HistoryApplicationService?) {
    lock.lock(); defer { lock.unlock() }
    self.history = history
  }

  func inventory() throws -> [MediaStorageEntry] {
    lock.lock(); let service = history; lock.unlock()
    guard let service else { throw RepositoryFailure.unavailable }
    return try service.mediaStorageInventory()
  }
}

/// 「关于汲作」面板和帮助菜单用到的官网地址。
enum AppAboutPanel {
  static let siteURL = URL(string: "https://songxiaor.github.io/jizuo/")!
  static let guideURL = URL(string: "https://songxiaor.github.io/jizuo/#install")!
  static let faqURL = URL(string: "https://songxiaor.github.io/jizuo/#faq")!
  static let privacyURL = URL(string: "https://songxiaor.github.io/jizuo/privacy.html")!

  @MainActor static func show() {
    let body = NSMutableAttributedString(
      string: "读过的、看过的、自己写的，\n都收进本机的一个资料库；\n总结、翻译、转写都在这里完成。\n\n",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    )
    let links: [(String, URL)] = [("官网", siteURL), ("使用说明", guideURL), ("隐私说明", privacyURL)]
    for (index, link) in links.enumerated() {
      if index > 0 {
        body.append(NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
      }
      body.append(NSAttributedString(string: link.0, attributes: [.font: NSFont.systemFont(ofSize: 11), .link: link.1]))
    }
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    body.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: body.length))
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: body,
      NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "资料只存在这台电脑上",
    ])
  }
}
