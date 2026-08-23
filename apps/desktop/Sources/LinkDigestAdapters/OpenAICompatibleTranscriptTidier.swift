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
  /// 同时在飞的校对请求数。
  ///
  /// **不要照抄翻译的 6。** 校对和翻译确实都是输出受限的活，但两者的请求形状
  /// 不同：校对每片都要额外带上标题与配文作为上下文，单请求更重，6 路并发实测
  /// 直接被服务端限流——一次 7 段的校对里 6 段失败，失败分片静默回填原文，
  /// 界面显示「已保存」而错字一个没改，比慢得多更糟。
  ///
  /// 3 是实测能稳定跑完的值。真要更快，该换更快的模型，而不是加并发。
  private static let maximumConcurrentChunkRequests = 3

  /// 单片最多这么多字。
  ///
  /// **这是为了不撞请求超时（180 秒），不是为了省 token。**
  ///
  /// 校对的输出和输入同量级：6000 字的片要模型吐出 6000 字，按常见速度正好逼近
  /// 180 秒。实测一次 7 段的校对里 6 段失败、总耗时 175 秒——几乎就是超时线，
  /// 而失败的片会静默回填原文，界面显示「已保存」而错字一个没改。
  ///
  /// 切到 2000 字，单片生成约几十秒，离超时留出数倍余量。片数变多了，但它们是
  /// 并发跑的；宁可多跑几波，也不要一波里大半超时。
  private static let maximumChunkCharacters = 2_000

  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  /// 取凭据，并把「没配」和「这次读不出来」分开。
  ///
  /// 分开是因为用户动作相反：前者要去设置里填，后者只需重试。原来两者都报
  /// 「请先在设置中保存文本模型」——实测点一次校对失败，配置却完好无损，
  /// 人被指向了一个根本没问题的地方。
  ///
  /// 超时额外自动重试一次：钥匙串首读慢是**一次性**的（App 重新签名后系统要
  /// 重新评估一次代码签名，之后就有缓存）。让用户手动重试一次才能用，等于把
  /// 一个已知的一次性延迟变成每次部署后必踩的坑。
  static func loadCredentials(
    from configurationService: ProviderConfigurationService
  ) async throws -> (profile: ProviderProfile, apiKey: String) {
    var timedOutOnce = false
    while true {
      do {
        guard let loaded = try await configurationService.loadCredentials() else {
          // 真的没有 profile，这时「去设置里配」才是对的指引。
          throw TranscriptTidyError.modelNotConfigured
        }
        return loaded
      } catch let error as TranscriptTidyError {
        throw error
      } catch ProviderConfigurationError.secretStoreReadTimedOut where !timedOutOnce {
        timedOutOnce = true
        continue
      } catch {
        throw TranscriptTidyError.credentialsUnavailable
      }
    }
  }

  public func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    // 片长按并发反算，让片数落在并发的整数倍上。
    //
    // 耗时 ≈ ⌈片数 ÷ 并发⌉ × 单片耗时。片数不是并发整数倍时，最后一波多数通道
    // 在空转：34,406 字按固定 6000 切出 6 片、并发 6 本可一波跑完，而 110,228 字
    // 会切出 19 片，第 4 波只剩 1 片在跑、另外 5 条通道白等——这一波的时间不花
    // 任何额外配额就能省掉。
    let chunkLimit = ChunkedTranslationStreamer.chunkLimit(
      forCharacterCount: text.trimmingCharacters(in: .whitespacesAndNewlines).count,
      concurrency: Self.maximumConcurrentChunkRequests,
      maximum: Self.maximumChunkCharacters
    )
    let chunks = TranscriptTidyChunker.chunks(of: text, limit: chunkLimit)
    guard !chunks.isEmpty else { throw TranscriptTidyError.emptyTranscript }

    let credentials = try await Self.loadCredentials(from: configurationService)
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
            // 笔记不带上下文头：它本来就是自己写的，标题配文帮不上忙。
            // 听写稿和字幕稿都需要——专有名词全靠上下文才认得回来。
            let payload = style == .note
              ? chunks[index]
              : TranscriptTidyPrompt.userMessage(chunk: chunks[index], context: context)
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
          // 每落地一片就报一次。分片是并发跑的，完成顺序不定，所以按**已完成
          // 片数**报进度，而不是按 index——否则进度会来回跳。
          progress?(collected.count, chunks.count)
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
        let cleaned: String = style.normalizesParagraphs
          ? TranscriptTidyNormalizer.normalize(
              TranscriptTidyPrompt.stripEchoedContext(
                outcome.text, chunk: chunk, context: context
              )
            )
          : outcome.text.replacingOccurrences(of: "\r\n", with: "\n")
              .trimmingCharacters(in: .whitespacesAndNewlines)
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
