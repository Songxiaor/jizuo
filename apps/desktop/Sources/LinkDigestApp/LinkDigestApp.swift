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
  var identity: DataDestinationIdentity?
  var disclosure: DataDestinationDisclosure?
}

@MainActor final class AppViewModel: ObservableObject {
  @Published var connection = "等待扩展连接"
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

  var envelope: CaptureEnvelopeV1? { currentCapture?.envelope }

  func installModelRunOrchestrator(_ value: ModelRunOrchestrator) {
    guard modelRunOrchestrator == nil else { return }
    modelRunOrchestrator = value
  }

  func setConnection(_ value: String) { connection = value }

  func setStorageAvailability(_ value: StorageAvailability) {
    storageAvailability = value
  }

  func receive(_ value: CurrentCapture) {
    connection = "已连接"
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
    return !currentCapture.envelope.capture.text
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

  func summarize() async { await requestRun(intent: .summarize) }
  func translate() async { await requestRun(intent: .translate) }

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
      expectedIdentity: identity,
      token: attempt.token
    )
  }

  func stop() async {
    await modelRunOrchestrator?.stop()
  }

  private func requestRun(intent: RunIntentKind) async {
    guard
      canStartRun,
      let currentCapture,
      let consentStore
    else {
      return
    }
    let token = beginPreparation(for: currentCapture, intent: intent)
    var retainedBySheetOrLaunch = false
    defer {
      if !retainedBySheetOrLaunch {
        releasePreparation(ifOwner: token)
      }
    }

    do {
      guard let identity = try await loadDisclosureIdentity() else {
        guard preparationIsValid(token, capture: currentCapture) else { return }
        dataDestinationNotice = V02ErrorCatalog.presentation(
          for: ModelRunErrorCode.modelNotConfigured.rawValue
        ).visibleText
        return
      }
      guard !Task.isCancelled,
            setPreparationIdentity(identity, ifOwner: token, capture: currentCapture)
      else { return }

      if try await consentStore.isConfirmed(for: identity) {
        guard !Task.isCancelled,
              preparationIsValid(token, capture: currentCapture)
        else { return }
        retainedBySheetOrLaunch = await authorizeAndLaunch(
          capture: currentCapture,
          intent: intent,
          expectedIdentity: identity,
          token: token
        )
      } else {
        guard !Task.isCancelled,
              preparationIsValid(token, capture: currentCapture)
        else { return }
        retainedBySheetOrLaunch = presentDisclosure(
          for: currentCapture,
          intent: intent,
          identity: identity,
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
      targetLanguage: intent == .translate ? "简体中文" : nil
    )
    // Protect the real Task before createRun can block. This pending ownership
    // must not publish `.starting`: that state remains commit-confirmed.
    taskIDByRunID[request.runID] = request.taskID
    launchPendingRunID = request.runID
    activeRunTaskID = request.taskID
    releasePreparation(ifOwner: token)
    await modelRunOrchestrator.start(
      request: request,
      capture: capture.envelope,
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
      guard let identity = try await loadDisclosureIdentity() else {
        guard preparationIsValid(token, capture: capture) else { return false }
        dataDestinationNotice = V02ErrorCatalog.presentation(
          for: ModelRunErrorCode.modelNotConfigured.rawValue
        ).visibleText
        return false
      }
      guard !Task.isCancelled,
            setPreparationIdentity(identity, ifOwner: token, capture: capture)
      else { return false }
      let presented = presentDisclosure(
        for: capture,
        intent: intent,
        identity: identity,
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

  private func loadDisclosureIdentity() async throws -> DataDestinationIdentity? {
    guard let configurationService else { return nil }
    do {
      guard let profile = try await configurationService.loadProfileForDisclosure() else { return nil }
      return DataDestinationIdentity(profile: profile)
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
      title: capture.envelope.source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func beginPreparation(for capture: CurrentCapture, intent: RunIntentKind) -> UUID {
    let token = UUID()
    preparationAttempt = .init(
      token: token,
      capture: capture,
      intent: intent,
      identity: nil,
      disclosure: nil
    )
    return token
  }

  private func releasePreparation(ifOwner token: UUID) {
    guard let attempt = preparationAttempt, attempt.token == token else { return }
    preparationAttempt = nil
    if dataDestinationDisclosure?.id == attempt.disclosure?.id {
      dataDestinationDisclosure = nil
    }
  }

  private func setPreparationIdentity(
    _ identity: DataDestinationIdentity,
    ifOwner token: UUID,
    capture: CurrentCapture
  ) -> Bool {
    guard var attempt = preparationAttempt,
          attempt.token == token,
          matchesCurrentCapture(attempt.capture, capture),
          matchesCurrentCapture(capture, currentCapture)
    else { return false }
    attempt.identity = identity
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
  @StateObject private var model: AppViewModel
  @StateObject private var historyModel: HistoryViewModel
  @StateObject private var providerSettings: ProviderSettingsViewModel

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let composition: AppComposition

  init() {
    let applicationSupportRoot: AppComposition.ApplicationSupportRoot
    do {
      let root = try AppApplicationSupportRoot.resolve()
      applicationSupportRoot = { root }
    } catch {
      // Preserve the composition's structured storage-unavailable path rather
      // than letting an invalid debug smoke override crash the SwiftUI process.
      applicationSupportRoot = { throw RepositoryFailure.unavailable }
    }
    let configurationService: ProviderConfigurationService
    let provider: any ModelProvider
    let consentStore: any DataDestinationConsentStore
    #if DEBUG
    if AppApplicationSupportRoot.shouldUseVisualFixture() {
      let fixture = DebugVisualFixture()
      configurationService = fixture.configurationService
      provider = fixture.provider
      consentStore = fixture.consentStore
    } else {
      configurationService = ProviderConfigurationService(
        profileStore: UserDefaultsProviderProfileStore(),
        secretStore: KeychainSecretStore()
      )
      let sessionConfiguration = URLSessionConfiguration.ephemeral
      sessionConfiguration.httpCookieStorage = nil
      sessionConfiguration.urlCache = nil
      provider = OpenAICompatibleProvider(
        session: URLSession(configuration: sessionConfiguration)
      )
      consentStore = UserDefaultsDataDestinationConsentStore()
    }
    #else
    configurationService = ProviderConfigurationService(
      profileStore: UserDefaultsProviderProfileStore(),
      secretStore: KeychainSecretStore()
    )
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.urlCache = nil
    provider = OpenAICompatibleProvider(
      session: URLSession(configuration: sessionConfiguration)
    )
    consentStore = UserDefaultsDataDestinationConsentStore()
    #endif
    let model = AppViewModel(
      configurationService: configurationService,
      consentStore: consentStore
    )
    let historyModel = HistoryViewModel()
    historyModel.beginBootstrapLoading()
    let nowMilliseconds: @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
    let serverStarter = makeUnixSocketServerStarter(
      path: linkDigestSocketPath,
      statusSink: { value in await model.setConnection(value) }
    )
    let injectSmokeOpenFailure = AppApplicationSupportRoot.shouldInjectOpenFailure()
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: applicationSupportRoot,
      repositoryFactory: { location in
        if injectSmokeOpenFailure {
          throw RepositoryFailure.injectedFailure
        }
        return try GRDBHistoryRepository.open(at: location)
      },
      nowMilliseconds: nowMilliseconds,
      serverStarter: serverStarter,
      availabilitySink: { value in
        await model.setStorageAvailability(value)
      },
      captureSink: { value in
        await model.receive(value)
        await historyModel.reveal(taskID: value.taskID)
      }
    ))

    self.configurationService = configurationService
    self.provider = provider
    self.composition = composition
    _model = StateObject(wrappedValue: model)
    _historyModel = StateObject(wrappedValue: historyModel)
    _providerSettings = StateObject(
      wrappedValue: ProviderSettingsViewModel(
        configurationService: configurationService,
        provider: provider
      )
    )
  }

  var body: some Scene {
    WindowGroup("LinkDigest") {
      HistoryContentView(model: historyModel, appModel: model)
        .task {
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
          if result.availability.isWriteReady, let history = result.history {
            let orchestrator = ModelRunOrchestrator(
              configurationService: configurationService,
              provider: provider,
              history: history,
              storageWriteGate: result.storageWriteGate
            )
            model.installModelRunOrchestrator(orchestrator)
          }
          if !result.serverStarted {
            model.setConnection("接收服务启动失败")
          }
        }
    }
    .defaultSize(width: 1100, height: 760)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified(showsTitle: true))

    Settings {
      ProviderSettingsView(model: providerSettings)
        .padding(24)
        .frame(minWidth: 480)
    }
  }
}

#if DEBUG
private final class DebugVisualFixture: @unchecked Sendable {
  let configurationService: ProviderConfigurationService
  let provider: any ModelProvider
  let consentStore: any DataDestinationConsentStore = DebugVisualConsentStore()

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
