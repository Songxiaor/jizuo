import Foundation

/// The non-sensitive identity a person sees before LinkDigest sends captured
/// webpage content to their selected model destination. It deliberately omits
/// the Keychain reference and API key.
public struct DataDestinationIdentity: Codable, Hashable, Sendable {
  public let normalizedBaseURL: String
  public let host: String
  public let model: String
  public let apiMode: APIMode

  public init(profile: ProviderProfile) {
    self.init(validatedBaseURL: profile.baseURL, model: profile.model, apiMode: profile.apiMode)
  }

  /// Builds the same non-sensitive identity from an unsaved settings draft.
  /// No API key or fabricated Keychain reference is needed for comparison.
  public init(
    baseURL: String,
    model: String,
    apiMode: APIMode = .chatCompletions,
    allowLoopbackHTTP: Bool = false
  ) throws {
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
      throw ProviderConfigurationError.modelRequired
    }
    let validatedBaseURL = try ProviderProfile.validatedBaseURL(
      baseURL,
      allowLoopbackHTTP: allowLoopbackHTTP
    )
    self.init(validatedBaseURL: validatedBaseURL, model: trimmedModel, apiMode: apiMode)
  }

  private init(validatedBaseURL: URL, model: String, apiMode: APIMode) {
    var components = URLComponents(url: validatedBaseURL, resolvingAgainstBaseURL: false)
    if var value = components {
      value.scheme = value.scheme?.lowercased()
      value.host = value.host?.lowercased()
      if value.path.count > 1 {
        value.path = "/" + value.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
      components = value
    }
    normalizedBaseURL = components?.url?.absoluteString ?? validatedBaseURL.absoluteString
    host = components?.host ?? validatedBaseURL.host ?? ""
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiMode = apiMode
  }
}

public enum DataDestinationConsentStoreFailure: Error, Sendable, Equatable {
  case readFailed
  case writeFailed
}

/// Records consent for a non-sensitive destination identity only. It is not a
/// credential store and must fail closed when its record cannot be read.
public protocol DataDestinationConsentStore: Sendable {
  func isConfirmed(for identity: DataDestinationIdentity) async throws -> Bool
  func rememberConfirmation(for identity: DataDestinationIdentity) async throws
}
