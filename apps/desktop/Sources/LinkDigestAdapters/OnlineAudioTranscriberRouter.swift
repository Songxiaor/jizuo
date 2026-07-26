import Foundation
import LinkDigestCore

/// 按配置的服务地址挑转写通道。
///
/// 阶跃自家域名走流式 SSE（`StepAudioStreamingTranscriber`），其余一律走通用的
/// `/v1/audio/transcriptions`。判断依据是**域名而不是模型名**：模型名用户可以随便填，
/// 而 `step_plan` 这条路径只有阶跃的域名上存在，填错模型名应该由服务端明确报错，
/// 不该悄悄换一条接口。
public final class OnlineAudioTranscriberRouter: StreamingOnlineAudioTranscribing, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let streaming: StepAudioStreamingTranscriber
  private let compatible: OpenAICompatibleAudioTranscriber

  public init(configurationService: ProviderConfigurationService) {
    self.configurationService = configurationService
    streaming = StepAudioStreamingTranscriber(configurationService: configurationService)
    compatible = OpenAICompatibleAudioTranscriber(configurationService: configurationService)
  }

  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> String {
    try await transcribe(
      remoteMediaURL: remoteMediaURL,
      model: model,
      language: language,
      progress: progress,
      partialTranscript: nil
    )
  }

  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?,
    partialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String {
    if try await useStreaming() {
      return try await streaming.transcribe(
        remoteMediaURL: remoteMediaURL,
        model: model,
        language: language,
        progress: progress,
        partialTranscript: partialTranscript
      )
    }
    return try await compatible.transcribe(
      remoteMediaURL: remoteMediaURL,
      model: model,
      language: language,
      progress: progress
    )
  }

  /// 读不到凭据时返回 false：让通用通道去抛「未配置」，
  /// 错误文案在那条路径上已经是对的，不必在这里复制一遍。
  private func useStreaming() async throws -> Bool {
    guard let credentials = try? await configurationService.loadTranscriptionCredentials()
    else { return false }
    return StepAudioStreamingTranscriber.handles(baseURL: credentials.profile.baseURL)
  }
}
