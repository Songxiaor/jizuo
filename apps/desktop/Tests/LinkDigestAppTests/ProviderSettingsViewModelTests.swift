import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

private actor SettingsAsyncBarrier {
  private var entered = false
  private var released = false
  private var blockedContinuations: [CheckedContinuation<Void, Never>] = []
  private var entryContinuations: [CheckedContinuation<Void, Never>] = []

  func suspend() async {
    entered = true
    let observers = entryContinuations
    entryContinuations.removeAll()
    observers.forEach { $0.resume() }
    guard !released else { return }
    await withCheckedContinuation { blockedContinuations.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryContinuations.append($0) }
  }

  func release() {
    released = true
    let continuations = blockedContinuations
    blockedContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }
}

private actor ViewModelProfileStore: ProviderProfileStore {
  private var profile: ProviderProfile?

  init(profile: ProviderProfile? = nil) {
    self.profile = profile
  }

  func load() async throws -> ProviderProfile? {
    profile
  }

  func save(_ profile: ProviderProfile) async throws {
    self.profile = profile
  }

  func delete() async throws {
    profile = nil
  }
}

private actor ViewModelSecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  private let failSave: Bool
  private let failRead: Bool

  init(
    values: [SecretReference: String] = [:],
    failSave: Bool = false,
    failRead: Bool = false
  ) {
    self.values = values
    self.failSave = failSave
    self.failRead = failRead
  }

  func save(_ secret: String, for reference: SecretReference) async throws {
    if failSave {
      throw SecretStoreFailure(operation: .write, status: -1)
    }
    values[reference] = secret
  }

  func read(_ reference: SecretReference) async throws -> String? {
    if failRead {
      throw SecretStoreFailure(operation: .read, status: -1)
    }
    return values[reference]
  }

  func contains(_ reference: SecretReference) async throws -> Bool {
    values[reference] != nil
  }

  func delete(_ reference: SecretReference) async throws {
    values.removeValue(forKey: reference)
  }
}

private final class SettingsTestProvider: ModelProvider, @unchecked Sendable {
  enum Script: Sendable {
    case success
    case failure(ModelProviderFailure)
    case malformedCompletion
    case blocked(SettingsAsyncBarrier)
  }

  private let lock = NSLock()
  private var scripts: [Script]
  private var recordedIntents: [RunIntent] = []
  private var recordedIdentities: [DataDestinationIdentity] = []
  private var maxConcurrentCalls = 0
  private var activeCalls = 0

  init(scripts: [Script]) { self.scripts = scripts }

  func stream(
    profile: ProviderProfile,
    apiKey _: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let script = lock.withLock { () -> Script in
      recordedIntents.append(intent)
      recordedIdentities.append(DataDestinationIdentity(profile: profile))
      activeCalls += 1
      maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)
      return scripts.removeFirst()
    }
    return AsyncThrowingStream { continuation in
      switch script {
      case .success:
        continuation.yield(.delta("OK"))
        continuation.yield(.completed)
        continuation.finish()
        self.finishCall()
      case let .failure(failure):
        continuation.finish(throwing: failure)
        self.finishCall()
      case .malformedCompletion:
        continuation.finish()
        self.finishCall()
      case let .blocked(barrier):
        let task = Task {
          await barrier.suspend()
          continuation.yield(.completed)
          continuation.finish()
          self.finishCall()
        }
        continuation.onTermination = { _ in
          task.cancel()
          self.finishCall()
        }
      }
    }
  }

  func cancelActiveStreams() {}
  var intents: [RunIntent] { lock.withLock { recordedIntents } }
  var identities: [DataDestinationIdentity] { lock.withLock { recordedIdentities } }
  var maximumConcurrentCalls: Int { lock.withLock { maxConcurrentCalls } }

  private func finishCall() {
    lock.withLock { activeCalls = max(0, activeCalls - 1) }
  }
}

@MainActor
final class ProviderSettingsViewModelTests: XCTestCase {
  func testSecretFailureIsRecoverableAndObservableStateDoesNotExposeKey() async {
    let service = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore(failSave: true)
    )
    let model = ProviderSettingsViewModel(
      configurationService: service,
      provider: SettingsTestProvider(scripts: [])
    )
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    let submittedSecret = UUID().uuidString

    await model.save(apiKey: submittedSecret)

    XCTAssertEqual(
      model.state,
      .failed(code: ProviderConfigurationError.secretStoreWriteFailed.rawValue)
    )
    XCTAssertFalse(model.statusText.contains(submittedSecret))
    XCTAssertFalse(model.baseURL.contains(submittedSecret))
    XCTAssertFalse(model.modelName.contains(submittedSecret))
  }

  func testSuccessfulSaveShowsFixedMaskWithoutExposingKey() async {
    let service = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore()
    )
    let model = ProviderSettingsViewModel(
      configurationService: service,
      provider: SettingsTestProvider(scripts: [])
    )
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    let submittedSecret = UUID().uuidString

    await model.save(apiKey: submittedSecret)

    XCTAssertEqual(model.state, .configured)
    XCTAssertEqual(model.statusText, "API Key：••••••••（已保存）")
    XCTAssertFalse(model.statusText.contains(submittedSecret))
  }

  func testConnectionSuccessUsesConnectionIntentAndNeverSavesResponse() async throws {
    let profile = try profile()
    let provider = SettingsTestProvider(scripts: [.success])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
      ),
      provider: provider
    )
    await model.load()

    await model.testConnection()

    XCTAssertEqual(model.connectionTestState, ConnectionTestState.success)
    XCTAssertEqual(provider.intents, [.connectionTest])
    XCTAssertFalse(model.connectionTestStatusText.contains("not-a-real-key"))
  }

  func testConnectionMapsProviderFailuresToSafeCatalog() async throws {
    for code in [
      ModelProviderErrorCode.authInvalid,
      .rateLimited,
      .providerUnavailable,
      .streamMalformed
    ] {
      let profile = try profile()
      let provider = SettingsTestProvider(scripts: [.failure(.init(code: code, retryable: true, hadOutput: false))])
      let model = ProviderSettingsViewModel(
        configurationService: ProviderConfigurationService(
          profileStore: ViewModelProfileStore(profile: profile),
          secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
        ),
        provider: provider
      )
      await model.load()

      await model.testConnection()

      XCTAssertEqual(model.connectionTestState, ConnectionTestState.failure(code: code.rawValue))
      XCTAssertFalse(model.connectionTestStatusText.contains(code.rawValue))
    }
  }

  func testConnectionMissingConfigurationAndSecretReadFailureDoNotCallProvider() async throws {
    let missingProvider = SettingsTestProvider(scripts: [])
    let missing = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: nil),
        secretStore: ViewModelSecretStore()
      ),
      provider: missingProvider
    )
    await missing.load()
    await missing.testConnection()
    XCTAssertEqual(missing.connectionTestState, .blockedUnsavedChanges)
    XCTAssertEqual(missing.connectionTestStatusText, "有未保存更改，请先保存后再测试")
    XCTAssertTrue(missingProvider.intents.isEmpty)

    let profile = try profile()
    let secretProvider = SettingsTestProvider(scripts: [])
    let secretFailure = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(
          values: [profile.secretReference: "not-a-real-key"],
          failRead: true
        )
      ),
      provider: secretProvider
    )
    await secretFailure.load()
    await secretFailure.testConnection()
    XCTAssertEqual(secretFailure.connectionTestState, ConnectionTestState.failure(code: ProviderConfigurationError.secretStoreReadFailed.rawValue))
    XCTAssertTrue(secretProvider.intents.isEmpty)
  }

  func testConnectionRepeatedTapDoesNotRunConcurrently() async throws {
    let profile = try profile()
    let barrier = SettingsAsyncBarrier()
    let provider = SettingsTestProvider(scripts: [.blocked(barrier)])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
      ),
      provider: provider
    )
    await model.load()

    let first = Task { await model.testConnection() }
    await barrier.waitUntilEntered()
    await model.testConnection()

    XCTAssertEqual(provider.intents, [.connectionTest])
    XCTAssertEqual(provider.maximumConcurrentCalls, 1)
    await barrier.release()
    await first.value
  }

  func testEditingDestinationInvalidatesOldSuccessfulConnectionState() async throws {
    let profile = try profile()
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
      ),
      provider: SettingsTestProvider(scripts: [.success])
    )
    await model.load()
    await model.testConnection()
    XCTAssertEqual(model.connectionTestState, ConnectionTestState.success)

    model.modelName = "changed-model"
    XCTAssertEqual(model.connectionTestState, .blockedUnsavedChanges)
  }

  func testUnsavedDraftNeverCallsProvider() async throws {
    let profile = try profile()
    let provider = SettingsTestProvider(scripts: [])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
      ),
      provider: provider
    )
    await model.load()

    model.baseURL = "https://changed.example.test/v1"
    await model.testConnection()

    XCTAssertTrue(provider.intents.isEmpty)
    XCTAssertTrue(model.hasUnsavedIdentityChanges)
    XCTAssertEqual(model.connectionTestState, .blockedUnsavedChanges)
    XCTAssertEqual(model.connectionTestStatusText, "有未保存更改，请先保存后再测试")
  }

  func testEditingWhileTestIsBlockedDiscardsLateSuccess() async throws {
    let profile = try profile()
    let barrier = SettingsAsyncBarrier()
    let provider = SettingsTestProvider(scripts: [.blocked(barrier)])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
      ),
      provider: provider
    )
    await model.load()

    let testTask = Task { await model.testConnection() }
    await barrier.waitUntilEntered()
    model.modelName = "changed-model"
    await barrier.release()
    await testTask.value

    XCTAssertEqual(provider.intents, [.connectionTest])
    XCTAssertEqual(model.connectionTestState, .blockedUnsavedChanges)
    XCTAssertNotEqual(model.connectionTestState, .success)
  }

  func testSaveThenTestUsesNewSavedIdentity() async throws {
    let original = try profile()
    let provider = SettingsTestProvider(scripts: [.success])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: original),
        secretStore: ViewModelSecretStore(values: [original.secretReference: "old-key"]),
        makeSecretReference: { .init(rawValue: "new-reference") }
      ),
      provider: provider
    )
    await model.load()
    model.baseURL = "https://new.example.test/v1"
    model.modelName = "new-model"

    await model.save(apiKey: "new-key")
    await model.testConnection()

    let expected = try DataDestinationIdentity(
      baseURL: "https://new.example.test/v1",
      model: "new-model"
    )
    XCTAssertEqual(model.savedIdentity, expected)
    XCTAssertFalse(model.hasUnsavedIdentityChanges)
    XCTAssertEqual(provider.identities, [expected])
    XCTAssertEqual(model.connectionTestState, .success)
  }

  private func profile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: .init(rawValue: "fixture-reference")
    )
  }
}
