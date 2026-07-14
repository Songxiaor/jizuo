import Foundation

/// The deliberately small set of model operations exposed by the V0.2 adapter.
public enum RunIntent: Sendable, Equatable {
  case connectionTest
  case summarize(title: String?, text: String)
  case translate(title: String?, text: String, targetLanguage: String)

  public var kind: RunIntentKind {
    switch self {
    case .connectionTest:
      .connectionTest
    case .summarize:
      .summarize
    case .translate:
      .translate
    }
  }
}

public enum RunIntentKind: String, Codable, Sendable, Equatable {
  case connectionTest = "connection_test"
  case summarize
  case translate
}

public enum ModelStreamEvent: Sendable, Equatable {
  case delta(String)
  case completed
}

public enum ModelProviderErrorCode: String, Codable, Sendable, Equatable {
  case baseURLInvalid = "MODEL_BASE_URL_INVALID"
  case authInvalid = "MODEL_AUTH_INVALID"
  case endpointNotFound = "MODEL_ENDPOINT_NOT_FOUND"
  case rateLimited = "MODEL_RATE_LIMITED"
  case providerUnavailable = "MODEL_PROVIDER_UNAVAILABLE"
  case networkInterrupted = "MODEL_NETWORK_INTERRUPTED"
  case protocolIncompatible = "MODEL_PROTOCOL_INCOMPATIBLE"
  case streamMalformed = "MODEL_STREAM_MALFORMED"
  case inputTooLarge = "MODEL_INPUT_TOO_LARGE"
}

/// A UI-safe failure. It intentionally carries no URLSession error text,
/// response body, request headers, or secret-bearing details.
public struct ModelProviderFailure: Error, Sendable, Equatable, CustomStringConvertible {
  public let code: ModelProviderErrorCode
  public let retryable: Bool
  public let hadOutput: Bool

  public init(
    code: ModelProviderErrorCode,
    retryable: Bool,
    hadOutput: Bool
  ) {
    self.code = code
    self.retryable = retryable
    self.hadOutput = hadOutput
  }

  public var description: String { code.rawValue }
}

public protocol ModelProvider: Sendable {
  func stream(
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error>

  /// Cancels requests currently owned by this provider instance.
  /// V0.2 has one active model run; adapters that create unstructured producer
  /// tasks must implement this so the orchestrator can propagate user stop.
  func cancelActiveStreams()
}
