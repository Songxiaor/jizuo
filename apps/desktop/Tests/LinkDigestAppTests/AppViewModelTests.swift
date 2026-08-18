import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestAdapters
import LinkDigestCore

private actor AppAsyncBarrier {
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

private actor AppProfileStore: ProviderProfileStore {
  private var profile: ProviderProfile?
  private let failLoad: Bool
  private let loadBarrier: AppAsyncBarrier?
  private let blockedLoadCall: Int?
  private var loadCount = 0

  init(
    profile: ProviderProfile?,
    failLoad: Bool = false,
    loadBarrier: AppAsyncBarrier? = nil,
    blockedLoadCall: Int? = nil
  ) {
    self.profile = profile
    self.failLoad = failLoad
    self.loadBarrier = loadBarrier
    self.blockedLoadCall = blockedLoadCall
  }

  func load() async throws -> ProviderProfile? {
    loadCount += 1
    if blockedLoadCall == loadCount, let loadBarrier {
      await loadBarrier.suspend()
    }
    if failLoad { throw ProviderProfileStoreFailure.readFailed }
    return profile
  }
  func save(_ profile: ProviderProfile) async throws { self.profile = profile }
  func delete() async throws { profile = nil }
  func replace(_ value: ProviderProfile?) { profile = value }
  func loads() -> Int { loadCount }
}

private actor AppConsentStore: DataDestinationConsentStore {
  private var values: Set<DataDestinationIdentity>
  private let failRead: Bool
  private let failWrite: Bool
  private let readBarrier: AppAsyncBarrier?
  private let writeBarrier: AppAsyncBarrier?
  private var readCount = 0
  private var writeCount = 0

  init(
    values: Set<DataDestinationIdentity> = [],
    failRead: Bool = false,
    failWrite: Bool = false,
    readBarrier: AppAsyncBarrier? = nil,
    writeBarrier: AppAsyncBarrier? = nil
  ) {
    self.values = values
    self.failRead = failRead
    self.failWrite = failWrite
    self.readBarrier = readBarrier
    self.writeBarrier = writeBarrier
  }

  func isConfirmed(for identity: DataDestinationIdentity) async throws -> Bool {
    readCount += 1
    if let readBarrier { await readBarrier.suspend() }
    if failRead { throw DataDestinationConsentStoreFailure.readFailed }
    return values.contains(identity)
  }

  func rememberConfirmation(for identity: DataDestinationIdentity) async throws {
    writeCount += 1
    if let writeBarrier { await writeBarrier.suspend() }
    if failWrite { throw DataDestinationConsentStoreFailure.writeFailed }
    values.insert(identity)
  }

  func forgetAll() async throws { values.removeAll() }

  func reads() -> Int { readCount }
  func writes() -> Int { writeCount }
}

private actor AppSecretStore: SecretStore {
  private var secret: String?
  private let readBarrier: AppAsyncBarrier?
  private let failRead: Bool
  private var readCount = 0

  init(
    secret: String?,
    readBarrier: AppAsyncBarrier? = nil,
    failRead: Bool = false
  ) {
    self.secret = secret
    self.readBarrier = readBarrier
    self.failRead = failRead
  }

  func save(_ value: String, for _: SecretReference) async throws { secret = value }
  func read(_: SecretReference) async throws -> String? {
    readCount += 1
    if let readBarrier { await readBarrier.suspend() }
    if failRead { throw SecretStoreFailure(operation: .read, status: -1) }
    return secret
  }
  func contains(_: SecretReference) async throws -> Bool { secret != nil }
  func delete(_: SecretReference) async throws { secret = nil }
  func replace(_ value: String?) { secret = value }
  func reads() -> Int { readCount }
}

private final class AppHistoryRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let failPartial: Bool
  private let failTerminal: Bool
  private let failCreateRun: Bool
  private let blockCreateRun: Bool
  private let createRunRelease = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var captureCalls = 0
  private var createRunEntered = false
  private var createRunCommands: [CreateRunCommand] = []
  init(
    failPartial: Bool = false,
    failTerminal: Bool = false,
    failCreateRun: Bool = false,
    blockCreateRun: Bool = false
  ) {
    self.failPartial = failPartial
    self.failTerminal = failTerminal
    self.failCreateRun = failCreateRun
    self.blockCreateRun = blockCreateRun
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
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult {
    lock.withLock {
      createRunEntered = true
      createRunCommands.append(command)
    }
    if blockCreateRun { createRunRelease.wait() }
    if failCreateRun { throw RepositoryFailure.injectedFailure }
    return .init(runID: command.runID, wasCreated: true)
  }
  var didEnterCreateRun: Bool { lock.withLock { createRunEntered } }
  var createdRunCommands: [CreateRunCommand] { lock.withLock { createRunCommands } }
  func releaseCreateRun() { createRunRelease.signal() }
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
    case pendingWithPrefix(String)
  }

  private let lock = NSLock()
  private var results: [Result]
  private var recordedIntents: [RunIntent] = []
  private var recordedModels: [String] = []
  private var recordedKeyPresence: [Bool] = []

  init(results: [Result]) {
    self.results = results
  }

  func stream(
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let result = lock.withLock { () -> Result in
      recordedIntents.append(intent)
      recordedModels.append(profile.model)
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
      case let .pendingWithPrefix(prefix):
        continuation.yield(.delta(prefix))
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

  var models: [String] {
    lock.withLock { recordedModels }
  }

  var keyPresence: [Bool] {
    lock.withLock { recordedKeyPresence }
  }
}

@MainActor
final class AppViewModelTests: XCTestCase {
  func testReceiverHealthAndLastBrowserDeliveryAreIndependentFromLocalHistorySelection() {
    let model = AppViewModel()
    XCTAssertEqual(model.browserReceiverState, .starting)
    XCTAssertNil(model.lastBrowserCaptureAt)

    model.setBrowserReceiverAvailable(true)
    XCTAssertEqual(model.browserReceiverState, .ready)

    let envelope = capture()
    model.receive(CurrentCapture(envelope: envelope, taskID: TaskID(), snapshotID: ContentSnapshotID()))
    let deliveredAt = model.lastBrowserCaptureAt
    XCTAssertNotNil(deliveredAt)

    model.receive(CurrentCapture(
      document: CapturedDocument(wire: envelope),
      taskID: TaskID(),
      snapshotID: ContentSnapshotID()
    ))
    XCTAssertEqual(model.lastBrowserCaptureAt, deliveredAt)

    model.setBrowserReceiverAvailable(false)
    XCTAssertEqual(model.browserReceiverState, .unavailable)
  }

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

  func testRestartedPreferencesDriveFirstSummaryAndTranslationWithoutOpeningSettings() async throws {
    let suite = ephemeralDefaultsSuiteName("com.syc.linkdigest.restart-run-preferences.")
    let persisted = try ModelPreferences(
      summaryPrompt: "重启后首次总结使用的自定义 prompt",
      targetLanguage: "Español"
    )
    let preferenceStore = UserDefaultsModelPreferencesStore(suiteName: suite)
    try await preferenceStore.save(persisted)
    let settings = ProviderSettingsViewModel(
      configurationService: ProviderConfigurationService(
        profileStore: AppProfileStore(profile: nil),
        secretStore: AppSecretStore(secret: nil, failRead: false)
      ),
      provider: AppTestModelProvider(results: []),
      preferencesStore: preferenceStore
    )

    await settings.load() // App bootstrap calls this before any Settings scene is opened.
    let provider = AppTestModelProvider(results: [
      .success([.delta("摘要"), .completed]),
      .success([.delta("翻译"), .completed])
    ])
    let model = try makeModel(provider: provider)
    model.receive(currentCapture())

    await model.summarize(preferences: settings.runPreferences)
    await waitUntil { model.runState == .completed(intent: .summarize, text: "摘要") }
    await model.translate(preferences: settings.runPreferences)
    await waitUntil { model.runState == .completed(intent: .translate, text: "翻译") }

    XCTAssertEqual(provider.intents, [
      .summarize(
        title: "Fixture title",
        text: "Fixture body",
        prompt: ModelPreferences.summaryPrompt(
          configuredPrompt: persisted.summaryPrompt,
          outputLanguage: persisted.outputLanguage
        )
      ),
      .translate(title: "Fixture title", text: "Fixture body", targetLanguage: persisted.targetLanguage)
    ])
  }

  func testRestartedIndependentTranslationModelIsDisclosedAndUsedWithoutChangingSummaryModel() async throws {
    let provider = AppTestModelProvider(results: [
      .success([.delta("摘要"), .completed]),
      .success([.delta("翻译"), .completed])
    ])
    let model = try makeModel(provider: provider)
    model.receive(currentCapture())
    let preferences = try ModelPreferences(
      summaryPrompt: "custom",
      outputLanguage: "简体中文",
      translationModel: "translation-model"
    )

    await model.summarize(preferences: preferences)
    await waitUntil { model.runState == .completed(intent: .summarize, text: "摘要") }
    await model.translate(preferences: preferences)
    XCTAssertEqual(model.dataDestinationDisclosure?.identity.model, "translation-model")
    await model.confirmDataDestinationDisclosure()
    await waitUntil { model.runState == .completed(intent: .translate, text: "翻译") }

    XCTAssertEqual(provider.models, ["fixture-model", "translation-model"])
    XCTAssertEqual(provider.intents.last, .translate(
      title: "Fixture title", text: "Fixture body", targetLanguage: "简体中文"
    ))
  }

  func testSameLanguageTranslationIsDisabledAndDirectActionDoesNotCallProvider() async throws {
    let provider = AppTestModelProvider(results: [.success([.delta("unexpected"), .completed])])
    let model = try makeModel(provider: provider)
    model.receive(currentCapture(text: String(repeating: "这是中文正文。", count: 4)))
    let preferences = try ModelPreferences(outputLanguage: "简体中文")

    XCTAssertFalse(model.canTranslate(preferences: preferences))
    await model.translate(preferences: preferences)

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertEqual(model.dataDestinationNotice, "捕获内容与输出语言相同，无需翻译。")
  }

  func testAmbiguousScriptCapturesRemainTranslatableThroughActionEntry() async throws {
    let cases: [(String, String)] = [
      (String(repeating: "中", count: 24) + String(repeating: "a", count: 20), "简体中文"),
      (String(repeating: "中", count: 16) + String(repeating: "a", count: 16), "English"),
      (String(repeating: "a", count: 48) + "かな", "日本語"),
      (String(repeating: "مرحبا", count: 8), "简体中文")
    ]

    for (index, fixture) in cases.enumerated() {
      let provider = AppTestModelProvider(results: [.success([.delta("译文\(index)"), .completed])])
      let model = try makeModel(provider: provider)
      model.receive(currentCapture(text: fixture.0))
      let preferences = try ModelPreferences(outputLanguage: fixture.1)

      XCTAssertTrue(model.canTranslate(preferences: preferences), "fixture \(index) must remain available")
      await model.translate(preferences: preferences)
      await waitUntil { model.runState == .completed(intent: .translate, text: "译文\(index)") }
      XCTAssertEqual(provider.callCount, 1, "fixture \(index) must reach Provider")
    }
  }

  func testUnknownDominantCapturesWithLatinMarkersRemainTranslatableThroughActionEntry() async throws {
    let latinMarker = "OpenAIBrandURL"
    let fixtures = [
      String(repeating: "مرحبا", count: 20) + latinMarker,
      String(repeating: "Привет", count: 20) + latinMarker,
      String(repeating: "नमस्ते", count: 20) + latinMarker
    ]

    for (index, fixture) in fixtures.enumerated() {
      let provider = AppTestModelProvider(results: [.success([.delta("译文-unknown-\(index)"), .completed])])
      let model = try makeModel(provider: provider)
      model.receive(currentCapture(text: fixture))
      let preferences = try ModelPreferences(outputLanguage: "English")

      XCTAssertTrue(model.canTranslate(preferences: preferences), "unknown-dominant fixture \(index) must remain available")
      await model.translate(preferences: preferences)
      await waitUntil { model.runState == .completed(intent: .translate, text: "译文-unknown-\(index)") }
      XCTAssertEqual(provider.callCount, 1, "unknown-dominant fixture \(index) must reach Provider")
    }
  }

  func testHistoryRegenerationWithTemporaryModelWaitsForConfirmationAndUsesOnlyLocalSnapshot() async throws {
    let localBody = "这是一段只存在于本地历史快照的正文。"
    let detail = historyDetail(body: localBody)
    let repository = AppHistoryRepository()
    let provider = AppTestModelProvider(results: [.success([.delta("重新生成结果"), .completed])])
    let model = try makeModel(provider: provider, repository: repository, consented: false)
    let preferences = try ModelPreferences(outputLanguage: "English")

    await model.summarize(
      historyDetail: detail,
      preferences: preferences,
      modelOverride: "temporary-model"
    )

    XCTAssertEqual(provider.callCount, 0, "destination confirmation must precede Provider")
    XCTAssertEqual(repository.acceptCaptureCallCount, 0, "history regeneration must not re-enter capture/fetch flow")
    XCTAssertEqual(model.currentCapture?.document.text, localBody)
    XCTAssertEqual(model.dataDestinationDisclosure?.identity.model, "temporary-model")

    await model.confirmDataDestinationDisclosure()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "重新生成结果") }

    XCTAssertEqual(provider.models, ["temporary-model"])
    XCTAssertEqual(provider.intents, [
      .summarize(
        title: "历史快照",
        text: localBody,
        prompt: ModelPreferences.summaryPrompt(
          configuredPrompt: preferences.summaryPrompt,
          outputLanguage: preferences.outputLanguage
        )
      )
    ])
    let created = repository.createdRunCommands
    XCTAssertEqual(created.count, 1)
    XCTAssertEqual(created.first?.taskID, detail.task.id)
    XCTAssertEqual(created.first?.snapshotID, detail.snapshots.last?.id)
    XCTAssertEqual(repository.acceptCaptureCallCount, 0)
  }

  func testHistorySummaryAndTranslateUseEffectiveSnapshotPlacedLastByRepositoryProjection() async throws {
    let original = historyDetail(body: "最终转写 A")
    let effective = try XCTUnwrap(original.snapshots.first)
    let laterHistorical = ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: original.task.id,
      sequence: 2,
      envelopeCreatedAtMilliseconds: effective.envelopeCreatedAtMilliseconds + 1,
      capturedAtMilliseconds: effective.capturedAtMilliseconds + 1,
      sourceKind: effective.sourceKind,
      sourceURL: effective.sourceURL,
      title: "后来正文 B",
      platform: effective.platform,
      captureMethod: effective.captureMethod,
      completeness: effective.completeness,
      bodyText: "后来正文 B",
      characterCount: 6,
      bodySHA256: String(repeating: "b", count: 64),
      sourceLabel: effective.sourceLabel,
      usedCookie: false
    )
    let detail = HistoryDetailProjection(
      task: original.task,
      snapshots: [laterHistorical, effective],
      runs: []
    )
    let preferences = try ModelPreferences(outputLanguage: "English")

    let summaryRepository = AppHistoryRepository()
    let summaryProvider = AppTestModelProvider(results: [.success([.delta("摘要"), .completed])])
    let summaryModel = try makeModel(provider: summaryProvider, repository: summaryRepository)
    await summaryModel.summarize(historyDetail: detail, preferences: preferences)
    await waitUntil { summaryModel.runState == .completed(intent: .summarize, text: "摘要") }
    XCTAssertEqual(summaryModel.runState, .completed(intent: .summarize, text: "摘要"))

    let translationRepository = AppHistoryRepository()
    let translationProvider = AppTestModelProvider(results: [.success([.delta("译文"), .completed])])
    let translationModel = try makeModel(provider: translationProvider, repository: translationRepository)
    await translationModel.translate(historyDetail: detail, preferences: preferences)
    await waitUntil { translationModel.runState == .completed(intent: .translate, text: "译文") }
    XCTAssertEqual(translationModel.runState, .completed(intent: .translate, text: "译文"))

    XCTAssertEqual(summaryRepository.createdRunCommands.map(\.snapshotID), [effective.id])
    XCTAssertEqual(translationRepository.createdRunCommands.map(\.snapshotID), [effective.id])
    XCTAssertEqual(summaryProvider.intents, [
      .summarize(
        title: "历史快照",
        text: "最终转写 A",
        prompt: ModelPreferences.summaryPrompt(
          configuredPrompt: preferences.summaryPrompt,
          outputLanguage: preferences.outputLanguage
        )
      )
    ])
    XCTAssertEqual(translationProvider.intents, [
      .translate(title: "历史快照", text: "最终转写 A", targetLanguage: "English"),
    ])
  }

  func testFirstRunRequiresDisclosureAndCancelNeverCallsProvider() async throws {
    let provider = AppTestModelProvider(results: [.success([.delta("ignored"), .completed])])
    let model = try makeModel(provider: provider, consented: false)
    model.receive(currentCapture())

    await model.summarize()

    XCTAssertNotNil(model.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 0)
    model.cancelDataDestinationDisclosure()
    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testDisclosureConfirmationRunsOnceAndSameIdentitySkipsLaterPrompt() async throws {
    let provider = AppTestModelProvider(results: [
      .success([.delta("first"), .completed]),
      .success([.delta("second"), .completed])
    ])
    let model = try makeModel(provider: provider, consented: false)
    model.receive(currentCapture())

    await model.summarize()
    await model.confirmDataDestinationDisclosure()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "first") }
    await model.translate()
    await waitUntil { model.runState == .completed(intent: .translate, text: "second") }

    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 2)
  }

  func testNewCaptureDuringDisclosureNeverSendsFrozenOldBody() async throws {
    let provider = AppTestModelProvider(results: [.success([.delta("new"), .completed])])
    let model = try makeModel(provider: provider, consented: false)
    let original = currentCapture()
    model.receive(original)
    await model.summarize()
    XCTAssertNotNil(model.dataDestinationDisclosure)

    let replacement = currentCapture()
    model.receive(replacement)
    await model.confirmDataDestinationDisclosure()

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertTrue(model.dataDestinationNotice?.contains("新") == true)
  }

  func testDisclosureReappearsWhenConfigurationIdentityChanges() async throws {
    let provider = AppTestModelProvider(results: [.success([.delta("not sent"), .completed])])
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: .init(rawValue: "fixture-reference")
    )
    let profileStore = AppProfileStore(profile: profile)
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: AppSecretStore(secret: "fixture-secret")
    )
    let model = AppViewModel(
      modelRunOrchestrator: ModelRunOrchestrator(
        configurationService: service,
        provider: provider,
        history: HistoryApplicationService(repository: AppHistoryRepository())
      ),
      configurationService: service,
      consentStore: AppConsentStore()
    )
    model.setStorageAvailability(.writable)
    model.receive(currentCapture())
    await model.summarize()
    let changed = try ProviderProfile(
      baseURL: "https://changed.example.test/v1",
      model: "new-model",
      secretReference: .init(rawValue: "fixture-reference")
    )
    await profileStore.replace(changed)

    await model.confirmDataDestinationDisclosure()

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertEqual(model.dataDestinationDisclosure?.identity, DataDestinationIdentity(profile: changed))
  }

  func testConsentStoreReadAndWriteFailuresFailSafeWithoutSecretState() async throws {
    let provider = AppTestModelProvider(results: [.success([.delta("once"), .completed])])
    let readFailure = try makeModel(provider: provider, consentStore: AppConsentStore(failRead: true))
    readFailure.receive(currentCapture())
    await readFailure.summarize()
    XCTAssertNotNil(readFailure.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 0)

    let writeFailure = try makeModel(provider: provider, consentStore: AppConsentStore(failWrite: true))
    writeFailure.receive(currentCapture())
    await writeFailure.summarize()
    await writeFailure.confirmDataDestinationDisclosure()
    await waitUntil { writeFailure.runState == .completed(intent: .summarize, text: "once") }
    XCTAssertTrue(writeFailure.dataDestinationNotice?.contains("下次") == true)
    XCTAssertFalse(String(describing: writeFailure).contains("fixture-secret"))

    await writeFailure.summarize()
    XCTAssertNotNil(writeFailure.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 1)
  }

  func testUnconfiguredAttemptReleasesThenSavedConfigurationCanRetry() async throws {
    let profileStore = AppProfileStore(profile: nil)
    let secretStore = AppSecretStore(secret: nil)
    let provider = AppTestModelProvider(results: [.success([.delta("done"), .completed])])
    let (model, service) = makeHarness(
      provider: provider,
      profileStore: profileStore,
      secretStore: secretStore,
      consentStore: AppConsentStore()
    )
    model.receive(currentCapture())

    await model.summarize()
    XCTAssertTrue(model.canStartRun)
    XCTAssertTrue(model.dataDestinationNotice?.contains("尚未配置") == true)

    _ = try await service.save(
      baseURL: "https://saved.example.test/v1",
      model: "saved-model",
      apiKey: "saved-key"
    )
    await model.summarize()
    XCTAssertNotNil(model.dataDestinationDisclosure)
    await model.confirmDataDestinationDisclosure()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "done") }
    XCTAssertEqual(provider.callCount, 1)
  }

  func testProfileReadFailureReleasesAttemptForImmediateRetry() async throws {
    let provider = AppTestModelProvider(results: [])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: nil, failLoad: true),
      secretStore: AppSecretStore(secret: nil),
      consentStore: AppConsentStore()
    )
    model.receive(currentCapture())

    await model.summarize()

    XCTAssertTrue(model.canStartRun)
    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(model.dataDestinationNotice?.contains("无法读取") == true)
  }

  func testIdentityLoadBarrierRejectsDoubleTapAndOldCaptureContinuation() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let profileStore = AppProfileStore(
      profile: profile,
      loadBarrier: barrier,
      blockedLoadCall: 1
    )
    let provider = AppTestModelProvider(results: [])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: profileStore,
      secretStore: AppSecretStore(secret: "key"),
      consentStore: AppConsentStore()
    )
    model.receive(currentCapture(title: "A", text: "body A"))

    let first = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    await model.translate()
    model.receive(currentCapture(title: "B", text: "body B"))
    await barrier.release()
    await first.value

    let loadCount = await profileStore.loads()
    XCTAssertEqual(loadCount, 1)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertTrue(model.canStartRun)
    await model.translate()
    XCTAssertEqual(model.dataDestinationDisclosure?.title, "B")
  }

  func testCancelledIdentityLoadReleasesAttemptForRetry() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let provider = AppTestModelProvider(results: [])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(
        profile: profile,
        loadBarrier: barrier,
        blockedLoadCall: 1
      ),
      secretStore: AppSecretStore(secret: "key"),
      consentStore: AppConsentStore()
    )
    model.receive(currentCapture())

    let task = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    task.cancel()
    await barrier.release()
    await task.value

    XCTAssertTrue(model.canStartRun)
    XCTAssertNil(model.dataDestinationDisclosure)
    XCTAssertEqual(provider.callCount, 0)
  }

  func testConsentReadBarrierRejectsDoubleTapAndOldCaptureContinuation() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let consentStore = AppConsentStore(readBarrier: barrier)
    let provider = AppTestModelProvider(results: [])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: profile),
      secretStore: AppSecretStore(secret: "key"),
      consentStore: consentStore
    )
    model.receive(currentCapture(title: "A", text: "body A"))

    let first = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    await model.translate()
    model.receive(currentCapture(title: "B", text: "body B"))
    await barrier.release()
    await first.value

    let readCount = await consentStore.reads()
    XCTAssertEqual(readCount, 1)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(model.canStartRun)
    await model.translate()
    XCTAssertEqual(model.dataDestinationDisclosure?.title, "B")
  }

  func testConsentWriteBarrierAcceptsOneConfirmationAndNeverSendsOldCapture() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let consentStore = AppConsentStore(writeBarrier: barrier)
    let provider = AppTestModelProvider(results: [.success([.delta("B"), .completed])])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: profile),
      secretStore: AppSecretStore(secret: "key"),
      consentStore: consentStore
    )
    model.receive(currentCapture(title: "A", text: "body A"))
    await model.summarize()

    let firstConfirmation = Task { await model.confirmDataDestinationDisclosure() }
    await barrier.waitUntilEntered()
    await model.confirmDataDestinationDisclosure()
    model.receive(currentCapture(title: "B", text: "body B"))
    await barrier.release()
    await firstConfirmation.value

    let writeCount = await consentStore.writes()
    XCTAssertEqual(writeCount, 1)
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(model.canStartRun)
    await model.translate()
    await waitUntil { model.runState == .completed(intent: .translate, text: "B") }
    XCTAssertEqual(provider.intents, [.translate(title: "B", text: "body B", targetLanguage: "简体中文")])
  }

  func testAuthorizeBarrierRejectsDoubleTapAndNeverSendsOldCapture() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let provider = AppTestModelProvider(results: [.success([.delta("B"), .completed])])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: profile),
      secretStore: AppSecretStore(secret: "key", readBarrier: barrier),
      consentStore: AppConsentStore(values: [DataDestinationIdentity(profile: profile)])
    )
    model.receive(currentCapture(title: "A", text: "body A"))

    let first = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    await model.translate()
    model.receive(currentCapture(title: "B", text: "body B"))
    await barrier.release()
    await first.value

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(model.canStartRun)
    await model.translate()
    await waitUntil { model.runState == .completed(intent: .translate, text: "B") }
    XCTAssertEqual(provider.intents, [.translate(title: "B", text: "body B", targetLanguage: "简体中文")])
  }

  func testLaunchGuardFailureReleasesAttemptAndAllowsRetry() async throws {
    let profile = try configuredProfile()
    let barrier = AppAsyncBarrier()
    let provider = AppTestModelProvider(results: [.success([.delta("retry"), .completed])])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: profile),
      secretStore: AppSecretStore(secret: "key", readBarrier: barrier),
      consentStore: AppConsentStore(values: [DataDestinationIdentity(profile: profile)])
    )
    model.receive(currentCapture())

    let first = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    model.setStorageAvailability(.unavailable(.writeFailed))
    await barrier.release()
    await first.value

    XCTAssertEqual(provider.callCount, 0)
    model.setStorageAvailability(.writable)
    XCTAssertTrue(model.canStartRun)
    await model.summarize()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "retry") }
  }

  func testConfigurationChangeDuringAuthorizePresentsNewIdentity() async throws {
    let oldProfile = try configuredProfile()
    let newProfile = try ProviderProfile(
      baseURL: "https://new.example.test/v1",
      model: "new-model",
      secretReference: oldProfile.secretReference
    )
    let barrier = AppAsyncBarrier()
    let profileStore = AppProfileStore(profile: oldProfile)
    let provider = AppTestModelProvider(results: [])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: profileStore,
      secretStore: AppSecretStore(secret: "key", readBarrier: barrier),
      consentStore: AppConsentStore(values: [DataDestinationIdentity(profile: oldProfile)])
    )
    model.receive(currentCapture())

    let task = Task { await model.summarize() }
    await barrier.waitUntilEntered()
    await profileStore.replace(newProfile)
    await barrier.release()
    await task.value

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertEqual(model.dataDestinationDisclosure?.identity, DataDestinationIdentity(profile: newProfile))
    XCTAssertTrue(model.dataDestinationNotice?.contains("变化") == true)
  }

  func testAuthorizationFailureReleasesAttemptForRetry() async throws {
    let profile = try configuredProfile()
    let secretStore = AppSecretStore(secret: nil)
    let provider = AppTestModelProvider(results: [.success([.delta("retry"), .completed])])
    let (model, _) = makeHarness(
      provider: provider,
      profileStore: AppProfileStore(profile: profile),
      secretStore: secretStore,
      consentStore: AppConsentStore(values: [DataDestinationIdentity(profile: profile)])
    )
    model.receive(currentCapture())

    await model.summarize()
    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(model.canStartRun)
    await secretStore.replace("key")
    await model.summarize()
    await waitUntil { model.runState == .completed(intent: .summarize, text: "retry") }
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

  func testFormalRunUsesFixedProviderRejectionCopy() async throws {
    let submittedSecret = "sentinel-\(UUID().uuidString)"
    let responseBodyMarker = "provider-body-marker-\(UUID().uuidString)"
    let failure = ModelProviderFailure(
      code: .providerRequestRejected,
      retryable: false,
      hadOutput: false
    )
    let provider = AppTestModelProvider(results: [.failure(prefix: nil, failure)])
    let model = try makeModel(provider: provider, secret: submittedSecret)
    model.receive(currentCapture())

    await model.summarize()
    await waitUntil {
      model.runState == .failed(
        intent: .summarize,
        code: ModelProviderErrorCode.providerRequestRejected.rawValue
      )
    }

    XCTAssertEqual(
      model.runStatusText,
      V02ErrorCatalog.presentation(for: ModelProviderErrorCode.providerRequestRejected.rawValue).visibleText
    )
    XCTAssertFalse(model.runStatusText.contains(responseBodyMarker))
    XCTAssertFalse(model.runStatusText.contains(submittedSecret))
  }

  func testFormalRunProviderFailureCodesUseFixedLocalCopy() async throws {
    let responseBodyMarker = "provider-body-marker-\(UUID().uuidString)"
    for code in [
      ModelProviderErrorCode.providerBillingLimited,
      .modelNotFound,
      .endpointNotFound,
      .providerRequestRejected,
      .providerUnavailable,
      .networkInterrupted
    ] {
      let failure = ModelProviderFailure(code: code, retryable: false, hadOutput: false)
      let model = try makeModel(
        provider: AppTestModelProvider(results: [.failure(prefix: nil, failure)]),
        secret: "not-a-real-key"
      )
      model.receive(currentCapture())

      await model.summarize()
      await waitUntil {
        model.runState == .failed(intent: .summarize, code: code.rawValue)
      }

      XCTAssertEqual(model.runStatusText, V02ErrorCatalog.presentation(for: code.rawValue).visibleText)
      XCTAssertFalse(model.runStatusText.contains(responseBodyMarker))
      XCTAssertFalse(model.runStatusText.contains(code.rawValue))
    }
  }

  func testFormalRunNeverRendersProviderBodyFixtures() async throws {
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
      let failure = ModelProviderFailure(
        code: .providerRequestRejected,
        retryable: false,
        hadOutput: false
      )
      let model = try makeModel(
        provider: AppTestModelProvider(results: [.failure(prefix: nil, failure)]),
        secret: "not-a-real-key"
      )
      model.receive(currentCapture())

      await model.summarize()
      await waitUntil {
        model.runState == .failed(
          intent: .summarize,
          code: ModelProviderErrorCode.providerRequestRejected.rawValue
        )
      }

      XCTAssertFalse(String(describing: model.runState).contains(leakedValue), fixture.name)
      XCTAssertFalse(model.runStatusText.contains(leakedValue), fixture.name)
      XCTAssertFalse(model.runResultText.contains(leakedValue), fixture.name)
      XCTAssertFalse(model.runStatusText.contains(fixture.payload), fixture.name)
      XCTAssertEqual(
        model.runStatusText,
        V02ErrorCatalog.presentation(for: ModelProviderErrorCode.providerRequestRejected.rawValue).visibleText,
        fixture.name
      )
    }
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
      await orchestrator.start(request: request, capture: existing.wireEnvelope) { runID, state in
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

  /// 流式纯增长拍点不得触发整个 ObservableObject 的通知（那会让观察
  /// AppViewModel 的整棵历史窗口每 250ms 重求值，是生成期间滚动卡顿的
  /// 来源）；状态切换照常通知，且 runState 读取方始终拿到最新正文。
  func testStreamingGrowthTicksUpdateLeafOnlyAndKeepRunStateFresh() {
    let model = AppViewModel()
    let runID = RunID()
    model.receiveRunState(runID: runID, state: .starting(intent: .summarize))

    var wholeObjectNotifications = 0
    let notificationCounter = model.objectWillChange.sink { _ in wholeObjectNotifications += 1 }

    model.receiveRunState(runID: runID, state: .thinking(intent: .summarize))
    XCTAssertEqual(wholeObjectNotifications, 1)
    XCTAssertTrue(model.liveRunText.text.isEmpty)

    // 第一段正文是 thinking → streaming 的边界切换：整体通知 + 叶子更新。
    model.receiveRunState(runID: runID, state: .streaming(intent: .summarize, partialText: "第一"))
    XCTAssertEqual(wholeObjectNotifications, 2)
    XCTAssertEqual(model.liveRunText.text, "第一")
    XCTAssertEqual(model.runResultText, "第一")

    // 同 intent 的纯增长拍点：叶子更新，整体不通知，存储值保持最新。
    model.receiveRunState(runID: runID, state: .streaming(intent: .summarize, partialText: "第一段"))
    model.receiveRunState(runID: runID, state: .streaming(intent: .summarize, partialText: "第一段落"))
    XCTAssertEqual(wholeObjectNotifications, 2)
    XCTAssertEqual(model.liveRunText.text, "第一段落")
    XCTAssertEqual(model.runResultText, "第一段落")

    // 终态切换回到整体通知，叶子同步全文。计数是 4 而非 3：receiveRunState
    // 在终态还会清空 @Published 的 activeRunTaskID，那是真正的状态切换，
    // 本就该通知（SwiftUI 会在同一 runloop 合并这两次 objectWillChange）。
    model.receiveRunState(runID: runID, state: .completed(intent: .summarize, text: "第一段落。"))
    XCTAssertEqual(wholeObjectNotifications, 4)
    XCTAssertEqual(model.liveRunText.text, "第一段落。")
    XCTAssertEqual(model.runResultText, "第一段落。")

    notificationCounter.cancel()
  }

  /// 推理模型的思考阶段每收到一个 delta 就上报一次 `.thinking(intent:)`，值
  /// 完全相同。这种同值拍点不得触发整体通知：实测不去重时主线程 100% CPU、
  /// 连续 23 秒几乎不出帧，界面完全无法操作。
  func testRepeatedIdenticalThinkingTicksDoNotNotifyWholeObject() {
    let model = AppViewModel()
    let runID = RunID()
    model.receiveRunState(runID: runID, state: .starting(intent: .translate))

    var wholeObjectNotifications = 0
    let notificationCounter = model.objectWillChange.sink { _ in wholeObjectNotifications += 1 }

    // 第一次是 starting → thinking 的真实切换，照常通知。
    model.receiveRunState(runID: runID, state: .thinking(intent: .translate))
    XCTAssertEqual(wholeObjectNotifications, 1)

    for _ in 0..<50 {
      model.receiveRunState(runID: runID, state: .thinking(intent: .translate))
    }
    XCTAssertEqual(wholeObjectNotifications, 1)
    XCTAssertEqual(model.runState, .thinking(intent: .translate))

    // intent 变了就不再是同值，必须照常通知。
    model.receiveRunState(runID: runID, state: .thinking(intent: .summarize))
    XCTAssertEqual(wholeObjectNotifications, 2)

    // 正文到达是真实切换，叶子同步。
    model.receiveRunState(runID: runID, state: .streaming(intent: .summarize, partialText: "首段"))
    XCTAssertEqual(wholeObjectNotifications, 3)
    XCTAssertEqual(model.liveRunText.text, "首段")

    notificationCounter.cancel()
  }

  /// 卡顿的形态是「整棵历史窗口按 delta 速率重求值」，所以真正要钉住的不是
  /// 某一个拍点的行为，而是「通知总量与 delta 数量无关」。这里按一次真实
  /// 推理型翻译的形状回放：先长时间只出 reasoning，再转正文流式，最后终态。
  func testWholeObjectNotificationsDoNotScaleWithDeltaCount() {
    func notificationCount(thinkingTicks: Int, streamingDeltas: Int) -> Int {
      let model = AppViewModel()
      let runID = RunID()
      var notifications = 0
      let counter = model.objectWillChange.sink { _ in notifications += 1 }
      defer { counter.cancel() }

      model.receiveRunState(runID: runID, state: .starting(intent: .translate))
      for _ in 0..<thinkingTicks {
        model.receiveRunState(runID: runID, state: .thinking(intent: .translate))
      }
      var text = ""
      for index in 0..<streamingDeltas {
        text += "第\(index)段。"
        model.receiveRunState(runID: runID, state: .streaming(intent: .translate, partialText: text))
      }
      model.receiveRunState(runID: runID, state: .completed(intent: .translate, text: text))
      XCTAssertEqual(model.liveRunText.text, text)
      return notifications
    }

    // 只有阶段切换该通知整树，delta 数量不该进入这个式子。
    let short = notificationCount(thinkingTicks: 5, streamingDeltas: 3)
    let long = notificationCount(thinkingTicks: 600, streamingDeltas: 200)
    XCTAssertEqual(short, long)
    XCTAssertLessThanOrEqual(long, 8)
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

  func testVisibleRunOwnershipStaysWithAWhenCaptureBReplacesCurrentAndAfterTerminal() async throws {
    let provider = AppTestModelProvider(results: [.pendingWithPrefix("A output")])
    let model = try makeModel(provider: provider)
    let captureA = currentCapture()
    let captureB = currentCapture()
    model.receive(captureA)

    await model.summarize()
    await waitUntil { model.runState == .streaming(intent: .summarize, partialText: "A output") }
    XCTAssertEqual(model.activeRunTaskID, captureA.taskID)
    XCTAssertEqual(model.visibleRunTaskID, captureA.taskID)
    XCTAssertTrue(model.showsVisibleRun(for: captureA.taskID))
    XCTAssertTrue(model.canStopVisibleRun(for: captureA.taskID))

    model.receive(captureB)
    XCTAssertEqual(model.currentCapture, captureB)
    XCTAssertEqual(model.activeRunTaskID, captureA.taskID)
    XCTAssertEqual(model.visibleRunTaskID, captureA.taskID)
    XCTAssertNotEqual(model.activeRunTaskID, captureB.taskID)
    XCTAssertTrue(model.showsVisibleRun(for: captureA.taskID))
    XCTAssertFalse(model.showsVisibleRun(for: captureB.taskID))
    XCTAssertTrue(model.canStopVisibleRun(for: captureA.taskID))
    XCTAssertFalse(model.canStopVisibleRun(for: captureB.taskID))
    XCTAssertEqual(model.runResultText, "A output")

    await model.stop()
    await waitUntil { model.runState == .stopped(intent: .summarize, partialText: "A output") }
    XCTAssertNil(model.activeRunTaskID)
    XCTAssertEqual(model.visibleRunTaskID, captureA.taskID)
    XCTAssertTrue(model.showsVisibleRun(for: captureA.taskID))
    XCTAssertFalse(model.showsVisibleRun(for: captureB.taskID))
    XCTAssertFalse(model.canStopVisibleRun(for: captureA.taskID))
    XCTAssertEqual(model.runResultText, "A output")
  }

  func testLaunchPendingProtectsTaskBeforeCreateRunReturnsWithoutPublishingStarting() async throws {
    let repository = AppHistoryRepository(blockCreateRun: true)
    let provider = AppTestModelProvider(results: [.pending])
    let model = try makeModel(provider: provider, repository: repository)
    let capture = currentCapture()
    model.receive(capture)

    let startTask = Task { await model.summarize() }
    await waitUntil { repository.didEnterCreateRun }
    XCTAssertEqual(model.activeRunTaskID, capture.taskID)
    XCTAssertFalse(model.canStartRun)
    XCTAssertEqual(model.runState, .idle)

    repository.releaseCreateRun()
    await startTask.value
    await waitUntil { model.runState == .starting(intent: .summarize) }
    XCTAssertEqual(model.activeRunTaskID, capture.taskID)

    await model.stop()
    await waitUntil { model.runState == .stopped(intent: .summarize, partialText: "") }
    XCTAssertNil(model.activeRunTaskID)
  }

  func testRetryAfterStopClearsVisiblePartialBeforeCreateRunConfirmsStarting() async throws {
    let repository = AppHistoryRepository(blockCreateRun: true)
    let provider = AppTestModelProvider(results: [
      .pendingWithPrefix("partial summary"),
      .pendingWithPrefix("partial summary"),
    ])
    let model = try makeModel(provider: provider, repository: repository)
    let capture = currentCapture()
    model.receive(capture)

    // The first launch establishes the stopped partial; only the retry is the
    // createRun call this test needs to hold behind the barrier.
    repository.releaseCreateRun()
    await model.summarize()
    await waitUntil { model.runState == .streaming(intent: .summarize, partialText: "partial summary") }
    await model.stop()
    await waitUntil { model.runState == .stopped(intent: .summarize, partialText: "partial summary") }
    XCTAssertEqual(model.runResultText, "partial summary")

    let retryTask = Task { await model.summarize() }
    await waitUntil { repository.createdRunCommands.count == 2 }
    XCTAssertEqual(model.runState, .starting(intent: .summarize))
    XCTAssertEqual(model.runResultText, "")

    repository.releaseCreateRun()
    await retryTask.value
    await waitUntil { model.runState == .streaming(intent: .summarize, partialText: "partial summary") }
  }

  func testPreStartStorageFailureTakesPendingOwnershipThenClearsDeletionProtection() async throws {
    let repository = AppHistoryRepository(failCreateRun: true)
    let provider = AppTestModelProvider(results: [])
    let model = try makeModel(provider: provider, repository: repository)
    let capture = currentCapture()
    model.receive(capture)

    await model.summarize()
    guard case .storageError = model.runState else {
      return XCTFail("createRun failure must publish a storageError")
    }
    XCTAssertNil(model.activeRunTaskID)
    XCTAssertEqual(model.visibleRunTaskID, capture.taskID)
    XCTAssertEqual(model.storageAvailability, .unavailable(.writeFailed))

    model.setStorageAvailability(.writable)
    XCTAssertTrue(model.canStartRun, "pre-start failure must clear launch-pending state")
  }

  func testOrchestratorNoCallbackReturnClearsPendingMappingAndDeletionProtection() async throws {
    let provider = AppTestModelProvider(results: [.pending])
    let (model, orchestrator) = try makeModelAndOrchestrator(provider: provider)
    let authorityCapture = currentCapture()
    await orchestrator.start(
      request: .init(
        runID: RunID(),
        taskID: authorityCapture.taskID,
        snapshotID: authorityCapture.snapshotID,
        intent: .summarize
      ),
      capture: authorityCapture.wireEnvelope
    ) { _, _ in }

    let capture = currentCapture()
    model.receive(capture)
    await model.summarize()

    XCTAssertNil(model.activeRunTaskID)
    XCTAssertNil(model.visibleRunTaskID)
    XCTAssertEqual(model.runState, .idle)
    XCTAssertTrue(model.canStartRun, "authority rejection must not leave a permanent pending launch")
    await orchestrator.stop()
  }

  private func makeModel(
    provider: AppTestModelProvider,
    secret: String = "not-a-real-key",
    repository: AppHistoryRepository = AppHistoryRepository(),
    consented: Bool = true,
    consentStore: (any DataDestinationConsentStore)? = nil
  ) throws -> AppViewModel {
    try makeModelAndOrchestrator(
      provider: provider,
      secret: secret,
      repository: repository,
      consented: consented,
      consentStore: consentStore
    ).0
  }

  private func makeModelAndOrchestrator(
    provider: AppTestModelProvider,
    secret: String = "not-a-real-key",
    repository: AppHistoryRepository = AppHistoryRepository(),
    consented: Bool = true,
    consentStore: (any DataDestinationConsentStore)? = nil
  ) throws -> (AppViewModel, ModelRunOrchestrator) {
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
    let resolvedConsentStore: any DataDestinationConsentStore = consentStore ?? AppConsentStore(
      values: consented ? [DataDestinationIdentity(profile: profile)] : []
    )
    let model = AppViewModel(
      modelRunOrchestrator: orchestrator,
      configurationService: service,
      consentStore: resolvedConsentStore
    )
    model.setStorageAvailability(.writable)
    return (model, orchestrator)
  }

  private func makeHarness(
    provider: AppTestModelProvider,
    profileStore: AppProfileStore,
    secretStore: AppSecretStore,
    consentStore: any DataDestinationConsentStore,
    repository: AppHistoryRepository = AppHistoryRepository()
  ) -> (AppViewModel, ProviderConfigurationService) {
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore
    )
    let model = AppViewModel(
      modelRunOrchestrator: ModelRunOrchestrator(
        configurationService: service,
        provider: provider,
        history: HistoryApplicationService(repository: repository)
      ),
      configurationService: service,
      consentStore: consentStore
    )
    model.setStorageAvailability(.writable)
    return (model, service)
  }

  private func configuredProfile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: .init(rawValue: "fixture-reference")
    )
  }

  private func currentCapture(
    title: String = "Fixture title",
    text: String = "Fixture body"
  ) -> CurrentCapture {
    .init(
      envelope: capture(title: title, text: text),
      taskID: TaskID(),
      snapshotID: ContentSnapshotID()
    )
  }

  private func historyDetail(body: String) -> HistoryDetailProjection {
    let taskID = TaskID()
    let snapshotID = ContentSnapshotID()
    let snapshot = ContentSnapshot(
      id: snapshotID,
      taskID: taskID,
      sequence: 1,
      envelopeCreatedAtMilliseconds: 1_784_937_600_000,
      capturedAtMilliseconds: 1_784_937_600_000,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      sourceURL: "https://example.test/local-history",
      title: "历史快照",
      platform: "fixture",
      captureMethod: "rendered_dom",
      completeness: "full_article",
      bodyText: body,
      characterCount: body.unicodeScalars.count,
      bodySHA256: String(repeating: "a", count: 64),
      sourceLabel: "本地测试",
      usedCookie: false
    )
    return HistoryDetailProjection(
      task: .init(
        id: taskID,
        canonicalURL: snapshot.sourceURL,
        canonicalizationVersion: 1,
        createdAtMilliseconds: snapshot.envelopeCreatedAtMilliseconds,
        updatedAtMilliseconds: snapshot.capturedAtMilliseconds
      ),
      snapshots: [snapshot],
      runs: []
    )
  }

  private func capture(
    title: String = "Fixture title",
    text: String = "Fixture body"
  ) -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(
      version: 1,
      requestId: UUID().uuidString,
      createdAt: "2026-07-14T00:00:00Z",
      source: .init(
        kind: "browser_capture",
        url: "https://example.test/article",
        title: title,
        platform: "generic"
      ),
      capture: .init(
        method: "rendered_dom",
        text: text,
        characterCount: text.unicodeScalars.count,
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
