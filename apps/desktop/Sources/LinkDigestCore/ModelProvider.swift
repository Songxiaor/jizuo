import Foundation

/// The deliberately small set of model operations exposed by the V0.2 adapter.
public enum RunIntent: Sendable, Equatable {
  case connectionTest
  case summarize(title: String?, text: String, prompt: String)
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
  /// Provider-reported token counters from a terminal SSE chunk. They are
  /// accounting metadata, not model output, and must never be rendered as
  /// generated text.
  case usage(RunUsageCost)
  case completed
}

/// Narrow, non-secret companion port for an OpenAI-compatible `/models`
/// response. It deliberately accepts a validated Base URL rather than a full
/// ProviderProfile, because discovering model ids must not require a model id.
/// Callers receive ids only; provider response fields never cross this boundary.
public protocol ModelCatalogLoading: Sendable {
  func listModels(baseURL: URL, apiKey: String) async throws -> [String]
}

/// A deliberately narrow, non-streaming companion port used only for the
/// post-summary local-label hint. Its text never becomes visible output and a
/// failure is intentionally ignored by the run orchestrator.
public protocol SummaryTagGenerating: Sendable {
  func generateSummaryTags(profile: ProviderProfile, apiKey: String, summary: String) async throws -> String
}

public enum ModelProviderErrorCode: String, Codable, Sendable, Equatable {
  case baseURLInvalid = "MODEL_BASE_URL_INVALID"
  case authInvalid = "MODEL_AUTH_INVALID"
  case endpointNotFound = "MODEL_ENDPOINT_NOT_FOUND"
  case modelNotFound = "MODEL_NOT_FOUND"
  case providerBillingLimited = "MODEL_PROVIDER_BILLING_LIMITED"
  case providerRequestRejected = "MODEL_PROVIDER_REQUEST_REJECTED"
  case rateLimited = "MODEL_RATE_LIMITED"
  case providerUnavailable = "MODEL_PROVIDER_UNAVAILABLE"
  case networkInterrupted = "MODEL_NETWORK_INTERRUPTED"
  case protocolIncompatible = "MODEL_PROTOCOL_INCOMPATIBLE"
  case streamMalformed = "MODEL_STREAM_MALFORMED"
  case inputTooLarge = "MODEL_INPUT_TOO_LARGE"
}

/// A UI-safe failure. It intentionally carries no URLSession error text,
/// raw response body, request headers, or provider-supplied text. UI layers
/// can only render the fixed local copy for `code`.
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
