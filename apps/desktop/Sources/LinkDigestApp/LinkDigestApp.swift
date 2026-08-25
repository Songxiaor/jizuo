import AppKit
import Darwin
import SwiftUI
import Foundation
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

@MainActor final class AppViewModel: ObservableObject {
  @Published var connection = "等待扩展连接"
  @Published private(set) var browserReceiverState: BrowserReceiverState = .starting
  @Published private(set) var lastBrowserCaptureAt: Date?
  @Published private(set) var currentCapture: CurrentCapture?
  /// 非 @Published：写入统一走 `setRunState`（见其注释）。读取方始终拿到
  /// 最新值；只有状态真正切换时才发 objectWillChange，流式纯增长拍点不发。
  private(set) var runState: RunState = .idle
  /// 流式正文的热路径发布通道；与 runState 同步更新（见 setRunState）。
  let liveRunText = LiveRunTextModel()
  @Published private(set) var activeRunTaskID: TaskID?
  @Published private(set) var visibleRunTaskID: TaskID?
  @Published private(set) var storageAvailability: StorageAvailability = .bootstrapping
  @Published private(set) var dataDestinationDisclosure: DataDestinationDisclosure?
  @Published private(set) var dataDestinationNotice: String?

  private var modelRunOrchestrator: ModelRunOrchestrator?
  private let configurationService: ProviderConfigurationService?
  private let consentStore: (any DataDestinationConsentStore)?
  private let makeRunID: @Sendable () -> RunID
  private var visibleRunID: RunID?
  private var launchPendingRunID: RunID?
  private var taskIDByRunID: [RunID: TaskID] = [:]
  private var preparationAttempt: RunPreparationAttempt?
  private var confirmingAttemptToken: UUID?

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
      "正在准备本地历史…"
    case .writable:
      "本地历史可用"
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
    await requestRun(intent: .summarize, preferences: preferences, modelOverride: modelOverride)
  }
  func translate(
    preferences: ModelPreferences = .default,
    modelOverride: String? = nil
  ) async {
    guard !isTranslationLanguageMatch(
      text: currentCapture?.document.text,
      outputLanguage: preferences.outputLanguage
    ) else {
      dataDestinationNotice = "捕获内容与输出语言相同，无需翻译。"
      return
    }
    await requestRun(intent: .translate, preferences: preferences, modelOverride: modelOverride)
  }

  func summarize(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async {
    guard prepareHistoryCapture(historyDetail) else { return }
    await summarize(preferences: preferences, modelOverride: modelOverride)
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
    return runState.isActive
      || isDataDestinationDisclosurePresented
      || isConfirmingDataDestinationDisclosure
  }

  func translate(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async {
    guard prepareHistoryCapture(historyDetail) else { return }
    await translate(preferences: preferences, modelOverride: modelOverride)
  }

  func canStartRun(from detail: HistoryDetailProjection) -> Bool {
    runStartUnavailableReason(usingCurrentCapture: false, detail: detail) == nil
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
      ? "捕获内容与输出语言相同，无需翻译。"
      : nil
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
    ) ? nil : "捕获内容与输出语言相同，无需翻译。"
  }

  /// `canStartRun` 的人话版。顺序按用户最可能先撞上的拦下来。
  func runStartUnavailableReason(
    usingCurrentCapture: Bool,
    detail: HistoryDetailProjection?
  ) -> String? {
    if !usingCurrentCapture {
      guard let detail else { return "还没有可发送的内容" }
      if detail.snapshots.isEmpty { return "这条没有可发送的正文" }
      if currentCapture?.taskID == detail.task.id {
        return runStartUnavailableReason(usingCurrentCapture: true, detail: nil)
      }
    }

    switch storageAvailability {
    case .writable:
      break
    case .bootstrapping:
      return "正在准备本地历史…"
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
    connection = "本地历史"
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

  /// `runState` 唯一的写入口。流式生成每 250ms 就有一个「同 intent、正文
  /// 纯增长」的拍点——这种拍点不触发 objectWillChange，正文只写进
  /// `liveRunText`，重绘收窄到显示它的叶子视图；其余任何变化（开始/思考/
  /// 停止/终态、intent 切换、清空）照常通知整树。`runState` 本身每个拍点
  /// 都会更新，读取方语义与 @Published 时代一致。
  private func setRunState(_ state: RunState) {
    // 同值拍点直接丢弃。推理模型的思考阶段每收到一个 delta 就报一次
    // `.thinking(intent:)`，而这个状态不带任何随 delta 变化的负载；照发
    // objectWillChange 等于让整棵历史窗口按 delta 速率重求值。实测一次
    // 翻译的思考阶段主线程 100% CPU、连续 23 秒几乎不出帧。
    guard state != runState else { return }
    if case let .streaming(intent, partialText) = state,
       case .streaming(let previousIntent, _) = runState,
       previousIntent == intent,
       !partialText.isEmpty {
      runState = state
      liveRunText.setText(partialText)
      return
    }
    objectWillChange.send()
    runState = state
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
  }
}

@main struct LinkDigestApp: App {
  @NSApplicationDelegateAdaptor(LinkDigestAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: AppViewModel
  @StateObject private var historyModel: HistoryViewModel
  @StateObject private var manualLink: ManualLinkViewModel
  @StateObject private var providerSettings: ProviderSettingsViewModel
  @StateObject private var browserSupport: BrowserSupportViewModel
  @StateObject private var mediaStorageSettings: MediaStorageSettingsViewModel
  @StateObject private var knowledgeVaultSettings: KnowledgeVaultSettingsViewModel
  @StateObject private var sessionMediaPlayback: SessionMediaPlaybackController
  @State private var didBootstrap = false
  /// 注入 `\.appTheme` 用。视图各自读 AppStorage 会重复三行样板，
  /// 而设置页那几个子视图当初就是因为拿不到主题才写死了 `.red`。
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  /// 用户指定的界面字体。空/theme 表示跟随主题。
  @AppStorage(UIFontSelection.storageKey) private var uiFontRaw = UIFontSelection.defaultStoredValue

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let composition: AppComposition
  private let appUpdateController: AppUpdateController
  private let socketServerLifecycle: UnixSocketServerLifecycle
  private let applicationTerminationObserver: NSObjectProtocol
  private let terminationSignalSource: DispatchSourceSignal

  init() {
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
    #else
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
    let startupTranscriptionCleanupFailure: String?
    do {
      try transcriptionTempStore?.cleanupAll()
      startupTranscriptionCleanupFailure = nil
    } catch let error as TranscriptionTempStoreError {
      startupTranscriptionCleanupFailure = error.userMessage
    } catch {
      startupTranscriptionCleanupFailure = TranscriptionTempStoreError.unavailable.userMessage
    }
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
        configurationService: configurationService
      ),
      // 起草用用户自己装的 Claude Code。没装的话构造出来也无妨——
      // 它的 locateExecutable() 会返回 nil,那一步的入口说清楚缺什么。
      draftAgent: ClaudeCLIAgent(),
      mindMapExtractor: OpenAICompatibleMindMapExtractor(
        configurationService: configurationService
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
    let manualLink = ManualLinkViewModel(
      captureService: .init(
        fetcher: manualResourceFetcher,
        sourceAdapters: [douyinAdapter, xiaohongshuAdapter, bilibiliAdapter, githubAdapter]
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
      }
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
        await historyModel.reveal(taskID: value.taskID)
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
        } else if mediaStoragePreference.autoSaveCapturedVideo,
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
            // Refresh the open detail so local images appear once staging finishes.
            await historyModel.reveal(taskID: taskID)
          }
        }
      },
      // 收藏夹同步：扩展只交来一串推文 id，正文由公开端点逐条取回。受理必须
      // 立刻返回（扩展只有 10s 预算），真正的抓取在 App 的抓取队列里串行进行。
      bookmarksSink: { request in
        let outcome = await MainActor.run { manualLink.enqueueXBookmarks(request.tweetIDs) }
        return .init(queued: outcome.queued, skipped: outcome.skipped)
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
    _model = StateObject(wrappedValue: model)
    _historyModel = StateObject(wrappedValue: historyModel)
    _manualLink = StateObject(wrappedValue: manualLink)
    _providerSettings = StateObject(
      wrappedValue: ProviderSettingsViewModel(
        configurationService: configurationService,
        provider: provider,
        preferencesStore: preferencesStore
      )
    )
    _browserSupport = StateObject(
      wrappedValue: BrowserSupportViewModel(
        installer: try? BrowserSupportInstaller.appBundled(),
        deliveryLog: .standard(),
        applicationRoots: BrowserSupportBrowser.systemApplicationRoots(
          homeRoot: FileManager.default.homeDirectoryForCurrentUser)
      )
    )
    _mediaStorageSettings = StateObject(
      wrappedValue: MediaStorageSettingsViewModel(store: mediaStoragePreference)
    )
    _knowledgeVaultSettings = StateObject(wrappedValue: knowledgeVaultSettingsModel)
    _sessionMediaPlayback = StateObject(wrappedValue: sessionMediaPlaybackController)
  }

  var body: some Scene {
    WindowGroup(ProductDisplay.name) {
      HistoryContentView(
        model: historyModel,
        appModel: model,
        manualLink: manualLink,
        providerSettings: providerSettings,
        browserSupport: browserSupport,
        sessionMediaPlayback: sessionMediaPlayback
      )
        .task {
          manualLink.handleScenePhase(scenePhase)
          guard !didBootstrap else { return }
          didBootstrap = true
          var didConfigureHistory = false
          defer {
            if Task.isCancelled && !didConfigureHistory { didBootstrap = false }
          }
          await providerSettings.load()
          if AppApplicationSupportRoot.shouldHoldHistoryLoading() {
            try? await Task.sleep(for: .seconds(10))
          }
          let result = await composition.bootstrap()
          historyModel.configure(
            history: result.history,
            isReadOnly: result.historyIsReadOnly,
            unavailableCode: result.historyUnavailableCode,
            readOnlyReason: result.historyReadOnlyReason
          )
          didConfigureHistory = true
          knowledgeVaultSettings.configure(history: result.history)
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
                await historyModel.reveal(taskID: value.taskID)
                await knowledgeVaultSettings.scheduleAutoSync()
              }
            )
          }
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
    // 明确声明这个场景不接任何外部事件。不写这一条，SwiftUI 会把每个进来的
    // `linkdigest://` 当成「再开一个窗口」的请求自己消化掉，URL 根本到不了
    // AppDelegate——表现就是点一次回链多一个汲作窗口。
    .handlesExternalEvents(matching: [])
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      LinkDigestCommands(manualLink: manualLink)
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
        updater: appUpdateController.updaterController.updater
      )
        .background(SettingsWindowResizer())
        .appThemeEnvironment(appearanceThemeRaw, uiFontRawValue: uiFontRaw)
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
  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async {
      guard let window = probe.window else { return }
      window.styleMask.insert(.resizable)
      window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
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
  /// 新建笔记的动作由承载列表的视图提供——只有它知道建完要选中哪一条。
  @FocusedValue(\.newNote) private var newNote
  @FocusedValue(\.todayNote) private var todayNote
  @FocusedValue(\.focusHistorySearch) private var focusHistorySearch

  var body: some Commands {
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
    }
    CommandGroup(after: .textEditing) {
      Button("搜索历史") { focusHistorySearch?.run() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(focusHistorySearch == nil)
    }
  }
}
