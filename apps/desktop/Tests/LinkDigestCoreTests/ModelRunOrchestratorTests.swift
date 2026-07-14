import Foundation
import XCTest
@testable import LinkDigestCore

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

private actor RunStateRecorder {
  private var updates: [(UUID, RunState)] = []

  func append(runID: UUID, state: RunState) {
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
      .init(steps: [.event(.completed)]),
      .init(steps: [.event(.completed)])
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
    await waitUntil { await recorder.lastState == .completed(intent: .summarize, text: "") }

    await start(orchestrator, intent: .translate, capture: currentCapture, recorder: recorder)
    await waitUntil { provider.callCount == 2 }
    await waitUntil { await recorder.lastState == .completed(intent: .translate, text: "") }

    XCTAssertEqual(provider.intents, [
      .summarize(title: "Fixture title", text: "Fixture body"),
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

  func testNewRunIsolatesOldDelayedEvents() async throws {
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
    return ModelRunOrchestrator(configurationService: service, provider: provider)
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
    await orchestrator.start(intent: intent, capture: capture) { runID, state in
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
