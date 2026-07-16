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
  case secretStoreWriteFailed = "SECRET_STORE_WRITE_FAILED"
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
  public let operation: SecretStoreOperation
  public let status: Int32

  public init(operation: SecretStoreOperation, status: Int32) {
    self.operation = operation
    self.status = status
  }

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
  private let makeSecretReference: @Sendable () -> SecretReference
  private var configurationRevision: UInt64 = 0
  private var inFlightMutation: UUID?

  public init(
    profileStore: any ProviderProfileStore,
    secretStore: any SecretStore,
    makeSecretReference: @escaping @Sendable () -> SecretReference = {
      SecretReference(rawValue: UUID().uuidString)
    }
  ) {
    self.profileStore = profileStore
    self.secretStore = secretStore
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
    } catch let error as ProviderConfigurationError {
      throw error
    } catch {
      throw ProviderConfigurationError.secretStoreReadFailed
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
        let value = try await secretStore.read(profile.secretReference),
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ProviderConfigurationError.secretStoreReadFailed
      }
      apiKey = value
    } catch let error as ProviderConfigurationError {
      throw error
    } catch {
      throw ProviderConfigurationError.secretStoreReadFailed
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
      guard let value = try await secretStore.read(firstProfile.secretReference),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ProviderConfigurationError.secretStoreReadFailed }
      apiKey = value
    } catch let error as ProviderConfigurationError {
      throw error
    } catch {
      throw ProviderConfigurationError.secretStoreReadFailed
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
      try? await secretStore.delete(previousReference)
    }

    return newProfile
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
    return owner
  }

  private func finishMutation(ifOwner owner: UUID) {
    guard inFlightMutation == owner else { return }
    inFlightMutation = nil
  }
}
