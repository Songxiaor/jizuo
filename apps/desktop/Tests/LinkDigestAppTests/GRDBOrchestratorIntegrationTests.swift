import Foundation
import XCTest
import LinkDigestAdapters
import LinkDigestCore
import LinkDigestPersistence
@testable import LinkDigestApp

private actor GRDBProfileStore: ProviderProfileStore {
  let profile: ProviderProfile
  init(_ profile: ProviderProfile) { self.profile = profile }
  func load() async throws -> ProviderProfile? { profile }
  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor GRDBSecretStore: SecretStore {
  let secret: String
  let readDelay: Duration?
  init(_ secret: String = "fixture-secret", readDelay: Duration? = nil) {
    self.secret = secret
    self.readDelay = readDelay
  }
  func save(_: String, for _: SecretReference) async throws {}
  func read(_: SecretReference) async throws -> String? {
    if let readDelay { try await Task.sleep(for: readDelay) }
    return secret
  }
  func contains(_: SecretReference) async throws -> Bool { true }
  func delete(_: SecretReference) async throws {}
}

private final class GRDBTestProvider: ModelProvider, @unchecked Sendable {
  private let events: [ModelStreamEvent]
  private let staysOpen: Bool
  private let lock = NSLock()
  private var streamCalls = 0
  private var explicitCancels = 0
  private var terminations = 0
  private var producerFinishes = 0

  init(events: [ModelStreamEvent], staysOpen: Bool = false) {
    self.events = events
    self.staysOpen = staysOpen
  }

  func stream(profile _: ProviderProfile, apiKey _: String, intent _: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    lock.withLock { streamCalls += 1 }
    let events = events, staysOpen = staysOpen
    return AsyncThrowingStream { continuation in
      let producer = Task {
        do {
          for event in events {
            continuation.yield(event)
            try await Task.sleep(for: .milliseconds(20))
          }
          if staysOpen { try await Task.sleep(for: .seconds(30)) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: CancellationError())
        }
        self.lock.withLock { self.producerFinishes += 1 }
      }
      continuation.onTermination = { @Sendable _ in
        self.lock.withLock { self.terminations += 1 }
        producer.cancel()
      }
    }
  }

  func cancelActiveStreams() { lock.withLock { explicitCancels += 1 } }
  var streamCallCount: Int { lock.withLock { streamCalls } }
  var explicitCancelCount: Int { lock.withLock { explicitCancels } }
  var terminationCount: Int { lock.withLock { terminations } }
  var producerFinishCount: Int { lock.withLock { producerFinishes } }
}

/// A fixture-only BYOK endpoint that exercises the same persistent
/// orchestrator path as the App: summary, its fail-open tag side path, then
/// translation.  It performs no I/O and never receives a real credential.
private final class IntegratedDeliveryProvider: ModelProvider, SummaryTagGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedIntents: [RunIntentKind] = []
  private var recordedTagSummaries: [String] = []

  func stream(profile _: ProviderProfile, apiKey _: String, intent: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    lock.withLock { recordedIntents.append(intent.kind) }
    let body = intent.kind == .summarize ? "集成总结" : "集成翻译"
    return AsyncThrowingStream { continuation in
      continuation.yield(.delta(body))
      continuation.yield(.usage(.init(inputTokens: 12, outputTokens: 4, totalTokens: 16)))
      continuation.yield(.completed)
      continuation.finish()
    }
  }

  func generateSummaryTags(profile _: ProviderProfile, apiKey _: String, summary: String) async throws -> String {
    lock.withLock { recordedTagSummaries.append(summary) }
    return "集成, 总检"
  }

  func cancelActiveStreams() {}
  var intents: [RunIntentKind] { lock.withLock { recordedIntents } }
  var tagSummaries: [String] { lock.withLock { recordedTagSummaries } }
}

/// Exercises the real SSE decoder on the way into the persistent orchestrator.
/// Its raw lines deliberately include malformed optional usage metadata.
private final class DecodingGRDBTestProvider: ModelProvider, @unchecked Sendable {
  private let lines: [String]
  init(lines: [String]) { self.lines = lines }

  func stream(profile _: ProviderProfile, apiKey _: String, intent _: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let lines = lines
    return AsyncThrowingStream { continuation in
      Task {
        do {
          let decoder = ChatCompletionsStreamDecoder()
          for line in lines {
            if let event = try decoder.decode(line: line) { continuation.yield(event) }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func cancelActiveStreams() {}
}

private actor OneShotSignal {
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signaled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func signal() {
    guard !signaled else { return }
    signaled = true
    let current = waiters
    waiters.removeAll()
    current.forEach { $0.resume() }
  }
}

private final class HostileLateProvider: ModelProvider, @unchecked Sendable {
  let firstYielded = OneShotSignal()
  let releaseLate = OneShotSignal()
  let finished = OneShotSignal()
  private let lock = NSLock()
  private var cancels = 0
  private var active = 0

  func stream(profile _: ProviderProfile, apiKey _: String, intent _: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    lock.withLock { active += 1 }
    return AsyncThrowingStream { continuation in
      Task.detached {
        continuation.yield(.delta("candidate"))
        await self.firstYielded.signal()
        await self.releaseLate.wait()
        continuation.yield(.delta("hostile-late"))
        continuation.yield(.completed)
        continuation.finish()
        self.lock.withLock { self.active -= 1 }
        await self.finished.signal()
      }
    }
  }
  func cancelActiveStreams() { lock.withLock { cancels += 1 } }
  var cancelCount: Int { lock.withLock { cancels } }
  var activeCount: Int { lock.withLock { active } }
}

private actor GRDBStateRecorder {
  private(set) var updates: [(RunID, RunState)] = []
  func receive(_ runID: RunID, _ state: RunState) { updates.append((runID, state)) }
  var last: RunState? { updates.last?.1 }
  var all: [RunState] { updates.map(\.1) }
}

private actor GRDBCurrentCaptureSink {
  private(set) var values: [CurrentCapture] = []
  func receive(_ value: CurrentCapture) { values.append(value) }
}

private final class TerminalFailureOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining = 1
  func beforeTerminalCommit() throws {
    let shouldFail = lock.withLock { () -> Bool in
      guard remaining > 0 else { return false }
      remaining -= 1
      return true
    }
    if shouldFail { throw RepositoryFailure.injectedFailure }
  }
}

private final class WriteFailureCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let failingCall: Int
  init(failingCall: Int) { self.failingCall = failingCall }
  func beforeWrite() throws {
    let current = lock.withLock { () -> Int in count += 1; return count }
    if current == failingCall { throw RepositoryFailure.injectedFailure }
  }
}

final class GRDBOrchestratorIntegrationTests: XCTestCase {
  func testIntegratedFixtureBYOKSummaryTranslationAndTagsPersistWithoutNetwork() async throws {
    try await withTemporaryRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = IntegratedDeliveryProvider()
      let recorder = GRDBStateRecorder()
      let profile = try ProviderProfile(baseURL: "https://example.test/v1", model: "fixture-model", secretReference: .init(rawValue: "fixture-reference"))
      let orchestrator = ModelRunOrchestrator(
        configurationService: .init(profileStore: GRDBProfileStore(profile), secretStore: GRDBSecretStore()),
        provider: provider,
        summaryTagGenerator: provider,
        history: HistoryApplicationService(repository: repository),
        nowMilliseconds: { 10 }
      )

      let summary = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      await orchestrator.start(request: summary, capture: integrationCapture()) { runID, state in await recorder.receive(runID, state) }
      await waitUntil { await recorder.last == .completed(intent: .summarize, text: "集成总结") }
      await waitUntil { Set(try! repository.allTags().map(\.name)) == Set(["集成", "总检"]) }

      let translation = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .translate, targetLanguage: "简体中文")
      await orchestrator.start(request: translation, capture: integrationCapture()) { runID, state in await recorder.receive(runID, state) }
      await waitUntil { await recorder.last == .completed(intent: .translate, text: "集成翻译") }

      let detail = try repository.detail(taskID: accepted.taskID)
      let runsByKind = Dictionary(uniqueKeysWithValues: detail.runs.map { ($0.run.kind, $0) })
      XCTAssertEqual(Set(runsByKind.keys), [.summarize, .translate])
      XCTAssertEqual(runsByKind[.summarize]?.artifact?.bodyText, "集成总结")
      XCTAssertEqual(runsByKind[.translate]?.artifact?.bodyText, "集成翻译")
      XCTAssertEqual(runsByKind.values.map(\.run.usageCost.totalTokens), [16, 16])
      XCTAssertEqual(provider.intents, [.summarize, .translate])
      XCTAssertEqual(provider.tagSummaries, ["集成总结", "集成翻译"])
    }
  }

  func testManualDocumentPersistsPublishesThenCreatesFakeProviderArtifact() async throws {
    try await withTemporaryRepository { repository, _ in
      let document = CapturedDocument(
        requestID: "manual-integration", createdAt: "2026-07-15T04:00:00Z",
        idempotencyKey: "manual-integration-key", origin: .manualLink,
        url: "https://example.test/manual", title: "Manual Fixture", platform: "manual",
        method: "public_html", text: "manual fixture body", completeness: "best_effort",
        capturedAt: "2026-07-15T04:00:00Z", sourceLabel: "Manual fixture"
      )
      let sink = GRDBCurrentCaptureSink()
      let ingestor = CaptureIngestService(
        history: HistoryApplicationService(repository: repository),
        storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 },
        captureSink: { await sink.receive($0) }
      )
      let current = try await ingestor.ingest(document)
      XCTAssertNil(current.wireEnvelope)
      let published = await sink.values
      XCTAssertEqual(published.single?.document.origin, .manualLink)

      let provider = GRDBTestProvider(events: [.delta("summary"), .completed])
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      let request = PersistentRunRequest(runID: RunID(), taskID: current.taskID, snapshotID: current.snapshotID, intent: .summarize)
      let recorder = GRDBStateRecorder()
      await orchestrator.start(request: request, capture: current.document) { runID, state in await recorder.receive(runID, state) }
      await waitUntil { (await recorder.updates).contains { $0.1 == .completed(intent: .summarize, text: "summary") } }
      XCTAssertEqual(try repository.detail(taskID: current.taskID).runs.single?.artifact?.bodyText, "summary")
    }
  }
  func testImmediateStopInsideStartingCallbackPersistsQueuedStoppedUnder500ms() async throws {
    try await withTemporaryRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = GRDBTestProvider(events: [], staysOpen: true)
      let recorder = GRDBStateRecorder()
      let orchestrator = try makeOrchestrator(
        repository: repository,
        provider: provider,
        credentialDelay: .seconds(30)
      )
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      let startedAt = ContinuousClock.now
      await orchestrator.start(request: request, capture: integrationCapture()) { runID, state in
        await recorder.receive(runID, state)
        if case .starting = state { await orchestrator.stop() }
      }
      let elapsed = ContinuousClock.now - startedAt

      XCTAssertLessThan(elapsed, .milliseconds(500))
      let lastState = await recorder.last
      XCTAssertEqual(lastState, .stopped(intent: .summarize, partialText: ""))
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.run.status, .stopped)
      XCTAssertEqual(provider.streamCallCount, 0)
      XCTAssertGreaterThanOrEqual(provider.explicitCancelCount, 1)
    }
  }

  func testSecondStartWhileActiveIsIgnoredAndLeavesNoDanglingRun() async throws {
    try await withTemporaryRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = GRDBTestProvider(events: [.delta("kept")], staysOpen: true)
      let recorder = GRDBStateRecorder()
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      let first = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      let second = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .translate, targetLanguage: "简体中文")
      await orchestrator.start(request: first, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { await recorder.last == .streaming(intent: .summarize, partialText: "kept") }
      await orchestrator.start(request: second, capture: integrationCapture()) { await recorder.receive($0, $1) }

      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.count, 1)
      XCTAssertEqual(provider.streamCallCount, 1)
      await orchestrator.stop()
      let runs = try repository.detail(taskID: accepted.taskID).runs
      XCTAssertEqual(runs.count, 1)
      XCTAssertEqual(runs.single?.run.status, .stopped)
      XCTAssertTrue(runs.allSatisfy { $0.run.status.isTerminal })
    }
  }

  func testSplitSecretAndHeldBackPartialFailureNeverPersistSecretFragments() async throws {
    let secret = "sentinel-secret-\(UUID().uuidString)"
    try await withTemporaryRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let split = secret.index(secret.startIndex, offsetBy: secret.count / 2)
      let provider = GRDBTestProvider(events: [
        .delta("safe "), .delta(String(secret[..<split])), .delta(String(secret[split...])), .delta(" tail"), .completed
      ])
      let recorder = GRDBStateRecorder()
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider, secret: secret)
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { if case .completed = await recorder.last { true } else { false } }

      let detail = try repository.detail(taskID: accepted.taskID)
      let observable = String(describing: await recorder.updates) + String(describing: detail)
      XCTAssertFalse(observable.contains(secret))
      XCTAssertFalse(observable.contains(String(secret[..<split])))
      XCTAssertTrue(detail.runs.single?.artifact?.bodyText.contains("[已隐藏]") == true)
    }

    try await withTemporaryLocation { location in
      let counter = WriteFailureCounter(failingCall: 5)
      var dependencies = PersistenceDependencies.live
      dependencies.beforeWrite = { try counter.beforeWrite() }
      let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let fragment = String(secret.prefix(secret.count / 2))
      let provider = GRDBTestProvider(events: [.delta("safe "), .delta(fragment), .completed])
      let recorder = GRDBStateRecorder()
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider, secret: secret)
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { if case .storageError = await recorder.last { true } else { false } }

      let detail = try repository.detail(taskID: accepted.taskID)
      let observable = String(describing: await recorder.updates) + String(describing: detail)
      XCTAssertFalse(observable.contains(fragment))
      XCTAssertFalse(observable.contains(secret))
      XCTAssertEqual(detail.runs.single?.artifact?.bodyText, "safe ")
      XCTAssertEqual(detail.runs.single?.run.status, .running)
      try repository.database.close()
      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      _ = try reopened.recoverInterruptedRuns(at: 99)
      XCTAssertEqual(try reopened.detail(taskID: accepted.taskID).runs.single?.run.status, .interrupted)
    }
  }

  func testTerminalFailureReleasesAuthorityForNewRunWithoutOldStateOverwrite() async throws {
    try await withTemporaryLocation { location in
      let failure = TerminalFailureOnce()
      var dependencies = PersistenceDependencies.live
      dependencies.beforeTerminalCommit = { try failure.beforeTerminalCommit() }
      let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = GRDBTestProvider(events: [.delta("result"), .completed])
      let recorder = GRDBStateRecorder()
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      let first = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      await orchestrator.start(request: first, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { if case .storageError = await recorder.last { true } else { false } }

      let second = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .translate, targetLanguage: "简体中文")
      await orchestrator.start(request: second, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { await recorder.last == .completed(intent: .translate, text: "result") }
      let beforeRestart = try repository.detail(taskID: accepted.taskID).runs
      XCTAssertEqual(beforeRestart.count, 2)
      let beforeByID = Dictionary(uniqueKeysWithValues: beforeRestart.map { ($0.run.id, $0.run.status) })
      XCTAssertEqual(beforeByID[first.runID], .running)
      XCTAssertEqual(beforeByID[second.runID], .completed)
      try repository.database.close()

      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      _ = try reopened.recoverInterruptedRuns(at: 99)
      let afterRestart = try reopened.detail(taskID: accepted.taskID).runs
      let afterByID = Dictionary(uniqueKeysWithValues: afterRestart.map { ($0.run.id, $0.run.status) })
      XCTAssertEqual(afterByID[first.runID], .interrupted)
      XCTAssertEqual(afterByID[second.runID], .completed)
    }
  }

  func testSuccessfulRunPersistsFiveUsageCostColumnsAsNullAcrossReopen() async throws {
    try await withTemporaryRepository { repository, location in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = GRDBTestProvider(events: [.delta("complete"), .completed])
      let recorder = GRDBStateRecorder()
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { await recorder.last == .completed(intent: .summarize, text: "complete") }
      try repository.database.close()

      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      let usage = try XCTUnwrap(try reopened.detail(taskID: accepted.taskID).runs.single?.run.usageCost)
      XCTAssertNil(usage.inputTokens)
      XCTAssertNil(usage.outputTokens)
      XCTAssertNil(usage.totalTokens)
      XCTAssertNil(usage.costAmountMicros)
      XCTAssertNil(usage.costCurrencyCode)
    }
  }

  func testSuccessfulRunPersistsUsageTailAcrossReopen() async throws {
    try await withTemporaryRepository { repository, location in
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let usage = RunUsageCost(inputTokens: 120, outputTokens: 45, totalTokens: 165)
      let provider = GRDBTestProvider(events: [.delta("complete"), .usage(usage), .completed])
      let recorder = GRDBStateRecorder()
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .translate, targetLanguage: "简体中文")
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { await recorder.last == .completed(intent: .translate, text: "complete") }
      try repository.database.close()

      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      let persisted = try XCTUnwrap(try reopened.detail(taskID: accepted.taskID).runs.single?.run)
      XCTAssertEqual(persisted.kind, .translate)
      XCTAssertEqual(persisted.model, "fixture")
      XCTAssertEqual(persisted.status, .completed)
      XCTAssertEqual(persisted.usageCost, usage)
    }
  }

  func testMalformedUsageTailCannotTurnCompletedRunIntoFailure() async throws {
    let malformedUsagePayloads = [
      "{\"choices\":[],\"usage\":{\"total_tokens\":-1}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":\"seven\"}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":9223372036854775808}}",
      "{\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":\"bad\",\"total_tokens\":2}}"
    ]
    for payload in malformedUsagePayloads {
      try await withTemporaryRepository { repository, _ in
        let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
        let provider = DecodingGRDBTestProvider(lines: [
          "data: {\"choices\":[{\"delta\":{\"content\":\"complete\"}}]}",
          "data: \(payload)",
          "data: [DONE]"
        ])
        let recorder = GRDBStateRecorder()
        let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
        let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
        await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
        await waitUntil { await recorder.last == .completed(intent: .summarize, text: "complete") }

        let run = try XCTUnwrap(try repository.detail(taskID: accepted.taskID).runs.single?.run)
        XCTAssertEqual(run.status, .completed)
        XCTAssertNil(run.failureCode)
        XCTAssertEqual(run.usageCost, .unknown)
        XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "complete")
        let states = await recorder.all
        XCTAssertFalse(states.contains { state in
          if case .failed = state { return true }
          if case .incomplete = state { return true }
          return false
        })
      }
    }
  }

  func testPartialWriteFailureKeepsCommittedTextRunningThenRestartInterrupts() async throws {
    try await withTemporaryLocation { location in
      let counter = WriteFailureCounter(failingCall: 5)
      var dependencies = PersistenceDependencies.live
      dependencies.beforeWrite = { try counter.beforeWrite() }
      let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = GRDBTestProvider(events: [.delta("kept"), .delta("-candidate"), .completed], staysOpen: true)
      let recorder = GRDBStateRecorder()
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      let orchestrator = try makeOrchestrator(repository: repository, provider: provider)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await waitUntil { await recorder.last == .storageError(intent: .summarize, partialText: "kept", code: .writeFailed) }

      let beforeRestart = try repository.detail(taskID: accepted.taskID).runs.single
      XCTAssertEqual(beforeRestart?.run.status, .running)
      XCTAssertEqual(beforeRestart?.artifact?.bodyText, "kept")
      XCTAssertGreaterThanOrEqual(provider.explicitCancelCount, 1)
      await waitUntil { provider.terminationCount >= 1 && provider.producerFinishCount >= 1 }
      try repository.database.close()

      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      _ = try reopened.recoverInterruptedRuns(at: 99)
      XCTAssertEqual(try reopened.detail(taskID: accepted.taskID).runs.single?.run.status, .interrupted)
    }
  }

  func testPartialFailureRejectsHostileLateEventsWithoutMoreWritesOrUI() async throws {
    try await withTemporaryLocation { location in
      let counter = WriteFailureCounter(failingCall: 4)
      var dependencies = PersistenceDependencies.live
      dependencies.beforeWrite = { try counter.beforeWrite() }
      let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
      let provider = HostileLateProvider()
      let recorder = GRDBStateRecorder()
      let profile = try ProviderProfile(baseURL: "https://example.test/v1", model: "fixture", secretReference: .init(rawValue: "fixture-reference"))
      let orchestrator = ModelRunOrchestrator(
        configurationService: ProviderConfigurationService(profileStore: GRDBProfileStore(profile), secretStore: GRDBSecretStore()),
        provider: provider,
        history: HistoryApplicationService(repository: repository),
        nowMilliseconds: { 10 }
      )
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
      await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
      await provider.firstYielded.wait()
      await waitUntil { if case .storageError = await recorder.last { true } else { false } }
      let statesBeforeLate = await recorder.updates
      let detailBeforeLate = try repository.detail(taskID: accepted.taskID)
      XCTAssertGreaterThanOrEqual(provider.cancelCount, 1)

      await provider.releaseLate.signal()
      await provider.finished.wait()
      let statesAfterLate = await recorder.updates
      let detailAfterLate = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(statesAfterLate.map(\.1), statesBeforeLate.map(\.1))
      XCTAssertEqual(detailAfterLate, detailBeforeLate)
      XCTAssertEqual(provider.activeCount, 0)
      XCTAssertEqual(detailAfterLate.runs.single?.run.status, .running)
      XCTAssertNil(detailAfterLate.runs.single?.artifact)
    }
  }

  func testTerminalAndStopWriteFailuresLeaveRunningForRestartRecoveryWithoutFakeTerminal() async throws {
    for mode in ["terminal", "stop"] {
      try await withTemporaryLocation { location in
        var dependencies = PersistenceDependencies.live
        dependencies.beforeTerminalCommit = { throw RepositoryFailure.injectedFailure }
        let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
        let accepted = try repository.acceptCapture(.init(envelope: integrationCapture(), receivedAtMilliseconds: 1))
        let provider = GRDBTestProvider(
          events: mode == "terminal" ? [.delta("kept"), .completed] : [.delta("kept")],
          staysOpen: mode == "stop"
        )
        let recorder = GRDBStateRecorder()
        let gate = StorageWriteGate(initialAvailability: .writable)
        let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)
        let orchestrator = try makeOrchestrator(
          repository: repository,
          provider: provider,
          storageWriteGate: gate
        )
        await orchestrator.start(request: request, capture: integrationCapture()) { await recorder.receive($0, $1) }
        if mode == "stop" {
          await waitUntil { await recorder.last == .streaming(intent: .summarize, partialText: "kept") }
          await orchestrator.stop()
        }
        await waitUntil { await recorder.last == .storageError(intent: .summarize, partialText: "kept", code: .writeFailed) }

        let states = await recorder.updates.map(\.1)
        XCTAssertFalse(states.contains(.completed(intent: .summarize, text: "kept")))
        XCTAssertFalse(states.contains(.stopped(intent: .summarize, partialText: "kept")))
        XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.run.status, .running)
        let gateAvailability = await gate.currentAvailability()
        XCTAssertEqual(gateAvailability, .unavailable(.writeFailed))
        XCTAssertGreaterThanOrEqual(provider.explicitCancelCount, 1)
        await waitUntil { provider.terminationCount >= 1 && provider.producerFinishCount >= 1 }
        try repository.database.close()

        let reopened = try GRDBHistoryRepository.open(at: location)
        defer { try? reopened.database.close() }
        _ = try reopened.recoverInterruptedRuns(at: 99)
        XCTAssertEqual(try reopened.detail(taskID: accepted.taskID).runs.single?.run.status, .interrupted)
      }
    }
  }

  private func makeOrchestrator(
    repository: GRDBHistoryRepository,
    provider: any ModelProvider,
    secret: String = "fixture-secret",
    credentialDelay: Duration? = nil,
    storageWriteGate: StorageWriteGate? = nil
  ) throws -> ModelRunOrchestrator {
    let profile = try ProviderProfile(baseURL: "https://example.test/v1", model: "fixture", secretReference: .init(rawValue: "fixture-reference"))
    return ModelRunOrchestrator(
      configurationService: ProviderConfigurationService(profileStore: GRDBProfileStore(profile), secretStore: GRDBSecretStore(secret, readDelay: credentialDelay)),
      provider: provider,
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: storageWriteGate,
      nowMilliseconds: { 10 }
    )
  }

  private func waitUntil(condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<300 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition timed out")
  }
}

private func integrationCapture() -> CaptureEnvelopeV1 {
  let body = "fixture body"
  return .init(
    version: 1, requestId: "integration-request", createdAt: "2026-07-15T04:00:00Z", idempotencyKey: "integration-delivery",
    source: .init(kind: "browser_capture", url: "https://example.test/article", title: "Fixture", platform: "generic"),
    capture: .init(method: "rendered_dom", text: body, characterCount: body.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"),
    evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
  )
}

private func withTemporaryRepository(_ body: (GRDBHistoryRepository, LocalDatabaseLocation) async throws -> Void) async throws {
  try await withTemporaryLocation { location in
    let repository = try GRDBHistoryRepository.open(at: location)
    try await body(repository, location)
  }
}

private func withTemporaryLocation(_ body: (LocalDatabaseLocation) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-02b-grdb-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(LocalDatabaseLocation(applicationSupportRoot: root))
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
