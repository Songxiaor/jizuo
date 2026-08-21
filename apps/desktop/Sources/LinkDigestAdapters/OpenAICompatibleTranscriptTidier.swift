import Foundation
import LinkDigestCore

/// Sends transcript text (never audio, never the media URL) to the user's
/// configured chat provider for 听写还原. Title and caption ride along as
/// context on every chunk. Chunks are tidied independently; a failed chunk
/// keeps its original text so a partial outage can never lose transcript content.
public final class OpenAICompatibleTranscriptTidier: TranscriptTidying, @unchecked Sendable {
  /// 同时在飞的整理请求数。整理和翻译一样是输出受限的活（产出与原文同量级，
  /// 模型只能逐 token 吐），分片之间互不依赖，串行等于把耗时按片数线性叠加：
  /// 半小时视频的转写稿切 6 片、每片几十秒，串行就是三五分钟白等。
  /// 取 3 而不是翻译那样可调到更高：整理经常在自动管线里与总结/翻译同时跑，
  /// 再抬高会和它们抢同一个服务商的速率配额。
  private static let maximumConcurrentChunkRequests = 3

  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext
  ) async throws -> TranscriptTidyOutcome {
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

    // 分片并发执行，结果按分片序号还原——绝不能按完成顺序，那会把文稿打乱。
    // 单片失败不拖垮整体（该片保留原文），但取消必须立刻贯穿全部在飞请求。
    let results = try await withThrowingTaskGroup(
      of: (Int, Result<TranscriptTidyOutcome, Error>).self
    ) { group -> [Int: Result<TranscriptTidyOutcome, Error>] in
      var collected: [Int: Result<TranscriptTidyOutcome, Error>] = [:]
      var next = 0
      func launch(_ index: Int) {
        group.addTask { [provider, credentials, effectiveModel, style, context] in
          do {
            let payload = style == .transcript
              ? TranscriptTidyPrompt.userMessage(chunk: chunks[index], context: context)
              : chunks[index]
            let outcome = try await provider.tidyTranscriptChunk(
              profile: credentials.profile,
              apiKey: credentials.apiKey,
              model: effectiveModel,
              text: payload,
              systemPrompt: style.systemPrompt
            )
            return (index, .success(outcome))
          } catch is CancellationError {
            // 让取消走 TaskGroup 的抛出路径，而不是被计成“这片失败了”。
            throw TranscriptTidyError.cancelled
          } catch {
            return (index, .failure(error))
          }
        }
      }
      while next < min(Self.maximumConcurrentChunkRequests, chunks.count) {
        launch(next)
        next += 1
      }
      do {
        while let (index, result) = try await group.next() {
          collected[index] = result
          if next < chunks.count {
            launch(next)
            next += 1
          }
        }
      } catch is CancellationError {
        throw TranscriptTidyError.cancelled
      }
      return collected
    }

    var outputs: [String] = []
    var failedChunkCount = 0
    var firstFailure: Error?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    for (index, chunk) in chunks.enumerated() {
      switch results[index] {
      case let .success(outcome):
        // 归一化换行方言：Markdown 阅读区把单换行折叠成空格，
        // 不归一化就会出现“句号后一坨空格 + 整篇不分段”。
        //
        // 笔记不能走这一步：它的产物是 Markdown，换行本身有语义。归一化会把
        // 段内单换行拼回一行，`- a\n- b` 这样的列表会被拼成 `- a - b`。
        let cleaned: String = switch style {
        case .transcript:
          TranscriptTidyNormalizer.normalize(
            TranscriptTidyPrompt.stripEchoedContext(
              outcome.text, chunk: chunk, context: context
            )
          )
        case .note: outcome.text.replacingOccurrences(of: "\r\n", with: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        outputs.append(cleaned.isEmpty ? chunk : cleaned)
        promptTokens = Self.summed(promptTokens, outcome.promptTokens)
        completionTokens = Self.summed(completionTokens, outcome.completionTokens)
        totalTokens = Self.summed(totalTokens, outcome.totalTokens)
      case let .failure(error):
        failedChunkCount += 1
        // 首个失败按分片序号取（并发下完成顺序不定，报错必须可复现）。
        if firstFailure == nil { firstFailure = error }
        outputs.append(chunk)
      case nil:
        // TaskGroup 正常收尾后每片必有结果；缺席只可能是实现错误。
        failedChunkCount += 1
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
      totalTokens: totalTokens,
      failedChunkCount: failedChunkCount,
      chunkCount: chunks.count
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
