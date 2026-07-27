import Foundation
import XCTest
@testable import LinkDigestCore

private actor LibraryMemoryProfileStore: ProviderProfileStore {
  private(set) var profile: ProviderProfile?
  private let failDelete: Bool
  init(profile: ProviderProfile? = nil, failDelete: Bool = false) {
    self.profile = profile
    self.failDelete = failDelete
  }
  func load() async throws -> ProviderProfile? { profile }
  func save(_ profile: ProviderProfile) async throws { self.profile = profile }
  func delete() async throws {
    if failDelete { throw ProviderProfileStoreFailure.writeFailed }
    profile = nil
  }
}

private actor LibraryMemorySecretStore: SecretStore {
  private(set) var values: [SecretReference: String]
  private let failDelete: Bool
  init(values: [SecretReference: String] = [:], failDelete: Bool = false) {
    self.values = values
    self.failDelete = failDelete
  }
  func save(_ secret: String, for reference: SecretReference) async throws { values[reference] = secret }
  func read(_ reference: SecretReference) async throws -> String? { values[reference] }
  func contains(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
  func delete(_ reference: SecretReference) async throws {
    if failDelete { throw SecretStoreFailure(operation: .delete, status: -1) }
    values.removeValue(forKey: reference)
  }
}

private actor LibraryMemoryStore: ModelLibraryStore {
  private(set) var library: ModelLibrary?
  private(set) var saveCount = 0
  private let failSave: Bool
  init(library: ModelLibrary? = nil, failSave: Bool = false) {
    self.library = library
    self.failSave = failSave
  }
  func load() async throws -> ModelLibrary? { library }
  func save(_ library: ModelLibrary) async throws {
    if failSave { throw ProviderProfileStoreFailure.writeFailed }
    self.library = library
    saveCount += 1
  }
}

final class ModelLibraryServiceTests: XCTestCase {
  private func makeLegacyProfile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      secretReference: .init(rawValue: "legacy-reference")
    )
  }

  func testLoadLibraryMigratesLegacySingleProfile() async throws {
    let legacy = try makeLegacyProfile()
    let profileStore = LibraryMemoryProfileStore(profile: legacy)
    let libraryStore = LibraryMemoryStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: LibraryMemorySecretStore(values: [legacy.secretReference: "sk-legacy"]),
      libraryStore: libraryStore
    )

    let library = try await service.loadLibrary()

    XCTAssertEqual(library.profiles, [legacy])
    XCTAssertEqual(library.summaryProfileID, legacy.id)
    XCTAssertNil(library.transcriptionProfileID)
    let persisted = await libraryStore.library
    XCTAssertEqual(persisted, library)
  }

  func testAddProfileAppendsAndFirstEntryBecomesSummary() async throws {
    let profileStore = LibraryMemoryProfileStore()
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )

    let first = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )
    let second = try await service.addProfile(
      baseURL: "https://api.groq.com/openai/v1",
      model: "llama-3.3-70b",
      apiKey: "sk-two"
    )

    let library = try await service.loadLibrary()
    XCTAssertEqual(library.profiles.map(\.id), [first.id, second.id])
    XCTAssertEqual(library.summaryProfileID, first.id)
    let slot = await profileStore.profile
    XCTAssertEqual(slot, first)
    let storedFirst = await secretStore.values[first.secretReference]
    let storedSecond = await secretStore.values[second.secretReference]
    XCTAssertEqual(storedFirst, "sk-one")
    XCTAssertEqual(storedSecond, "sk-two")
  }

  func testAddProfilesSavesOneCatalogSelectionWithOneSharedSecret() async throws {
    let profileStore = LibraryMemoryProfileStore()
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )

    let profiles = try await service.addProfiles(
      baseURL: "https://api.deepseek.com/v1",
      models: ["model-a", "model-b", "model-a", "  model-c  "],
      apiKey: "sk-shared"
    )

    XCTAssertEqual(profiles.map(\.model), ["model-a", "model-b", "model-c"])
    XCTAssertEqual(Set(profiles.map(\.secretReference)).count, 1)
    let library = try await service.loadLibrary()
    let activeProfile = await profileStore.profile
    let storedSecrets = await secretStore.values
    XCTAssertEqual(library.profiles, profiles)
    XCTAssertEqual(activeProfile, profiles[0])
    XCTAssertEqual(storedSecrets.count, 1)
    XCTAssertEqual(storedSecrets[profiles[0].secretReference], "sk-shared")
  }

  func testDeletingOneBatchProfileKeepsSharedSecretForRemainingModels() async throws {
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )
    let profiles = try await service.addProfiles(
      baseURL: "https://api.deepseek.com/v1",
      models: ["model-a", "model-b"],
      apiKey: "sk-shared"
    )

    _ = try await service.deleteProfile(id: profiles[0].id)
    let retainedSecret = await secretStore.values[profiles[0].secretReference]
    XCTAssertEqual(retainedSecret, "sk-shared")

    _ = try await service.deleteProfile(id: profiles[1].id)
    let removedSecret = await secretStore.values[profiles[0].secretReference]
    XCTAssertNil(removedSecret)
  }

  func testUpdateProfileWithoutKeyKeepsSecretAndSyncsSummarySlot() async throws {
    let profileStore = LibraryMemoryProfileStore()
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )
    let added = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )

    let updated = try await service.updateProfile(
      id: added.id,
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-reasoner",
      apiKey: nil
    )

    XCTAssertEqual(updated.secretReference, added.secretReference)
    XCTAssertEqual(updated.model, "deepseek-reasoner")
    let slot = await profileStore.profile
    XCTAssertEqual(slot, updated)
    let secret = await secretStore.values[added.secretReference]
    XCTAssertEqual(secret, "sk-one")
  }

  func testUpdateProfileWithKeyRotatesSecret() async throws {
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )
    let added = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-old"
    )

    let updated = try await service.updateProfile(
      id: added.id,
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-new"
    )

    XCTAssertNotEqual(updated.secretReference, added.secretReference)
    let oldSecret = await secretStore.values[added.secretReference]
    let newSecret = await secretStore.values[updated.secretReference]
    XCTAssertNil(oldSecret)
    XCTAssertEqual(newSecret, "sk-new")
  }

  func testUpdateProfileReportsOldSecretCleanupFailureAfterCommittingUpdate() async throws {
    let oldReference = SecretReference(rawValue: "old-reference")
    let oldProfile = try ProviderProfile(
      id: "profile-id",
      baseURL: "https://api.deepseek.com/v1",
      model: "old-model",
      secretReference: oldReference
    )
    let libraryStore = LibraryMemoryStore(library: ModelLibrary(
      profiles: [oldProfile],
      summaryProfileID: oldProfile.id,
      transcriptionProfileID: nil
    ))
    let profileStore = LibraryMemoryProfileStore(profile: oldProfile)
    let secretStore = LibraryMemorySecretStore(
      values: [oldReference: "old-key"],
      failDelete: true
    )
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: libraryStore,
      makeSecretReference: { .init(rawValue: "new-reference") }
    )

    await assertProviderConfigurationError(.secretStoreDeleteFailed) {
      try await service.updateProfile(
        id: oldProfile.id,
        baseURL: "https://api.deepseek.com/v1",
        model: "new-model",
        apiKey: "new-key"
      )
    }

    let persisted = await libraryStore.library
    let active = await profileStore.profile
    let secrets = await secretStore.values
    XCTAssertEqual(persisted?.profiles.first?.model, "new-model")
    XCTAssertEqual(active?.model, "new-model")
    XCTAssertEqual(secrets[oldReference], "old-key")
    XCTAssertEqual(secrets[.init(rawValue: "new-reference")], "new-key")
  }

  func testDeleteSummaryProfileClearsSlotAndSecret() async throws {
    let profileStore = LibraryMemoryProfileStore()
    let secretStore = LibraryMemorySecretStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: LibraryMemoryStore()
    )
    let added = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )

    let library = try await service.deleteProfile(id: added.id)

    XCTAssertTrue(library.profiles.isEmpty)
    XCTAssertNil(library.summaryProfileID)
    let slot = await profileStore.profile
    XCTAssertNil(slot)
    let secret = await secretStore.values[added.secretReference]
    XCTAssertNil(secret)
  }

  func testDeleteSummaryProfileDoesNotCommitLibraryWhenActiveSlotCannotBeCleared() async throws {
    let profile = try makeLegacyProfile()
    let library = ModelLibrary(
      profiles: [profile],
      summaryProfileID: profile.id,
      transcriptionProfileID: nil
    )
    let profileStore = LibraryMemoryProfileStore(profile: profile, failDelete: true)
    let libraryStore = LibraryMemoryStore(library: library)
    let secretStore = LibraryMemorySecretStore(values: [profile.secretReference: "sk-one"])
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: libraryStore
    )

    await assertProviderConfigurationError(.profileStoreWriteFailed) {
      try await service.deleteProfile(id: profile.id)
    }

    let persisted = await libraryStore.library
    let active = await profileStore.profile
    let secret = await secretStore.values[profile.secretReference]
    XCTAssertEqual(persisted, library)
    XCTAssertEqual(active, profile)
    XCTAssertEqual(secret, "sk-one")
  }

  func testDeleteProfileDoesNotCommitConfigurationWhenSecretCleanupFails() async throws {
    let profile = try makeLegacyProfile()
    let library = ModelLibrary(
      profiles: [profile],
      summaryProfileID: nil,
      transcriptionProfileID: nil
    )
    let libraryStore = LibraryMemoryStore(library: library)
    let secretStore = LibraryMemorySecretStore(
      values: [profile.secretReference: "sk-one"],
      failDelete: true
    )
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: secretStore,
      libraryStore: libraryStore
    )

    await assertProviderConfigurationError(.secretStoreDeleteFailed) {
      try await service.deleteProfile(id: profile.id)
    }

    let persisted = await libraryStore.library
    let secret = await secretStore.values[profile.secretReference]
    XCTAssertEqual(persisted, library)
    XCTAssertEqual(secret, "sk-one")
  }

  func testDeleteProfileRestoresSlotAndSecretWhenLibraryCommitFails() async throws {
    let profile = try makeLegacyProfile()
    let library = ModelLibrary(
      profiles: [profile],
      summaryProfileID: profile.id,
      transcriptionProfileID: nil
    )
    let profileStore = LibraryMemoryProfileStore(profile: profile)
    let secretStore = LibraryMemorySecretStore(values: [profile.secretReference: "sk-one"])
    let libraryStore = LibraryMemoryStore(library: library, failSave: true)
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: secretStore,
      libraryStore: libraryStore
    )

    await assertProviderConfigurationError(.profileStoreWriteFailed) {
      try await service.deleteProfile(id: profile.id)
    }

    let persisted = await libraryStore.library
    let active = await profileStore.profile
    let secret = await secretStore.values[profile.secretReference]
    XCTAssertEqual(persisted, library)
    XCTAssertEqual(active, profile)
    XCTAssertEqual(secret, "sk-one")
  }

  func testAssignSummaryProfileSyncsSlot() async throws {
    let profileStore = LibraryMemoryProfileStore()
    let service = ProviderConfigurationService(
      profileStore: profileStore,
      secretStore: LibraryMemorySecretStore(),
      libraryStore: LibraryMemoryStore()
    )
    _ = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )
    let second = try await service.addProfile(
      baseURL: "https://api.groq.com/openai/v1",
      model: "llama-3.3-70b",
      apiKey: "sk-two"
    )

    try await service.assignSummaryProfile(id: second.id)

    let library = try await service.loadLibrary()
    XCTAssertEqual(library.summaryProfileID, second.id)
    let slot = await profileStore.profile
    XCTAssertEqual(slot, second)
  }

  func testTranscriptionAssignmentDrivesTranscriptionCredentials() async throws {
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: LibraryMemorySecretStore(),
      libraryStore: LibraryMemoryStore()
    )
    _ = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )
    let groq = try await service.addProfile(
      baseURL: "https://api.groq.com/openai/v1",
      model: "llama-3.3-70b",
      apiKey: "sk-groq"
    )

    let unassigned = try await service.loadTranscriptionCredentials()
    XCTAssertNil(unassigned)

    try await service.assignTranscriptionProfile(id: groq.id)
    let credentials = try await service.loadTranscriptionCredentials()
    XCTAssertEqual(credentials?.profile.id, groq.id)
    XCTAssertEqual(credentials?.apiKey, "sk-groq")

    try await service.assignTranscriptionProfile(id: nil)
    let cleared = try await service.loadTranscriptionCredentials()
    XCTAssertNil(cleared)
  }

  func testDeleteTranscriptionAssignedProfileFallsBackToLocal() async throws {
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: LibraryMemorySecretStore(),
      libraryStore: LibraryMemoryStore()
    )
    _ = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )
    let groq = try await service.addProfile(
      baseURL: "https://api.groq.com/openai/v1",
      model: "llama-3.3-70b",
      apiKey: "sk-groq"
    )
    try await service.assignTranscriptionProfile(id: groq.id)

    let library = try await service.deleteProfile(id: groq.id)

    XCTAssertNil(library.transcriptionProfileID)
    let credentials = try await service.loadTranscriptionCredentials()
    XCTAssertNil(credentials)
  }

  func testLoadCredentialsByProfileIDReadsEntrySecret() async throws {
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(),
      secretStore: LibraryMemorySecretStore(),
      libraryStore: LibraryMemoryStore()
    )
    _ = try await service.addProfile(
      baseURL: "https://api.deepseek.com/v1",
      model: "deepseek-chat",
      apiKey: "sk-one"
    )
    let second = try await service.addProfile(
      baseURL: "https://api.groq.com/openai/v1",
      model: "llama-3.3-70b",
      apiKey: "sk-two"
    )

    let credentials = try await service.loadCredentials(profileID: second.id)

    XCTAssertEqual(credentials?.profile.id, second.id)
    XCTAssertEqual(credentials?.apiKey, "sk-two")
  }

  func testWithoutLibraryStoreSynthesizesReadOnlyView() async throws {
    let legacy = try makeLegacyProfile()
    let service = ProviderConfigurationService(
      profileStore: LibraryMemoryProfileStore(profile: legacy),
      secretStore: LibraryMemorySecretStore(values: [legacy.secretReference: "sk-legacy"])
    )

    let library = try await service.loadLibrary()

    XCTAssertEqual(library.profiles, [legacy])
    XCTAssertEqual(library.summaryProfileID, legacy.id)
    XCTAssertNil(library.transcriptionProfileID)
    XCTAssertFalse(service.supportsModelLibrary)
    let transcription = try await service.loadTranscriptionCredentials()
    XCTAssertNil(transcription)
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
