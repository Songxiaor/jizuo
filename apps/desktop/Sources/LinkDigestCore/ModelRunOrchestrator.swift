import Foundation

public enum ModelRunErrorCode: String, Codable, Sendable, Equatable {
  case modelNotConfigured = "MODEL_NOT_CONFIGURED"
  case profileStoreReadFailed = "PROFILE_STORE_READ_FAILED"
  case secretStoreReadFailed = "SECRET_STORE_READ_FAILED"
  case captureNotAvailable = "CAPTURE_NOT_AVAILABLE"
  case captureContentEmpty = "CAPTURE_CONTENT_EMPTY"
  case runFailed = "MODEL_RUN_FAILED"
}

public struct PersistentRunRequest: Sendable, Equatable {
  public let runID: RunID
  public let taskID: TaskID
  public let snapshotID: ContentSnapshotID
  public let intent: RunIntentKind
  public let targetLanguage: String?

  public init(
    runID: RunID,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    intent: RunIntentKind,
    targetLanguage: String? = nil
  ) {
    self.runID = runID
    self.taskID = taskID
    self.snapshotID = snapshotID
    self.intent = intent
    self.targetLanguage = targetLanguage
  }

  public var idempotencyKey: String { "run:v1:ui:\(runID.rawValue)" }
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
  case storageError(intent: RunIntentKind?, partialText: String, code: StorageErrorCode)

  public var isActive: Bool {
    switch self {
    case .starting, .streaming, .stopping:
      true
    case .idle, .stopped, .completed, .incomplete, .failed, .storageError:
      false
    }
  }

  public var outputText: String {
    switch self {
    case let .streaming(_, partialText),
         let .stopping(_, partialText),
         let .stopped(_, partialText),
         let .incomplete(_, partialText, _),
         let .storageError(_, partialText, _):
      partialText
    case let .completed(_, text):
      text
    case .idle, .starting, .failed:
      ""
    }
  }
}

public actor ModelRunOrchestrator {
  public typealias StateHandler = @Sendable (RunID, RunState) async -> Void

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let history: HistoryApplicationService
  private let storageWriteGate: StorageWriteGate?
  private let nowMilliseconds: @Sendable () -> Int64

  private var currentRunID: RunID?
  private var currentIntent: RunIntentKind?
  private var currentCommittedPartialText = ""
  private var currentArtifactID: ArtifactID?
  private var currentSecretRedactor: StreamingSecretRedactor?
  private var currentTask: Task<Void, Never>?
  private var currentStateHandler: StateHandler?

  public init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider,
    history: HistoryApplicationService,
    storageWriteGate: StorageWriteGate? = nil,
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.configurationService = configurationService
    self.provider = provider
    self.history = history
    self.storageWriteGate = storageWriteGate
    self.nowMilliseconds = nowMilliseconds
  }

  public func start(
    request: PersistentRunRequest,
    capture: CaptureEnvelopeV1?,
    authorization: ProviderAuthorization? = nil,
    onState: @escaping StateHandler
  ) async {
    // The UI already disables a second action, but the orchestrator is the
    // authority: an active Run keeps sole terminal ownership until stop/end.
    guard currentRunID == nil else { return }

    let kind: RunKind
    switch request.intent {
    case .summarize:
      kind = .summarize
    case .translate:
      kind = .translate
    case .connectionTest:
      await onState(
        request.runID,
        .failed(intent: request.intent, code: ModelRunErrorCode.runFailed.rawValue)
      )
      return
    }

    let created: CreateRunResult
    do {
      created = try history.createRun(.init(
        runID: request.runID,
        taskID: request.taskID,
        snapshotID: request.snapshotID,
        idempotencyKey: request.idempotencyKey,
        kind: kind,
        targetLanguage: request.targetLanguage,
        createdAtMilliseconds: nowMilliseconds()
      ))
    } catch let failure as RepositoryFailure {
      let mapped = StorageErrorMapper.map(failure, context: .write)
      let gateCode = await degradeStorage(mapped.code)
      await onState(
        request.runID,
        .storageError(intent: request.intent, partialText: "", code: gateCode)
      )
      return
    } catch {
      let gateCode = await degradeStorage(.writeFailed)
      await onState(
        request.runID,
        .storageError(intent: request.intent, partialText: "", code: gateCode)
      )
      return
    }

    guard created.runID == request.runID else {
      let gateCode = await degradeStorage(.stateConflict)
      await onState(
        request.runID,
        .storageError(intent: request.intent, partialText: "", code: gateCode)
      )
      return
    }

    let runID = request.runID
    currentRunID = runID
    currentIntent = request.intent
    currentCommittedPartialText = ""
    currentArtifactID = ArtifactID()
    currentSecretRedactor = nil
    currentStateHandler = onState

    // Install a cancellable producer before the reentrant starting callback.
    // The gate preserves queued commit → starting UI → credentials ordering.
    let (startGate, startGateContinuation) = AsyncStream<Void>.makeStream()
    currentTask = Task { [weak self] in
      for await _ in startGate {
        await self?.execute(
          runID: runID,
          intentKind: request.intent,
          targetLanguage: request.targetLanguage,
          capture: capture,
          authorization: authorization
        )
        break
      }
    }
    await onState(runID, .starting(intent: request.intent))
    guard currentRunID == runID, currentTask != nil else {
      startGateContinuation.finish()
      return
    }
    startGateContinuation.yield(())
    startGateContinuation.finish()
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

    let partialText = currentCommittedPartialText
    let artifactID = currentArtifactID

    // Losing ownership first is the stale-run gate. Any late provider or
    // persistence callback observes a different currentRunID and is ignored.
    clearCurrentRun()
    // Cancellation must not wait behind a slow MainActor/UI callback.
    provider.cancelActiveStreams()
    task.cancel()
    await onState(runID, .stopping(intent: intent, partialText: partialText))

    do {
      try history.finishRun(.init(
        runID: runID,
        status: .stopped,
        finishedAtMilliseconds: nowMilliseconds(),
        artifact: partialText.isEmpty ? nil : .init(
          id: artifactID ?? ArtifactID(),
          contentFormat: .markdown,
          completeness: .partial,
          bodyText: partialText
        ),
        usageCost: .unknown
      ))
      await onState(runID, .stopped(intent: intent, partialText: partialText))
    } catch let failure as RepositoryFailure {
      let mapped = StorageErrorMapper.map(failure, context: .write)
      let gateCode = await degradeStorage(mapped.code)
      await onState(
        runID,
        .storageError(intent: intent, partialText: partialText, code: gateCode)
      )
    } catch {
      let gateCode = await degradeStorage(.writeFailed)
      await onState(
        runID,
        .storageError(intent: intent, partialText: partialText, code: gateCode)
      )
    }
  }

  private func execute(
    runID: RunID,
    intentKind: RunIntentKind,
    targetLanguage: String?,
    capture: CaptureEnvelopeV1?,
    authorization: ProviderAuthorization?
  ) async {
    guard let capture else {
      await persistFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.captureNotAvailable.rawValue,
        retryable: false
      )
      return
    }

    let text = capture.capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      await persistFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.captureContentEmpty.rawValue,
        retryable: false
      )
      return
    }

    let credentials: (profile: ProviderProfile, apiKey: String)
    if let authorization {
      credentials = (authorization.profile, authorization.apiKey)
    } else {
      do {
        guard let loaded = try await configurationService.loadCredentials() else {
          await persistFailure(
            runID: runID,
            intent: intentKind,
            code: ModelRunErrorCode.modelNotConfigured.rawValue,
            retryable: false
          )
          return
        }
        credentials = loaded
      } catch let error as ProviderConfigurationError {
        await persistFailure(
          runID: runID,
          intent: intentKind,
          code: mapConfigurationError(error),
          retryable: false
        )
        return
      } catch {
        await persistFailure(
          runID: runID,
          intent: intentKind,
          code: ModelRunErrorCode.runFailed.rawValue,
          retryable: false
        )
        return
      }
    }

    guard currentRunID == runID, !Task.isCancelled else { return }

    do {
      try history.markRunRunning(.init(
        runID: runID,
        startedAtMilliseconds: nowMilliseconds(),
        provider: .init(
          profileID: credentials.profile.id,
          providerKind: "openai-compatible",
          baseURL: credentials.profile.baseURL.absoluteString,
          apiMode: credentials.profile.apiMode.rawValue,
          model: credentials.profile.model
        )
      ))
      guard currentRunID == runID, !Task.isCancelled else { return }
      currentSecretRedactor = StreamingSecretRedactor(secret: credentials.apiKey)
    } catch {
      await persistenceFailed(error, runID: runID, intent: intentKind)
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
        targetLanguage: targetLanguage ?? "简体中文"
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
          hadOutput: !currentCommittedPartialText.isEmpty
        ),
        runID: runID,
        intent: intentKind
      )
    } catch is CancellationError {
      // stop(), a storage failure, or a newer run already owns UI closure.
    } catch let failure as ModelProviderFailure {
      await finishProviderFailure(failure, runID: runID, intent: intentKind)
    } catch {
      await persistFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.runFailed.rawValue,
        retryable: false
      )
    }
  }

  private func receiveDelta(
    _ delta: String,
    redactingSecret secret: String,
    runID: RunID,
    intent: RunIntentKind
  ) async {
    guard
      currentRunID == runID,
      !Task.isCancelled,
      let onState = currentStateHandler,
      let artifactID = currentArtifactID
    else {
      return
    }

    if currentSecretRedactor == nil {
      currentSecretRedactor = StreamingSecretRedactor(secret: secret)
    }
    guard var redactor = currentSecretRedactor else { return }
    let candidate = redactor.append(delta)
    currentSecretRedactor = redactor
    guard !candidate.isEmpty, candidate != currentCommittedPartialText else { return }

    do {
      try history.savePartialArtifact(.init(
        runID: runID,
        artifactID: artifactID,
        contentFormat: .markdown,
        bodyText: candidate,
        updatedAtMilliseconds: nowMilliseconds()
      ))
      guard currentRunID == runID, !Task.isCancelled else { return }
      currentCommittedPartialText = candidate
      await onState(runID, .streaming(intent: intent, partialText: candidate))
    } catch {
      await persistenceFailed(error, runID: runID, intent: intent)
    }
  }

  private func flushSecretHoldback(
    runID: RunID,
    intent: RunIntentKind
  ) async -> Bool {
    guard currentRunID == runID else { return false }
    guard var redactor = currentSecretRedactor else { return true }
    let candidate = redactor.finalize()
    currentSecretRedactor = redactor
    guard candidate != currentCommittedPartialText else { return true }
    guard
      !candidate.isEmpty,
      let artifactID = currentArtifactID,
      let onState = currentStateHandler
    else {
      return true
    }

    do {
      try history.savePartialArtifact(.init(
        runID: runID,
        artifactID: artifactID,
        contentFormat: .markdown,
        bodyText: candidate,
        updatedAtMilliseconds: nowMilliseconds()
      ))
      guard currentRunID == runID, !Task.isCancelled else { return false }
      currentCommittedPartialText = candidate
      await onState(runID, .streaming(intent: intent, partialText: candidate))
      guard currentRunID == runID, !Task.isCancelled else { return false }
      return true
    } catch {
      await persistenceFailed(error, runID: runID, intent: intent)
      return false
    }
  }

  private func finishCompleted(runID: RunID, intent: RunIntentKind) async {
    guard currentRunID == runID else { return }
    guard await flushSecretHoldback(runID: runID, intent: intent) else { return }
    let text = currentCommittedPartialText
    guard !text.isEmpty else {
      await persistFailure(
        runID: runID,
        intent: intent,
        code: ModelProviderErrorCode.streamMalformed.rawValue,
        retryable: false
      )
      return
    }

    await persistTerminal(
      runID: runID,
      intent: intent,
      status: .completed,
      artifactCompleteness: .complete,
      failureCode: nil,
      failureRetryable: nil,
      successState: .completed(intent: intent, text: text)
    )
  }

  private func finishProviderFailure(
    _ failure: ModelProviderFailure,
    runID: RunID,
    intent: RunIntentKind
  ) async {
    guard currentRunID == runID else { return }
    guard await flushSecretHoldback(runID: runID, intent: intent) else { return }
    let partialText = currentCommittedPartialText
    let state: RunState = partialText.isEmpty
      ? .failed(intent: intent, code: failure.code.rawValue)
      : .incomplete(intent: intent, partialText: partialText, code: failure.code.rawValue)
    await persistTerminal(
      runID: runID,
      intent: intent,
      status: .failed,
      artifactCompleteness: partialText.isEmpty ? nil : .partial,
      failureCode: failure.code.rawValue,
      failureRetryable: failure.retryable,
      successState: state
    )
  }

  private func persistFailure(
    runID: RunID,
    intent: RunIntentKind?,
    code: String,
    retryable: Bool
  ) async {
    guard currentRunID == runID else { return }
    await persistTerminal(
      runID: runID,
      intent: intent,
      status: .failed,
      artifactCompleteness: currentCommittedPartialText.isEmpty ? nil : .partial,
      failureCode: code,
      failureRetryable: retryable,
      successState: currentCommittedPartialText.isEmpty
        ? .failed(intent: intent, code: code)
        : .incomplete(intent: intent ?? .summarize, partialText: currentCommittedPartialText, code: code)
    )
  }

  private func persistTerminal(
    runID: RunID,
    intent: RunIntentKind?,
    status: RunStatus,
    artifactCompleteness: ArtifactCompleteness?,
    failureCode: String?,
    failureRetryable: Bool?,
    successState: RunState
  ) async {
    guard
      currentRunID == runID,
      let onState = currentStateHandler
    else {
      return
    }

    let partialText = currentCommittedPartialText
    let artifact = artifactCompleteness.flatMap { completeness -> FinishRunCommand.ArtifactValue? in
      guard !partialText.isEmpty else { return nil }
      return .init(
        id: currentArtifactID ?? ArtifactID(),
        contentFormat: .markdown,
        completeness: completeness,
        bodyText: partialText
      )
    }

    do {
      try history.finishRun(.init(
        runID: runID,
        status: status,
        finishedAtMilliseconds: nowMilliseconds(),
        artifact: artifact,
        usageCost: .unknown,
        failureCode: failureCode,
        failureRetryable: failureRetryable
      ))
      guard currentRunID == runID else { return }
      clearCurrentRun()
      await onState(runID, successState)
    } catch {
      await persistenceFailed(error, runID: runID, intent: intent)
    }
  }

  private func persistenceFailed(
    _ error: Error,
    runID: RunID,
    intent: RunIntentKind?
  ) async {
    guard currentRunID == runID, let onState = currentStateHandler else { return }
    let partialText = currentCommittedPartialText
    let mapped = (error as? RepositoryFailure).map {
      StorageErrorMapper.map($0, context: .write).code
    } ?? .writeFailed
    let task = currentTask
    clearCurrentRun()
    provider.cancelActiveStreams()
    task?.cancel()
    let gateCode = await degradeStorage(mapped)
    await onState(
      runID,
      .storageError(intent: intent, partialText: partialText, code: gateCode)
    )
  }

  private func degradeStorage(_ code: StorageErrorCode) async -> StorageErrorCode {
    guard let storageWriteGate else { return code }
    return await storageWriteGate.degrade(code).code ?? code
  }

  private func clearCurrentRun() {
    currentRunID = nil
    currentIntent = nil
    currentCommittedPartialText = ""
    currentArtifactID = nil
    currentSecretRedactor = nil
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

private struct StreamingSecretRedactor: Sendable {
  private let secret: String
  private var holdback = ""
  private var emitted = ""

  init(secret: String) {
    self.secret = secret
  }

  mutating func append(_ delta: String) -> String {
    holdback += delta
    processCompleteInput()
    return emitted
  }

  mutating func finalize() -> String {
    processCompleteInput()
    if !holdback.isEmpty {
      emitted += "[已隐藏]"
      holdback = ""
    }
    return emitted
  }

  private mutating func processCompleteInput() {
    guard !secret.isEmpty else {
      emitted += holdback
      holdback = ""
      return
    }

    while let range = holdback.range(of: secret) {
      emitted += String(holdback[..<range.lowerBound])
      emitted += "[已隐藏]"
      holdback = String(holdback[range.upperBound...])
    }

    let bufferCharacters = Array(holdback)
    let secretCharacters = Array(secret)
    let upperBound = min(bufferCharacters.count, max(secretCharacters.count - 1, 0))
    var heldCount = 0
    if upperBound > 0 {
      for count in stride(from: upperBound, through: 1, by: -1) {
        if Array(bufferCharacters.suffix(count)) == Array(secretCharacters.prefix(count)) {
          heldCount = count
          break
        }
      }
    }
    let releaseCount = bufferCharacters.count - heldCount
    if releaseCount > 0 {
      emitted += String(bufferCharacters.prefix(releaseCount))
    }
    holdback = String(bufferCharacters.suffix(heldCount))
  }
}
