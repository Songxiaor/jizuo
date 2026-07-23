import Foundation
import LinkDigestCore

/// Sends transcript text (never audio, never the media URL) to the user's
/// configured chat provider for a punctuation/paragraph/typo pass. Chunks are
/// tidied independently; a failed chunk keeps its original text so a partial
/// outage can never lose transcript content.
public final class OpenAICompatibleTranscriptTidier: TranscriptTidying, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func tidy(text: String, model: String?) async throws -> TranscriptTidyOutcome {
    let chunks = TranscriptTidyChunker.chunks(of: text)
    guard !chunks.isEmpty else { throw TranscriptTidyError.emptyTranscript }

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

    var outputs: [String] = []
    var failedChunkCount = 0
    var firstFailure: Error?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    for chunk in chunks {
      try Task.checkCancellation()
      do {
        let outcome = try await provider.tidyTranscriptChunk(
          profile: credentials.profile,
          apiKey: credentials.apiKey,
          model: effectiveModel,
          text: chunk
        )
        // 归一化换行方言：Markdown 阅读区把单换行折叠成空格，
        // 不归一化就会出现“句号后一坨空格 + 整篇不分段”。
        let normalized = TranscriptTidyNormalizer.normalize(outcome.text)
        outputs.append(normalized.isEmpty ? chunk : normalized)
        promptTokens = Self.summed(promptTokens, outcome.promptTokens)
        completionTokens = Self.summed(completionTokens, outcome.completionTokens)
        totalTokens = Self.summed(totalTokens, outcome.totalTokens)
      } catch is CancellationError {
        throw TranscriptTidyError.cancelled
      } catch {
        failedChunkCount += 1
        if firstFailure == nil { firstFailure = error }
        outputs.append(chunk)
      }
    }
    // Every chunk failing is a configuration/outage problem, not a partial
    // result; surface it instead of returning the input as a fake success.
    if failedChunkCount == chunks.count, let firstFailure {
      throw Self.mapped(firstFailure)
    }
    return TranscriptTidyOutcome(
      text: outputs.joined(separator: "\n\n"),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens
    )
  }

  /// nil 表示服务商没报用量；只要有一片报了就累计，不把 nil 当 0。
  private static func summed(_ left: Int?, _ right: Int?) -> Int? {
    switch (left, right) {
    case (nil, nil): return nil
    case let (value?, nil), let (nil, value?): return value
    case let (lhs?, rhs?): return lhs + rhs
    }
  }

  private static func mapped(_ error: Error) -> TranscriptTidyError {
    guard let failure = error as? ModelProviderFailure else { return .responseRejected }
    switch failure.code {
    case .authInvalid: return .authInvalid
    case .networkInterrupted: return .networkInterrupted
    default: return .responseRejected
    }
  }
}
