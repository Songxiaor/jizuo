import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

private actor AppProfileStore: ProviderProfileStore {
  private let profile: ProviderProfile?

  init(profile: ProviderProfile?) {
    self.profile = profile
  }

  func load() async throws -> ProviderProfile? { profile }
  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor AppSecretStore: SecretStore {
  private let secret: String?

  init(secret: String?) {
    self.secret = secret
  }

  func save(_: String, for _: SecretReference) async throws {}
  func read(_: SecretReference) async throws -> String? { secret }
  func contains(_: SecretReference) async throws -> Bool { secret != nil }
  func delete(_: SecretReference) async throws {}
}

private final class AppHistoryRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let failPartial: Bool
  private let failTerminal: Bool
  private let lock = NSLock()
  private var captureCalls = 0
  init(failPartial: Bool = false, failTerminal: Bool = false) {
    self.failPartial = failPartial
    self.failTerminal = failTerminal
  }
  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    lock.withLock { captureCalls += 1 }
    return .init(
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      taskWasCreated: true,
      snapshotWasCreated: true,
      deliveryWasReplayed: false
    )
  }
  var acceptCaptureCallCount: Int { lock.withLock { captureCalls } }
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { .init(runID: command.runID, wasCreated: true) }
  func markRunRunning(_: MarkRunRunningCommand) throws {}
  func savePartialArtifact(_: SavePartialArtifactCommand) throws {
    if failPartial { throw RepositoryFailure.injectedFailure }
  }
  func finishRun(_: FinishRunCommand) throws {
    if failTerminal { throw RepositoryFailure.injectedFailure }
  }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
}

private final class AppTestModelProvider: ModelProvider, @unchecked Sendable {
  enum Result: Sendable {
    case success([ModelStreamEvent])
    case failure(prefix: String?, ModelProviderFailure)
    case pending
  }

  private let lock = NSLock()
  private var results: [Result]
  private var recordedIntents: [RunIntent] = []
  private var recordedKeyPresence: [Bool] = []

  init(results: [Result]) {
    self.results = results
  }

  func stream(
    profile _: ProviderProfile,
    apiKey: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let result = lock.withLock { () -> Result in
      recordedIntents.append(intent)
      recordedKeyPresence.append(!apiKey.isEmpty)
      return results.removeFirst()
    }

    return AsyncThrowingStream { continuation in
      switch result {
      case let .success(events):
        events.forEach { continuation.yield($0) }
        continuation.finish()
      case let .failure(prefix, failure):
        if let prefix {
          continuation.yield(.delta(prefix))
        }
        continuation.finish(throwing: failure)
      case .pending:
        let producer = Task {
          do {
            try await Task.sleep(for: .seconds(30))
            continuation.finish()
          } catch {
            continuation.finish(throwing: CancellationError())
          }
        }
        continuation.onTermination = { @Sendable _ in
          producer.cancel()
        }
      }
    }
  }

  func cancelActiveStreams() {
    // The pending test stream is cancelled by continuation termination below.
  }

  var callCount: Int {
    lock.withLock { recordedIntents.count }
  }

  var intents: [RunIntent] {
    lock.withLock { recordedIntents }
  }

  var keyPresence: [Bool] {
    lock.withLock { recordedKeyPresence }
  }
}

@MainActor
final class AppViewModelTests: XCTestCase {
  func testNoCaptureKeepsActionsDisabledAndDoesNotStartProvider() async throws {
    let provider = AppTestModelProvider(results: [])
    let model = try makeModel(provider: provider)

    XCTAssertFalse(model.canStartRun)
    await model.summarize()

    XCTAssertEqual(model.runState, .idle)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testConfiguredCaptureCanSummarizeAndTranslateWithoutExposingKey() async throws {
    let submittedSecret = "sentinel-\(UUID().uuidString)"
    let provider = AppTestModelProvider(results: [
      .success([.delta("摘要"), .completed]),
      .success([.delta("翻译"), .completed])
    ])
    let model = try makeModel(provider: provider, secret: submittedSecret)
    model.receive(currentCapture())

    XCTAssertTrue(model.canStartRun)
    await model.summarize()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "摘要") }
    await model.translate()
    await waitUntil { model.runState == .completed(intent: .translate, text: "翻译") }

    XCTAssertEqual(provider.callCount, 2)
    XCTAssertEqual(provider.keyPresence, [true, true])
    XCTAssertFalse(String(describing: model.runState).contains(submittedSecret))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))
    XCTAssertFalse(model.runResultText.contains(submittedSecret))
    XCTAssertEqual(provider.intents.last, .translate(
      title: "Fixture title",
      text: "Fixture body",
      targetLanguage: "简体中文"
    ))
  }

  func testFailedAndIncompleteMessagesUseRecoveryCopyWithoutExposingSecret() async throws {
    let submittedSecret = "sentinel-\(UUID().uuidString)"
    let failure = ModelProviderFailure(
      code: .protocolIncompatible,
      retryable: false,
      hadOutput: false
    )
    let provider = AppTestModelProvider(results: [
      .failure(prefix: nil, failure),
      .failure(prefix: "部分结果", failure)
    ])
    let model = try makeModel(provider: provider, secret: submittedSecret)
    model.receive(currentCapture())

    await model.summarize()
    await waitUntil {
      model.runState == .failed(
        intent: .summarize,
        code: ModelProviderErrorCode.protocolIncompatible.rawValue
      )
    }
    XCTAssertEqual(
      model.runStatusText,
      V02ErrorCatalog.presentation(
        for: ModelProviderErrorCode.protocolIncompatible.rawValue
      ).visibleText
    )
    XCTAssertFalse(model.runStatusText.contains(ModelProviderErrorCode.protocolIncompatible.rawValue))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))

    await model.translate()
    await waitUntil {
      model.runState == .incomplete(
        intent: .translate,
        partialText: "部分结果",
        code: ModelProviderErrorCode.protocolIncompatible.rawValue
      )
    }
    XCTAssertEqual(model.runResultText, "部分结果")
    XCTAssertTrue(model.runStatusText.hasPrefix("结果不完整。"))
    XCTAssertTrue(model.runStatusText.contains("检查 Base URL"))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))
    XCTAssertFalse(model.runResultText.contains(submittedSecret))
  }

  func testProviderEchoedSecretIsRedactedFromVisibleRunState() async throws {
    let submittedSecret = "sentinel-\(UUID().uuidString)"
    let failure = ModelProviderFailure(
      code: .networkInterrupted,
      retryable: true,
      hadOutput: true
    )
    let provider = AppTestModelProvider(results: [
      .success([.delta(submittedSecret), .completed]),
      .failure(prefix: submittedSecret, failure)
    ])
    let model = try makeModel(provider: provider, secret: submittedSecret)
    model.receive(currentCapture())

    await model.summarize()
    await waitUntil {
      model.runState == .completed(intent: .summarize, text: "[已隐藏]")
    }
    XCTAssertFalse(String(describing: model.runState).contains(submittedSecret))
    XCTAssertFalse(model.runResultText.contains(submittedSecret))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))

    await model.translate()
    await waitUntil {
      model.runState == .incomplete(
        intent: .translate,
        partialText: "[已隐藏]",
        code: ModelProviderErrorCode.networkInterrupted.rawValue
      )
    }
    XCTAssertFalse(String(describing: model.runState).contains(submittedSecret))
    XCTAssertFalse(model.runResultText.contains(submittedSecret))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))
  }

  func testColdStartAndReadOnlyKeepRunActionsExplicitlyDisabled() async throws {
    let provider = AppTestModelProvider(results: [])
    let cold = AppViewModel()
    XCTAssertEqual(cold.storageAvailability, .bootstrapping)
    XCTAssertFalse(cold.canStartRun)

    let readOnly = try makeModel(provider: provider)
    readOnly.receive(currentCapture())
    readOnly.setStorageAvailability(.unavailable(.futureSchema))
    XCTAssertNotNil(readOnly.currentCapture)
    XCTAssertFalse(readOnly.canStartRun)
    XCTAssertTrue(readOnly.storageStatusText.contains("本地历史"))
  }

  func testProviderFailureDoesNotPolluteGlobalStorageState() async throws {
    let provider = AppTestModelProvider(results: [.failure(
      prefix: nil,
      ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    )])
    let model = try makeModel(provider: provider)
    model.receive(currentCapture())
    await model.summarize()
    await waitUntil { if case .failed = model.runState { true } else { false } }
    XCTAssertEqual(model.storageAvailability, .writable)
    XCTAssertEqual(model.storageStatusText, "本地历史可用")
    XCTAssertTrue(model.runStatusText.contains("身份验证"))
  }

  func testPartialAndTerminalStorageFailuresNeverShowUncommittedOrFakeTerminal() async throws {
    let partialProvider = AppTestModelProvider(results: [.success([.delta("candidate"), .completed])])
    let partialModel = try makeModel(
      provider: partialProvider,
      repository: AppHistoryRepository(failPartial: true)
    )
    partialModel.receive(currentCapture())
    await partialModel.summarize()
    await waitUntil { if case .storageError = partialModel.runState { true } else { false } }
    XCTAssertEqual(partialModel.runResultText, "")
    XCTAssertEqual(partialModel.storageAvailability, .unavailable(.writeFailed))
    XCTAssertFalse(partialModel.canStartRun)

    let terminalProvider = AppTestModelProvider(results: [.success([.delta("committed"), .completed])])
    let terminalModel = try makeModel(
      provider: terminalProvider,
      repository: AppHistoryRepository(failTerminal: true)
    )
    terminalModel.receive(currentCapture())
    await terminalModel.summarize()
    await waitUntil { if case .storageError = terminalModel.runState { true } else { false } }
    XCTAssertEqual(terminalModel.runResultText, "committed")
    XCTAssertNotEqual(terminalModel.runStatusText, "已完成")
    XCTAssertEqual(terminalModel.storageAvailability, .unavailable(.writeFailed))
  }

  func testRunPersistenceFailureClosesSharedGateBeforeLaterCapture() async throws {
    for mode in ["partial", "terminal"] {
      let repository = AppHistoryRepository(
        failPartial: mode == "partial",
        failTerminal: mode == "terminal"
      )
      let provider = AppTestModelProvider(results: [
        .success([.delta(mode == "partial" ? "candidate" : "committed"), .completed])
      ])
      let profile = try ProviderProfile(
        baseURL: "https://example.test/v1",
        model: "fixture-model",
        secretReference: SecretReference(rawValue: "fixture-reference")
      )
      let configuration = ProviderConfigurationService(
        profileStore: AppProfileStore(profile: profile),
        secretStore: AppSecretStore(secret: "fixture-secret")
      )
      let model = AppViewModel()
      let gate = StorageWriteGate(
        initialAvailability: .writable,
        availabilitySink: { await model.setStorageAvailability($0) }
      )
      let history = HistoryApplicationService(repository: repository)
      let orchestrator = ModelRunOrchestrator(
        configurationService: configuration,
        provider: provider,
        history: history,
        storageWriteGate: gate
      )
      model.setStorageAvailability(.writable)
      let existing = currentCapture()
      model.receive(existing)
      let receiver = CaptureReceiver(
        history: history,
        storageWriteGate: gate,
        nowMilliseconds: { 1 },
        captureSink: { await model.receive($0) }
      )

      let (storageErrors, storageErrorContinuation) = AsyncStream<RunState>.makeStream()
      var storageErrorIterator = storageErrors.makeAsyncIterator()
      let request = PersistentRunRequest(
        runID: RunID(),
        taskID: existing.taskID,
        snapshotID: existing.snapshotID,
        intent: .summarize
      )
      await orchestrator.start(request: request, capture: existing.envelope) { runID, state in
        await model.receiveRunState(runID: runID, state: state)
        if case .storageError = state {
          storageErrorContinuation.yield(state)
        }
      }
      guard case .storageError = await storageErrorIterator.next() else {
        return XCTFail("expected storageError callback after gate degradation")
      }
      let gateAvailability = await gate.currentAvailability()
      XCTAssertEqual(gateAvailability, .unavailable(.writeFailed))
      let response = await receiver.process(try JSONEncoder().encode(capture()))

      guard case let .error(error) = response else {
        return XCTFail("\(mode) failure must close capture writes")
      }
      let presentation = StorageErrorMapper.presentation(for: .writeFailed)
      XCTAssertEqual(error.code, presentation.code.rawValue)
      XCTAssertEqual(error.retryable, presentation.retryable)
      XCTAssertEqual(error.action, presentation.action)
      XCTAssertNil(error.safeDetail)
      XCTAssertEqual(repository.acceptCaptureCallCount, 0)
      XCTAssertEqual(model.currentCapture, existing)
      XCTAssertEqual(model.storageAvailability, .unavailable(.writeFailed))
    }
  }

  func testMainActorRejectsEveryOldRunStateAfterNewRunTakesVisibility() {
    let model = AppViewModel()
    let oldRun = RunID(), newRun = RunID()
    model.receiveRunState(runID: oldRun, state: .starting(intent: .summarize))
    model.receiveRunState(runID: oldRun, state: .streaming(intent: .summarize, partialText: "old"))
    model.receiveRunState(runID: newRun, state: .starting(intent: .translate))

    let staleStates: [RunState] = [
      .streaming(intent: .summarize, partialText: "late"),
      .stopping(intent: .summarize, partialText: "old"),
      .stopped(intent: .summarize, partialText: "old"),
      .completed(intent: .summarize, text: "old"),
      .incomplete(intent: .summarize, partialText: "old", code: "OLD"),
      .failed(intent: .summarize, code: "OLD"),
      .storageError(intent: .summarize, partialText: "old", code: .writeFailed)
    ]
    for state in staleStates {
      model.receiveRunState(runID: oldRun, state: state)
      XCTAssertEqual(model.runState, .starting(intent: .translate))
      XCTAssertEqual(model.storageAvailability, .bootstrapping)
    }
    model.receiveRunState(runID: newRun, state: .completed(intent: .translate, text: "new"))
    XCTAssertEqual(model.runState, .completed(intent: .translate, text: "new"))
  }

  func testStorageCopyNeverSuggestsProviderAPIKeyBaseURLOrNetwork() {
    for code in StorageErrorCode.allCases {
      let text = StorageErrorCatalog.presentation(for: code).visibleText.lowercased()
      for forbidden in ["provider", "api key", "base url", "网络"] {
        XCTAssertFalse(text.contains(forbidden), "\(code) leaked provider recovery language")
      }
      XCTAssertTrue(text.contains("本地") || text.contains("页面") || text.contains("运行"))
    }
  }

  func testStoppedMessageExplicitlyMarksResultIncomplete() async throws {
    let provider = AppTestModelProvider(results: [.pending])
    let model = try makeModel(provider: provider)
    model.receive(currentCapture())

    await model.summarize()
    await waitUntil { model.runState == .starting(intent: .summarize) }
    await model.stop()
    await waitUntil {
      model.runState == .stopped(intent: .summarize, partialText: "")
    }

    XCTAssertEqual(model.runStatusText, "用户已停止，结果不完整。")
  }

  private func makeModel(
    provider: AppTestModelProvider,
    secret: String = "not-a-real-key",
    repository: AppHistoryRepository = AppHistoryRepository()
  ) throws -> AppViewModel {
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "fixture-reference")
    )
    let service = ProviderConfigurationService(
      profileStore: AppProfileStore(profile: profile),
      secretStore: AppSecretStore(secret: secret)
    )
    let orchestrator = ModelRunOrchestrator(
      configurationService: service,
      provider: provider,
      history: HistoryApplicationService(repository: repository)
    )
    let model = AppViewModel(modelRunOrchestrator: orchestrator)
    model.setStorageAvailability(.writable)
    return model
  }

  private func currentCapture() -> CurrentCapture {
    .init(envelope: capture(), taskID: TaskID(), snapshotID: ContentSnapshotID())
  }

  private func capture() -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(
      version: 1,
      requestId: UUID().uuidString,
      createdAt: "2026-07-14T00:00:00Z",
      source: .init(
        kind: "browser_capture",
        url: "https://example.test/article",
        title: "Fixture title",
        platform: "generic"
      ),
      capture: .init(
        method: "rendered_dom",
        text: "Fixture body",
        characterCount: "Fixture body".unicodeScalars.count,
        completeness: "full_article",
        capturedAt: "2026-07-14T00:00:00Z"
      ),
      evidence: .init(sourceLabel: "fixture", usedCookie: false)
    )
  }

  private func waitUntil(
    timeoutMilliseconds: UInt64 = 2_000,
    condition: @escaping @MainActor () -> Bool
  ) async {
    let iterations = Int(timeoutMilliseconds / 10)
    for _ in 0..<iterations {
      if condition() {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not met before timeout")
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
