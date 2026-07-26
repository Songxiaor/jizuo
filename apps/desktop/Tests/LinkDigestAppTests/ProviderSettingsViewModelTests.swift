import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestAdapters
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
  private let loadBarrier: SettingsAsyncBarrier?
  private var writes = 0

  init(profile: ProviderProfile? = nil, loadBarrier: SettingsAsyncBarrier? = nil) {
    self.profile = profile
    self.loadBarrier = loadBarrier
  }

  func load() async throws -> ProviderProfile? {
    if let loadBarrier { await loadBarrier.suspend() }
    return profile
  }

  func save(_ profile: ProviderProfile) async throws {
    writes += 1
    self.profile = profile
  }

  func delete() async throws {
    profile = nil
  }

  func writeCount() -> Int { writes }
}

private actor ViewModelSecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  private let failSave: Bool
  private let failRead: Bool
  private var writes = 0
  private var reads = 0

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
    writes += 1
    if failSave {
      throw SecretStoreFailure(operation: .write, status: -1)
    }
    values[reference] = secret
  }

  func read(_ reference: SecretReference) async throws -> String? {
    reads += 1
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

  func writeCount() -> Int { writes }
  func readCount() -> Int { reads }
}

private actor ViewModelLibraryStore: ModelLibraryStore {
  private var library: ModelLibrary?

  init(_ library: ModelLibrary? = nil) { self.library = library }

  func load() async throws -> ModelLibrary? { library }
  func save(_ library: ModelLibrary) async throws { self.library = library }
}

private actor ViewModelPreferencesStore: ModelPreferencesStore {
  private var value: ModelPreferences
  private let loadBarrier: SettingsAsyncBarrier?
  private var writes = 0

  init(_ value: ModelPreferences = .default, loadBarrier: SettingsAsyncBarrier? = nil) {
    self.value = value
    self.loadBarrier = loadBarrier
  }

  func load() async throws -> ModelPreferences {
    if let loadBarrier { await loadBarrier.suspend() }
    return value
  }
  func save(_ preferences: ModelPreferences) async throws {
    writes += 1
    value = preferences
  }
  func writeCount() -> Int { writes }
  func storedValue() -> ModelPreferences { value }
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

private final class SettingsCatalogLoader: ModelCatalogLoading, @unchecked Sendable {
  enum Result: Sendable {
    case models([String])
    case failure(ModelProviderFailure)
  }

  private let result: Result
  private let barrier: SettingsAsyncBarrier?
  private let lock = NSLock()
  private var recordedBaseURLs: [URL] = []

  init(result: Result, barrier: SettingsAsyncBarrier? = nil) {
    self.result = result
    self.barrier = barrier
  }

  func listModels(baseURL: URL, apiKey _: String) async throws -> [String] {
    lock.withLock { recordedBaseURLs.append(baseURL) }
    if let barrier { await barrier.suspend() }
    switch result {
    case let .models(models): return models
    case let .failure(error): throw error
    }
  }

  var baseURLs: [URL] { lock.withLock { recordedBaseURLs } }
}

@MainActor
final class ProviderSettingsViewModelTests: XCTestCase {
  func testDirectSavePreferencesDuringLoadDoesNotWriteOrReplaceStoredValue() async throws {
    let persisted = try ModelPreferences(
      summaryPrompt: "已保存的提示词",
      outputLanguage: "Deutsch",
      translationModel: "saved-translation-model"
    )
    let barrier = SettingsAsyncBarrier()
    let store = ViewModelPreferencesStore(persisted, loadBarrier: barrier)
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )

    let loadTask = Task { await model.load() }
    await barrier.waitUntilEntered()
    XCTAssertFalse(model.canSavePreferences)
    model.summaryPrompt = "不应覆盖旧值"
    model.targetLanguage = "English"

    await model.savePreferences()

    let writesDuringLoad = await store.writeCount()
    let storedDuringLoad = await store.storedValue()
    XCTAssertEqual(writesDuringLoad, 0)
    XCTAssertEqual(storedDuringLoad, persisted)
    await barrier.release()
    await loadTask.value
    XCTAssertEqual(model.runPreferences, persisted)
  }

  func testPresetSelectionFillsEditableBaseURLAndManualEditBecomesCustom() async throws {
    let existing = try profile()
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: existing),
        secretStore: ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
      ),
      provider: SettingsTestProvider(scripts: [])
    )
    await model.load()

    model.selectPreset(.deepInfra)
    XCTAssertEqual(model.selectedPreset, .deepInfra)
    XCTAssertEqual(model.baseURL, ProviderPreset.deepInfra.baseURLTemplate)
    XCTAssertTrue(model.hasUnsavedIdentityChanges)

    model.baseURL = "https://gateway.example.test/v1"
    XCTAssertEqual(model.selectedPreset, .custom)
    XCTAssertEqual(model.baseURL, "https://gateway.example.test/v1")
  }

  func testSavedModelCatalogSuccessCapsAtFiveHundredAndSelectionRemainsEditable() async throws {
    let existing = try profile()
    let models = (0..<550).map { String(format: "model-%03d", $0) }
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: existing),
        secretStore: ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
      ),
      provider: SettingsTestProvider(scripts: []),
      modelCatalogLoader: SettingsCatalogLoader(result: .models(models))
    )
    await model.load()

    await model.loadModels()

    XCTAssertEqual(model.modelCatalogState, .loaded)
    XCTAssertEqual(model.availableModels.count, 500)
    model.modelSearchQuery = "model-149"
    XCTAssertEqual(model.filteredModels, ["model-149"])
    model.selectModel("model-149")
    XCTAssertEqual(model.modelName, "model-149")
  }

  func testFirstConfigurationLoadsModelsFromUnsavedBaseURLWithoutSelectingFirstItem() async throws {
    let loader = SettingsCatalogLoader(result: .models(["model-b", "model-a"]))
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      modelCatalogLoader: loader
    )
    await model.load()
    model.baseURL = "https://gateway.example.test/v1"

    await model.loadModels(apiKey: "fake-key-for-catalog-only")

    XCTAssertEqual(model.modelCatalogState, .loaded)
    XCTAssertEqual(model.availableModels, ["model-b", "model-a"])
    XCTAssertEqual(model.modelName, "", "catalog success must not silently choose a model")
    XCTAssertFalse(model.canSaveConfiguration)
    XCTAssertEqual(loader.baseURLs.map(\.absoluteString), ["https://gateway.example.test/v1"])

    model.selectModel("model-a")
    XCTAssertEqual(model.modelCatalogState, .loaded, "selecting a returned model must keep the picker available")
    XCTAssertTrue(model.canSaveConfiguration)
  }

  func testCatalogAllowsMultiSelectionAndSavesAllModelsTogether() async throws {
    let secretStore = ViewModelSecretStore()
    let configuration = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: secretStore,
      libraryStore: ViewModelLibraryStore()
    )
    let model = ProviderSettingsViewModel(
      configurationService: configuration,
      provider: SettingsTestProvider(scripts: []),
      modelCatalogLoader: SettingsCatalogLoader(result: .models(["model-a", "model-b", "model-c"]))
    )
    await model.load()
    model.baseURL = "https://gateway.example.test/v1"

    await model.loadModels(apiKey: "shared-key")
    model.toggleCatalogModel("model-a")
    model.toggleCatalogModel("model-c")

    XCTAssertEqual(model.selectedCatalogModels, ["model-a", "model-c"])
    XCTAssertEqual(model.selectedCatalogModelCount, 2)
    XCTAssertTrue(model.canSaveConfiguration)

    await model.save(apiKey: "shared-key")

    XCTAssertEqual(model.libraryEntryDisplays.map(\.modelName), ["model-a", "model-c"])
    XCTAssertEqual(model.lastSavedProfileCount, 2)
    XCTAssertFalse(model.isEditorVisible)
    let secretWrites = await secretStore.writeCount()
    XCTAssertEqual(secretWrites, 1)
  }

  func testLibraryPresentationUsesFriendlyNamesAndFiltersTranscriptionModels() async throws {
    let configuration = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore(),
      libraryStore: ViewModelLibraryStore()
    )
    _ = try await configuration.addProfiles(
      baseURL: "https://api.stepfun.com/v1",
      models: ["stepaudio-2.5-asr", "step-3.7-flash"],
      apiKey: "fake-key"
    )
    let model = ProviderSettingsViewModel(
      configurationService: configuration,
      provider: SettingsTestProvider(scripts: [])
    )

    await model.load()

    XCTAssertEqual(
      model.libraryEntryDisplays.map(\.displayName),
      ["StepAudio 2.5 ASR", "Step 3.7 Flash"]
    )
    XCTAssertEqual(model.libraryEntryDisplays.map(\.title), ["阶跃星辰", "阶跃星辰"])
    XCTAssertEqual(model.transcriptionEntryDisplays.map(\.modelName), ["stepaudio-2.5-asr"])
    XCTAssertEqual(model.summaryEntryDisplays.map(\.modelName), ["step-3.7-flash"])
  }

  func testPresetSelectsRecommendedChatModelOnlyWhenCatalogActuallyContainsIt() async throws {
    let loader = SettingsCatalogLoader(result: .models(["embedding-model", "deepseek-v4-flash"]))
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      modelCatalogLoader: loader
    )
    await model.load()
    model.selectPreset(.deepSeek)

    await model.loadModels(apiKey: "fake-key")

    XCTAssertEqual(model.modelName, "deepseek-v4-flash")
    XCTAssertTrue(model.canSaveConfiguration)
  }

  func testBaseURLAndAPIKeyDraftChangesInvalidateOldCatalogResults() async throws {
    let barrier = SettingsAsyncBarrier()
    let loader = SettingsCatalogLoader(result: .models(["late-model"]), barrier: barrier)
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      modelCatalogLoader: loader
    )
    await model.load()
    model.baseURL = "https://first.example.test/v1"

    let request = Task { await model.loadModels(apiKey: "fake-key") }
    await barrier.waitUntilEntered()
    model.baseURL = "https://second.example.test/v1"
    await barrier.release()
    await request.value

    XCTAssertEqual(model.modelCatalogState, .idle)
    XCTAssertEqual(model.availableModels, [])

    await model.loadModels(apiKey: "fake-key")
    XCTAssertEqual(model.modelCatalogState, .loaded)
    model.apiKeyDraftDidChange()
    XCTAssertEqual(model.modelCatalogState, .idle)
    XCTAssertEqual(model.availableModels, [])
  }

  func testCatalogFailuresUseFixedLocalCopyAndRequireExplicitManualFallback() async throws {
    let cases: [(ModelProviderErrorCode, String)] = [
      (.authInvalid, "API Key"),
      (.endpointNotFound, "404"),
      (.networkInterrupted, "网络"),
      (.inputTooLarge, "1 MiB"),
      (.protocolIncompatible, "协议不兼容"),
    ]
    for (code, marker) in cases {
      let model = ProviderSettingsViewModel(
        configurationService: ProviderConfigurationService(
          profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
        ),
        provider: SettingsTestProvider(scripts: []),
        modelCatalogLoader: SettingsCatalogLoader(result: .failure(.init(
          code: code, retryable: false, hadOutput: false
        )))
      )
      await model.load()
      model.baseURL = "https://gateway.example.test/v1"

      await model.loadModels(apiKey: "fake-key")

      XCTAssertEqual(model.modelCatalogState, .failed(code: code))
      XCTAssertTrue(model.modelCatalogStatusText.contains(marker))
      XCTAssertTrue(model.shouldOfferManualModelEntry)
      XCTAssertFalse(model.isManualModelEntryEnabled)
      model.enableManualModelEntry()
      XCTAssertTrue(model.isManualModelEntryEnabled)
      XCTAssertFalse(model.shouldOfferManualModelEntry)
    }
  }

  func testModelCatalogFailureAndTimeoutKeepManualModelValue() async throws {
    for failure in [
      ModelProviderFailure(code: .providerUnavailable, retryable: true, hadOutput: false),
      ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    ] {
      let existing = try profile()
      let model = ProviderSettingsViewModel(
        configurationService: ProviderConfigurationService(
          profileStore: ViewModelProfileStore(profile: existing),
          secretStore: ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
        ),
        provider: SettingsTestProvider(scripts: []),
        modelCatalogLoader: SettingsCatalogLoader(result: .failure(failure))
      )
      await model.load()
      let original = model.modelName

      await model.loadModels()

      XCTAssertEqual(model.modelCatalogState, .failed(code: failure.code))
      XCTAssertEqual(model.modelName, original)
      XCTAssertTrue(model.modelCatalogStatusText.contains("手动填写"))
    }
  }

  func testTranslationModelPreferencePersistsAcrossRestart() async throws {
    let store = ViewModelPreferencesStore()
    let first = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )
    await first.load()
    first.targetLanguage = "日本語"
    first.usesSeparateTranslationModel = true
    first.translationModelName = "translation-model"
    await first.savePreferences()

    let restarted = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(), secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )
    await restarted.load()

    XCTAssertEqual(restarted.runPreferences.outputLanguage, "日本語")
    XCTAssertEqual(restarted.runPreferences.translationModel, "translation-model")
    XCTAssertTrue(restarted.usesSeparateTranslationModel)
  }

  func testGenerationPreferencesLoadValidateSaveAndBecomeRunPreferences() async throws {
    let initial = try ModelPreferences(
      summaryPrompt: "默认测试模板",
      targetLanguage: "日本語"
    )
    let store = ViewModelPreferencesStore(initial)
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(),
        secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )

    await model.load()
    XCTAssertEqual(model.runPreferences, initial)
    model.summaryPrompt = "自定义总结模板"
    model.targetLanguage = "Español"
    await model.savePreferences()

    XCTAssertEqual(
      model.runPreferences,
      try ModelPreferences(summaryPrompt: "自定义总结模板", targetLanguage: "Español")
    )
    XCTAssertEqual(model.preferencesState, .saved)
  }

  func testResetSummaryPromptRestoresBuiltInTemplateBeforeSaving() async throws {
    let store = ViewModelPreferencesStore()
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(),
        secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )
    await model.load()
    model.summaryPrompt = "本次自定义提示词"

    model.resetSummaryPrompt()

    XCTAssertEqual(model.summaryPrompt, ModelPreferences.defaultSummaryPrompt)
    await model.savePreferences()
    XCTAssertEqual(model.runPreferences.summaryPrompt, ModelPreferences.defaultSummaryPrompt)
  }

  func testInitialAPIKeyEntryUsesNeutralGuidanceUntilSaveIsAttempted() async {
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: nil),
        secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: [])
    )

    await model.load()

    XCTAssertEqual(model.state, .unconfigured)
    XCTAssertTrue(model.shouldShowAPIKeyInput)
    XCTAssertFalse(model.isReplacingAPIKey)
    XCTAssertEqual(model.statusText, "先验证模型列表并选择模型，再保存；LinkDigest 不会回显完整 API Key。")
  }

  func testEmptyAPIKeyShowsErrorOnlyAfterExplicitSaveAttempt() async {
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: nil),
        secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: [])
    )
    await model.load()
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    XCTAssertEqual(model.statusText, "先验证模型列表并选择模型，再保存；LinkDigest 不会回显完整 API Key。")

    await model.save(apiKey: "  \n")

    XCTAssertEqual(model.state, .failed(code: ProviderConfigurationError.apiKeyRequired.rawValue))
    XCTAssertTrue(model.statusText.contains("API Key 不能为空"))
    XCTAssertTrue(model.shouldShowAPIKeyInput)
  }

  func testConfiguredAPIKeyCanEnterReplacementModeWithoutExposingSecret() async throws {
    let existing = try profile()
    let secretStore = ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
    let provider = SettingsTestProvider(scripts: [])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: existing),
        secretStore: secretStore
      ),
      provider: provider
    )

    await model.load()

    XCTAssertTrue(model.hasConfiguredAPIKey)
    XCTAssertFalse(model.shouldShowAPIKeyInput)
    XCTAssertEqual(model.apiKeyStatusText, "✓ 已配置")
    XCTAssertFalse(model.canSaveConfiguration, "unchanged configured rows must not submit an empty replacement key")
    XCTAssertTrue(model.canTestConnection)
    model.beginAPIKeyReplacement()
    XCTAssertTrue(model.isReplacingAPIKey)
    XCTAssertTrue(model.shouldShowAPIKeyInput)
    XCTAssertTrue(model.canSaveConfiguration)
    XCTAssertFalse(model.canTestConnection, "replacement mode must not test the old saved key")

    await model.save(apiKey: "replacement-not-a-real-key")

    XCTAssertTrue(model.hasConfiguredAPIKey)
    XCTAssertFalse(model.isReplacingAPIKey)
    XCTAssertFalse(model.shouldShowAPIKeyInput)
    XCTAssertFalse(model.canSaveConfiguration)
    XCTAssertTrue(model.canTestConnection)
    XCTAssertFalse(model.statusText.contains("replacement-not-a-real-key"))
  }

  func testDirectConnectionTestDuringReplacementDoesNotReadOrCallProvider() async throws {
    let existing = try profile()
    let secretStore = ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
    let provider = SettingsTestProvider(scripts: [])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: existing),
        secretStore: secretStore
      ),
      provider: provider
    )
    await model.load()
    model.beginAPIKeyReplacement()

    await model.testConnection()

    XCTAssertTrue(provider.intents.isEmpty)
    let readCount = await secretStore.readCount()
    XCTAssertEqual(readCount, 0)
    XCTAssertEqual(model.connectionTestState, .blockedUnsavedChanges)
  }

  func testDirectSaveDoesNotWriteConfiguredProfileUnlessReplacing() async throws {
    let existing = try profile()
    let profileStore = ViewModelProfileStore(profile: existing)
    let secretStore = ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: profileStore,
        secretStore: secretStore
      ),
      provider: SettingsTestProvider(scripts: [])
    )
    await model.load()

    await model.save(apiKey: "must-not-be-written")

    XCTAssertEqual(model.state, .configured)
    let profileWrites = await profileStore.writeCount()
    let secretWrites = await secretStore.writeCount()
    XCTAssertEqual(profileWrites, 0)
    XCTAssertEqual(secretWrites, 0)
  }

  func testDirectSaveDuringConfigurationLoadDoesNotWrite() async throws {
    let existing = try profile()
    let barrier = SettingsAsyncBarrier()
    let profileStore = ViewModelProfileStore(profile: existing, loadBarrier: barrier)
    let secretStore = ViewModelSecretStore(values: [existing.secretReference: "not-a-real-key"])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: profileStore,
        secretStore: secretStore
      ),
      provider: SettingsTestProvider(scripts: [])
    )

    let loadTask = Task { await model.load() }
    await barrier.waitUntilEntered()
    XCTAssertTrue(model.isConfigurationLoading)

    await model.save(apiKey: "must-not-be-written")

    let profileWrites = await profileStore.writeCount()
    let secretWrites = await secretStore.writeCount()
    XCTAssertEqual(profileWrites, 0)
    XCTAssertEqual(secretWrites, 0)
    await barrier.release()
    await loadTask.value
    XCTAssertEqual(model.state, .configured)
  }

  func testStartupLoadRestoresPersistedPreferencesWithoutOpeningSettings() async throws {
    let suite = "com.syc.linkdigest.preferences-bootstrap-tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let persisted = try ModelPreferences(
      summaryPrompt: "重启后首次总结必须使用这条 prompt",
      targetLanguage: "Español"
    )
    let store = UserDefaultsModelPreferencesStore(suiteName: suite)
    try await store.save(persisted)
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(),
        secretStore: ViewModelSecretStore()
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: store
    )

    XCTAssertFalse(model.arePreferencesReady, "composition must disable generation before its startup load")
    await model.load()

    XCTAssertTrue(model.arePreferencesReady)
    XCTAssertEqual(model.runPreferences.summaryPrompt, persisted.summaryPrompt)
    XCTAssertEqual(model.runPreferences.targetLanguage, persisted.targetLanguage)
  }

  func testSecretFailureIsRecoverableAndObservableStateDoesNotExposeKey() async {
    let service = ProviderConfigurationService(
      profileStore: ViewModelProfileStore(),
      secretStore: ViewModelSecretStore(failSave: true)
    )
    let model = ProviderSettingsViewModel(
      configurationService: service,
      provider: SettingsTestProvider(scripts: [])
    )
    await model.load()
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
    await model.load()
    model.baseURL = "https://example.test/v1"
    model.modelName = "fixture-model"
    let submittedSecret = UUID().uuidString

    await model.save(apiKey: submittedSecret)

    XCTAssertEqual(model.state, .configured)
    XCTAssertEqual(model.statusText, "模型配置已保存")
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
      .providerBillingLimited,
      .modelNotFound,
      .endpointNotFound,
      .providerRequestRejected,
      .rateLimited,
      .providerUnavailable,
      .networkInterrupted,
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
      XCTAssertEqual(
        model.connectionTestStatusText,
        V02ErrorCatalog.presentation(for: code.rawValue).visibleText
      )
      XCTAssertFalse(model.connectionTestStatusText.contains(code.rawValue))
    }
  }

  func testConnectionBillingFailureUsesFixedLocalCopy() async throws {
    let profile = try profile()
    let submittedSecret = "not-a-real-key"
    let responseBodyMarker = "provider-body-marker-\(UUID().uuidString)"
    let provider = SettingsTestProvider(scripts: [
      .failure(.init(
        code: .providerBillingLimited,
        retryable: false,
        hadOutput: false
      ))
    ])
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(profile: profile),
        secretStore: ViewModelSecretStore(values: [profile.secretReference: submittedSecret])
      ),
      provider: provider
    )
    await model.load()

    await model.testConnection()

    XCTAssertEqual(
      model.connectionTestState,
      .failure(code: ModelProviderErrorCode.providerBillingLimited.rawValue)
    )
    XCTAssertEqual(
      model.connectionTestStatusText,
      V02ErrorCatalog.presentation(for: ModelProviderErrorCode.providerBillingLimited.rawValue).visibleText
    )
    XCTAssertTrue(model.connectionTestStatusText.contains("服务商控制台"))
    XCTAssertFalse(model.connectionTestStatusText.contains(responseBodyMarker))
    XCTAssertFalse(model.connectionTestStatusText.contains(submittedSecret))
  }

  func testConnectionNeverRendersProviderBodyFixtures() async throws {
    let leakedValue = "leak-marker-\(UUID().uuidString)"
    let fixtures: [(name: String, payload: String)] = [
      ("newline key", "ordinary text\nKey: \(leakedValue)"),
      ("key assignment", "key=\(leakedValue)"),
      ("secret assignment", "secret=\(leakedValue)"),
      ("token assignment", "token=\(leakedValue)"),
      ("password assignment", "password=\(leakedValue)"),
      ("URL userinfo", "https://user:\(leakedValue)@provider.example.test/help"),
      ("username-only URL userinfo", "https://\(leakedValue)@provider.example.test/help"),
      ("URL query key", "https://provider.example.test/help?key=\(leakedValue)"),
      ("access token", "access_token=\(leakedValue)"),
      ("client secret", "client_secret: \(leakedValue)"),
      ("private key", "privateKey=\(leakedValue)"),
      ("access key", "accessKey=\(leakedValue)"),
      ("refresh token", "refreshToken=\(leakedValue)"),
      ("JSON client secret", #"{"client_secret":"\#(leakedValue)"}"#),
      ("folded URL userinfo", "ordinary https://user:\n\(leakedValue)@host.test/help"),
      ("X API key", "X_API_KEY=\(leakedValue)"),
      ("API key hyphen", "api-key=\(leakedValue)"),
      ("session token", "sessionToken=\(leakedValue)"),
      ("bare bearer", "Bearer \(leakedValue)"),
      ("pwd assignment", "pwd=\(leakedValue)"),
      ("base64 prefix", "Base64: \(leakedValue)"),
      ("normalized sk project", "sk-proj-\(leakedValue)")
    ]

    for fixture in fixtures {
      let profile = try profile()
      let failure = ModelProviderFailure(
        code: .providerRequestRejected,
        retryable: false,
        hadOutput: false
      )
      let model = ProviderSettingsViewModel(
        configurationService: ProviderConfigurationService(
          profileStore: ViewModelProfileStore(profile: profile),
          secretStore: ViewModelSecretStore(values: [profile.secretReference: "not-a-real-key"])
        ),
        provider: SettingsTestProvider(scripts: [.failure(failure)])
      )
      await model.load()

      await model.testConnection()

      XCTAssertEqual(
        model.connectionTestState,
        .failure(code: ModelProviderErrorCode.providerRequestRejected.rawValue),
        fixture.name
      )
      XCTAssertFalse(String(describing: model.connectionTestState).contains(leakedValue), fixture.name)
      XCTAssertFalse(model.connectionTestStatusText.contains(leakedValue), fixture.name)
      XCTAssertFalse(model.connectionTestStatusText.contains(fixture.payload), fixture.name)
      XCTAssertEqual(
        model.connectionTestStatusText,
        V02ErrorCatalog.presentation(for: ModelProviderErrorCode.providerRequestRejected.rawValue).visibleText,
        fixture.name
      )
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
    model.beginAPIKeyReplacement()

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

// MARK: - 在线转写模型解析

@MainActor
final class EffectiveTranscriptionModelNameTests: XCTestCase {
  /// 回归：设置页「视频转文字」下拉选好了模型（assignment 已设），但旧的
  /// 手填模型名从未填过。曾因此处只读手填字段而返回 nil，导致设置显示
  /// 已配置、「在线转写」菜单却永远置灰说未配置。
  func testAssignmentAloneYieldsProfileModelName() async throws {
    let profile = try ProviderProfile(
      id: "step-asr",
      baseURL: "https://api.stepfun.com/v1",
      model: "stepaudio-2.5-asr",
      secretReference: .init(rawValue: "test-step-asr")
    )
    let library = ModelLibrary(profiles: [profile], transcriptionProfileID: "step-asr")
    let model = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: ViewModelProfileStore(),
        secretStore: ViewModelSecretStore(),
        libraryStore: ViewModelLibraryStore(library)
      ),
      provider: SettingsTestProvider(scripts: []),
      preferencesStore: ViewModelPreferencesStore()
    )

    await model.refreshLibrary()

    XCTAssertEqual(model.transcriptionAssignmentID, "step-asr")
    XCTAssertEqual(model.effectiveTranscriptionModelName, "stepaudio-2.5-asr")

    // 手填字段仍然是显式覆盖。
    model.transcriptionModelName = "whisper-override"
    XCTAssertEqual(model.effectiveTranscriptionModelName, "whisper-override")

    // 没有 assignment 时保持 nil（本机 Apple Speech 默认，不得误亮在线入口）。
    await model.assignTranscriptionModel(nil)
    XCTAssertNil(model.transcriptionAssignmentID)
    XCTAssertNil(model.effectiveTranscriptionModelName)
  }
}
