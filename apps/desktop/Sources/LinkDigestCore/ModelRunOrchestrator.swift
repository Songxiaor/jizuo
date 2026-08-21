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
  public let summaryPrompt: String?
  public let translationModel: String?
  public let modelOverride: String?
  /// 长正文翻译的分片并发度。nil 用 `ModelPreferences` 的默认值。
  public let translationConcurrency: Int?

  public init(
    runID: RunID,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    intent: RunIntentKind,
    targetLanguage: String? = nil,
    summaryPrompt: String? = nil,
    translationModel: String? = nil,
    modelOverride: String? = nil,
    translationConcurrency: Int? = nil
  ) {
    self.runID = runID
    self.taskID = taskID
    self.snapshotID = snapshotID
    self.intent = intent
    self.targetLanguage = targetLanguage
    self.summaryPrompt = summaryPrompt
    self.translationModel = translationModel
    self.modelOverride = modelOverride
    self.translationConcurrency = translationConcurrency
  }

  public var idempotencyKey: String { "run:v1:ui:\(runID.rawValue)" }
}

public enum RunState: Sendable, Equatable {
  case idle
  case starting(intent: RunIntentKind)
  /// 推理模型已经开始吐思考过程，但正文还没开始。
  ///
  /// 单独立一个状态是因为它在界面上的含义完全不同：`.starting` 是「还没连上」，
  /// 而这个是「连上了、正在想」。推理模型这一段能持续几十秒，没有区分的话，
  /// 用户看到的是一个和卡死无法分辨的静止界面。
  case thinking(intent: RunIntentKind)
  case streaming(intent: RunIntentKind, partialText: String)
  case stopping(intent: RunIntentKind, partialText: String)
  case stopped(intent: RunIntentKind, partialText: String)
  case completed(intent: RunIntentKind, text: String)
  case incomplete(intent: RunIntentKind, partialText: String, code: String)
  case failed(intent: RunIntentKind?, code: String)
  case storageError(intent: RunIntentKind?, partialText: String, code: StorageErrorCode)

  public var isActive: Bool {
    switch self {
    case .starting, .thinking, .streaming, .stopping:
      true
    case .idle, .stopped, .completed, .incomplete, .failed, .storageError:
      false
    }
  }

  public var intent: RunIntentKind? {
    switch self {
    case let .starting(intent),
         let .thinking(intent),
         let .streaming(intent, _),
         let .stopping(intent, _),
         let .stopped(intent, _),
         let .completed(intent, _),
         let .incomplete(intent, _, _):
      intent
    case let .failed(intent, _), let .storageError(intent, _, _):
      intent
    case .idle:
      nil
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
    // 思考过程绝不算输出：它一个字都不该出现在产物里。
    case .idle, .starting, .thinking, .failed:
      ""
    }
  }
}

public actor ModelRunOrchestrator {
  public typealias StateHandler = @Sendable (RunID, RunState) async -> Void
  /// Non-RunState notification for local History metadata that is committed
  /// after a completed run (currently automatic tags). It deliberately has no
  /// failure payload: metadata remains a fail-open side path.
  public typealias HistoryMetadataChangedHandler = @Sendable (TaskID) async -> Void

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let summaryTagGenerator: (any SummaryTagGenerating)?
  private let history: HistoryApplicationService
  private let onHistoryMetadataChanged: HistoryMetadataChangedHandler?
  private let onRunMetadataChanged: HistoryMetadataChangedHandler?
  private let storageWriteGate: StorageWriteGate?
  private let nowMilliseconds: @Sendable () -> Int64
  /// 模型可能每秒吐几十个 token。界面只需要保持“正在增长”的感觉，不应让
  /// 每个 token 都触发一次整窗 SwiftUI 求值。
  private let streamingUIPublishInterval: Duration
  /// 草稿用于崩溃恢复，不需要跟 token 同频写 SQLite。终态仍会强制写入全文。
  private let partialArtifactSaveInterval: Duration

  private var currentRunID: RunID?
  private var currentIntent: RunIntentKind?
  private var currentCommittedPartialText = ""
  private var currentPersistedPartialText = ""
  private var currentPublishedPartialText = ""
  /// 本次运行是否已经报过「正在思考」。见 `publishThinking`。
  private var currentPublishedThinking = false
  private var currentArtifactID: ArtifactID?
  private var currentSecretRedactor: StreamingSecretRedactor?
  private var currentTask: Task<Void, Never>?
  private var currentUIPublishTask: Task<Void, Never>?
  private var currentPartialSaveTask: Task<Void, Never>?
  private var currentTaskID: TaskID?
  private var currentStateHandler: StateHandler?

  public init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider,
    summaryTagGenerator: (any SummaryTagGenerating)? = nil,
    history: HistoryApplicationService,
    onHistoryMetadataChanged: HistoryMetadataChangedHandler? = nil,
    onRunMetadataChanged: HistoryMetadataChangedHandler? = nil,
    storageWriteGate: StorageWriteGate? = nil,
    streamingUIPublishInterval: Duration = .milliseconds(250),
    partialArtifactSaveInterval: Duration = .seconds(1),
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.configurationService = configurationService
    self.provider = provider
    self.summaryTagGenerator = summaryTagGenerator ?? (provider as? any SummaryTagGenerating)
    self.history = history
    self.onHistoryMetadataChanged = onHistoryMetadataChanged
    self.onRunMetadataChanged = onRunMetadataChanged
    self.storageWriteGate = storageWriteGate
    self.streamingUIPublishInterval = streamingUIPublishInterval
    self.partialArtifactSaveInterval = partialArtifactSaveInterval
    self.nowMilliseconds = nowMilliseconds
  }

  public func start(
    request: PersistentRunRequest,
    capture: CaptureEnvelopeV1?,
    authorization: ProviderAuthorization? = nil,
    onState: @escaping StateHandler
  ) async {
    await start(request: request, capture: capture.map(CapturedDocument.init(wire:)), authorization: authorization, onState: onState)
  }

  public func start(
    request: PersistentRunRequest,
    capture: CapturedDocument?,
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
    currentPersistedPartialText = ""
    currentPublishedPartialText = ""
    currentPublishedThinking = false
    currentArtifactID = ArtifactID()
    currentSecretRedactor = nil
    currentUIPublishTask = nil
    currentPartialSaveTask = nil
    currentStateHandler = onState
    currentTaskID = request.taskID

    // Install a cancellable producer before the reentrant starting callback.
    // The gate preserves queued commit → starting UI → credentials ordering.
    let (startGate, startGateContinuation) = AsyncStream<Void>.makeStream()
    currentTask = Task { [weak self] in
      for await _ in startGate {
        await self?.execute(
          runID: runID,
          intentKind: request.intent,
          targetLanguage: request.targetLanguage,
          summaryPrompt: request.summaryPrompt,
          translationModel: request.translationModel,
          modelOverride: request.modelOverride,
          translationConcurrency: request.translationConcurrency,
          taskID: request.taskID,
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
      let taskID = currentTaskID,
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
      await onRunMetadataChanged?(taskID)
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
    summaryPrompt: String?,
    translationModel: String?,
    modelOverride: String?,
    translationConcurrency: Int?,
    taskID: TaskID,
    capture: CapturedDocument?,
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

    let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    let effectiveProfile: ProviderProfile
    do {
      if let alternateModel = (modelOverride ?? (intentKind == .translate ? translationModel : nil))?.trimmingCharacters(in: .whitespacesAndNewlines),
         !alternateModel.isEmpty {
        effectiveProfile = try credentials.profile.replacing(model: alternateModel)
      } else {
        effectiveProfile = credentials.profile
      }
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

    do {
      try history.markRunRunning(.init(
        runID: runID,
        startedAtMilliseconds: nowMilliseconds(),
        provider: .init(
          profileID: effectiveProfile.id,
          providerKind: "openai-compatible",
          baseURL: effectiveProfile.baseURL.absoluteString,
          apiMode: effectiveProfile.apiMode.rawValue,
          model: effectiveProfile.model
        )
      ))
      guard currentRunID == runID, !Task.isCancelled else { return }
      currentSecretRedactor = StreamingSecretRedactor(secret: credentials.apiKey)
    } catch {
      await persistenceFailed(error, runID: runID, intent: intentKind)
      return
    }

    let title = capture.title?.trimmingCharacters(in: .whitespacesAndNewlines)

    // 翻译只发正文。正文开头的 `---` 元数据块（作者/发布/点赞，阅读页顶部
    // 属性栏的数据源）是结构化字段，不是待译内容：带上它，模型会把整块
    // 原样翻一遍再吐回来——短帖里这能占掉近半的输出 token，翻译因此明显
    // 变慢，流式预览里还会滚出一段 YAML。总结保留元数据，作者和日期对
    // 摘要是有效上下文，且总结输出远短于输入，几十个 token 无关痛痒。
    let strippedBody = MarkdownNoteFrontmatter.parse(text).body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let translationText = strippedBody.isEmpty ? text : strippedBody

    let intent: RunIntent = switch intentKind {
    case .summarize:
      .summarize(
        title: title?.isEmpty == true ? nil : title,
        text: text,
        prompt: ModelPreferences.summaryPrompt(
          configuredPrompt: summaryPrompt ?? ModelPreferences.defaultSummaryPrompt,
          outputLanguage: targetLanguage ?? ModelPreferences.defaultTargetLanguage
        )
      )
    case .translate:
      .translate(
        title: title?.isEmpty == true ? nil : title,
        text: translationText,
        targetLanguage: targetLanguage ?? "简体中文"
      )
    case .connectionTest:
      .connectionTest
    }

    // 长正文翻译改走分片并发：译文长度和原文同量级，单条请求里模型只能串行吐
    // token，所以整篇一次发时耗时随长度线性增长（实测 3.8 万字 6.5 分钟未完）。
    // 只有翻译走这条路——总结的输出远短于输入，瓶颈不在这里，拆开反而丢上下文。
    let events: AsyncThrowingStream<ModelStreamEvent, Error>
    if intentKind == .translate, ChunkedTranslationStreamer.shouldChunk(translationText) {
      events = ChunkedTranslationStreamer(
        provider: provider,
        concurrency: translationConcurrency ?? ModelPreferences.defaultTranslationConcurrency
      ).stream(
        profile: effectiveProfile,
        apiKey: credentials.apiKey,
        title: title?.isEmpty == true ? nil : title,
        text: translationText,
        targetLanguage: targetLanguage ?? "简体中文"
      )
    } else {
      events = provider.stream(
        profile: effectiveProfile,
        apiKey: credentials.apiKey,
        intent: intent
      )
    }

    var reportedUsage = RunUsageCost.unknown
    do {
      for try await event in events {
        try Task.checkCancellation()
        switch event {
        case let .delta(delta):
          await receiveDelta(
            delta,
            redactingSecret: credentials.apiKey,
            runID: runID,
            intent: intentKind
          )
        case .reasoning:
          // 内容本身丢弃——它不是生成结果。只把「正在想」这件事报给界面，
          // 而且仅在正文还没开始时报，免得中途的思考把已有译文顶掉。
          if currentCommittedPartialText.isEmpty {
            await publishThinking(intent: intentKind)
          }
        case let .usage(usage):
          reportedUsage = usage
        case .completed:
          await finishCompleted(
            runID: runID,
            intent: intentKind,
            usageCost: reportedUsage,
            taskID: taskID,
            profile: effectiveProfile,
            apiKey: credentials.apiKey
          )
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
        intent: intentKind,
        usageCost: reportedUsage
      )
    } catch is CancellationError {
      // stop(), a storage failure, or a newer run already owns UI closure.
    } catch let failure as ModelProviderFailure {
      await finishProviderFailure(failure, runID: runID, intent: intentKind, usageCost: reportedUsage)
    } catch {
      await persistFailure(
        runID: runID,
        intent: intentKind,
        code: ModelRunErrorCode.runFailed.rawValue,
        retryable: false
      )
    }
  }

  /// 报告「模型正在思考」。
  ///
  /// 刻意不落盘、不动 `currentCommittedPartialText`：思考过程不是产物，这里改变的
  /// 只有界面上那行字。
  private func publishThinking(intent: RunIntentKind) async {
    guard let runID = currentRunID, !Task.isCancelled,
          let onState = currentStateHandler
    else { return }
    // 一次运行只报一次：`.thinking(intent:)` 不带随 delta 变化的负载，而调用点
    // 对每个 reasoning delta 都会走到这里。不去重就是按 delta 速率做无谓的
    // 跨 actor 跳转；正文一开始就不再进入这条路径（见调用点的 isEmpty 判断）。
    guard !currentPublishedThinking else { return }
    currentPublishedThinking = true
    await onState(runID, .thinking(intent: intent))
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
      currentStateHandler != nil,
      currentArtifactID != nil
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
    currentCommittedPartialText = candidate

    // 第一段立即落盘并显示，用户不用盯着空白页等一个节流周期。后续增量分成
    // 两个时钟：UI 约 4Hz，SQLite 约 1Hz；终态再强制冲刷最后全文。
    if currentPublishedPartialText.isEmpty {
      guard await persistBufferedPartial(runID: runID, intent: intent) else { return }
      await publishBufferedPartial(runID: runID, intent: intent)
      return
    }
    scheduleUIPublish(runID: runID, intent: intent)
    schedulePartialSave(runID: runID, intent: intent)
  }

  private func scheduleUIPublish(runID: RunID, intent: RunIntentKind) {
    guard currentUIPublishTask == nil else { return }
    let delay = streamingUIPublishInterval
    currentUIPublishTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.runScheduledUIPublish(runID: runID, intent: intent)
    }
  }

  private func runScheduledUIPublish(runID: RunID, intent: RunIntentKind) async {
    currentUIPublishTask = nil
    await publishBufferedPartial(runID: runID, intent: intent)
  }

  private func schedulePartialSave(runID: RunID, intent: RunIntentKind) {
    guard currentPartialSaveTask == nil else { return }
    let delay = partialArtifactSaveInterval
    currentPartialSaveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.runScheduledPartialSave(runID: runID, intent: intent)
    }
  }

  private func runScheduledPartialSave(runID: RunID, intent: RunIntentKind) async {
    currentPartialSaveTask = nil
    _ = await persistBufferedPartial(runID: runID, intent: intent)
  }

  private func publishBufferedPartial(runID: RunID, intent: RunIntentKind) async {
    guard currentRunID == runID,
          !Task.isCancelled,
          let onState = currentStateHandler
    else { return }
    let candidate = visibleOutput(intent: intent, text: currentCommittedPartialText)
    guard !candidate.isEmpty, candidate != currentPublishedPartialText else { return }
    currentPublishedPartialText = candidate
    await onState(runID, .streaming(intent: intent, partialText: candidate))
  }

  @discardableResult
  private func persistBufferedPartial(runID: RunID, intent: RunIntentKind) async -> Bool {
    guard currentRunID == runID,
          !Task.isCancelled,
          let artifactID = currentArtifactID
    else { return false }
    let candidate = visibleOutput(intent: intent, text: currentCommittedPartialText)
    guard !candidate.isEmpty else { return true }
    guard candidate != currentPersistedPartialText else { return true }
    do {
      try history.savePartialArtifact(.init(
        runID: runID,
        artifactID: artifactID,
        contentFormat: .markdown,
        bodyText: candidate,
        updatedAtMilliseconds: nowMilliseconds()
      ))
      guard currentRunID == runID, !Task.isCancelled else { return false }
      currentPersistedPartialText = candidate
      return true
    } catch {
      await persistenceFailed(error, runID: runID, intent: intent)
      return false
    }
  }

  private func flushSecretHoldback(
    runID: RunID,
    intent: RunIntentKind
  ) async -> Bool {
    guard currentRunID == runID else { return false }
    if var redactor = currentSecretRedactor {
      let candidate = redactor.finalize()
      currentSecretRedactor = redactor
      if !candidate.isEmpty, candidate != currentCommittedPartialText {
        currentCommittedPartialText = candidate
      }
    }
    currentUIPublishTask?.cancel()
    currentUIPublishTask = nil
    currentPartialSaveTask?.cancel()
    currentPartialSaveTask = nil
    guard await persistBufferedPartial(runID: runID, intent: intent) else { return false }
    await publishBufferedPartial(runID: runID, intent: intent)
    return currentRunID == runID && !Task.isCancelled
  }

  private func finishCompleted(
    runID: RunID,
    intent: RunIntentKind,
    usageCost: RunUsageCost,
    taskID: TaskID,
    profile: ProviderProfile,
    apiKey: String
  ) async {
    guard currentRunID == runID else { return }
    guard await flushSecretHoldback(runID: runID, intent: intent) else { return }
    let rawText = currentCommittedPartialText
    let split = intent == .summarize ? SummaryTagTrailer.split(rawText) : (body: rawText, tags: [])
    let text = split.body
    currentCommittedPartialText = text
    guard !text.isEmpty else {
      await persistFailure(
        runID: runID,
        intent: intent,
        code: ModelProviderErrorCode.streamMalformed.rawValue,
        retryable: false
      )
      return
    }

    let persisted = await persistTerminal(
      runID: runID,
      intent: intent,
      status: .completed,
      artifactCompleteness: .complete,
      failureCode: nil,
      failureRetryable: nil,
      usageCost: usageCost,
      successState: .completed(intent: intent, text: text)
    )
    guard persisted else { return }
    await applyAutomaticTags(
      to: taskID,
      generatedText: text,
      embeddedTags: split.tags,
      profile: profile,
      apiKey: apiKey
    )
  }

  private func visibleOutput(intent: RunIntentKind, text: String) -> String {
    intent == .summarize ? SummaryTagTrailer.visibleBody(text) : text
  }

  private func finishProviderFailure(
    _ failure: ModelProviderFailure,
    runID: RunID,
    intent: RunIntentKind,
    usageCost: RunUsageCost = .unknown
  ) async {
    guard currentRunID == runID else { return }
    guard await flushSecretHoldback(runID: runID, intent: intent) else { return }
    let partialText = currentCommittedPartialText
    let state: RunState = partialText.isEmpty
      ? .failed(intent: intent, code: failure.code.rawValue)
      : .incomplete(
        intent: intent,
        partialText: partialText,
        code: failure.code.rawValue
      )
    await persistTerminal(
      runID: runID,
      intent: intent,
      status: .failed,
      artifactCompleteness: partialText.isEmpty ? nil : .partial,
      failureCode: failure.code.rawValue,
      failureRetryable: failure.retryable,
      usageCost: usageCost,
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

  @discardableResult
  private func persistTerminal(
    runID: RunID,
    intent: RunIntentKind?,
    status: RunStatus,
    artifactCompleteness: ArtifactCompleteness?,
    failureCode: String?,
    failureRetryable: Bool?,
    usageCost: RunUsageCost = .unknown,
    successState: RunState
  ) async -> Bool {
    guard
      currentRunID == runID,
      let onState = currentStateHandler
    else {
      return false
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
        usageCost: usageCost,
        failureCode: failureCode,
        failureRetryable: failureRetryable
      ))
      guard currentRunID == runID else { return false }
      let taskID = currentTaskID
      clearCurrentRun()
      await onState(runID, successState)
      if let taskID { await onRunMetadataChanged?(taskID) }
      return true
    } catch {
      await persistenceFailed(error, runID: runID, intent: intent)
      return false
    }
  }

  /// Automatic labels are best-effort local metadata. They deliberately run
  /// after the completed result has been persisted and presented, use the same
  /// already-authorized profile/model, and never surface a provider failure.
  /// When the model call fails or returns nothing parseable, a small local
  /// heuristic may still attach platform / gate chips so the tag row is not
  /// left empty after a successful summary.
  private func applyAutomaticTags(
    to taskID: TaskID,
    generatedText: String,
    embeddedTags: [HistoryTag] = [],
    profile: ProviderProfile,
    apiKey: String
  ) async {
    var tags = embeddedTags
    if tags.isEmpty, let summaryTagGenerator {
      do {
        let response = try await summaryTagGenerator.generateSummaryTags(
          profile: profile,
          apiKey: apiKey,
          summary: generatedText
        )
        tags = HistoryTagNormalizer.automaticTags(from: response)
      } catch {
        // Fail-open by design: tagging must not change a completed run, its
        // visible state, or the data-destination confirmation contract.
      }
    }
    if tags.isEmpty {
      tags = HistoryTagNormalizer.fallbackTags(from: generatedText)
    }
    guard !tags.isEmpty else { return }
    do {
      _ = try history.addTags(tags.map(\.name), to: taskID)
      await onHistoryMetadataChanged?(taskID)
    } catch {
      // Still fail-open: completed Run remains the source of truth.
    }
  }

  private func persistenceFailed(
    _ error: Error,
    runID: RunID,
    intent: RunIntentKind?
  ) async {
    guard currentRunID == runID, let onState = currentStateHandler else { return }
    // UI 可能领先最近一次 1Hz 草稿检查点；存储已经失效时只展示真正写成功的
    // 部分，避免把尚未持久化的文本冒充为可恢复内容。
    let partialText = currentPersistedPartialText
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
    currentUIPublishTask?.cancel()
    currentPartialSaveTask?.cancel()
    currentRunID = nil
    currentIntent = nil
    currentCommittedPartialText = ""
    currentPersistedPartialText = ""
    currentPublishedPartialText = ""
    currentPublishedThinking = false
    currentArtifactID = nil
    currentSecretRedactor = nil
    currentTask = nil
    currentUIPublishTask = nil
    currentPartialSaveTask = nil
    currentTaskID = nil
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
