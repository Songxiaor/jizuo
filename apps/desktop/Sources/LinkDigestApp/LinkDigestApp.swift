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
  @Published private(set) var storageAvailability: StorageAvailability = .bootstrapping

  private var modelRunOrchestrator: ModelRunOrchestrator?
  private let makeRunID: @Sendable () -> RunID
  private var visibleRunID: RunID?

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
  }

  var canStopRun: Bool { runState.isActive }
  var runResultText: String { runState.outputText }

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
    await modelRunOrchestrator.start(
      request: request,
      capture: currentCapture.envelope
    ) { [weak self] runID, state in
      await self?.receiveRunState(runID: runID, state: state)
    }
  }

  func receiveRunState(runID: RunID, state: RunState) {
    if case .starting = state {
      visibleRunID = runID
      runState = state
      return
    }

    if visibleRunID == nil, case .storageError = state {
      visibleRunID = runID
    }
    guard visibleRunID == runID else { return }
    if case let .storageError(_, _, code) = state {
      storageAvailability = .unavailable(code)
    }
    runState = state
  }
}

struct ContentView: View {
  @ObservedObject var model: AppViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("LinkDigest")
        .font(.title)
      Text(model.connection)
        .foregroundStyle(.secondary)
      Text(model.storageStatusText)
        .font(.caption)
        .foregroundStyle(model.storageAvailability.isWriteReady ? Color.secondary : Color.orange)
        .accessibilityIdentifier("storage-availability")

      if let value = model.envelope {
        Text(value.source.title ?? "无标题")
          .font(.headline)
        Text(value.source.url)
          .font(.caption)
        Text(
          "捕获方式：\(value.capture.method) · \(value.capture.completeness) · \(value.capture.characterCount) 字符"
        )
        ScrollView {
          Text(value.capture.text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140, maxHeight: 260)

        HStack(spacing: 12) {
          Button("总结") {
            Task { await model.summarize() }
          }
          .disabled(!model.canStartRun)
          .accessibilityIdentifier("summarize-current-capture")

          Button("翻译") {
            Task { await model.translate() }
          }
          .disabled(!model.canStartRun)
          .accessibilityIdentifier("translate-current-capture")

          if model.canStopRun {
            Button("停止", role: .cancel) {
              Task { await model.stop() }
            }
            .disabled(!model.canStopRun)
            .accessibilityIdentifier("stop-model-run")
          }
        }

        GroupBox("生成结果") {
          VStack(alignment: .leading, spacing: 8) {
            Text(model.runStatusText)
              .foregroundStyle(model.runHasFailure ? .red : .secondary)
              .accessibilityIdentifier("model-run-status")

            if !model.runResultText.isEmpty {
              ScrollView {
                Text(model.runResultText)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(minHeight: 120, maxHeight: 260)
              .accessibilityIdentifier("model-run-output")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
      } else {
        Text("先从 Chrome、Brave 或 Edge 的当前页面发送内容")
      }

      Divider()
      ProviderSettingsView(model: providerSettings)
    }
    .padding(24)
    .frame(minWidth: 620, minHeight: 620)
  }
}

@main struct LinkDigestApp: App {
  @StateObject private var model: AppViewModel
  @StateObject private var providerSettings: ProviderSettingsViewModel

  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider
  private let composition: AppComposition

  init() {
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
    let nowMilliseconds: @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
    let serverStarter = makeUnixSocketServerStarter(
      path: linkDigestSocketPath,
      statusSink: { value in await model.setConnection(value) }
    )
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: liveApplicationSupportRoot,
      repositoryFactory: { location in
        try GRDBHistoryRepository.open(at: location)
      },
      nowMilliseconds: nowMilliseconds,
      serverStarter: serverStarter,
      availabilitySink: { value in
        await model.setStorageAvailability(value)
      },
      captureSink: { value in
        await model.receive(value)
      }
    ))

    self.configurationService = configurationService
    self.provider = provider
    self.composition = composition
    _model = StateObject(wrappedValue: model)
    _providerSettings = StateObject(
      wrappedValue: ProviderSettingsViewModel(configurationService: configurationService)
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model, providerSettings: providerSettings)
        .task {
          let result = await composition.bootstrap()
          if let history = result.history {
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
  }
}
