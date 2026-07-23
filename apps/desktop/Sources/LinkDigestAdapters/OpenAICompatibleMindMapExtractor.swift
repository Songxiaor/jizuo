import Foundation
import LinkDigestCore

/// Sends document text (never media) to the configured chat provider and
/// parses the fixed-contract JSON outline. Geometry and style never come from
/// the model; a bad response fails cleanly instead of rendering garbage.
public final class OpenAICompatibleMindMapExtractor: MindMapExtracting, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func extractOutline(text: String, model: String?) async throws -> MindMapExtractionOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MindMapOutlineError.emptyInput }

    let credentials: (profile: ProviderProfile, apiKey: String)
    do {
      guard let loaded = try await configurationService.loadCredentials() else {
        throw TranscriptTidyError.modelNotConfigured
      }
      credentials = loaded
    } catch let error as TranscriptTidyError {
      throw error
    } catch {
      throw TranscriptTidyError.modelNotConfigured
    }
    let trimmedOverride = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveModel = trimmedOverride?.isEmpty == false ? trimmedOverride! : credentials.profile.model

    let response: (content: String, promptTokens: Int?, completionTokens: Int?, totalTokens: Int?)
    do {
      response = try await provider.extractMindMapOutline(
        profile: credentials.profile,
        apiKey: credentials.apiKey,
        model: effectiveModel,
        text: trimmed
      )
    } catch is CancellationError {
      throw TranscriptTidyError.cancelled
    } catch let failure as ModelProviderFailure {
      switch failure.code {
      case .authInvalid: throw TranscriptTidyError.authInvalid
      case .networkInterrupted: throw TranscriptTidyError.networkInterrupted
      default: throw TranscriptTidyError.responseRejected
      }
    }
    let outline = try MindMapOutline.fromModelOutput(response.content)
    return MindMapExtractionOutcome(
      outline: outline,
      promptTokens: response.promptTokens,
      completionTokens: response.completionTokens,
      totalTokens: response.totalTokens
    )
  }
}
