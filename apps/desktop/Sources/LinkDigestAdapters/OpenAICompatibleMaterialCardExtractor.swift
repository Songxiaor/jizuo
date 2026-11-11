import Foundation
import LinkDigestCore

/// 素材卡的模型调用：只发转写稿（最多 `transcriptCharacterLimit` 字）和标题。
/// 取凭据、错误分类和脑图、标签整理共用同一套规则；金句在这里按转写稿全文校验。
public final class OpenAICompatibleMaterialCardExtractor: MaterialCardExtracting, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func extractCard(transcript: String, title: String?) async throws -> MaterialCardOutcome {
    guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= MaterialCardPrompt.minimumTranscriptCharacters else {
      throw MaterialCardError.emptyTranscript
    }
    let credentials = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: configurationService)
    let response: (content: String, promptTokens: Int?, completionTokens: Int?, totalTokens: Int?)
    do {
      response = try await provider.completeStructured(
        profile: credentials.profile, apiKey: credentials.apiKey, model: credentials.profile.model,
        systemPrompt: MaterialCardPrompt.system,
        userContent: MaterialCardPrompt.userContent(transcript: transcript, title: title)
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
    let card = try MaterialCardPrompt.parse(response.content, transcript: transcript)
    return MaterialCardOutcome(
      card: card, promptTokens: response.promptTokens,
      completionTokens: response.completionTokens, totalTokens: response.totalTokens,
      provider: "openai_compatible", model: credentials.profile.model
    )
  }
}
