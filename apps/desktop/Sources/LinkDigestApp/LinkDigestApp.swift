import SwiftUI
import Foundation
import LinkDigestAdapters
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestTransport

public let linkDigestSocketPath = ProcessInfo.processInfo.environment["LINKDIGEST_SOCKET_PATH"] ?? "/tmp/linkdigest-\(getuid()).sock"

@MainActor final class AppViewModel: ObservableObject {
  @Published var connection = "等待扩展连接"
  @Published private(set) var currentCapture: CurrentCapture?
  @Published private(set) var runState: RunState = .idle
  @Published private(set) var activeRunTaskID: TaskID?
  @Published private(set) var visibleRunTaskID: TaskID?
  @Published private(set) var storageAvailability: StorageAvailability = .bootstrapping

  private var modelRunOrchestrator: ModelRunOrchestrator?
  private let makeRunID: @Sendable () -> RunID
  private var visibleRunID: RunID?
  private var launchPendingRunID: RunID?
  private var taskIDByRunID: [RunID: TaskID] = [:]

  init(
    modelRunOrchestrator: ModelRunOrchestrator? = nil,
    makeRunID: @escaping @Sendable () -> RunID = { RunID() }
  ) {
    self.modelRunOrchestrator = modelRunOrchestrator
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
    currentCapture = value
  }

  var canStartRun: Bool {
    guard
      storageAvailability.isWriteReady,
      modelRunOrchestrator != nil,
      let currentCapture
    else {
      return false
    }
    return !currentCapture.envelope.capture.text
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !runState.isActive
      && launchPendingRunID == nil
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

  func summarize() async { await start(intent: .summarize) }
  func translate() async { await start(intent: .translate) }

  func stop() async {
    await modelRunOrchestrator?.stop()
  }

  private func start(intent: RunIntentKind) async {
    guard
      canStartRun,
      let currentCapture,
      let modelRunOrchestrator
    else {
      return
    }

    let request = PersistentRunRequest(
      runID: makeRunID(),
      taskID: currentCapture.taskID,
      snapshotID: currentCapture.snapshotID,
      intent: intent,
      targetLanguage: intent == .translate ? "简体中文" : nil
    )
    // Protect the real Task before createRun can block. This pending ownership
    // must not publish `.starting`: that state remains commit-confirmed.
    taskIDByRunID[request.runID] = request.taskID
    launchPendingRunID = request.runID
    activeRunTaskID = request.taskID
    await modelRunOrchestrator.start(
      request: request,
      capture: currentCapture.envelope
    ) { [weak self] runID, state in
      await self?.receiveRunState(runID: runID, state: state)
    }
    clearLaunchPendingIfNeeded(runID: request.runID)
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
  private let provider: OpenAICompatibleProvider
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
    let configurationService = ProviderConfigurationService(
      profileStore: UserDefaultsProviderProfileStore(),
      secretStore: KeychainSecretStore()
    )
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.urlCache = nil
    let provider = OpenAICompatibleProvider(
      session: URLSession(configuration: sessionConfiguration)
    )
    let model = AppViewModel()
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
      wrappedValue: ProviderSettingsViewModel(configurationService: configurationService)
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
