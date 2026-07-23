import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore
import LinkDigestPersistence

private final class CommitBlocker: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func block() {
    entered.signal()
    release.wait()
  }
}

private final class WiringEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) { lock.withLock { storage.append(value) } }
  var values: [String] { lock.withLock { storage } }
}

private actor WiringCaptureSink {
  private(set) var captures: [CurrentCapture] = []
  func receive(_ value: CurrentCapture) { captures.append(value) }
}

private actor V2CaptureObservationSink {
  private(set) var ephemeralPlaybackURL: String?
  private(set) var legacyMediaWasPresent = false
  private(set) var wireVersion: Int?
  private(set) var taskID: TaskID?

  func receive(_ value: CurrentCapture) {
    ephemeralPlaybackURL = value.mediaDescriptor?.ephemeralPlaybackURL
    legacyMediaWasPresent = value.document.media != nil
    wireVersion = value.wireEnvelopeV2?.version ?? value.wireEnvelope?.version
    taskID = value.taskID
  }
}

private actor WiringAvailabilitySink {
  private(set) var values: [StorageAvailability] = []
  func receive(_ value: StorageAvailability) { values.append(value) }
}

private final class WiringRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode
  private let log: WiringEventLog
  private let captureResult: AcceptCaptureResult
  private let captureFailure: RepositoryFailure?
  private let recoveryFailure: RepositoryFailure?
  private let captureBlocker: CommitBlocker?
  private let recoveryBlocker: CommitBlocker?
  private let stateLock = NSLock()
  private var captureCalls = 0
  private var acceptedCommandDescription = ""
  private var acceptedProvenance: CaptureDeliveryProvenance?

  init(
    accessMode: HistoryRepositoryAccessMode = .writable,
    log: WiringEventLog = WiringEventLog(),
    captureResult: AcceptCaptureResult = .init(
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      taskWasCreated: true,
      snapshotWasCreated: true,
      deliveryWasReplayed: false
    ),
    captureFailure: RepositoryFailure? = nil,
    recoveryFailure: RepositoryFailure? = nil,
    captureBlocker: CommitBlocker? = nil,
    recoveryBlocker: CommitBlocker? = nil
  ) {
    self.accessMode = accessMode
    self.log = log
    self.captureResult = captureResult
    self.captureFailure = captureFailure
    self.recoveryFailure = recoveryFailure
    self.captureBlocker = captureBlocker
    self.recoveryBlocker = recoveryBlocker
  }

  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    stateLock.withLock {
      captureCalls += 1
      acceptedCommandDescription = String(reflecting: command)
      acceptedProvenance = command.provenance
    }
    if let captureBlocker {
      log.append("capture-entry")
      captureBlocker.block()
    }
    if let captureFailure { throw captureFailure }
    log.append("capture-commit")
    return captureResult
  }
  var acceptCaptureCallCount: Int { stateLock.withLock { captureCalls } }
  var lastAcceptedCommandDescription: String { stateLock.withLock { acceptedCommandDescription } }
  var lastAcceptedProvenance: CaptureDeliveryProvenance? { stateLock.withLock { acceptedProvenance } }
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { .init(runID: command.runID, wasCreated: true) }
  func markRunRunning(_: MarkRunRunningCommand) throws {}
  func savePartialArtifact(_: SavePartialArtifactCommand) throws {}
  func finishRun(_: FinishRunCommand) throws {}
  func recoverInterruptedRuns(at _: Int64) throws -> Int {
    if let recoveryBlocker {
      log.append("recovery-entry")
      recoveryBlocker.block()
    }
    if let recoveryFailure { throw recoveryFailure }
    log.append("recover")
    return 1
  }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
}

private final class ToggleCaptureRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let lock = NSLock()
  private var failure: RepositoryFailure? = .unavailable
  private var calls = 0
  private let result = AcceptCaptureResult(
    taskID: TaskID(),
    snapshotID: ContentSnapshotID(),
    taskWasCreated: true,
    snapshotWasCreated: true,
    deliveryWasReplayed: false
  )

  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    try lock.withLock {
      calls += 1
      if let failure { throw failure }
      return result
    }
  }

  func allowSuccess() { lock.withLock { failure = nil } }
  var acceptCaptureCallCount: Int { lock.withLock { calls } }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws {}
  func savePartialArtifact(_: SavePartialArtifactCommand) throws {}
  func finishRun(_: FinishRunCommand) throws {}
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
}

private final class ConcurrentCaptureRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let lock = NSLock()
  private var identities: [String: (TaskID, ContentSnapshotID)] = [:]

  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    let identity = lock.withLock { () -> (TaskID, ContentSnapshotID) in
      if let existing = identities[command.document.requestID] { return existing }
      let created = (TaskID(), ContentSnapshotID())
      identities[command.document.requestID] = created
      return created
    }
    return .init(taskID: identity.0, snapshotID: identity.1, taskWasCreated: true, snapshotWasCreated: true, deliveryWasReplayed: false)
  }
  func expected(for requestID: String) -> (TaskID, ContentSnapshotID)? { lock.withLock { identities[requestID] } }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws {}
  func savePartialArtifact(_: SavePartialArtifactCommand) throws {}
  func finishRun(_: FinishRunCommand) throws {}
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
}

private final class ServerRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let log: WiringEventLog
  private var starts = 0
  private var capturedReceiver: CaptureReceiver?

  init(log: WiringEventLog) { self.log = log }

  func start(_ receiver: CaptureReceiver) {
    lock.withLock {
      starts += 1
      capturedReceiver = receiver
    }
    log.append("server")
  }

  var startCount: Int { lock.withLock { starts } }
  var receiver: CaptureReceiver? { lock.withLock { capturedReceiver } }
}

final class AppCompositionTests: XCTestCase {
  func testSocketLifecycleStopUnlinksOwnedPathAndIsIdempotent() throws {
    let path = "/tmp/linkdigest-composition-stop-\(UUID().uuidString).sock"
    let lifecycle = UnixSocketServerLifecycle(path: path, statusSink: { _ in })
    let gate = StorageWriteGate(availabilitySink: { _ in })
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: gate,
      nowMilliseconds: { 1 },
      captureSink: { _ in }
    )
    defer { lifecycle.stop() }

    try lifecycle.start(receiver)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    lifecycle.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    lifecycle.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testDebugSmokeRootInjectionNeverResolvesLiveApplicationSupport() throws {
    let expected = URL(fileURLWithPath: "/private/tmp/linkdigest-smoke-root", isDirectory: true)
    let resolved = try AppApplicationSupportRoot.resolve(
      environment: [
        AppApplicationSupportRoot.smokeOverrideEnvironmentKey: expected.path
      ],
      liveRoot: { throw RepositoryFailure.unavailable }
    )

    XCTAssertEqual(resolved, expected)
  }

  func testNormalRootResolutionDelegatesToLiveRoot() throws {
    let expected = URL(fileURLWithPath: "/private/var/folders/live-root", isDirectory: true)
    let resolved = try AppApplicationSupportRoot.resolve(
      environment: [:],
      liveRoot: { expected }
    )

    XCTAssertEqual(resolved, expected)
  }

  func testDebugSmokeOpenFailureInjectionRequiresExactOptIn() {
    XCTAssertTrue(AppApplicationSupportRoot.shouldInjectOpenFailure(
      environment: [AppApplicationSupportRoot.smokeOpenFailureEnvironmentKey: "1"]
    ))
    XCTAssertFalse(AppApplicationSupportRoot.shouldInjectOpenFailure(environment: [:]))
    XCTAssertFalse(AppApplicationSupportRoot.shouldInjectOpenFailure(
      environment: [AppApplicationSupportRoot.smokeOpenFailureEnvironmentKey: "true"]
    ))
  }

  func testWritableBootstrapRecoversBeforeStartingServerAndRunsOnlyOnce() async {
    let log = WiringEventLog()
    let repository = WiringRepository(log: log)
    let server = ServerRecorder(log: log)
    let availability = WiringAvailabilitySink()
    let captures = WiringCaptureSink()
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: { URL(fileURLWithPath: "/virtual-test-root") },
      repositoryFactory: { _ in repository },
      nowMilliseconds: { 123 },
      serverStarter: { server.start($0) },
      availabilitySink: { await availability.receive($0) },
      captureSink: { await captures.receive($0) }
    ))

    async let first = composition.bootstrap()
    async let second = composition.bootstrap()
    let results = await [first, second]

    XCTAssertEqual(log.values, ["recover", "server"])
    XCTAssertEqual(server.startCount, 1)
    XCTAssertTrue(results.allSatisfy { $0.availability == .writable && $0.history != nil })
    let observedAvailability = await availability.values
    XCTAssertEqual(observedAvailability, [.bootstrapping, .writable])
    XCTAssertTrue(results[0].storageWriteGate === results[1].storageWriteGate)

    await results[0].storageWriteGate.degrade(.writeFailed)
    let rejected = await server.receiver!.process(try! JSONEncoder().encode(capture()))
    guard case let .error(error) = rejected else {
      return XCTFail("composition receiver must share the lifecycle gate")
    }
    XCTAssertEqual(error.code, StorageErrorCode.writeFailed.rawValue)
    XCTAssertEqual(repository.acceptCaptureCallCount, 0)
  }

  func testRecoveryCommitMustFinishBeforeNormalServerStarts() async {
    let log = WiringEventLog()
    let blocker = CommitBlocker()
    let repository = WiringRepository(log: log, recoveryBlocker: blocker)
    let server = ServerRecorder(log: log)
    let availability = WiringAvailabilitySink()
    let captures = WiringCaptureSink()
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: { URL(fileURLWithPath: "/virtual-test-root") },
      repositoryFactory: { _ in repository },
      nowMilliseconds: { 123 },
      serverStarter: { server.start($0) },
      availabilitySink: { await availability.receive($0) },
      captureSink: { await captures.receive($0) }
    ))

    let bootstrap = Task { await composition.bootstrap() }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(log.values, ["recovery-entry"])
    XCTAssertEqual(server.startCount, 0)
    blocker.release.signal()
    let result = await bootstrap.value
    XCTAssertEqual(result.availability, .writable)
    XCTAssertEqual(log.values, ["recovery-entry", "recover", "server"])
    XCTAssertEqual(server.startCount, 1)
  }

  func testReadOnlyOpenAndRecoveryFailuresStartRejectingServer() async throws {
    for scenario in ["read-only", "open", "recovery"] {
      let log = WiringEventLog()
      let server = ServerRecorder(log: log)
      let availability = WiringAvailabilitySink()
      let captures = WiringCaptureSink()
      let repository = WiringRepository(
        accessMode: scenario == "read-only" ? .readOnly(.futureSchema) : .writable,
        log: log,
        recoveryFailure: scenario == "recovery" ? .unavailable : nil
      )
      let composition = AppComposition(dependencies: .init(
        applicationSupportRoot: { URL(fileURLWithPath: "/virtual-test-root") },
        repositoryFactory: { _ in
          if scenario == "open" { throw RepositoryFailure.unavailable }
          return repository
        },
        nowMilliseconds: { 123 },
        serverStarter: { server.start($0) },
        availabilitySink: { await availability.receive($0) },
        captureSink: { await captures.receive($0) }
      ))

      let result = await composition.bootstrap()
      if scenario == "read-only" {
        XCTAssertNotNil(result.history)
        XCTAssertTrue(result.historyIsReadOnly)
        XCTAssertEqual(result.historyReadOnlyReason, .futureSchema)
        XCTAssertNil(result.historyUnavailableCode)
      } else {
        XCTAssertNil(result.history)
        XCTAssertFalse(result.historyIsReadOnly)
        XCTAssertNil(result.historyReadOnlyReason)
        XCTAssertNotNil(result.historyUnavailableCode)
      }
      XCTAssertTrue(result.serverStarted)
      XCTAssertEqual(server.startCount, 1)
      let first = await server.receiver!.process(
        try JSONEncoder().encode(capture(requestID: "\(scenario)-first"))
      )
      let second = await server.receiver!.process(
        try JSONEncoder().encode(capture(requestID: "\(scenario)-second"))
      )
      for response in [first, second] {
        guard case let .error(error) = response else {
          return XCTFail("expected permanent structured rejection")
        }
        XCTAssertEqual(error.category, "storage")
        XCTAssertNil(error.safeDetail)
        XCTAssertTrue(error.code.hasPrefix("STORAGE_"))
        let code = try XCTUnwrap(StorageErrorCode(rawValue: error.code))
        let presentation = StorageErrorMapper.presentation(for: code)
        XCTAssertEqual(error.retryable, presentation.retryable)
        XCTAssertEqual(error.action, presentation.action)
      }
      XCTAssertEqual(repository.acceptCaptureCallCount, 0)
      let rejectedCaptures = await captures.captures
      XCTAssertTrue(rejectedCaptures.isEmpty)
    }
  }

  func testTemporaryGRDBRestartRecoveryPrecedesServer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-02b-composition-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let location = LocalDatabaseLocation(applicationSupportRoot: root)
    let first = try GRDBHistoryRepository.open(at: location)
    let accepted = try first.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
    let run = try first.createRun(.init(
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID,
      idempotencyKey: "run:restart",
      kind: .summarize,
      createdAtMilliseconds: 2
    ))
    try first.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init()))
    try first.database.close()

    let log = WiringEventLog()
    let server = ServerRecorder(log: log)
    let availability = WiringAvailabilitySink()
    let captures = WiringCaptureSink()
    let composition = AppComposition(dependencies: .init(
      applicationSupportRoot: { root },
      repositoryFactory: { try GRDBHistoryRepository.open(at: $0) },
      nowMilliseconds: { 99 },
      serverStarter: { server.start($0) },
      availabilitySink: { await availability.receive($0) },
      captureSink: { await captures.receive($0) }
    ))

    let result = await composition.bootstrap()
    XCTAssertEqual(server.startCount, 1)
    XCTAssertEqual(try result.history?.detail(taskID: accepted.taskID).runs.first?.run.status, .interrupted)
  }

  func testDebugHistoryLoadingHookFailsClosedUnlessEveryGateMatches() {
    let root = "/private/tmp/linkdigest-history-state.session/Application Support"
    // URL.standardizedFileURL canonicalizes this /private/tmp input to /tmp.
    let sentinel = "/tmp/linkdigest-history-state.session/\(AppApplicationSupportRoot.debugHistoryLoadingSentinelName)"
    let base = [
      AppApplicationSupportRoot.smokeOverrideEnvironmentKey: root,
      AppApplicationSupportRoot.debugHistoryLoadingEnvironmentKey: "1",
    ]
    XCTAssertTrue(AppApplicationSupportRoot.shouldHoldHistoryLoading(
      environment: base,
      fileExists: { $0 == sentinel }
    ))
    XCTAssertFalse(AppApplicationSupportRoot.shouldHoldHistoryLoading(
      environment: base,
      fileExists: { _ in false }
    ))
    var canonicalRoot = base; canonicalRoot[AppApplicationSupportRoot.smokeOverrideEnvironmentKey] = "/tmp/linkdigest-history-state.session/Application Support"
    XCTAssertTrue(AppApplicationSupportRoot.shouldHoldHistoryLoading(
      environment: canonicalRoot,
      fileExists: { $0 == sentinel }
    ))
    var wrongValue = base; wrongValue[AppApplicationSupportRoot.debugHistoryLoadingEnvironmentKey] = "true"
    XCTAssertFalse(AppApplicationSupportRoot.shouldHoldHistoryLoading(environment: wrongValue, fileExists: { _ in true }))
    var wrongPath = base; wrongPath[AppApplicationSupportRoot.smokeOverrideEnvironmentKey] = "/tmp/not-linkdigest/Application Support"
    XCTAssertFalse(AppApplicationSupportRoot.shouldHoldHistoryLoading(environment: wrongPath, fileExists: { _ in true }))
    var wrongParent = base; wrongParent[AppApplicationSupportRoot.smokeOverrideEnvironmentKey] = "/private/var/linkdigest-history-state.session/Application Support"
    XCTAssertFalse(AppApplicationSupportRoot.shouldHoldHistoryLoading(environment: wrongParent, fileExists: { _ in true }))
  }

  func testDebugVisualFixtureGateRequiresExactRootEnvironmentAndSentinel() {
    let root = "/private/tmp/linkdigest-history-state.session/Application Support"
    let sentinel = "/tmp/linkdigest-history-state.session/\(AppApplicationSupportRoot.debugVisualFixtureSentinelName)"
    let environment = [
      AppApplicationSupportRoot.smokeOverrideEnvironmentKey: root,
      AppApplicationSupportRoot.debugVisualFixtureEnvironmentKey: "1",
    ]
    XCTAssertTrue(AppApplicationSupportRoot.shouldUseVisualFixture(
      environment: environment,
      fileExists: { $0 == sentinel }
    ))
    XCTAssertFalse(AppApplicationSupportRoot.shouldUseVisualFixture(
      environment: environment,
      fileExists: { _ in false }
    ))
    var wrongValue = environment
    wrongValue[AppApplicationSupportRoot.debugVisualFixtureEnvironmentKey] = "true"
    XCTAssertFalse(AppApplicationSupportRoot.shouldUseVisualFixture(environment: wrongValue, fileExists: { _ in true }))
    var wrongRoot = environment
    wrongRoot[AppApplicationSupportRoot.smokeOverrideEnvironmentKey] = "/tmp/not-linkdigest/Application Support"
    XCTAssertFalse(AppApplicationSupportRoot.shouldUseVisualFixture(environment: wrongRoot, fileExists: { _ in true }))
  }
}

final class CaptureReceiverTests: XCTestCase {
  func testV1BrowserMediaRemainsRemoteUntilExplicitSave() throws {
    let envelope = CaptureEnvelopeV1(
      version: 1,
      requestId: "v1-remote-default",
      createdAt: "2026-07-20T00:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test/video", title: "Video", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "video body", characterCount: 10, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z"),
      evidence: .init(sourceLabel: "Current page DOM", usedCookie: false),
      media: .init(platform: "generic", videoURL: "https://media.example.test/video.mp4")
    )
    let current = CurrentCapture(
      envelope: envelope,
      taskID: TaskID(),
      snapshotID: ContentSnapshotID()
    )

    XCTAssertEqual(current.mediaDescriptor?.kind, .directFile)
    XCTAssertEqual(current.mediaDescriptor?.ephemeralPlaybackURL, envelope.media?.videoURL)
    XCTAssertFalse(current.shouldAutomaticallyPersistLegacyMedia)
  }
  func testProgrammaticInvalidV2IsRejectedBeforeRepository() async throws {
    let repository = WiringRepository()
    let ingestor = CaptureIngestService(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in }
    )
    let invalid = CaptureEnvelopeV2(
      requestId: "invalid-programmatic-v2",
      createdAt: "2026-07-20T00:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test/video", title: "Video", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "invalid media", characterCount: 13, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z"),
      evidence: .init(sourceLabel: "Current page DOM", usedCookie: false),
      media: .init(
        kind: .directFile,
        pageURL: "https://example.test/video",
        canonicalURL: "https://example.test/video",
        platform: "generic",
        transcriptionCapability: .supported
      )
    )

    do {
      _ = try await ingestor.ingest(envelope: invalid)
      XCTFail("invalid V2 must fail before repository handoff")
    } catch {}
    XCTAssertEqual(repository.acceptCaptureCallCount, 0)
  }

  func testCaptureEntrySurfaceHasNoOptionalWireMixingOrFullWireHistoryServiceOverloads() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
    let ingestSource = try String(contentsOf: sources.appendingPathComponent("LinkDigestApp/CaptureIngestService.swift"), encoding: .utf8)
    let historySource = try String(contentsOf: sources.appendingPathComponent("LinkDigestCore/HistoryApplicationService.swift"), encoding: .utf8)

    XCTAssertFalse(ingestSource.contains("wireEnvelope: CaptureEnvelopeV1?"))
    XCTAssertFalse(ingestSource.contains("wireEnvelopeV2: CaptureEnvelopeV2?"))
    XCTAssertTrue(ingestSource.contains("ingest(envelope: CaptureEnvelopeV1"))
    XCTAssertTrue(ingestSource.contains("ingest(envelope: CaptureEnvelopeV2"))
    XCTAssertTrue(historySource.contains("acceptCapture(_ command: AcceptCaptureCommand)"))
    XCTAssertFalse(historySource.contains("acceptCapture(_ envelope: CaptureEnvelopeV1"))
    XCTAssertFalse(historySource.contains("acceptCapture(_ envelope: CaptureEnvelopeV2"))
    XCTAssertFalse(historySource.contains("acceptCapture(_ document: CapturedDocument"))
  }

  func testGRDBDefensivelyRejectsMismatchedClosedProvenanceBeforeAnyWrite() throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-m1-provenance-defense-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(directoryURL: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      requestID: "manual-defense",
      createdAt: "2026-07-20T00:00:00Z",
      idempotencyKey: "manual-defense",
      origin: .manualLink,
      url: "https://example.test/manual-defense",
      title: "Manual",
      platform: "generic",
      method: "public_html",
      text: "manual defense body",
      completeness: "full_article",
      capturedAt: "2026-07-20T00:00:00Z",
      sourceLabel: "manual fixture"
    )
    let malformed = [
      CaptureDeliveryProvenance(
        deliveryKey: "capture:v2:id:manual-defense",
        captureContractVersion: 2,
        semanticPayloadSHA256: String(repeating: "a", count: 64)
      ),
      CaptureDeliveryProvenance(
        deliveryKey: "manual:v1:id:wrong-suffix",
        captureContractVersion: 1,
        semanticPayloadSHA256: String(repeating: "a", count: 64)
      ),
      CaptureDeliveryProvenance(
        deliveryKey: "manual:v1:id:manual-defense",
        captureContractVersion: 1,
        semanticPayloadSHA256: String(repeating: "A", count: 64)
      ),
    ]

    for provenance in malformed {
      let command = AcceptCaptureCommand(
        validatedDocument: document,
        provenance: provenance,
        receivedAtMilliseconds: 1
      )
      XCTAssertThrowsError(try repository.acceptCapture(command)) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidInput)
      }
    }
    XCTAssertEqual(
      try DatabaseMaintenance(database: repository.database).counts(),
      .init(tasks: 0, snapshots: 0, deliveries: 0, runs: 0, artifacts: 0)
    )
  }

  func testV2EphemeralPlaybackURLStaysInCurrentCaptureAndOutOfPersistenceInput() async throws {
    let sentinel = "https://media.example.test/video.mp4?ephemeral-sentinel=only-in-memory"
    let posterSentinel = "https://images.example.test/poster.jpg?poster-sentinel=only-in-digest"
    let expiresSentinel = "2099-07-20T00:01:00Z"
    let mediaPageSentinel = "https://media-page.example.test/watch?descriptor-only=1"
    let envelope = CaptureEnvelopeV2(
      requestId: "v2-memory-only",
      createdAt: "2026-07-20T00:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test/video", title: "Video", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "video page body", characterCount: 15, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z"),
      evidence: .init(sourceLabel: "Current page DOM", usedCookie: false),
      media: .init(
        kind: .directFile,
        pageURL: mediaPageSentinel,
        canonicalURL: "https://example.test/video",
        platform: "generic",
        ephemeralPlaybackURL: sentinel,
        mimeType: "video/mp4",
        posterURL: posterSentinel,
        expiresAt: expiresSentinel,
        transcriptionCapability: .supported
      )
    )
    let log = WiringEventLog()
    let sink = V2CaptureObservationSink()
    let repository = WiringRepository(log: log)
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    guard case .taskAccepted = await receiver.process(try JSONEncoder().encode(envelope)) else {
      return XCTFail("V2 should be accepted with the existing v1 ACK")
    }
    let observedURL = await sink.ephemeralPlaybackURL
    let legacyMediaWasPresent = await sink.legacyMediaWasPresent
    let wireVersion = await sink.wireVersion
    XCTAssertEqual(observedURL, sentinel)
    XCTAssertFalse(repository.lastAcceptedCommandDescription.contains(sentinel), "repository port must not observe the transient descriptor")
    XCTAssertFalse(repository.lastAcceptedCommandDescription.contains(posterSentinel), "poster URL must be reduced to the irreversible digest before the repository port")
    XCTAssertFalse(repository.lastAcceptedCommandDescription.contains(expiresSentinel))
    XCTAssertFalse(repository.lastAcceptedCommandDescription.contains(mediaPageSentinel))
    XCTAssertFalse(repository.lastAcceptedCommandDescription.contains("MediaDescriptor"))
    XCTAssertEqual(repository.lastAcceptedProvenance?.captureContractVersion, 2)
    XCTAssertTrue(repository.lastAcceptedProvenance?.deliveryKey.hasPrefix("capture:v2:") == true)
    XCTAssertEqual(repository.lastAcceptedProvenance?.semanticPayloadSHA256.count, 64)
    XCTAssertFalse(legacyMediaWasPresent)
    XCTAssertEqual(wireVersion, 2)
  }

  func testV2EphemeralPlaybackURLNeverEntersTemporarySQLiteExportOrLegacyMediaTable() async throws {
    let sentinel = "https://v3.douyinvod.com/video.mp4?ephemeral-sentinel=sqlite-scan"
    let posterSentinel = "https://images.example.test/poster.jpg?poster-sentinel=sqlite-scan"
    let expiresSentinel = "2099-07-20T00:02:00Z"
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-m1-v2-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = LocalDatabaseLocation(directoryURL: root)
    let repository = try GRDBHistoryRepository.open(at: location)
    let history = HistoryApplicationService(repository: repository)
    let sink = V2CaptureObservationSink()
    let envelope = CaptureEnvelopeV2(
      requestId: "v2-sqlite-only",
      createdAt: "2026-07-20T00:00:00Z",
      idempotencyKey: "v2-sqlite-only",
      source: .init(kind: "browser_capture", url: "https://example.test/video", title: "Video", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "persistent page body", characterCount: 20, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z"),
      evidence: .init(
        sourceLabel: "Current page DOM + same-origin session detail",
        usedCookie: true
      ),
      media: .init(
        kind: .directFile,
        pageURL: "https://example.test/video",
        canonicalURL: "https://example.test/video",
        platform: "generic",
        ephemeralPlaybackURL: sentinel,
        mimeType: "video/mp4",
        posterURL: posterSentinel,
        expiresAt: expiresSentinel,
        transcriptionCapability: .supported
      )
    )
    let receiver = CaptureReceiver(
      history: history,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    guard case .taskAccepted = await receiver.process(try JSONEncoder().encode(envelope)) else {
      return XCTFail("V2 should persist its page document")
    }
    let observedTaskID = await sink.taskID
    let taskID = try XCTUnwrap(observedTaskID)
    XCTAssertTrue(try history.detail(taskID: taskID).snapshots[0].usedCookie)
    let projection = try history.exportProjection(taskID: taskID)
    XCTAssertFalse(String(describing: projection).contains(sentinel))
    XCTAssertFalse(projection.snapshots[0].usedCookie, "exports keep cookie-use evidence private")
    XCTAssertNil(try history.mediaAsset(taskID: taskID), "M1 V2 must not create a legacy media_assets row")
    try repository.database.close()

    for forbidden in [sentinel, posterSentinel, expiresSentinel] {
      let needle = Data(forbidden.utf8)
      for url in [location.databaseURL, location.walURL, location.sharedMemoryURL]
        where FileManager.default.fileExists(atPath: url.path) {
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: needle), "media descriptor value leaked into \(url.lastPathComponent)")
      }
    }
  }

  func testCommitPrecedesUISinkAndSuccessACKCarriesOriginalContract() async throws {
    let log = WiringEventLog()
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    let repository = WiringRepository(
      log: log,
      captureResult: .init(
        taskID: taskID,
        snapshotID: snapshotID,
        taskWasCreated: true,
        snapshotWasCreated: true,
        deliveryWasReplayed: false
      )
    )
    let sink = WiringCaptureSink()
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 42 },
      captureSink: {
        log.append("ui")
        await sink.receive($0)
      }
    )

    let envelope = capture()
    let response = await receiver.process(try JSONEncoder().encode(envelope))

    XCTAssertEqual(log.values, ["capture-commit", "ui"])
    let receivedCaptures = await sink.captures
    XCTAssertEqual(receivedCaptures.first?.taskID, taskID)
    XCTAssertEqual(receivedCaptures.first?.snapshotID, snapshotID)
    XCTAssertEqual(
      response,
      .taskAccepted(version: 1, requestId: envelope.requestId, characterCount: envelope.capture.characterCount)
    )
  }

  func testCaptureUIAndACKWaitForCommitSuccessNotMethodEntry() async throws {
    let log = WiringEventLog()
    let blocker = CommitBlocker()
    let repository = WiringRepository(log: log, captureBlocker: blocker)
    let sink = WiringCaptureSink()
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 42 },
      captureSink: { await sink.receive($0) }
    )

    let processing = Task { await receiver.process(try! JSONEncoder().encode(capture())) }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(log.values, ["capture-entry"])
    let beforeCommit = await sink.captures
    XCTAssertTrue(beforeCommit.isEmpty)
    blocker.release.signal()
    let response = await processing.value
    guard case .taskAccepted = response else { return XCTFail("ACK must follow commit") }
    XCTAssertEqual(log.values, ["capture-entry", "capture-commit"])
    let afterCommit = await sink.captures
    XCTAssertEqual(afterCommit.count, 1)
  }

  func testConcurrentCaptureFailureLinearizesBeforeSecondRepositoryAuthorization() async throws {
    let blocker = CommitBlocker()
    let repository = WiringRepository(
      captureFailure: .unavailable,
      captureBlocker: blocker
    )
    let captures = WiringCaptureSink()
    let availability = WiringAvailabilitySink()
    let gate = StorageWriteGate(
      initialAvailability: .writable,
      availabilitySink: { await availability.receive($0) }
    )
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: gate,
      nowMilliseconds: { 1 },
      captureSink: { await captures.receive($0) }
    )

    let first = Task {
      await receiver.process(
        try! JSONEncoder().encode(capture(requestID: "linearized-a"))
      )
    }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(repository.acceptCaptureCallCount, 1)

    let second = Task {
      await receiver.process(
        try! JSONEncoder().encode(capture(requestID: "linearized-b"))
      )
    }
    await gate.waitForQueuedCaptureAttempt()
    XCTAssertEqual(repository.acceptCaptureCallCount, 1)
    let capturesBeforeRelease = await captures.captures
    XCTAssertTrue(capturesBeforeRelease.isEmpty)

    blocker.release.signal()
    let responses = await [first.value, second.value]
    let presentation = StorageErrorMapper.presentation(for: .writeFailed)
    for response in responses {
      guard case let .error(error) = response else {
        return XCTFail("neither concurrent Capture may ACK")
      }
      XCTAssertEqual(error.code, presentation.code.rawValue)
      XCTAssertEqual(error.retryable, presentation.retryable)
      XCTAssertEqual(error.action, presentation.action)
      XCTAssertNil(error.safeDetail)
    }
    XCTAssertEqual(repository.acceptCaptureCallCount, 1)
    let receivedCaptures = await captures.captures
    let availabilityValues = await availability.values
    XCTAssertTrue(receivedCaptures.isEmpty)
    XCTAssertEqual(availabilityValues, [.unavailable(.writeFailed)])
  }

  func testDuplicateRefreshesOldIDsWhileConflictAndStorageFailureNeverReachUI() async throws {
    let oldTaskID = TaskID(), oldSnapshotID = ContentSnapshotID()
    let duplicateSink = WiringCaptureSink()
    let duplicate = CaptureReceiver(
      history: HistoryApplicationService(repository: WiringRepository(captureResult: .init(
        taskID: oldTaskID,
        snapshotID: oldSnapshotID,
        taskWasCreated: false,
        snapshotWasCreated: false,
        deliveryWasReplayed: true
      ))),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await duplicateSink.receive($0) }
    )
    guard case .taskAccepted = await duplicate.process(try JSONEncoder().encode(capture())) else {
      return XCTFail("duplicate must ACK")
    }
    let duplicateCaptures = await duplicateSink.captures
    XCTAssertEqual(duplicateCaptures.first?.taskID, oldTaskID)

    for failure in [RepositoryFailure.captureIdempotencyConflict, .unavailable] {
      let sink = WiringCaptureSink()
      let receiver = CaptureReceiver(
        history: HistoryApplicationService(repository: WiringRepository(captureFailure: failure)),
        storageWriteGate: StorageWriteGate(initialAvailability: .writable),
        nowMilliseconds: { 1 },
        captureSink: { await sink.receive($0) }
      )
      let response = await receiver.process(try JSONEncoder().encode(capture()))
      guard case let .error(error) = response else { return XCTFail("expected error") }
      XCTAssertEqual(error.category, "storage")
      XCTAssertNil(error.safeDetail)
      let failedCaptures = await sink.captures
      XCTAssertTrue(failedCaptures.isEmpty)
    }
  }

  @MainActor
  func testCaptureStorageFailurePreservesExistingSuccessfulCaptureAndDisablesRuns() async throws {
    let model = AppViewModel()
    let existing = CurrentCapture(envelope: capture(requestID: "existing"), taskID: TaskID(), snapshotID: ContentSnapshotID())
    model.receive(existing)
    model.setStorageAvailability(.writable)
    let gate = StorageWriteGate(
      initialAvailability: .writable,
      availabilitySink: { await model.setStorageAvailability($0) }
    )
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: WiringRepository(captureFailure: .unavailable)),
      storageWriteGate: gate,
      nowMilliseconds: { 1 },
      captureSink: { await model.receive($0) }
    )

    guard case .error = await receiver.process(try JSONEncoder().encode(capture(requestID: "failed"))) else {
      return XCTFail("expected storage rejection")
    }
    XCTAssertEqual(model.currentCapture, existing)
    XCTAssertEqual(model.storageAvailability, .unavailable(.writeFailed))
    XCTAssertFalse(model.canStartRun)
  }

  @MainActor
  func testCaptureFailureClosesSharedGateAndLaterRepositorySuccessCannotRestoreWrites() async throws {
    let model = AppViewModel()
    let existing = CurrentCapture(
      envelope: capture(requestID: "existing-success"),
      taskID: TaskID(),
      snapshotID: ContentSnapshotID()
    )
    model.receive(existing)
    model.setStorageAvailability(.writable)
    let repository = ToggleCaptureRepository()
    let captures = WiringCaptureSink()
    let gate = StorageWriteGate(
      initialAvailability: .writable,
      availabilitySink: { await model.setStorageAvailability($0) }
    )
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: gate,
      nowMilliseconds: { 1 },
      captureSink: {
        await captures.receive($0)
        await model.receive($0)
      }
    )

    let first = await receiver.process(try JSONEncoder().encode(capture(requestID: "first-failure")))
    repository.allowSuccess()
    await gate.markWritableAfterBootstrap()
    let second = await receiver.process(try JSONEncoder().encode(capture(requestID: "second-after-failure")))

    for response in [first, second] {
      guard case let .error(error) = response else {
        return XCTFail("closed gate must never ACK")
      }
      let presentation = StorageErrorMapper.presentation(for: .writeFailed)
      XCTAssertEqual(error.code, presentation.code.rawValue)
      XCTAssertEqual(error.retryable, presentation.retryable)
      XCTAssertEqual(error.action, presentation.action)
      XCTAssertNil(error.safeDetail)
    }
    XCTAssertEqual(repository.acceptCaptureCallCount, 1)
    let gateAvailability = await gate.currentAvailability()
    let receivedCaptures = await captures.captures
    XCTAssertEqual(gateAvailability, .unavailable(.writeFailed))
    XCTAssertEqual(model.storageAvailability, .unavailable(.writeFailed))
    XCTAssertEqual(model.currentCapture, existing)
    XCTAssertTrue(receivedCaptures.isEmpty)
  }

  func testDynamicSentinelPathNeverEntersResponseUIOrSnapshot() async throws {
    let sentinel = FileManager.default.temporaryDirectory
      .appendingPathComponent("sentinel-\(UUID().uuidString)/history.sqlite").path
    final class SentinelRepository: HistoryRepository, @unchecked Sendable {
      let accessMode: HistoryRepositoryAccessMode = .writable
      let sentinel: String
      init(_ sentinel: String) { self.sentinel = sentinel }
      func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw NSError(domain: sentinel, code: 1) }
      func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw NSError(domain: sentinel, code: 1) }
      func markRunRunning(_: MarkRunRunningCommand) throws { throw NSError(domain: sentinel, code: 1) }
      func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw NSError(domain: sentinel, code: 1) }
      func finishRun(_: FinishRunCommand) throws { throw NSError(domain: sentinel, code: 1) }
      func recoverInterruptedRuns(at _: Int64) throws -> Int { throw NSError(domain: sentinel, code: 1) }
      func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw NSError(domain: sentinel, code: 1) }
      func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw NSError(domain: sentinel, code: 1) }
      func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw NSError(domain: sentinel, code: 1) }
      func deleteTask(taskID _: TaskID) throws { throw NSError(domain: sentinel, code: 1) }
    }
    let sink = WiringCaptureSink()
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: SentinelRepository(sentinel)),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )
    let response = await receiver.process(try JSONEncoder().encode(capture()))
    let responseJSON = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    let ui = StorageErrorCatalog.presentation(for: .writeFailed).visibleText
    let snapshots = String(describing: await sink.captures)
    XCTAssertFalse(responseJSON.contains(sentinel))
    XCTAssertFalse(ui.contains(sentinel))
    XCTAssertFalse(snapshots.contains(sentinel))
    let received = await sink.captures
    XCTAssertTrue(received.isEmpty)
  }

  func testConcurrentCapturesKeepEnvelopeTaskAndSnapshotIdentityGrouped() async throws {
    let repository = ConcurrentCaptureRepository()
    let sink = WiringCaptureSink()
    let receiver = CaptureReceiver(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )
    let envelopes = (0..<24).map { capture(requestID: "concurrent-\($0)") }
    let responses = await withTaskGroup(of: NativeResponse.self, returning: [NativeResponse].self) { group in
      for envelope in envelopes {
        group.addTask { await receiver.process(try! JSONEncoder().encode(envelope)) }
      }
      var values: [NativeResponse] = []
      for await response in group { values.append(response) }
      return values
    }

    XCTAssertEqual(responses.count, envelopes.count)
    XCTAssertTrue(responses.allSatisfy { if case .taskAccepted = $0 { true } else { false } })
    let captures = await sink.captures
    XCTAssertEqual(captures.count, envelopes.count)
    for current in captures {
      let wireEnvelope = try XCTUnwrap(current.wireEnvelope)
      let expected = try XCTUnwrap(repository.expected(for: wireEnvelope.requestId))
      XCTAssertEqual(current.taskID, expected.0)
      XCTAssertEqual(current.snapshotID, expected.1)
    }
  }

  func testValidationUsesFixedUnknownRequestIDAndStorageErrorsUseDecodedRequestID() async throws {
    let sink = WiringCaptureSink()
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(initialAvailability: .unavailable(.futureSchema)),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    guard case let .error(invalid) = await receiver.process(Data("not-json".utf8)) else {
      return XCTFail("expected validation error")
    }
    XCTAssertEqual(invalid.requestId, "app-receiver")
    XCTAssertEqual(invalid.category, "protocol")

    let envelope = capture(requestID: "decoded-request")
    guard case let .error(storage) = await receiver.process(try JSONEncoder().encode(envelope)) else {
      return XCTFail("expected storage error")
    }
    XCTAssertEqual(storage.requestId, "decoded-request")
    XCTAssertEqual(storage.code, StorageErrorCode.futureSchema.rawValue)
    XCTAssertEqual(storage.category, "storage")
    XCTAssertNil(storage.safeDetail)
  }
}

private func capture(requestID: String = "request-02b") -> CaptureEnvelopeV1 {
  CaptureEnvelopeV1(
    version: 1,
    requestId: requestID,
    createdAt: "2026-07-15T04:00:00Z",
    idempotencyKey: "delivery-02b",
    source: .init(kind: "browser_capture", url: "https://example.test/article", title: "Fixture", platform: "generic"),
    capture: .init(method: "rendered_dom", text: "fixture body", characterCount: 12, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"),
    evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
  )
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock(); defer { unlock() }
    return try body()
  }
}
