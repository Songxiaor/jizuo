import Foundation
import XCTest
@testable import LinkDigestCore

private final class CallbackBlocker: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func block() { entered.signal(); release.wait() }
}

private actor OrchestratorProfileStore: ProviderProfileStore {
  private let profile: ProviderProfile?
  private let failLoad: Bool

  init(profile: ProviderProfile? = nil, failLoad: Bool = false) {
    self.profile = profile
    self.failLoad = failLoad
  }

  func load() async throws -> ProviderProfile? {
    if failLoad {
      throw ProviderProfileStoreFailure.readFailed
    }
    return profile
  }

  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor OrchestratorSecretStore: SecretStore {
  private let value: String?
  private let failRead: Bool

  init(value: String? = nil, failRead: Bool = false) {
    self.value = value
    self.failRead = failRead
  }

  func save(_: String, for _: SecretReference) async throws {}

  func read(_: SecretReference) async throws -> String? {
    if failRead {
      throw SecretStoreFailure(operation: .read, status: -1)
    }
    return value
  }

  func contains(_: SecretReference) async throws -> Bool {
    value != nil
  }

  func delete(_: SecretReference) async throws {}
}

private final class ScriptedModelProvider: ModelProvider, @unchecked Sendable {
  enum Step: Sendable {
    case event(ModelStreamEvent, delayMilliseconds: UInt64 = 0)
    case failure(ModelProviderFailure, delayMilliseconds: UInt64 = 0)
  }

  struct Script: Sendable {
    let steps: [Step]
  }

  private let lock = NSLock()
  private var scripts: [Script]
  private var recordedIntents: [RunIntent] = []
  private var recordedKeyPresence: [Bool] = []
  private var recordedCancellationCount = 0
  private var recordedExplicitCancellationCount = 0

  init(scripts: [Script] = []) {
    self.scripts = scripts
  }

  func stream(
    profile _: ProviderProfile,
    apiKey: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let script = lock.withLock { () -> Script in
      recordedIntents.append(intent)
      recordedKeyPresence.append(!apiKey.isEmpty)
      return scripts.isEmpty ? Script(steps: []) : scripts.removeFirst()
    }

    return AsyncThrowingStream { continuation in
      let producer = Task {
        do {
          for step in script.steps {
            switch step {
            case let .event(event, delayMilliseconds):
              if delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
              }
              try Task.checkCancellation()
              continuation.yield(event)
            case let .failure(failure, delayMilliseconds):
              if delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
              }
              try Task.checkCancellation()
              continuation.finish(throwing: failure)
              return
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { [weak self] reason in
        if case .cancelled = reason {
          self?.lock.withLock {
            self?.recordedCancellationCount += 1
          }
        }
        producer.cancel()
      }
    }
  }

  func cancelActiveStreams() {
    lock.withLock {
      recordedExplicitCancellationCount += 1
    }
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

  var cancellationCount: Int {
    lock.withLock { recordedCancellationCount }
  }

  var explicitCancellationCount: Int {
    lock.withLock { recordedExplicitCancellationCount }
  }
}

private final class AdversarialModelProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var activeStreams = 0
  private var yieldedEvents = 0
  private var explicitCancellations = 0

  func stream(profile _: ProviderProfile, apiKey _: String, intent _: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let call = lock.withLock { () -> Int in
      calls += 1
      activeStreams += 1
      return calls
    }
    return AsyncThrowingStream { continuation in
      Task.detached {
        if call == 1 {
          try? await Task.sleep(for: .milliseconds(200))
          self.lock.withLock { self.yieldedEvents += 1 }
          continuation.yield(.delta("malicious-late-old"))
          self.lock.withLock { self.yieldedEvents += 1 }
          continuation.yield(.completed)
        } else {
          self.lock.withLock { self.yieldedEvents += 1 }
          continuation.yield(.delta("new"))
          self.lock.withLock { self.yieldedEvents += 1 }
          continuation.yield(.completed)
        }
        continuation.finish()
        self.lock.withLock { self.activeStreams -= 1 }
      }
      // Deliberately no onTermination cancellation: this provider violates the
      // cooperative cancellation contract and keeps producing late events.
    }
  }

  func cancelActiveStreams() { lock.withLock { explicitCancellations += 1 } }
  var callCount: Int { lock.withLock { calls } }
  var activeStreamCount: Int { lock.withLock { activeStreams } }
  var yieldedEventCount: Int { lock.withLock { yieldedEvents } }
  var cancellationCount: Int { lock.withLock { explicitCancellations } }
}

private final class OrchestratorHistoryRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let lock = NSLock()
  private var events: [String] = []
  private var automaticTagAssignments: [(TaskID, [HistoryTag])] = []

  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult {
    lock.withLock { events.append("queued:\(command.runID.rawValue)") }
    return .init(runID: command.runID, wasCreated: true)
  }
  func markRunRunning(_ command: MarkRunRunningCommand) throws {
    lock.withLock { events.append("running:\(command.runID.rawValue)") }
  }
  func savePartialArtifact(_ command: SavePartialArtifactCommand) throws {
    lock.withLock { events.append("partial:\(command.bodyText)") }
  }
  func finishRun(_ command: FinishRunCommand) throws {
    lock.withLock { events.append("terminal:\(command.status.rawValue)") }
  }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func allTags() throws -> [HistoryTag] { [] }
  func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] {
    let tags = HistoryTagNormalizer.normalizedTags(rawNames)
    lock.withLock { automaticTagAssignments.append((taskID, tags)) }
    return tags
  }
  func removeTag(normalizedName _: String, from _: TaskID) throws {}
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
  var eventCount: Int { lock.withLock { events.count } }
  var terminalCount: Int { lock.withLock { events.filter { $0.hasPrefix("terminal:") }.count } }
  var tagAssignments: [(TaskID, [HistoryTag])] { lock.withLock { automaticTagAssignments } }
}

private final class RecordingSummaryTagGenerator: SummaryTagGenerating, @unchecked Sendable {
  enum Result: Sendable { case value(String), failure }
  private let lock = NSLock()
  private var results: [Result]
  private var requests: [(ProviderProfile, String)] = []

  init(results: [Result]) { self.results = results }

  func generateSummaryTags(profile: ProviderProfile, apiKey _: String, summary: String) async throws -> String {
    let result = lock.withLock { () -> Result in
      requests.append((profile, summary))
      return results.isEmpty ? .value("") : results.removeFirst()
    }
    switch result {
    case let .value(value): return value
    case .failure: throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    }
  }

  var callCount: Int { lock.withLock { requests.count } }
  var summaries: [String] { lock.withLock { requests.map(\.1) } }
  var models: [String] { lock.withLock { requests.map { $0.0.model } } }
}

private actor RunStateRecorder {
  private var updates: [(RunID, RunState)] = []

  func append(runID: RunID, state: RunState) {
    updates.append((runID, state))
  }

  var states: [RunState] {
    updates.map(\.1)
  }

  var lastState: RunState? {
    updates.last?.1
  }
}

final class ModelRunOrchestratorTests: XCTestCase {
  func testMissingProfileFailsWithoutCallingProvider() async throws {
    let provider = ScriptedModelProvider()
    let orchestrator = makeOrchestrator(provider: provider, profile: nil, secret: nil)
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .failed(
      intent: .summarize,
      code: ModelRunErrorCode.modelNotConfigured.rawValue
    ) }

    XCTAssertEqual(provider.callCount, 0)
  }

  func testSecretReadFailureDoesNotCallProvider() async throws {
    let provider = ScriptedModelProvider()
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: nil,
      failSecretRead: true
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .failed(
      intent: .summarize,
      code: ModelRunErrorCode.secretStoreReadFailed.rawValue
    ) }

    XCTAssertEqual(provider.callCount, 0)
  }

  func testEmptyCaptureFailsWithoutCallingProvider() async throws {
    let provider = ScriptedModelProvider()
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()

    await start(
      orchestrator,
      intent: .summarize,
      capture: capture(text: "   "),
      recorder: recorder
    )
    await waitUntil { await recorder.lastState == .failed(
      intent: .summarize,
      code: ModelRunErrorCode.captureContentEmpty.rawValue
    ) }

    XCTAssertEqual(provider.callCount, 0)
  }

  func testSummarizeAndTranslateBuildCaptureIntentsWithDefaultLanguage() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.event(.delta("摘要")), .event(.completed)]),
      .init(steps: [.event(.delta("翻译")), .event(.completed)])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()
    let currentCapture = capture(title: "Fixture title", text: "Fixture body")

    await start(orchestrator, intent: .summarize, capture: currentCapture, recorder: recorder)
    await waitUntil { provider.callCount == 1 }
    await waitUntil { await recorder.lastState == .completed(intent: .summarize, text: "摘要") }

    await start(orchestrator, intent: .translate, capture: currentCapture, recorder: recorder)
    await waitUntil { provider.callCount == 2 }
    await waitUntil { await recorder.lastState == .completed(intent: .translate, text: "翻译") }

    XCTAssertEqual(provider.intents, [
      .summarize(
        title: "Fixture title",
        text: "Fixture body",
        prompt: ModelPreferences.summaryPrompt(
          configuredPrompt: ModelPreferences.defaultSummaryPrompt,
          outputLanguage: ModelPreferences.defaultTargetLanguage
        )
      ),
      .translate(
        title: "Fixture title",
        text: "Fixture body",
        targetLanguage: "简体中文"
      )
    ])
    XCTAssertEqual(provider.keyPresence, [true, true])
  }

  func testDeltasAccumulateInOrderAndComplete() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [
        .event(.delta("第一段")),
        .event(.delta("第二段")),
        .event(.completed)
      ])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil {
      await recorder.lastState == .completed(intent: .summarize, text: "第一段第二段")
    }

    let states = await recorder.states
    XCTAssertTrue(states.contains(.streaming(intent: .summarize, partialText: "第一段")))
    XCTAssertTrue(states.contains(.streaming(intent: .summarize, partialText: "第一段第二段")))
  }

  func testCompletedSummaryAddsNormalizedAutomaticTagsFromSummaryOnlyUsingSameModel() async throws {
    let provider = ScriptedModelProvider(scripts: [.init(steps: [.event(.delta("本地总结文本")), .event(.completed)])])
    let tags = RecordingSummaryTagGenerator(results: [.value("人工智能, Swift, 人工智能\n这行必须忽略")])
    let repository = OrchestratorHistoryRepository()
    let service = ProviderConfigurationService(
      profileStore: OrchestratorProfileStore(profile: try profile()),
      secretStore: OrchestratorSecretStore(value: "fixture-secret")
    )
    let orchestrator = ModelRunOrchestrator(
      configurationService: service,
      provider: provider,
      summaryTagGenerator: tags,
      history: HistoryApplicationService(repository: repository)
    )
    let recorder = RunStateRecorder()
    let request = PersistentRunRequest(runID: RunID(), taskID: TaskID(), snapshotID: ContentSnapshotID(), intent: .summarize)

    await orchestrator.start(request: request, capture: capture(text: "原文不能进入标签请求")) { runID, state in
      await recorder.append(runID: runID, state: state)
    }
    await waitUntil { await recorder.lastState == .completed(intent: .summarize, text: "本地总结文本") }
    await waitUntil { tags.callCount == 1 && repository.tagAssignments.count == 1 }

    XCTAssertEqual(tags.summaries, ["本地总结文本"])
    let expectedProfile = try profile()
    XCTAssertEqual(tags.models, [expectedProfile.model])
    XCTAssertEqual(repository.tagAssignments.first?.0, request.taskID)
    XCTAssertEqual(repository.tagAssignments.first?.1.map(\.name), ["人工智能", "Swift"])
  }

  func testAutomaticTaggingFailureOrEmptyParseNeverChangesCompletedRunAndTranslationsUseGeneratedText() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.event(.delta("第一份总结")), .event(.completed)]),
      .init(steps: [.event(.delta("第二份总结")), .event(.completed)]),
      .init(steps: [.event(.delta("翻译")), .event(.completed)]),
    ])
    let tags = RecordingSummaryTagGenerator(results: [.failure, .value(" , \n"), .value("译文标签")])
    let repository = OrchestratorHistoryRepository()
    let service = ProviderConfigurationService(
      profileStore: OrchestratorProfileStore(profile: try profile()),
      secretStore: OrchestratorSecretStore(value: "fixture-secret")
    )
    let orchestrator = ModelRunOrchestrator(
      configurationService: service,
      provider: provider,
      summaryTagGenerator: tags,
      history: HistoryApplicationService(repository: repository)
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .completed(intent: .summarize, text: "第一份总结") }
    await waitUntil { tags.callCount == 1 }
    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .completed(intent: .summarize, text: "第二份总结") }
    await waitUntil { tags.callCount == 2 }
    await start(orchestrator, intent: .translate, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .completed(intent: .translate, text: "翻译") }

    await waitUntil { tags.callCount == 3 && repository.tagAssignments.count == 1 }
    XCTAssertEqual(tags.summaries.last, "翻译")
    XCTAssertEqual(repository.tagAssignments.first?.1.map(\.name), ["译文标签"])
    let finalState = await recorder.lastState
    XCTAssertEqual(finalState, .completed(intent: .translate, text: "翻译"))
  }

  func testProviderEchoedSecretIsRedactedBeforeEnteringRunState() async throws {
    let submittedSecret = "sentinel-\(UUID().uuidString)"
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [
        .event(.delta(submittedSecret)),
        .event(.completed)
      ])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: submittedSecret
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil {
      await recorder.lastState == .completed(intent: .summarize, text: "[已隐藏]")
    }

    let states = await recorder.states
    XCTAssertFalse(String(describing: states).contains(submittedSecret))
  }

  func testProviderFailureWithoutPartialFailsAndWithPartialBecomesIncomplete() async throws {
    let failure = ModelProviderFailure(
      code: .networkInterrupted,
      retryable: true,
      hadOutput: false
    )
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.failure(failure)]),
      .init(steps: [.event(.delta("可保留")), .failure(failure)])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .failed(
      intent: .summarize,
      code: ModelProviderErrorCode.networkInterrupted.rawValue
    ) }

    await start(orchestrator, intent: .translate, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .incomplete(
      intent: .translate,
      partialText: "可保留",
      code: ModelProviderErrorCode.networkInterrupted.rawValue
    ) }
  }

  func testStopPublishesStoppedAndPreventsLateDelta() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [
        .event(.delta("先到")),
        .event(.delta("迟到"), delayMilliseconds: 250),
        .event(.completed)
      ])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil {
      await recorder.lastState == .streaming(intent: .summarize, partialText: "先到")
    }
    let stopStartedAt = ContinuousClock.now
    await orchestrator.stop()
    let stopElapsed = ContinuousClock.now - stopStartedAt
    try? await Task.sleep(for: .milliseconds(550))

    let states = await recorder.states
    XCTAssertLessThan(stopElapsed, .milliseconds(500))
    XCTAssertTrue(states.contains(.stopping(intent: .summarize, partialText: "先到")))
    XCTAssertEqual(states.last, .stopped(intent: .summarize, partialText: "先到"))
    XCTAssertFalse(states.contains { $0.outputText.contains("迟到") })
    XCTAssertEqual(provider.explicitCancellationCount, 1)
    XCTAssertGreaterThanOrEqual(provider.cancellationCount, 1)
  }

  func testStartingCallbackSuspensionStopAndSecondStartDoNotMismatchAuthority() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.event(.delta("new")), .event(.completed)])
    ])
    let orchestrator = makeOrchestrator(provider: provider, profile: try profile(), secret: "fixture-secret")
    let blocker = CallbackBlocker()
    let oldRecorder = RunStateRecorder(), newRecorder = RunStateRecorder()
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    let oldRequest = PersistentRunRequest(runID: RunID(), taskID: taskID, snapshotID: snapshotID, intent: .summarize)
    let ignoredRequest = PersistentRunRequest(runID: RunID(), taskID: taskID, snapshotID: snapshotID, intent: .translate)
    let newRequest = PersistentRunRequest(runID: RunID(), taskID: taskID, snapshotID: snapshotID, intent: .translate)
    let envelope = capture()

    let oldStart = Task {
      await orchestrator.start(request: oldRequest, capture: envelope) { runID, state in
        await oldRecorder.append(runID: runID, state: state)
        if case .starting = state { blocker.block() }
      }
    }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    await orchestrator.start(request: ignoredRequest, capture: envelope) { runID, state in
      await newRecorder.append(runID: runID, state: state)
    }
    XCTAssertEqual(provider.callCount, 0)
    await orchestrator.stop()
    await orchestrator.start(request: newRequest, capture: envelope) { runID, state in
      await newRecorder.append(runID: runID, state: state)
    }
    await waitUntil { await newRecorder.lastState == .completed(intent: .translate, text: "new") }
    blocker.release.signal()
    _ = await oldStart.value

    XCTAssertEqual(provider.callCount, 1)
    let oldLast = await oldRecorder.lastState
    let newLast = await newRecorder.lastState
    XCTAssertEqual(oldLast, .stopped(intent: .summarize, partialText: ""))
    XCTAssertEqual(newLast, .completed(intent: .translate, text: "new"))
  }

  func testStoppingCallbackSuspensionCannotCancelNewRun() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.event(.delta("old")), .event(.delta("late"), delayMilliseconds: 5_000)]),
      .init(steps: [.event(.delta("new")), .event(.completed)])
    ])
    let orchestrator = makeOrchestrator(provider: provider, profile: try profile(), secret: "fixture-secret")
    let blocker = CallbackBlocker()
    let oldRecorder = RunStateRecorder(), newRecorder = RunStateRecorder()
    let taskID = TaskID(), snapshotID = ContentSnapshotID(), envelope = capture()
    let oldRequest = PersistentRunRequest(runID: RunID(), taskID: taskID, snapshotID: snapshotID, intent: .summarize)
    let newRequest = PersistentRunRequest(runID: RunID(), taskID: taskID, snapshotID: snapshotID, intent: .translate)
    await orchestrator.start(request: oldRequest, capture: envelope) { runID, state in
      await oldRecorder.append(runID: runID, state: state)
      if case .stopping = state { blocker.block() }
    }
    await waitUntil { await oldRecorder.lastState == .streaming(intent: .summarize, partialText: "old") }

    let stopTask = Task { await orchestrator.stop() }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(provider.explicitCancellationCount, 1)
    await orchestrator.start(request: newRequest, capture: envelope) { runID, state in
      await newRecorder.append(runID: runID, state: state)
    }
    await waitUntil { await newRecorder.lastState == .completed(intent: .translate, text: "new") }
    blocker.release.signal()
    _ = await stopTask.value

    XCTAssertEqual(provider.explicitCancellationCount, 1)
    let newLast = await newRecorder.lastState
    XCTAssertEqual(newLast, .completed(intent: .translate, text: "new"))
  }

  func testStreamingCallbackSuspensionStopWinsWithoutCompletedUI() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [.event(.delta("committed")), .event(.completed)])
    ])
    let orchestrator = makeOrchestrator(provider: provider, profile: try profile(), secret: "fixture-secret")
    let blocker = CallbackBlocker(), recorder = RunStateRecorder()
    let request = PersistentRunRequest(runID: RunID(), taskID: TaskID(), snapshotID: ContentSnapshotID(), intent: .summarize)
    let envelope = capture()
    await orchestrator.start(request: request, capture: envelope) { runID, state in
      await recorder.append(runID: runID, state: state)
      if case .streaming = state { blocker.block() }
    }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    await orchestrator.stop()
    blocker.release.signal()

    let states = await recorder.states
    XCTAssertTrue(states.contains(.stopped(intent: .summarize, partialText: "committed")))
    XCTAssertFalse(states.contains(.completed(intent: .summarize, text: "committed")))
  }

  func testAdversarialProviderIgnoringCancellationCannotPublishLateOldDelta() async throws {
    let provider = AdversarialModelProvider()
    let service = ProviderConfigurationService(
      profileStore: OrchestratorProfileStore(profile: try profile()),
      secretStore: OrchestratorSecretStore(value: "fixture-secret")
    )
    let repository = OrchestratorHistoryRepository()
    let orchestrator = ModelRunOrchestrator(
      configurationService: service,
      provider: provider,
      history: HistoryApplicationService(repository: repository)
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { provider.callCount == 1 }
    await orchestrator.stop()
    await start(orchestrator, intent: .translate, capture: capture(), recorder: recorder)
    await waitUntil { await recorder.lastState == .completed(intent: .translate, text: "new") }
    let statesBeforeGate = await recorder.states
    let repositoryEventsBeforeGate = repository.eventCount
    let terminalsBeforeGate = repository.terminalCount
    try? await Task.sleep(for: .milliseconds(550))

    let states = await recorder.states
    XCTAssertEqual(states, statesBeforeGate)
    XCTAssertEqual(repository.eventCount, repositoryEventsBeforeGate)
    XCTAssertEqual(repository.terminalCount, terminalsBeforeGate)
    XCTAssertEqual(provider.activeStreamCount, 0)
    XCTAssertEqual(states.last, .completed(intent: .translate, text: "new"))
    XCTAssertFalse(states.contains { $0.outputText.contains("malicious-late-old") })
    XCTAssertGreaterThanOrEqual(provider.cancellationCount, 1)
    XCTAssertGreaterThanOrEqual(provider.yieldedEventCount, 4)
  }

  func testSecondStartIsIgnoredUntilActiveRunStopsThenNewRunIsIsolated() async throws {
    let provider = ScriptedModelProvider(scripts: [
      .init(steps: [
        .event(.delta("旧结果"), delayMilliseconds: 250),
        .event(.completed)
      ]),
      .init(steps: [
        .event(.delta("新结果")),
        .event(.completed)
      ])
    ])
    let orchestrator = makeOrchestrator(
      provider: provider,
      profile: try profile(),
      secret: "not-a-real-key"
    )
    let recorder = RunStateRecorder()

    await start(orchestrator, intent: .summarize, capture: capture(), recorder: recorder)
    await waitUntil { provider.callCount == 1 }
    await start(orchestrator, intent: .translate, capture: capture(), recorder: recorder)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(provider.callCount, 1)
    await orchestrator.stop()
    await start(orchestrator, intent: .translate, capture: capture(), recorder: recorder)
    await waitUntil {
      await recorder.lastState == .completed(intent: .translate, text: "新结果")
    }
    try? await Task.sleep(for: .milliseconds(350))

    let states = await recorder.states
    XCTAssertEqual(states.last, .completed(intent: .translate, text: "新结果"))
    XCTAssertFalse(states.contains { $0.outputText.contains("旧结果") })
  }

  private func makeOrchestrator(
    provider: ScriptedModelProvider,
    profile: ProviderProfile?,
    secret: String?,
    failSecretRead: Bool = false
  ) -> ModelRunOrchestrator {
    let service = ProviderConfigurationService(
      profileStore: OrchestratorProfileStore(profile: profile),
      secretStore: OrchestratorSecretStore(value: secret, failRead: failSecretRead)
    )
    return ModelRunOrchestrator(
      configurationService: service,
      provider: provider,
      history: HistoryApplicationService(repository: OrchestratorHistoryRepository())
    )
  }

  private func profile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "fixture-reference")
    )
  }

  private func capture(
    title: String? = "Fixture title",
    text: String = "Fixture body"
  ) -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(
      version: 1,
      requestId: UUID().uuidString,
      createdAt: "2026-07-14T00:00:00Z",
      source: .init(
        kind: "webpage",
        url: "https://example.test/article",
        title: title,
        platform: "test"
      ),
      capture: .init(
        method: "dom",
        text: text,
        characterCount: text.unicodeScalars.count,
        completeness: "current_visible",
        capturedAt: "2026-07-14T00:00:00Z"
      ),
      evidence: .init(sourceLabel: "fixture", usedCookie: false)
    )
  }

  private func start(
    _ orchestrator: ModelRunOrchestrator,
    intent: RunIntentKind,
    capture: CaptureEnvelopeV1?,
    recorder: RunStateRecorder
  ) async {
    let request = PersistentRunRequest(
      runID: RunID(),
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      intent: intent,
      targetLanguage: intent == .translate ? "简体中文" : nil
    )
    await orchestrator.start(request: request, capture: capture) { runID, state in
      await recorder.append(runID: runID, state: state)
    }
  }

  private func waitUntil(
    timeoutMilliseconds: UInt64 = 2_000,
    condition: @escaping @Sendable () async -> Bool
  ) async {
    let iterations = Int(timeoutMilliseconds / 10)
    for _ in 0..<iterations {
      if await condition() {
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
