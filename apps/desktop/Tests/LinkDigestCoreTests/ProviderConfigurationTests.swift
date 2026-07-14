import Foundation
import XCTest
@testable import LinkDigestCore

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
  private var deletedReferences: [SecretReference] = []

  init(
    values: [SecretReference: String] = [:],
    failSave: Bool = false
  ) {
    self.values = values
    self.failSave = failSave
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
}
