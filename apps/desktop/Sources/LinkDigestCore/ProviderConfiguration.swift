import Foundation

public enum APIMode: String, Codable, Sendable, Equatable {
  case chatCompletions = "chat_completions"
}

public struct SecretReference: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum ProviderConfigurationError: String, Error, Codable, Sendable, Equatable {
  case baseURLRequired = "PROVIDER_BASE_URL_REQUIRED"
  case baseURLInvalid = "PROVIDER_BASE_URL_INVALID"
  case modelRequired = "PROVIDER_MODEL_REQUIRED"
  case apiKeyRequired = "PROVIDER_API_KEY_REQUIRED"
  case profileStoreReadFailed = "PROFILE_STORE_READ_FAILED"
  case profileStoreWriteFailed = "PROFILE_STORE_WRITE_FAILED"
  case secretStoreReadFailed = "SECRET_STORE_READ_FAILED"
  case secretStoreReadTimedOut = "SECRET_STORE_READ_TIMED_OUT"
  case secretStoreWriteFailed = "SECRET_STORE_WRITE_FAILED"
  case secretStoreDeleteFailed = "SECRET_STORE_DELETE_FAILED"
  case configurationChanged = "PROVIDER_CONFIGURATION_CHANGED"
}

/// Opaque, short-lived authorization for one already-confirmed destination.
/// Its fields are internal so App/UI code can pass it to Core but cannot read,
/// encode, log, or publish its Keychain value.
public struct ProviderAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomLeafReflectable {
  private static let redactedDescription = "ProviderAuthorization([REDACTED])"

  let profile: ProviderProfile
  let apiKey: String

  init(profile: ProviderProfile, apiKey: String) {
    self.profile = profile
    self.apiKey = apiKey
  }

  /// Prevents Swift's default reflection from printing the short-lived API key,
  /// Keychain reference, or destination profile through logs/interpolation.
  public var description: String { Self.redactedDescription }
  public var debugDescription: String { Self.redactedDescription }

  /// `dump` and `Mirror` bypass string descriptions by default. Expose a
  /// terminal, synthetic mirror so reflection cannot traverse the profile or
  /// short-lived API key.
  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["authorization": "[REDACTED]"],
      displayStyle: .struct
    )
  }
}

public enum ProviderProfileStoreFailure: String, Error, Sendable, Equatable {
  case readFailed = "PROFILE_STORE_READ_FAILED"
  case writeFailed = "PROFILE_STORE_WRITE_FAILED"
}

public enum SecretStoreOperation: String, Sendable, Equatable {
  case read
  case write
  case delete
}

public struct SecretStoreFailure: Error, Sendable, Equatable {
  /// 与 Security `errSecTimeout` 相同，给钥匙串读取套超时用，不引入 Security 依赖。
  public static let timeoutStatus: Int32 = -25248

  public let operation: SecretStoreOperation
  public let status: Int32

  public init(operation: SecretStoreOperation, status: Int32) {
    self.operation = operation
    self.status = status
  }

  public var isTimeout: Bool { status == Self.timeoutStatus }

  public var code: String {
    switch operation {
    case .read:
      "SECRET_STORE_READ_FAILED"
    case .write:
      "SECRET_STORE_WRITE_FAILED"
    case .delete:
      "SECRET_STORE_DELETE_FAILED"
    }
  }
}

public struct ProviderProfile: Codable, Sendable, Equatable {
  public static let defaultID = "default"

  public let id: String
  public let baseURL: URL
  public let model: String
  public let apiMode: APIMode
  public let secretReference: SecretReference

  public init(
    id: String = ProviderProfile.defaultID,
    baseURL: String,
    model: String,
    apiMode: APIMode = .chatCompletions,
    secretReference: SecretReference,
    allowLoopbackHTTP: Bool = false
  ) throws {
    let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedReference = secretReference.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedID.isEmpty, !trimmedReference.isEmpty else {
      throw ProviderConfigurationError.baseURLInvalid
    }
    guard !trimmedModel.isEmpty else {
      throw ProviderConfigurationError.modelRequired
    }

    self.id = trimmedID
    self.baseURL = try ProviderProfile.validatedBaseURL(
      baseURL,
      allowLoopbackHTTP: allowLoopbackHTTP
    )
    self.model = trimmedModel
    self.apiMode = apiMode
    self.secretReference = SecretReference(rawValue: trimmedReference)
  }

  public static func validatedBaseURL(
    _ value: String,
    allowLoopbackHTTP: Bool = false
  ) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProviderConfigurationError.baseURLRequired
    }
    guard
      var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw ProviderConfigurationError.baseURLInvalid
    }

    let allowedScheme = scheme == "https"
      || (allowLoopbackHTTP && scheme == "http" && host == "127.0.0.1")
    guard allowedScheme else {
      throw ProviderConfigurationError.baseURLInvalid
    }

    components.scheme = scheme
    guard let url = components.url else {
      throw ProviderConfigurationError.baseURLInvalid
    }
    return url
  }

  /// Produces a transient profile for a user-selected alternate model while
  /// preserving the already validated endpoint and Keychain reference. It is
  /// intentionally not persisted: the selection lives in preferences.
  public func replacing(model: String) throws -> ProviderProfile {
    try ProviderProfile(
      id: id,
      baseURL: baseURL.absoluteString,
      model: model,
      apiMode: apiMode,
      secretReference: secretReference,
      allowLoopbackHTTP: baseURL.scheme?.lowercased() == "http" && baseURL.host == "127.0.0.1"
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case baseURL
    case model
    case apiMode
    case secretReference
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let baseURL = try container.decode(URL.self, forKey: .baseURL)
    let model = try container.decode(String.self, forKey: .model)
    let apiMode = try container.decode(APIMode.self, forKey: .apiMode)
    let secretReference = try container.decode(SecretReference.self, forKey: .secretReference)
    try self.init(
      id: id,
      baseURL: baseURL.absoluteString,
      model: model,
      apiMode: apiMode,
      secretReference: secretReference,
      allowLoopbackHTTP: baseURL.scheme == "http" && baseURL.host == "127.0.0.1"
    )
  }
}

public protocol ProviderProfileStore: Sendable {
  func load() async throws -> ProviderProfile?
  func save(_ profile: ProviderProfile) async throws
  func delete() async throws
}

public protocol SecretStore: Sendable {
  func save(_ secret: String, for reference: SecretReference) async throws
  func read(_ reference: SecretReference) async throws -> String?
  func contains(_ reference: SecretReference) async throws -> Bool
  func delete(_ reference: SecretReference) async throws
}

public actor ProviderConfigurationService {
  private let profileStore: any ProviderProfileStore
  private let secretStore: any SecretStore
  /// Optional multi-profile catalog. When absent the service keeps its
  /// original single-slot behavior so existing compositions and tests are
  /// unaffected. When present, `profileStore` always holds a copy of the
  /// summary-assigned profile so run/authorize/disclosure readers stay
  /// unchanged.
  private let libraryStore: (any ModelLibraryStore)?
  /// Lets synchronous UI code know whether multi-profile editing semantics
  /// (e.g. keeping a stored secret while updating endpoint/model) apply.
  public nonisolated let supportsModelLibrary: Bool
  private let makeSecretReference: @Sendable () -> SecretReference
  private var configurationRevision: UInt64 = 0
  private var inFlightMutation: UUID?
  /// 会话级密钥缓存：同一配置修订内每个 secret 只读一次 Keychain，
  /// 自动管线多步共用同一凭据时不再反复触发钥匙串授权。只存在 actor
  /// 内存中，任何配置变更（revision 递增）立即失效；不落盘、不进日志。
  private var sessionSecretCache: [String: (revision: UInt64, value: String)] = [:]

  private func cachedOrReadSecret(_ reference: SecretReference) async throws -> String? {
    if let cached = sessionSecretCache[reference.rawValue],
       cached.revision == configurationRevision {
      return cached.value
    }
    let value = try await secretStore.read(reference)
    if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sessionSecretCache[reference.rawValue] = (configurationRevision, value)
    }
    return value
  }

  public init(
    profileStore: any ProviderProfileStore,
    secretStore: any SecretStore,
    libraryStore: (any ModelLibraryStore)? = nil,
    makeSecretReference: @escaping @Sendable () -> SecretReference = {
      SecretReference(rawValue: UUID().uuidString)
    }
  ) {
    self.profileStore = profileStore
    self.secretStore = secretStore
    self.libraryStore = libraryStore
    self.supportsModelLibrary = libraryStore != nil
    self.makeSecretReference = makeSecretReference
  }

  public func load() async throws -> ProviderProfile? {
    let revision = try beginStableRead()
    let profile: ProviderProfile?
    do {
      profile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)

    guard let profile else {
      return nil
    }

    do {
      guard try await secretStore.contains(profile.secretReference) else {
        throw ProviderConfigurationError.secretStoreReadFailed
      }
    } catch {
      throw mapSecretStoreReadError(error)
    }
    try validateStableRead(revision)
    return profile
  }

  /// Reads only the non-sensitive profile for the data-destination notice.
  /// Unlike `load()` and `loadCredentials()`, this intentionally does not
  /// consult Keychain: disclosure must not require reading a secret just to
  /// tell the user where their captured content would go.
  public func loadProfileForDisclosure() async throws -> ProviderProfile? {
    let revision = try beginStableRead()
    do {
      let profile = try await profileStore.load()
      try validateStableRead(revision)
      return profile
    } catch let error as ProviderConfigurationError {
      throw error
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
  }

  /// Loads the active non-sensitive profile together with its Keychain-backed
  /// secret for one short-lived model request. Callers must not persist the
  /// returned API key or place it in observable state.
  public func loadCredentials() async throws -> (profile: ProviderProfile, apiKey: String)? {
    let revision = try beginStableRead()
    let profile: ProviderProfile?
    do {
      profile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)

    guard let profile else {
      return nil
    }

    let apiKey: String
    do {
      guard
        let value = try await cachedOrReadSecret(profile.secretReference),
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ProviderConfigurationError.secretStoreReadFailed
      }
      apiKey = value
    } catch {
      throw mapSecretStoreReadError(error)
    }
    try validateStableRead(revision)

    let verifiedProfile: ProviderProfile?
    do {
      verifiedProfile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)
    guard verifiedProfile == profile else {
      throw ProviderConfigurationError.configurationChanged
    }
    return (profile, apiKey)
  }

  /// Creates an opaque authorization for the exact non-sensitive identity the
  /// user approved. Actor reentrancy matters here: profile is read before and
  /// after Keychain access, and both identity and reference must still match.
  public func authorize(
    for expectedIdentity: DataDestinationIdentity
  ) async throws -> ProviderAuthorization? {
    let revision = try beginStableRead()
    let firstProfile: ProviderProfile?
    do {
      firstProfile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)
    guard let firstProfile else { return nil }
    guard DataDestinationIdentity(profile: firstProfile) == expectedIdentity else {
      throw ProviderConfigurationError.configurationChanged
    }

    let apiKey: String
    do {
      guard let value = try await cachedOrReadSecret(firstProfile.secretReference),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ProviderConfigurationError.secretStoreReadFailed }
      apiKey = value
    } catch {
      throw mapSecretStoreReadError(error)
    }
    try validateStableRead(revision)

    let secondProfile: ProviderProfile?
    do {
      secondProfile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)
    guard let secondProfile,
          DataDestinationIdentity(profile: secondProfile) == expectedIdentity,
          secondProfile.secretReference == firstProfile.secretReference
    else {
      throw ProviderConfigurationError.configurationChanged
    }
    return ProviderAuthorization(profile: firstProfile, apiKey: apiKey)
  }

  public func save(
    baseURL: String,
    model: String,
    apiKey: String,
    allowLoopbackHTTP: Bool = false
  ) async throws -> ProviderProfile {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw ProviderConfigurationError.apiKeyRequired
    }

    let newReference = makeSecretReference()
    let newProfile = try ProviderProfile(
      baseURL: baseURL,
      model: model,
      secretReference: newReference,
      allowLoopbackHTTP: allowLoopbackHTTP
    )
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    let previousProfile: ProviderProfile?
    do {
      previousProfile = try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }

    do {
      try await secretStore.save(trimmedKey, for: newReference)
    } catch {
      throw ProviderConfigurationError.secretStoreWriteFailed
    }

    do {
      try await profileStore.save(newProfile)
    } catch {
      try? await secretStore.delete(newReference)
      throw ProviderConfigurationError.profileStoreWriteFailed
    }

    if let previousReference = previousProfile?.secretReference,
       previousReference != newReference {
      do {
        try await secretStore.delete(previousReference)
      } catch {
        throw ProviderConfigurationError.secretStoreDeleteFailed
      }
    }

    return newProfile
  }

  // MARK: - Model library (multi-profile catalog)

  /// Loads the library, adopting the legacy single profile as the first entry
  /// on first read after the update. Without a library store this synthesizes
  /// a read-only view over the single slot.
  public func loadLibrary() async throws -> ModelLibrary {
    let revision = try beginStableRead()
    guard let libraryStore else {
      let active = try await loadLegacyProfile()
      try validateStableRead(revision)
      return ModelLibrary(
        profiles: active.map { [$0] } ?? [],
        summaryProfileID: active?.id,
        transcriptionProfileID: nil
      )
    }
    let stored: ModelLibrary?
    do {
      stored = try await libraryStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    try validateStableRead(revision)
    if let stored { return stored }

    let legacy = try await loadLegacyProfile()
    try validateStableRead(revision)
    let migrated = ModelLibrary(
      profiles: legacy.map { [$0] } ?? [],
      summaryProfileID: legacy?.id,
      transcriptionProfileID: nil
    )
    if legacy != nil {
      do {
        try await libraryStore.save(migrated)
      } catch {
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    }
    return migrated
  }

  /// Adds a new library entry with its own Keychain secret. The first entry
  /// automatically becomes the summary assignment, mirroring the pre-library
  /// behavior where saving a configuration made it active.
  public func addProfile(
    baseURL: String,
    model: String,
    apiKey: String,
    allowLoopbackHTTP: Bool = false
  ) async throws -> ProviderProfile {
    guard let profile = try await addProfiles(
      baseURL: baseURL,
      models: [model],
      apiKey: apiKey,
      allowLoopbackHTTP: allowLoopbackHTTP
    ).first else {
      throw ProviderConfigurationError.modelRequired
    }
    return profile
  }

  /// Adds several models from one verified provider catalog in a single
  /// library mutation. They intentionally share one Keychain reference because
  /// the endpoint and API key are the same; deletion keeps that secret until
  /// the final profile using it is removed.
  public func addProfiles(
    baseURL: String,
    models: [String],
    apiKey: String,
    allowLoopbackHTTP: Bool = false
  ) async throws -> [ProviderProfile] {
    let normalizedModels = models.reduce(into: [String]()) { result, value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, !result.contains(trimmed) {
        result.append(trimmed)
      }
    }
    guard !normalizedModels.isEmpty else {
      throw ProviderConfigurationError.modelRequired
    }
    guard libraryStore != nil else {
      guard normalizedModels.count == 1 else {
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
      return [try await save(
        baseURL: baseURL,
        model: normalizedModels[0],
        apiKey: apiKey,
        allowLoopbackHTTP: allowLoopbackHTTP
      )]
    }
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw ProviderConfigurationError.apiKeyRequired
    }
    let reference = makeSecretReference()
    let profiles = try normalizedModels.map { model in
      try ProviderProfile(
        id: UUID().uuidString,
        baseURL: baseURL,
        model: model,
        secretReference: reference,
        allowLoopbackHTTP: allowLoopbackHTTP
      )
    }
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    var library = try await loadLibraryForMutation()
    let becomesSummary = library.summaryProfileID == nil
    library.profiles.append(contentsOf: profiles)
    if becomesSummary { library.summaryProfileID = profiles[0].id }

    do {
      try await secretStore.save(trimmedKey, for: reference)
    } catch {
      throw ProviderConfigurationError.secretStoreWriteFailed
    }
    if becomesSummary {
      do {
        try await profileStore.save(profiles[0])
      } catch {
        try? await secretStore.delete(reference)
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    }
    do {
      try await saveLibraryForMutation(library)
    } catch {
      if becomesSummary { try? await profileStore.delete() }
      try? await secretStore.delete(reference)
      throw error
    }
    return profiles
  }

  /// Updates an existing entry in place. Passing `apiKey: nil` keeps the
  /// stored secret; passing a key rotates it exactly like the single-slot
  /// replacement flow.
  public func updateProfile(
    id: String,
    baseURL: String,
    model: String,
    apiKey: String?,
    allowLoopbackHTTP: Bool = false
  ) async throws -> ProviderProfile {
    guard libraryStore != nil else {
      if let apiKey {
        return try await save(
          baseURL: baseURL,
          model: model,
          apiKey: apiKey,
          allowLoopbackHTTP: allowLoopbackHTTP
        )
      }
      throw ProviderConfigurationError.apiKeyRequired
    }
    let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedKey, trimmedKey.isEmpty {
      throw ProviderConfigurationError.apiKeyRequired
    }
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    var library = try await loadLibraryForMutation()
    guard let index = library.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProviderConfigurationError.configurationChanged
    }
    let existing = library.profiles[index]
    let reference = trimmedKey == nil ? existing.secretReference : makeSecretReference()
    let updated = try ProviderProfile(
      id: existing.id,
      baseURL: baseURL,
      model: model,
      secretReference: reference,
      allowLoopbackHTTP: allowLoopbackHTTP
    )
    library.profiles[index] = updated
    let isSummary = library.summaryProfileID == existing.id

    if let trimmedKey {
      do {
        try await secretStore.save(trimmedKey, for: reference)
      } catch {
        throw ProviderConfigurationError.secretStoreWriteFailed
      }
    }
    if isSummary {
      do {
        try await profileStore.save(updated)
      } catch {
        if trimmedKey != nil { try? await secretStore.delete(reference) }
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    }
    do {
      try await saveLibraryForMutation(library)
    } catch {
      if isSummary { try? await profileStore.save(existing) }
      if trimmedKey != nil { try? await secretStore.delete(reference) }
      throw error
    }
    let oldReferenceStillUsed = library.profiles.contains {
      $0.id != updated.id && $0.secretReference == existing.secretReference
    }
    if trimmedKey != nil, existing.secretReference != reference, !oldReferenceStillUsed {
      do {
        try await secretStore.delete(existing.secretReference)
      } catch {
        throw ProviderConfigurationError.secretStoreDeleteFailed
      }
    }
    return updated
  }

  /// Removes an entry and its secret. A removed summary assignment clears the
  /// single slot; a removed transcription assignment falls back to local.
  public func deleteProfile(id: String) async throws -> ModelLibrary {
    guard libraryStore != nil else {
      throw ProviderConfigurationError.profileStoreWriteFailed
    }
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    var library = try await loadLibraryForMutation()
    guard let index = library.profiles.firstIndex(where: { $0.id == id }) else {
      throw ProviderConfigurationError.configurationChanged
    }
    let removed = library.profiles.remove(at: index)
    let wasSummary = library.summaryProfileID == removed.id
    if wasSummary { library.summaryProfileID = nil }
    if library.transcriptionProfileID == removed.id { library.transcriptionProfileID = nil }
    let secretStillUsed = library.profiles.contains {
      $0.secretReference == removed.secretReference
    }
    let removedSecret: String?
    if secretStillUsed {
      removedSecret = nil
    } else {
      do {
        removedSecret = try await secretStore.read(removed.secretReference)
      } catch {
        throw mapSecretStoreReadError(error)
      }
    }

    if wasSummary {
      do {
        try await profileStore.delete()
      } catch {
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    }
    if !secretStillUsed {
      do {
        try await secretStore.delete(removed.secretReference)
      } catch {
        if wasSummary { try? await profileStore.save(removed) }
        throw ProviderConfigurationError.secretStoreDeleteFailed
      }
    }
    do {
      try await saveLibraryForMutation(library)
    } catch {
      if wasSummary { try? await profileStore.save(removed) }
      if let removedSecret {
        try? await secretStore.save(removedSecret, for: removed.secretReference)
      }
      throw error
    }
    return library
  }

  /// Points summary/translation runs at an existing entry (or clears them).
  /// The single slot is kept in sync so orchestrator readers stay unchanged.
  public func assignSummaryProfile(id: String?) async throws {
    guard libraryStore != nil else {
      throw ProviderConfigurationError.profileStoreWriteFailed
    }
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    var library = try await loadLibraryForMutation()
    guard library.summaryProfileID != id else { return }
    let previousProfile = library.summaryProfile
    if let id {
      guard let profile = library.profile(withID: id) else {
        throw ProviderConfigurationError.configurationChanged
      }
      do {
        try await profileStore.save(profile)
      } catch {
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    } else {
      do {
        try await profileStore.delete()
      } catch {
        throw ProviderConfigurationError.profileStoreWriteFailed
      }
    }
    library.summaryProfileID = id
    do {
      try await saveLibraryForMutation(library)
    } catch {
      if let previousProfile {
        try? await profileStore.save(previousProfile)
      } else {
        try? await profileStore.delete()
      }
      throw error
    }
  }

  /// Points online transcription at an existing entry, or back to the local
  /// default when `id` is nil.
  public func assignTranscriptionProfile(id: String?) async throws {
    guard libraryStore != nil else {
      throw ProviderConfigurationError.profileStoreWriteFailed
    }
    let mutation = try beginMutation()
    defer { finishMutation(ifOwner: mutation) }

    var library = try await loadLibraryForMutation()
    guard library.transcriptionProfileID != id else { return }
    if let id, library.profile(withID: id) == nil {
      throw ProviderConfigurationError.configurationChanged
    }
    library.transcriptionProfileID = id
    try await saveLibraryForMutation(library)
  }

  /// Loads credentials for one library entry, e.g. for testing a connection
  /// that is not the summary assignment. Falls back to the single slot when
  /// no library store is configured.
  public func loadCredentials(profileID: String) async throws -> (profile: ProviderProfile, apiKey: String)? {
    let revision = try beginStableRead()
    let library = try await loadLibrary()
    guard let profile = library.profile(withID: profileID) else {
      return nil
    }
    let apiKey = try await readRequiredSecret(for: profile)
    try validateStableRead(revision)
    return (profile, apiKey)
  }

  /// Loads credentials for the transcription assignment; nil means the local
  /// transcriber should be used.
  public func loadTranscriptionCredentials() async throws -> (profile: ProviderProfile, apiKey: String)? {
    let revision = try beginStableRead()
    let library = try await loadLibrary()
    guard let profile = library.transcriptionProfile else {
      return nil
    }
    let apiKey = try await readRequiredSecret(for: profile)
    try validateStableRead(revision)
    return (profile, apiKey)
  }

  private func loadLegacyProfile() async throws -> ProviderProfile? {
    do {
      return try await profileStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
  }

  private func loadLibraryForMutation() async throws -> ModelLibrary {
    guard let libraryStore else {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    let stored: ModelLibrary?
    do {
      stored = try await libraryStore.load()
    } catch {
      throw ProviderConfigurationError.profileStoreReadFailed
    }
    if let stored { return stored }
    let legacy = try await loadLegacyProfile()
    return ModelLibrary(
      profiles: legacy.map { [$0] } ?? [],
      summaryProfileID: legacy?.id,
      transcriptionProfileID: nil
    )
  }

  private func saveLibraryForMutation(_ library: ModelLibrary) async throws {
    guard let libraryStore else {
      throw ProviderConfigurationError.profileStoreWriteFailed
    }
    do {
      try await libraryStore.save(library)
    } catch {
      throw ProviderConfigurationError.profileStoreWriteFailed
    }
  }

  private func readRequiredSecret(for profile: ProviderProfile) async throws -> String {
    do {
      guard
        let value = try await cachedOrReadSecret(profile.secretReference),
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ProviderConfigurationError.secretStoreReadFailed
      }
      return value
    } catch {
      throw mapSecretStoreReadError(error)
    }
  }

  private func mapSecretStoreReadError(_ error: Error) -> ProviderConfigurationError {
    if let error = error as? ProviderConfigurationError {
      return error
    }
    if let error = error as? SecretStoreFailure, error.isTimeout {
      return .secretStoreReadTimedOut
    }
    return .secretStoreReadFailed
  }

  private func beginStableRead() throws -> UInt64 {
    guard inFlightMutation == nil else {
      throw ProviderConfigurationError.configurationChanged
    }
    return configurationRevision
  }

  private func validateStableRead(_ expectedRevision: UInt64) throws {
    guard inFlightMutation == nil, configurationRevision == expectedRevision else {
      throw ProviderConfigurationError.configurationChanged
    }
  }

  private func beginMutation() throws -> UUID {
    guard inFlightMutation == nil else {
      throw ProviderConfigurationError.configurationChanged
    }
    let owner = UUID()
    inFlightMutation = owner
    configurationRevision &+= 1
    sessionSecretCache.removeAll()
    return owner
  }

  private func finishMutation(ifOwner owner: UUID) {
    guard inFlightMutation == owner else { return }
    inFlightMutation = nil
  }
}
