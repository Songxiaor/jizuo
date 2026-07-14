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
    model.receive(capture())

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
    model.receive(capture())

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
    model.receive(capture())

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

  func testStoppedMessageExplicitlyMarksResultIncomplete() async throws {
    let provider = AppTestModelProvider(results: [.pending])
    let model = try makeModel(provider: provider)
    model.receive(capture())

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
    secret: String = "not-a-real-key"
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
      provider: provider
    )
    return AppViewModel(modelRunOrchestrator: orchestrator)
  }

  private func capture() -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(
      version: 1,
      requestId: UUID().uuidString,
      createdAt: "2026-07-14T00:00:00Z",
      source: .init(
        kind: "webpage",
        url: "https://example.test/article",
        title: "Fixture title",
        platform: "test"
      ),
      capture: .init(
        method: "dom",
        text: "Fixture body",
        characterCount: "Fixture body".unicodeScalars.count,
        completeness: "current_visible",
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
