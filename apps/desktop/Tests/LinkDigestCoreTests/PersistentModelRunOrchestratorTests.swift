import Foundation
import XCTest
@testable import LinkDigestCore

private final class PersistentCommitBlocker: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func block() { entered.signal(); release.wait() }
}

private final class PersistentEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) { lock.withLock { storage.append(value) } }
  var values: [String] { lock.withLock { storage } }
}

private actor PersistentProfileStore: ProviderProfileStore {
  let profile: ProviderProfile?
  init(_ profile: ProviderProfile?) { self.profile = profile }
  func load() async throws -> ProviderProfile? { profile }
  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor PersistentSecretStore: SecretStore {
  let secret: String?
  let readDelay: Duration?
  init(_ secret: String?, readDelay: Duration? = nil) {
    self.secret = secret
    self.readDelay = readDelay
  }
  func save(_: String, for _: SecretReference) async throws {}
  func read(_: SecretReference) async throws -> String? {
    if let readDelay { try await Task.sleep(for: readDelay) }
    return secret
  }
  func contains(_: SecretReference) async throws -> Bool { secret != nil }
  func delete(_: SecretReference) async throws {}
}

private final class PersistentProvider: ModelProvider, @unchecked Sendable {
  private let log: PersistentEventLog
  private let events: [ModelStreamEvent]
  private let staysOpen: Bool
  private let lock = NSLock()
  private var cancellations = 0

  init(log: PersistentEventLog, events: [ModelStreamEvent], staysOpen: Bool = false) {
    self.log = log
    self.events = events
    self.staysOpen = staysOpen
  }

  func stream(
    profile _: ProviderProfile,
    apiKey _: String,
    intent _: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    log.append("provider")
    let events = events
    let staysOpen = staysOpen
    return AsyncThrowingStream { continuation in
      if staysOpen {
        let producer = Task {
          do {
            for event in events { continuation.yield(event) }
            try await Task.sleep(for: .seconds(30))
            continuation.finish()
          } catch {
            continuation.finish(throwing: CancellationError())
          }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
      } else {
        for event in events { continuation.yield(event) }
        continuation.finish()
      }
    }
  }

  func cancelActiveStreams() {
    lock.withLock { cancellations += 1 }
  }

  var cancellationCount: Int { lock.withLock { cancellations } }
}

private final class PersistentRepository: HistoryRepository, @unchecked Sendable {
  enum FailurePoint { case partial(Int), terminal }

  let accessMode: HistoryRepositoryAccessMode = .writable
  let log: PersistentEventLog
  let replayRunID: RunID?
  let failurePoint: FailurePoint?
  let blockedOperation: String?
  let commitBlocker: PersistentCommitBlocker?
  private let lock = NSLock()
  private var partialCalls = 0
  private var createCommands: [CreateRunCommand] = []
  private var committedPartialBodies: [String] = []
  private var terminalCommands: [FinishRunCommand] = []
  private var observedRunIDs: [RunID] = []

  init(
    log: PersistentEventLog,
    replayRunID: RunID? = nil,
    failurePoint: FailurePoint? = nil,
    blockedOperation: String? = nil,
    commitBlocker: PersistentCommitBlocker? = nil
  ) {
    self.log = log
    self.replayRunID = replayRunID
    self.failurePoint = failurePoint
    self.blockedOperation = blockedOperation
    self.commitBlocker = commitBlocker
  }

  private func blockBeforeCommit(_ operation: String) {
    guard blockedOperation == operation, let commitBlocker else { return }
    log.append("\(operation)-entry")
    commitBlocker.block()
  }

  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }

  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult {
    blockBeforeCommit("queued")
    log.append("queued")
    let runID = replayRunID ?? command.runID
    lock.withLock {
      createCommands.append(command)
      observedRunIDs.append(runID)
    }
    return .init(runID: runID, wasCreated: replayRunID == nil)
  }

  func markRunRunning(_ command: MarkRunRunningCommand) throws {
    blockBeforeCommit("running")
    log.append("running")
    lock.withLock { observedRunIDs.append(command.runID) }
  }

  func savePartialArtifact(_ command: SavePartialArtifactCommand) throws {
    let call = lock.withLock { () -> Int in
      partialCalls += 1
      observedRunIDs.append(command.runID)
      return partialCalls
    }
    blockBeforeCommit("partial")
    log.append("partial:\(command.bodyText)")
    if case let .partial(failingCall) = failurePoint, call == failingCall {
      throw RepositoryFailure.injectedFailure
    }
    lock.withLock { committedPartialBodies.append(command.bodyText) }
  }

  func finishRun(_ command: FinishRunCommand) throws {
    blockBeforeCommit("terminal")
    log.append("terminal:\(command.status.rawValue)")
    lock.withLock {
      observedRunIDs.append(command.runID)
      terminalCommands.append(command)
    }
    if case .terminal = failurePoint { throw RepositoryFailure.injectedFailure }
  }

  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }

  var creates: [CreateRunCommand] { lock.withLock { createCommands } }
  var partialBodies: [String] { lock.withLock { committedPartialBodies } }
  var terminals: [FinishRunCommand] { lock.withLock { terminalCommands } }
  var runIDs: [RunID] { lock.withLock { observedRunIDs } }
}

private actor PersistentStateRecorder {
  let log: PersistentEventLog
  private(set) var updates: [(RunID, RunState)] = []
  init(log: PersistentEventLog) { self.log = log }
  func receive(_ runID: RunID, _ state: RunState) {
    updates.append((runID, state))
    switch state {
    case .starting: log.append("state:starting")
    case .thinking: log.append("state:thinking")
    case .streaming: log.append("state:streaming")
    case .completed: log.append("state:completed")
    case .failed: log.append("state:failed")
    case .storageError: log.append("state:storage")
    case .stopping: log.append("state:stopping")
    case .stopped: log.append("state:stopped")
    case .incomplete: log.append("state:incomplete")
    case .idle: log.append("state:idle")
    }
  }
  var last: (RunID, RunState)? { updates.last }
}

final class PersistentModelRunOrchestratorTests: XCTestCase {
  func testStartingStreamingAndTerminalUIWaitForCommitSuccessNotMethodEntry() async throws {
    for operation in ["queued", "partial", "terminal"] {
      let log = PersistentEventLog()
      let blocker = PersistentCommitBlocker()
      let repository = PersistentRepository(
        log: log,
        blockedOperation: operation,
        commitBlocker: blocker
      )
      let provider = PersistentProvider(log: log, events: [.delta("A"), .completed])
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      let recorder = PersistentStateRecorder(log: log)
      let request = runRequest()
      let envelope = capture()

      let start = Task {
        await orchestrator.start(request: request, capture: envelope) {
          await recorder.receive($0, $1)
        }
      }
      XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
      let beforeCommit = await recorder.updates.map(\.1)
      switch operation {
      case "queued":
        XCTAssertTrue(beforeCommit.isEmpty)
      case "partial":
        XCTAssertEqual(beforeCommit.last, .starting(intent: .summarize))
        XCTAssertFalse(beforeCommit.contains { if case .streaming = $0 { true } else { false } })
      default:
        XCTAssertEqual(beforeCommit.last, .streaming(intent: .summarize, partialText: "A"))
        XCTAssertFalse(beforeCommit.contains(.completed(intent: .summarize, text: "A")))
      }
      blocker.release.signal()
      _ = await start.value
      await waitUntil { await recorder.last?.1 == .completed(intent: .summarize, text: "A") }
    }
  }

  func testQueuedRunningPartialTerminalAndUIOrderingWithUnknownUsage() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [.delta("A"), .delta("B"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)
    let request = runRequest()

    await orchestrator.start(request: request, capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil { await recorder.last?.1 == .completed(intent: .summarize, text: "AB") }

    XCTAssertEqual(log.values, [
      "queued", "state:starting", "running", "provider",
      "partial:A", "state:streaming", "partial:AB", "state:streaming",
      "terminal:completed", "state:completed"
    ])
    let terminal = try XCTUnwrap(repository.terminals.single)
    XCTAssertEqual(terminal.status, .completed)
    XCTAssertEqual(terminal.artifact?.bodyText, "AB")
    XCTAssertEqual(terminal.usageCost, .unknown)
  }

  func testCredentialsFailureIsPersistedWithoutCallingProvider() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider, secret: nil)
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil {
      await recorder.last?.1 == .failed(intent: .summarize, code: ModelRunErrorCode.secretStoreReadFailed.rawValue)
    }

    XCTAssertEqual(log.values, ["queued", "state:starting", "terminal:failed", "state:failed"])
    XCTAssertEqual(repository.terminals.single?.failureCode, ModelRunErrorCode.secretStoreReadFailed.rawValue)
  }

  func testEmptyCompletedPersistsMalformedFailureWithoutArtifact() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [.completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil {
      await recorder.last?.1 == .failed(intent: .summarize, code: ModelProviderErrorCode.streamMalformed.rawValue)
    }

    let terminal = try XCTUnwrap(repository.terminals.single)
    XCTAssertEqual(terminal.status, .failed)
    XCTAssertEqual(terminal.failureCode, ModelProviderErrorCode.streamMalformed.rawValue)
    XCTAssertNil(terminal.artifact)
  }

  func testPartialFailureCancelsProviderAndShowsOnlyLastCommittedPartial() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log, failurePoint: .partial(2))
    let provider = PersistentProvider(log: log, events: [.delta("kept"), .delta("-candidate"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil {
      await recorder.last?.1 == .storageError(
        intent: .summarize,
        partialText: "kept",
        code: .writeFailed
      )
    }

    XCTAssertGreaterThanOrEqual(provider.cancellationCount, 1)
    XCTAssertTrue(repository.terminals.isEmpty)
    let lastOutput = await recorder.last?.1.outputText
    XCTAssertEqual(lastOutput, "kept")
  }

  func testTerminalRollbackNeverPublishesCompleted() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log, failurePoint: .terminal)
    let provider = PersistentProvider(log: log, events: [.delta("committed"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil {
      await recorder.last?.1 == .storageError(
        intent: .summarize,
        partialText: "committed",
        code: .writeFailed
      )
    }

    let states = await recorder.updates.map(\.1)
    XCTAssertFalse(states.contains(.completed(intent: .summarize, text: "committed")))
    XCTAssertGreaterThanOrEqual(provider.cancellationCount, 1)
  }

  func testStopWhileCredentialsAreLoadingPersistsQueuedRunAsStopped() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [])
    let orchestrator = try makeOrchestrator(
      repository: repository,
      provider: provider,
      credentialDelay: .seconds(30)
    )
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil { await recorder.last?.1 == .starting(intent: .summarize) }
    await orchestrator.stop()
    await waitUntil {
      await recorder.last?.1 == .stopped(intent: .summarize, partialText: "")
    }

    XCTAssertEqual(repository.terminals.single?.status, .stopped)
    XCTAssertFalse(log.values.contains("provider"))
  }

  func testCompletedLinearizesBeforeLaterStopWithoutSecondTerminal() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [.delta("done"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)
    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil { await recorder.last?.1 == .completed(intent: .summarize, text: "done") }
    await orchestrator.stop()

    XCTAssertEqual(repository.terminals.count, 1)
    XCTAssertEqual(repository.terminals.single?.status, .completed)
    let lastState = await recorder.last?.1
    XCTAssertEqual(lastState, .completed(intent: .summarize, text: "done"))
  }

  func testStopPersistsLastCommittedPartialBeforeStoppedUI() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [.delta("kept")], staysOpen: true)
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)

    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil {
      await recorder.last?.1 == .streaming(intent: .summarize, partialText: "kept")
    }
    await orchestrator.stop()
    await waitUntil {
      await recorder.last?.1 == .stopped(intent: .summarize, partialText: "kept")
    }

    let terminal = try XCTUnwrap(repository.terminals.single)
    XCTAssertEqual(terminal.status, .stopped)
    XCTAssertEqual(terminal.artifact?.completeness, .partial)
    XCTAssertEqual(terminal.artifact?.bodyText, "kept")
    XCTAssertGreaterThanOrEqual(provider.cancellationCount, 1)
  }

  func testRepositoryReturnedRunIDMismatchIsStorageConflictAndNeverStartsProvider() async throws {
    let log = PersistentEventLog()
    let replayRunID = RunID()
    let repository = PersistentRepository(log: log, replayRunID: replayRunID)
    let provider = PersistentProvider(log: log, events: [.delta("ok"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)
    let request = runRequest()

    await orchestrator.start(request: request, capture: capture()) {
      await recorder.receive($0, $1)
    }

    XCTAssertNotEqual(request.runID, replayRunID)
    let lastState = await recorder.last?.1
    XCTAssertEqual(
      lastState,
      .storageError(intent: .summarize, partialText: "", code: .stateConflict)
    )
    XCTAssertFalse(log.values.contains("provider"))
    let callbacks = await recorder.updates
    XCTAssertTrue(callbacks.allSatisfy { $0.0 == request.runID })
  }

  func testSameRequestReusesAuthoritativeRunIDAndKeyWhileNewClickUsesNewKey() async throws {
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log)
    let provider = PersistentProvider(log: log, events: [.delta("ok"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
    let recorder = PersistentStateRecorder(log: log)
    let first = runRequest()

    for request in [first, first] {
      await orchestrator.start(request: request, capture: capture()) {
        await recorder.receive($0, $1)
      }
      await waitUntil { await recorder.last?.1 == .completed(intent: .summarize, text: "ok") }
    }
    let secondClick = runRequest()
    await orchestrator.start(request: secondClick, capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil { repository.creates.count == 3 }

    let creates = repository.creates
    XCTAssertEqual(creates[0].runID, first.runID)
    XCTAssertEqual(creates[1].runID, first.runID)
    XCTAssertEqual(creates[0].idempotencyKey, first.idempotencyKey)
    XCTAssertEqual(creates[1].idempotencyKey, first.idempotencyKey)
    XCTAssertNotEqual(secondClick.runID, first.runID)
    XCTAssertNotEqual(creates[2].idempotencyKey, first.idempotencyKey)
  }

  func testSplitSecretIsHeldBackAcrossDeltaBoundariesBeforePersistenceAndUI() async throws {
    let secret = "fixture-secret"
    for chunks in [
      ["safe ", "fixture-", "secret", " tail"],
      ["safe f", "ix", "ture-sec", "ret tail"],
      ["safe fixture-secre", "t tail"]
    ] {
      let log = PersistentEventLog()
      let repository = PersistentRepository(log: log)
      let events = chunks.map(ModelStreamEvent.delta) + [.completed]
      let provider = PersistentProvider(log: log, events: events)
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider, secret: secret)
      let recorder = PersistentStateRecorder(log: log)
      await orchestrator.start(request: runRequest(), capture: capture()) {
        await recorder.receive($0, $1)
      }
      await waitUntil { if case .completed = await recorder.last?.1 { true } else { false } }

      let stateTexts = await recorder.updates.map { $0.1.outputText }
      let observableTexts = stateTexts + repository.partialBodies + repository.terminals.compactMap { $0.artifact?.bodyText }
      for text in observableTexts {
        XCTAssertFalse(text.contains(secret))
        for prefixLength in 2..<secret.count {
          XCTAssertFalse(text.contains(String(secret.prefix(prefixLength))))
        }
      }
      XCTAssertTrue(repository.terminals.single?.artifact?.bodyText.contains("[已隐藏]") == true)
    }
  }

  func testPartialFailureWhileSecretIsHeldBackNeverCommitsOrPublishesFragment() async throws {
    let secret = "fixture-secret"
    let log = PersistentEventLog()
    let repository = PersistentRepository(log: log, failurePoint: .partial(2))
    let provider = PersistentProvider(log: log, events: [.delta("safe "), .delta("fixture-"), .completed])
    let orchestrator = try makeOrchestrator(repository: repository, provider: provider, secret: secret)
    let recorder = PersistentStateRecorder(log: log)
    await orchestrator.start(request: runRequest(), capture: capture()) {
      await recorder.receive($0, $1)
    }
    await waitUntil { if case .storageError = await recorder.last?.1 { true } else { false } }

    let observable = String(describing: await recorder.updates) + String(describing: repository.partialBodies)
    XCTAssertEqual(repository.partialBodies, ["safe "])
    XCTAssertFalse(observable.contains("fixture-"))
    XCTAssertFalse(observable.contains(secret))
    XCTAssertTrue(repository.terminals.isEmpty)
  }

  func testStorageMappingNeverIncludesRawPathSQLURLOrSecretMaterial() {
    let mappings = RepositoryFailure.allStorageFixtures.map {
      StorageErrorMapper.map($0, context: .write)
    }
    for mapping in mappings {
      XCTAssertNil(mapping.safeDetail)
      let rendered = String(describing: mapping)
      for forbidden in ["/Users/", "history.sqlite", "SELECT ", "https://private", "api-key", "Authorization", "raw body"] {
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains(forbidden))
      }
    }
  }

  private func makeOrchestrator(
    repository: PersistentRepository,
    provider: PersistentProvider,
    secret: String? = "fixture-secret",
    credentialDelay: Duration? = nil
  ) throws -> ModelRunOrchestrator {
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: .init(rawValue: "fixture-reference")
    )
    let configuration = ProviderConfigurationService(
      profileStore: PersistentProfileStore(profile),
      secretStore: PersistentSecretStore(secret, readDelay: credentialDelay)
    )
    return ModelRunOrchestrator(
      configurationService: configuration,
      provider: provider,
      history: HistoryApplicationService(repository: repository),
      nowMilliseconds: { 123 }
    )
  }

  private func runRequest() -> PersistentRunRequest {
    .init(
      runID: RunID(),
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      intent: .summarize
    )
  }

  private func capture() -> CaptureEnvelopeV1 {
    let text = "fixture body"
    return .init(
      version: 1,
      requestId: "request",
      createdAt: "2026-07-15T04:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test/article", title: "Fixture", platform: "generic"),
      capture: .init(method: "rendered_dom", text: text, characterCount: text.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"),
      evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
    )
  }

  private func waitUntil(
    condition: @escaping @Sendable () async -> Bool
  ) async {
    for _ in 0..<200 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition timed out")
  }
}

private extension RepositoryFailure {
  static let allStorageFixtures: [RepositoryFailure] = [
    .unavailable, .readOnly(.futureSchema), .readOnly(.migrationFailed),
    .readOnly(.storageUnavailable), .notFound, .captureIdempotencyConflict,
    .runIdempotencyConflict, .invalidStateTransition, .invalidInput,
    .integrityCheckFailed, .injectedFailure
  ]
}

private extension Array {
  var single: Element? { count == 1 ? first : nil }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock(); defer { unlock() }
    return try body()
  }
}
