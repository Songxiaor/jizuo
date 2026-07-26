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
  @Published private(set) var runState: RunState = .idle
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
    guard
      storageAvailability.isWriteReady,
      modelRunOrchestrator != nil,
      configurationService != nil,
      consentStore != nil,
      let currentCapture
    else {
      return false
    }
    return !currentCapture.document.text
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !runState.isActive
      && launchPendingRunID == nil
      && preparationAttempt == nil
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
    case .idle, .starting, .streaming, .stopping, .stopped, .completed:
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

  func translate(
    historyDetail: HistoryDetailProjection,
    preferences: ModelPreferences,
    modelOverride: String? = nil
  ) async {
    guard prepareHistoryCapture(historyDetail) else { return }
    await translate(preferences: preferences, modelOverride: modelOverride)
  }

  func canStartRun(from detail: HistoryDetailProjection) -> Bool {
    guard !detail.snapshots.isEmpty else { return false }
    if currentCapture?.taskID == detail.task.id { return canStartRun }
    guard storageAvailability.isWriteReady,
          modelRunOrchestrator != nil,
          configurationService != nil,
          consentStore != nil,
          !runState.isActive,
          launchPendingRunID == nil,
          preparationAttempt == nil
    else { return false }
    return detail.snapshots.last?.bodyText
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  func canTranslate(preferences: ModelPreferences) -> Bool {
    canStartRun && !isTranslationLanguageMatch(
      text: currentCapture?.document.text,
      outputLanguage: preferences.outputLanguage
    )
  }

  func canTranslate(from detail: HistoryDetailProjection, preferences: ModelPreferences) -> Bool {
    canStartRun(from: detail) && !isTranslationLanguageMatch(
      text: detail.snapshots.last?.bodyText,
      outputLanguage: preferences.outputLanguage
    )
  }

  func translationUnavailableReason(
    text: String?,
    outputLanguage: String
  ) -> String? {
    isTranslationLanguageMatch(text: text, outputLanguage: outputLanguage)
      ? "捕获内容与输出语言相同，无需翻译。"
      : nil
  }

  var isDataDestinationDisclosurePresented: Bool {
    dataDestinationDisclosure != nil
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
    if currentCapture?.taskID == detail.task.id,
       currentCapture?.snapshotID == snapshot.id {
      return true
    }
    let formatter = ISO8601DateFormatter()
    let document = CapturedDocument(
      createdAt: formatter.string(
        from: Date(timeIntervalSince1970: Double(snapshot.envelopeCreatedAtMilliseconds) / 1_000)
      ),
      origin: snapshot.sourceKind == CapturedDocument.Origin.manualLink.rawValue
        ? .manualLink
        : .browserCapture,
      url: snapshot.sourceURL,
      title: snapshot.title,
      platform: snapshot.platform,
      method: snapshot.captureMethod,
      text: snapshot.bodyText,
      characterCount: snapshot.characterCount,
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
      modelOverride: attemptModelOverride(for: token)
    )
    // Protect the real Task before createRun can block. This pending ownership
    // must not publish `.starting`: that state remains commit-confirmed.
    taskIDByRunID[request.runID] = request.taskID
    launchPendingRunID = request.runID
    activeRunTaskID = request.taskID
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
    guard let text else { return false }
    return CapturedContentLanguage.isSameOutputLanguage(
      content: text,
      outputLanguage: outputLanguage
    )
  }

  func receiveRunState(runID: RunID, state: RunState) {
    let wasLaunchPending = launchPendingRunID == runID
    if case .starting = state {
      if wasLaunchPending { launchPendingRunID = nil }
      visibleRunID = runID
      activeRunTaskID = taskIDByRunID[runID]
      visibleRunTaskID = taskIDByRunID[runID]
      runState = state
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
    runState = state
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
  }

  private func isTerminal(_ state: RunState) -> Bool {
    switch state {
    case .stopped, .completed, .incomplete, .failed, .storageError:
      true
    case .idle, .starting, .streaming, .stopping:
      false
    }
  }
}

@main struct LinkDigestApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: AppViewModel
  @StateObject private var historyModel: HistoryViewModel
  @StateObject private var manualLink: ManualLinkViewModel
  @StateObject private var providerSettings: ProviderSettingsViewModel
  @StateObject private var browserSupport: BrowserSupportViewModel
  @StateObject private var mediaStorageSettings: MediaStorageSettingsViewModel
  @StateObject private var sessionMediaPlayback: SessionMediaPlaybackController
  @State private var didBootstrap = false

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let composition: AppComposition
  private let socketServerLifecycle: UnixSocketServerLifecycle
  private let applicationTerminationObserver: NSObjectProtocol
  private let terminationSignalSource: DispatchSourceSignal

  init() {
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
    // 播放和转写共用同一个刷新服务：转写要单独问一次「只要音轨」的 playurl，
    // 复用同一份 Cookie 与选流诊断，避免两套并行的 B 站会话状态。
    let sessionMediaRefreshService = SessionMediaRefreshService(
      resources: manualResourceFetcher,
      bilibiliQuality: { mediaStoragePreference.bilibiliStreamQuality },
      bilibiliCookieHeader: {
        await BilibiliSiteSessionController.shared.cookieHeader()
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
    let douyinAdapter = DouyinSourceAdapter(fetcher: manualResourceFetcher)
    // Douyin is registered first so short links never fall into the generic HTML path.
    let historyModel = HistoryViewModel(
      imageCache: imageCache,
      imageResources: manualResourceFetcher,
      mediaStore: mediaStore,
      mediaDownloader: mediaDownloader,
      faviconCache: faviconCache,
      faviconResources: manualResourceFetcher,
      videoTranscriber: AppleSpeechVideoTranscriber(),
      imageTextRecognizer: AppleVisionTextRecognizer(),
      // Router 按服务地址在「阶跃流式 SSE」和「通用 /audio/transcriptions」之间选，
      // 两条路径的接口形态不同（增量 vs 一次性返回），不能只换参数。
      onlineAudioTranscriber: OnlineAudioTranscriberRouter(
        configurationService: configurationService
      ),
      transcriptTidier: OpenAICompatibleTranscriptTidier(
        configurationService: configurationService
      ),
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
        sourceAdapters: [douyinAdapter, githubAdapter]
      ),
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
      statusSink: { value in await model.setConnection(value) }
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
        installer: try? BrowserSupportInstaller.appBundled()
      )
    )
    _mediaStorageSettings = StateObject(
      wrappedValue: MediaStorageSettingsViewModel(store: mediaStoragePreference)
    )
    _sessionMediaPlayback = StateObject(wrappedValue: sessionMediaPlaybackController)
  }

  var body: some Scene {
    WindowGroup(ProductDisplay.name) {
      HistoryContentView(
        model: historyModel,
        appModel: model,
        manualLink: manualLink,
        providerSettings: providerSettings,
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
          if result.availability.isWriteReady, let history = result.history {
            manualLink.configure(
              history: history,
              storageWriteGate: result.storageWriteGate,
              nowMilliseconds: { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) },
              captureSink: { value in
                await model.receive(value)
                await historyModel.reveal(taskID: value.taskID)
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
        .frame(minWidth: 900, minHeight: 620)
    }
    .defaultSize(width: 1100, height: 760)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands { LinkDigestCommands(manualLink: manualLink) }

    Settings {
      // The window's size floor lives on ProviderSettingsView itself; adding a
      // second, smaller frame here would only be dead weight.
      ProviderSettingsView(
        model: providerSettings,
        appModel: model,
        browserSupport: browserSupport,
        mediaStorage: mediaStorageSettings
      )
        .background(SettingsWindowResizer())
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
  @FocusedValue(\.focusHistorySearch) private var focusHistorySearch

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("添加链接…") { manualLink.open() }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!manualLink.canOpen)
      Button("从剪贴板添加链接") { manualLink.readClipboardAndOpen() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!manualLink.canOpen)
    }
    CommandGroup(after: .textEditing) {
      Button("搜索历史") { focusHistorySearch?.run() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(focusHistorySearch == nil)
    }
  }
}
