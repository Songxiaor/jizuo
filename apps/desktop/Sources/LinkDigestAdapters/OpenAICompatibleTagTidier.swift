import Foundation
import LinkDigestCore

/// 「AI 整理标签」的模型调用。只发标签名和使用次数，不发资料正文。
/// 取凭据、错误分类和脑图、校对共用同一套规则。
public final class OpenAICompatibleTagTidier: TagTidying, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func proposePlan(tags: [HistoryNavigationTag]) async throws -> TagTidyOutcome {
    let content = TagTidyPrompt.userContent(tags: tags)
    guard !content.isEmpty else { throw TagTidyError.noTags }
    let credentials = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: configurationService)
    let response: (content: String, promptTokens: Int?, completionTokens: Int?, totalTokens: Int?)
    do {
      response = try await provider.completeStructured(
        profile: credentials.profile, apiKey: credentials.apiKey, model: credentials.profile.model,
        systemPrompt: TagTidyPrompt.system, userContent: content
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
    let plan = try TagTidyPrompt.parse(response.content, tags: tags)
    return TagTidyOutcome(
      plan: plan, promptTokens: response.promptTokens,
      completionTokens: response.completionTokens, totalTokens: response.totalTokens,
      model: credentials.profile.model
    )
  }
}
