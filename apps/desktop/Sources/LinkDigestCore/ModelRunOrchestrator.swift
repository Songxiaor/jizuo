import Foundation

public enum ModelRunErrorCode: String, Codable, Sendable, Equatable {
  case modelNotConfigured = "MODEL_NOT_CONFIGURED"
  case profileStoreReadFailed = "PROFILE_STORE_READ_FAILED"
  case secretStoreReadFailed = "SECRET_STORE_READ_FAILED"
  case captureNotAvailable = "CAPTURE_NOT_AVAILABLE"
  case captureContentEmpty = "CAPTURE_CONTENT_EMPTY"
  case runFailed = "MODEL_RUN_FAILED"
}

public enum RunState: Sendable, Equatable {
  case idle
  case starting(intent: RunIntentKind)
  case streaming(intent: RunIntentKind, partialText: String)
  case stopping(intent: RunIntentKind, partialText: String)
  case stopped(intent: RunIntentKind, partialText: String)
  case completed(intent: RunIntentKind, text: String)
  case incomplete(intent: RunIntentKind, partialText: String, code: String)
  case failed(intent: RunIntentKind?, code: String)

  public var isActive: Bool {
    switch self {
    case .starting, .streaming, .stopping:
      true
    case .idle, .stopped, .completed, .incomplete, .failed:
      false
    }
  }

  public var outputText: String {
    switch self {
    case let .streaming(_, partialText),
         let .stopping(_, partialText),
         let .stopped(_, partialText),
         let .incomplete(_, partialText, _):
      partialText
    case let .completed(_, text):
      text
    case .idle, .starting, .failed:
      ""
    }
  }
}

public actor ModelRunOrchestrator {
  public typealias StateHandler = @Sendable (UUID, RunState) async -> Void

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let makeRunID: @Sendable () -> UUID

  private var currentRunID: UUID?
  private var currentIntent: RunIntentKind?
  private var currentPartialText = ""
  private var currentTask: Task<Void, Never>?
  private var currentStateHandler: StateHandler?

  public init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider,
    makeRunID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.configurationService = configurationService
    self.provider = provider
    self.makeRunID = makeRunID
  }

  public func start(
    intent: RunIntentKind,
    capture: CaptureEnvelopeV1?,
    onState: @escaping StateHandler
  ) async {
    currentTask?.cancel()

    let runID = makeRunID()
    currentRunID = runID
    currentIntent = intent
    currentPartialText = ""
    currentStateHandler = onState

    await onState(runID, .starting(intent: intent))
    currentTask = Task { [weak self] in
      await self?.execute(runID: runID, intentKind: intent, capture: capture)
    }
  }

  public func stop() async {
    guard
      let runID = currentRunID,
      let intent = currentIntent,
      let task = currentTask,
      let onState = currentStateHandler
    else {
      return
    }

    let partialText = currentPartialText
    currentRunID = nil
    currentIntent = nil
    currentTask = nil
    currentStateHandler = nil

    await onState(runID, .stopping(intent: intent, partialText: partialText))
    provider.cancelActiveStreams()
    task.cancel()
    await onState(runID, .stopped(intent: intent, partialText: partialText))
  }

  private func execute(
    runID: UUID,
    intentKind: RunIntentKind,
    capture: CaptureEnvelopeV1?
  ) async {
    guard intentKind == .summarize || intentKind == .translate else {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.runFailed.rawValue
      )
      return
    }

    guard let capture else {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.captureNotAvailable.rawValue
      )
      return
    }

    let text = capture.capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.captureContentEmpty.rawValue
      )
      return
    }

    let credentials: (profile: ProviderProfile, apiKey: String)
    do {
      guard let loaded = try await configurationService.loadCredentials() else {
        await finishFailure(
          runID: runID,
          intent: intentKind,
          code: ModelRunErrorCode.modelNotConfigured.rawValue
        )
        return
      }
      credentials = loaded
    } catch let error as ProviderConfigurationError {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: mapConfigurationError(error)
      )
      return
    } catch {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.runFailed.rawValue
      )
      return
    }

    let title = capture.source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let intent: RunIntent = switch intentKind {
    case .summarize:
      .summarize(title: title?.isEmpty == true ? nil : title, text: text)
    case .translate:
      .translate(
        title: title?.isEmpty == true ? nil : title,
        text: text,
        targetLanguage: "简体中文"
      )
    case .connectionTest:
      .connectionTest
    }

    do {
      for try await event in provider.stream(
        profile: credentials.profile,
        apiKey: credentials.apiKey,
        intent: intent
      ) {
        try Task.checkCancellation()
        switch event {
        case let .delta(delta):
          await receiveDelta(
            delta,
            redactingSecret: credentials.apiKey,
            runID: runID,
            intent: intentKind
          )
        case .completed:
          await finishCompleted(runID: runID, intent: intentKind)
          return
        }
      }

      await finishProviderFailure(
        ModelProviderFailure(
          code: .networkInterrupted,
          retryable: true,
          hadOutput: !currentPartialText.isEmpty
        ),
        runID: runID,
        intent: intentKind
      )
    } catch is CancellationError {
      // stop() or a newer run owns the terminal UI state.
    } catch let failure as ModelProviderFailure {
      await finishProviderFailure(failure, runID: runID, intent: intentKind)
    } catch {
      await finishFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.runFailed.rawValue
      )
    }
  }

  private func receiveDelta(
    _ delta: String,
    redactingSecret secret: String,
    runID: UUID,
    intent: RunIntentKind
  ) async {
    guard
      currentRunID == runID,
      !Task.isCancelled,
      let onState = currentStateHandler
    else {
      return
    }

    currentPartialText += delta
    if !secret.isEmpty {
      currentPartialText = currentPartialText.replacingOccurrences(
        of: secret,
        with: "[已隐藏]"
      )
    }
    await onState(
      runID,
      .streaming(intent: intent, partialText: currentPartialText)
    )
  }

  private func finishCompleted(runID: UUID, intent: RunIntentKind) async {
    guard currentRunID == runID, let onState = currentStateHandler else {
      return
    }

    let text = currentPartialText
    clearCurrentRun(runID: runID)
    await onState(runID, .completed(intent: intent, text: text))
  }

  private func finishProviderFailure(
    _ failure: ModelProviderFailure,
    runID: UUID,
    intent: RunIntentKind
  ) async {
    guard currentRunID == runID, let onState = currentStateHandler else {
      return
    }

    let partialText = currentPartialText
    clearCurrentRun(runID: runID)
    if partialText.isEmpty {
      await onState(runID, .failed(intent: intent, code: failure.code.rawValue))
    } else {
      await onState(
        runID,
        .incomplete(
          intent: intent,
          partialText: partialText,
          code: failure.code.rawValue
        )
      )
    }
  }

  private func finishFailure(
    runID: UUID,
    intent: RunIntentKind?,
    code: String
  ) async {
    guard currentRunID == runID, let onState = currentStateHandler else {
      return
    }

    clearCurrentRun(runID: runID)
    await onState(runID, .failed(intent: intent, code: code))
  }

  private func clearCurrentRun(runID: UUID) {
    guard currentRunID == runID else {
      return
    }
    currentRunID = nil
    currentIntent = nil
    currentTask = nil
    currentStateHandler = nil
  }

  private func mapConfigurationError(_ error: ProviderConfigurationError) -> String {
    switch error {
    case .profileStoreReadFailed:
      ModelRunErrorCode.profileStoreReadFailed.rawValue
    case .secretStoreReadFailed:
      ModelRunErrorCode.secretStoreReadFailed.rawValue
    default:
      error.rawValue
    }
  }
}
