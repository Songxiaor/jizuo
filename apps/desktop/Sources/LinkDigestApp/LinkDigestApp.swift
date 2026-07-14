import SwiftUI
import Foundation
import LinkDigestAdapters
import LinkDigestCore
import LinkDigestTransport

public let linkDigestSocketPath = ProcessInfo.processInfo.environment["LINKDIGEST_SOCKET_PATH"] ?? "/tmp/linkdigest-\(getuid()).sock"

@MainActor final class AppViewModel: ObservableObject {
  @Published var connection = "等待扩展连接"
  @Published var envelope: CaptureEnvelopeV1?
  @Published private(set) var runState: RunState = .idle

  private let modelRunOrchestrator: ModelRunOrchestrator
  private var visibleRunID: UUID?

  init(modelRunOrchestrator: ModelRunOrchestrator) {
    self.modelRunOrchestrator = modelRunOrchestrator
  }

  func setConnection(_ value: String) { connection = value }
  func receive(_ value: CaptureEnvelopeV1) { connection = "已连接"; envelope = value }

  var canStartRun: Bool {
    guard let envelope else { return false }
    return !envelope.capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !runState.isActive
  }

  var canStopRun: Bool {
    runState.isActive
  }

  var runResultText: String {
    runState.outputText
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
    }
  }

  var runHasFailure: Bool {
    switch runState {
    case .failed, .incomplete:
      true
    case .idle, .starting, .streaming, .stopping, .stopped, .completed:
      false
    }
  }

  func summarize() async {
    await start(intent: .summarize)
  }

  func translate() async {
    await start(intent: .translate)
  }

  func stop() async {
    await modelRunOrchestrator.stop()
  }

  private func start(intent: RunIntentKind) async {
    guard canStartRun else { return }
    let capture = envelope
    await modelRunOrchestrator.start(intent: intent, capture: capture) { [weak self] runID, state in
      await self?.receiveRunState(runID: runID, state: state)
    }
  }

  private func receiveRunState(runID: UUID, state: RunState) {
    if case .starting = state {
      visibleRunID = runID
      runState = state
      return
    }

    guard visibleRunID == runID else {
      return
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

private func handleCaptureClient(_ client: FileHandle, model: AppViewModel, inbox: CaptureInbox) async {
  defer { try? client.close() }
  do {
    let data = try ChromiumFramer.readFrame(from: client, timeout: 10)
    let value = try CaptureValidator.decode(data)
    if await inbox.accept(value) { await model.receive(value) }
    let response = NativeResponse.taskAccepted(version: 1, requestId: value.requestId, characterCount: value.capture.characterCount)
    try ChromiumFramer.writeFrame(try JSONEncoder().encode(response), to: client)
  } catch let issue as CaptureValidationError {
    let error = AppError(version: 1, requestId: "app-receiver", createdAt: ISO8601DateFormatter().string(from: Date()), category: "protocol", code: issue.rawValue, retryable: false, action: "retry", safeDetail: nil)
    try? ChromiumFramer.writeFrame(try JSONEncoder().encode(NativeResponse.error(error)), to: client)
  } catch {
    let response = AppError(version: 1, requestId: "app-receiver", createdAt: ISO8601DateFormatter().string(from: Date()), category: "protocol", code: "CAPTURE_SCHEMA_INVALID", retryable: false, action: "retry", safeDetail: nil)
    try? ChromiumFramer.writeFrame(try JSONEncoder().encode(NativeResponse.error(response)), to: client)
  }
}

@main struct LinkDigestApp: App {
  @StateObject private var model: AppViewModel
  @StateObject private var providerSettings: ProviderSettingsViewModel

  init() {
    let configurationService = ProviderConfigurationService(
      profileStore: UserDefaultsProviderProfileStore(),
      secretStore: KeychainSecretStore()
    )
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.urlCache = nil
    let modelRunOrchestrator = ModelRunOrchestrator(
      configurationService: configurationService,
      provider: OpenAICompatibleProvider(
        session: URLSession(configuration: sessionConfiguration)
      )
    )
    _model = StateObject(
      wrappedValue: AppViewModel(modelRunOrchestrator: modelRunOrchestrator)
    )
    _providerSettings = StateObject(
      wrappedValue: ProviderSettingsViewModel(configurationService: configurationService)
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model, providerSettings: providerSettings)
        .task {
          startServer()
        }
    }
  }

  @MainActor private func startServer() {
    let model = model
    Task.detached(priority: .userInitiated) {
      let server = UnixSocketServer(path: linkDigestSocketPath)
      let inbox = CaptureInbox()
      do {
        try server.start()
        await model.setConnection("本机接收服务已启动")
      } catch {
        await model.setConnection("接收服务启动失败")
        return
      }

      while !Task.isCancelled {
        let client: FileHandle
        do {
          client = try server.accept(timeout: 1, ioTimeout: 10)
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
          continue
        } catch {
          await model.setConnection("接收服务错误")
          return
        }

        Task.detached { await handleCaptureClient(client, model: model, inbox: inbox) }
      }
    }
  }
}
