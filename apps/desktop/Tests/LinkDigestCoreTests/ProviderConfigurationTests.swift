import Foundation
import XCTest
@testable import LinkDigestCore

private actor CoreAsyncBarrier {
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

private actor BarrierSecretStore: SecretStore {
  private var values: [SecretReference: String]
  private let readBarrier: CoreAsyncBarrier?
  private let saveBarrier: CoreAsyncBarrier?
  private var shouldFailNextSave: Bool

  init(
    values: [SecretReference: String],
    readBarrier: CoreAsyncBarrier? = nil,
    saveBarrier: CoreAsyncBarrier? = nil,
    failNextSave: Bool = false
  ) {
    self.values = values
    self.readBarrier = readBarrier
    self.saveBarrier = saveBarrier
    shouldFailNextSave = failNextSave
  }

  func save(_ secret: String, for reference: SecretReference) async throws {
    if let saveBarrier { await saveBarrier.suspend() }
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw SecretStoreFailure(operation: .write, status: -1)
    }
    values[reference] = secret
  }

  func read(_ reference: SecretReference) async throws -> String? {
    if let readBarrier { await readBarrier.suspend() }
    return values[reference]
  }

  func contains(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
  func delete(_ reference: SecretReference) async throws { values.removeValue(forKey: reference) }
}

private actor MemoryProviderProfileStore: ProviderProfileStore {
  private var profile: ProviderProfile?
  private let failLoad: Bool
  private let failSave: Bool
  private var saveCount = 0

  init(
    profile: ProviderProfile? = nil,
    failLoad: Bool = false,
    failSave: Bool = false
  ) {
    self.profile = profile
    self.failLoad = failLoad
    self.failSave = failSave
  }

  func load() async throws -> ProviderProfile? {
    if failLoad {
      throw ProviderProfileStoreFailure.readFailed
    }
    return profile
  }

  func save(_ profile: ProviderProfile) async throws {
    if failSave {
      throw ProviderProfileStoreFailure.writeFailed
    }
    self.profile = profile
    saveCount += 1
  }

  func delete() async throws {
    profile = nil
  }

  func snapshot() -> ProviderProfile? {
    profile
  }

  func saves() -> Int {
    saveCount
  }
}

private actor MemorySecretStore: SecretStore {
  private var values: [SecretReference: String]
  private let failSave: Bool
  private let failDelete: Bool
  private var deletedReferences: [SecretReference] = []

  init(
    values: [SecretReference: String] = [:],
    failSave: Bool = false,
    failDelete: Bool = false
  ) {
    self.values = values
    self.failSave = failSave
    self.failDelete = failDelete
  }

  func save(_ secret: String, for reference: SecretReference) async throws {
    if failSave {
      throw SecretStoreFailure(operation: .write, status: -1)
    }
    values[reference] = secret
  }

  func read(_ reference: SecretReference) async throws -> String? {
    values[reference]
  }

  func contains(_ reference: SecretReference) async throws -> Bool {
    values[reference] != nil
  }

  func delete(_ reference: SecretReference) async throws {
    if failDelete {
      throw SecretStoreFailure(operation: .delete, status: -1)
    }
    values.removeValue(forKey: reference)
    deletedReferences.append(reference)
  }

  func value(for reference: SecretReference) -> String? {
    values[reference]
  }

  func wasDeleted(_ reference: SecretReference) -> Bool {
    deletedReferences.contains(reference)
  }
}

final class ProviderConfigurationTests: XCTestCase {
  func testProviderAuthorizationDescriptionsAreAlwaysFixedAndRedacted() async throws {
    let sentinelKey = "sentinel-key-\(UUID().uuidString)"
    let sentinelReference = SecretReference(rawValue: "sentinel-reference-\(UUID().uuidString)")
    let sentinelHost = "sentinel-destination.example.test"
    let sentinelModel = "sentinel-model-\(UUID().uuidString)"
    let profile = try ProviderProfile(
      baseURL: "https://\(sentinelHost)/private/v1",
      model: sentinelModel,
      secretReference: sentinelReference
    )
    let service = ProviderConfigurationService(
      profileStore: MemoryProviderProfileStore(profile: profile),
      secretStore: MemorySecretStore(values: [sentinelReference: sentinelKey])
    )
    let loadedAuthorization = try await service.authorize(
      for: DataDestinationIdentity(profile: profile)
    )
    let authorization = try XCTUnwrap(loadedAuthorization)

    var debugOutput = ""
    debugPrint(authorization, to: &debugOutput)
    var dumpOutput = ""
    dump(authorization, to: &dumpOutput)
    let mirror = Mirror(reflecting: authorization)
    let mirrorChildren = mirror.children.map { child in
      "\(child.label ?? "nil")=\(String(reflecting: child.value))"
    }.joined(separator: ",")
    let outputs = [
      String(describing: authorization),
      String(reflecting: authorization),
      "\(authorization)",
      debugOutput,
      dumpOutput,
      mirrorChildren
    ]

    for output in outputs {
      XCTAssertTrue(output.contains("[REDACTED]"))
      for forbidden in [
        sentinelKey,
        sentinelReference.rawValue,
        sentinelHost,
        sentinelModel,
        profile.baseURL.absoluteString,
        DataDestinationIdentity(profile: profile).normalizedBaseURL
      ] {
        XCTAssertFalse(output.contains(forbidden), "authorization description leaked \(forbidden)")
      }
    }
    XCTAssertEqual(String(describing: authorization), "ProviderAuthorization([REDACTED])")
    XCTAssertEqual(String(reflecting: authorization), "ProviderAuthorization([REDACTED])")
    XCTAssertEqual(mirror.displayStyle, .struct)
    XCTAssertEqual(mirror.children.count, 1)
    XCTAssertEqual(mirror.children.first?.label, "authorization")
    XCTAssertEqual(mirrorChildren, "authorization=\"[REDACTED]\"")
    XCTAssertTrue(dumpOutput.contains("[REDACTED]"))
  }

  func testProviderProfileEncodingNeverContainsSubmittedAPIKey() throws {
    let submittedKey = UUID().uuidString
    let profile = try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: UUID().uuidString)
    )

    let encoded = try JSONEncoder().encode(profile)
    let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertFalse(encodedText.contains(submittedKey))
    XCTAssertTrue(encodedText.contains("chat_completions"))
    XCTAssertEqual(profile.apiMode, .chatCompletions)
  }

  func testBaseURLValidation() throws {
    XCTAssertNoThrow(
      try ProviderProfile.validatedBaseURL("https://example.test/v1")
    )
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL(""))
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL("http://example.test/v1"))
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL("https://user@example.test/v1"))
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL("https://example.test/v1?x=1"))
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL("https://example.test/v1#fragment"))
    XCTAssertThrowsError(try ProviderProfile.validatedBaseURL("http://127.0.0.1:8080/v1"))
    XCTAssertNoThrow(
      try ProviderProfile.validatedBaseURL(
        "http://127.0.0.1:8080/v1",
        allowLoopbackHTTP: true
      )
    )
  }

  func testSecretWriteFailureDoesNotCommitProfileReference() async throws {
    let profileStore = MemoryProviderProfileStore()
    let secretStore = MemorySecretStore(failSave: true)
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      makeSecretReference: { SecretReference(rawValue: "staged-reference") }
    )

    do {
      _ = try await service.save(
        baseURL: "https://example.test/v1",
        model: "fixture-model",
        apiKey: UUID().uuidString
      )
      XCTFail("Expected secret store failure")
    } catch let error as ProviderConfigurationError {
      XCTAssertEqual(error, .secretStoreWriteFailed)
    }

    let savedProfile = await profileStore.snapshot()
    let saveCount = await profileStore.saves()
    XCTAssertNil(savedProfile)
    XCTAssertEqual(saveCount, 0)
  }

  func testProfileFailureDeletesStagedSecretAndKeepsProfileEmpty() async throws {
    let stagedReference = SecretReference(rawValue: "staged-reference")
    let profileStore = MemoryProviderProfileStore(failSave: true)
    let secretStore = MemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      makeSecretReference: { stagedReference }
    )

    do {
      _ = try await service.save(
        baseURL: "https://example.test/v1",
        model: "fixture-model",
        apiKey: UUID().uuidString
      )
      XCTFail("Expected profile store failure")
    } catch let error as ProviderConfigurationError {
      XCTAssertEqual(error, .profileStoreWriteFailed)
    }

    let savedProfile = await profileStore.snapshot()
    let stagedSecret = await secretStore.value(for: stagedReference)
    let stagedWasDeleted = await secretStore.wasDeleted(stagedReference)
    XCTAssertNil(savedProfile)
    XCTAssertNil(stagedSecret)
    XCTAssertTrue(stagedWasDeleted)
  }

  func testReplacementCommitsNewReferenceBeforeRemovingOldSecret() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let newReference = SecretReference(rawValue: "new-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let profileStore = MemoryProviderProfileStore(profile: oldProfile)
    let secretStore = MemorySecretStore(values: [oldReference: UUID().uuidString])
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      makeSecretReference: { newReference }
    )

    let newSecret = UUID().uuidString
    let profile = try await service.save(
      baseURL: "https://new.example.test/v1",
      model: "new-model",
      apiKey: newSecret
    )

    let savedProfile = await profileStore.snapshot()
    let savedSecret = await secretStore.value(for: newReference)
    let oldSecret = await secretStore.value(for: oldReference)
    XCTAssertEqual(profile.secretReference, newReference)
    XCTAssertEqual(savedProfile?.secretReference, newReference)
    XCTAssertEqual(savedSecret, newSecret)
    XCTAssertNil(oldSecret)
  }

  func testReplacementReportsOldSecretCleanupFailureAfterCommittingNewConfiguration() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let newReference = SecretReference(rawValue: "new-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let profileStore = MemoryProviderProfileStore(profile: oldProfile)
    let secretStore = MemorySecretStore(
      values: [oldReference: "old-key"],
      failDelete: true
    )
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      makeSecretReference: { newReference }
    )

    await assertProviderConfigurationError(.secretStoreDeleteFailed) {
      try await service.save(
        baseURL: "https://new.example.test/v1",
        model: "new-model",
        apiKey: "new-key"
      )
    }

    let savedProfile = await profileStore.snapshot()
    let oldSecret = await secretStore.value(for: oldReference)
    let newSecret = await secretStore.value(for: newReference)
    XCTAssertEqual(savedProfile?.secretReference, newReference)
    XCTAssertEqual(oldSecret, "old-key")
    XCTAssertEqual(newSecret, "new-key")
  }

  func testSaveMutationBlocksAuthorizationBeforeSecretCommit() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let saveBarrier = CoreAsyncBarrier()
    let service = ProviderConfigurationService(
      profileStore: MemoryProviderProfileStore(profile: oldProfile),
      secretStore: BarrierSecretStore(
        values: [oldReference: "old-key"],
        saveBarrier: saveBarrier
      ),
      makeSecretReference: { .init(rawValue: "new-reference") }
    )

    let saveTask = Task {
      try await service.save(
        baseURL: "https://new.example.test/v1",
        model: "new-model",
        apiKey: "new-key"
      )
    }
    await saveBarrier.waitUntilEntered()

    await assertProviderConfigurationError(.configurationChanged) {
      try await service.authorize(for: DataDestinationIdentity(profile: oldProfile))
    }

    await saveBarrier.release()
    _ = try await saveTask.value
  }

  func testAuthorizationRevisionFailsWhenSaveStartsDuringSecretRead() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let readBarrier = CoreAsyncBarrier()
    let saveBarrier = CoreAsyncBarrier()
    let service = ProviderConfigurationService(
      profileStore: MemoryProviderProfileStore(profile: oldProfile),
      secretStore: BarrierSecretStore(
        values: [oldReference: "old-key"],
        readBarrier: readBarrier,
        saveBarrier: saveBarrier
      ),
      makeSecretReference: { .init(rawValue: "new-reference") }
    )
    let authorizationTask = Task {
      try await service.authorize(for: DataDestinationIdentity(profile: oldProfile))
    }
    await readBarrier.waitUntilEntered()
    let saveTask = Task {
      try await service.save(
        baseURL: "https://new.example.test/v1",
        model: "new-model",
        apiKey: "new-key"
      )
    }
    await saveBarrier.waitUntilEntered()

    await readBarrier.release()
    await assertProviderConfigurationError(.configurationChanged) {
      try await authorizationTask.value
    }
    await saveBarrier.release()
    _ = try await saveTask.value
  }

  func testFailedSaveReleasesMutationForLaterAuthorization() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let service = ProviderConfigurationService(
      profileStore: MemoryProviderProfileStore(profile: oldProfile),
      secretStore: BarrierSecretStore(
        values: [oldReference: "old-key"],
        failNextSave: true
      ),
      makeSecretReference: { .init(rawValue: "failed-reference") }
    )

    await assertProviderConfigurationError(.secretStoreWriteFailed) {
      try await service.save(
        baseURL: "https://failed.example.test/v1",
        model: "failed-model",
        apiKey: "failed-key"
      )
    }
    let authorization = try await service.authorize(
      for: DataDestinationIdentity(profile: oldProfile)
    )
    XCTAssertNotNil(authorization)
  }

  func testSecondSaveCannotReplaceFirstMutationOwnership() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let oldProfile = try ProviderProfile(
      baseURL: "https://old.example.test/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let saveBarrier = CoreAsyncBarrier()
    let service = ProviderConfigurationService(
      profileStore: MemoryProviderProfileStore(profile: oldProfile),
      secretStore: BarrierSecretStore(
        values: [oldReference: "old-key"],
        saveBarrier: saveBarrier
      ),
      makeSecretReference: { .init(rawValue: "first-reference") }
    )
    let firstSave = Task {
      try await service.save(
        baseURL: "https://first.example.test/v1",
        model: "first-model",
        apiKey: "first-key"
      )
    }
    await saveBarrier.waitUntilEntered()

    await assertProviderConfigurationError(.configurationChanged) {
      try await service.save(
        baseURL: "https://second.example.test/v1",
        model: "second-model",
        apiKey: "second-key"
      )
    }
    await assertProviderConfigurationError(.configurationChanged) {
      try await service.authorize(for: DataDestinationIdentity(profile: oldProfile))
    }

    await saveBarrier.release()
    let firstProfile = try await firstSave.value
    let authorization = try await service.authorize(
      for: DataDestinationIdentity(profile: firstProfile)
    )
    XCTAssertNotNil(authorization)
  }

  private func assertProviderConfigurationError<T>(
    _ expected: ProviderConfigurationError,
    operation: () async throws -> T
  ) async {
    do {
      _ = try await operation()
      XCTFail("expected \(expected)")
    } catch let error as ProviderConfigurationError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}
