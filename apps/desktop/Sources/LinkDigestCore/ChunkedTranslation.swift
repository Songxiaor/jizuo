import Foundation

/// 长正文翻译的分片并发执行。
///
/// 为什么需要它：翻译是**输出受限**的活——译文长度和原文同量级，而单条请求里
/// 模型只能一个 token 一个 token 地吐。实测 38,487 字的转写稿走单请求跑了
/// 6.5 分钟仍未结束，期间文字一直在往外冒，说明不是排队而是吞吐见底。这类活
/// 唯一的提速方式是把它拆成互不依赖的片并行跑。
///
/// 分片器复用 `TranscriptTidyChunker`：段落边界切分这件事只该有一份实现，
/// 复制一份出来只会各自漂移。
///
/// 边界：分片之间互相看不到上下文。按段落切而不是按字数硬切，是为了让每一片
/// 都是完整的语义单元；代价是跨段指代可能不如整篇翻译连贯。这是拿一点连贯性
/// 换数倍速度，对转写稿这种本就松散的长文划算，对短文则根本不分片。
public struct ChunkedTranslationStreamer: Sendable {
  private let provider: any ModelProvider
  private let concurrency: Int
  private let chunkCharacterLimit: Int

  /// 低于这个长度不分片：一片的开销（额外请求、边界损失）换不回收益。
  public static let minimumCharactersToChunk = 8_000

  /// 片长的下限。再往下切，跨片上下文损失和每请求固定开销就开始反噬。
  public static let minimumChunkCharacters = 1_500

  /// 按并发反算片长，让片数落在并发的整数倍上。
  ///
  /// 耗时 ≈ ⌈片数 ÷ 并发⌉ × 单片耗时，而单片耗时正比于片长。片数不是并发的整数
  /// 倍时，最后一波里多数通道在空转：38,487 字按固定 6000 字切出 7 片、并发 3，
  /// 要跑 3 波，而最后一波只有 1 片在跑，另外两条通道白等——这一波的浪费不花任何
  /// 额外配额就能省掉。
  ///
  /// 取整到 9 片后仍是 3 波，但每片短了三成，总时长回到理论下限「总字数 ÷ 并发」。
  /// 在满足上限的前提下取**最少**的片数，是为了让每片尽量长——片越长，跨片丢失的
  /// 上下文越少。
  public static func chunkLimit(
    forCharacterCount count: Int,
    concurrency: Int,
    maximum: Int
  ) -> Int {
    // 并发为 1 时片数与波数一一对应，取整没有任何意义，保持原片长即可。
    guard count > 0, concurrency > 1, maximum > 0 else { return maximum }
    let capacityPerWave = concurrency * maximum
    let waves = max(1, Int((Double(count) / Double(capacityPerWave)).rounded(.up)))
    let chunkCount = waves * concurrency
    let target = Int((Double(count) / Double(chunkCount)).rounded(.up))
    return max(minimumChunkCharacters, min(maximum, target))
  }

  public init(
    provider: any ModelProvider,
    concurrency: Int,
    chunkCharacterLimit: Int = TranscriptTidyChunker.defaultChunkCharacterLimit
  ) {
    self.provider = provider
    self.concurrency = max(1, concurrency)
    self.chunkCharacterLimit = chunkCharacterLimit
  }

  /// 这段正文值不值得分片。
  public static func shouldChunk(_ text: String, limit: Int = TranscriptTidyChunker.defaultChunkCharacterLimit) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumCharactersToChunk else { return false }
    return TranscriptTidyChunker.chunks(of: trimmed, limit: limit).count > 1
  }

  public func stream(
    profile: ProviderProfile,
    apiKey: String,
    title: String?,
    text: String,
    targetLanguage: String
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let limit = Self.chunkLimit(
      forCharacterCount: text.trimmingCharacters(in: .whitespacesAndNewlines).count,
      concurrency: concurrency,
      maximum: chunkCharacterLimit
    )
    let chunks = TranscriptTidyChunker.chunks(of: text, limit: limit)
    let provider = provider
    let concurrency = concurrency

    return AsyncThrowingStream { continuation in
      let work = Task {
        guard !chunks.isEmpty else {
          continuation.yield(.completed)
          continuation.finish()
          return
        }
        let assembler = TranslationChunkAssembler(total: chunks.count)
        var usages: [RunUsageCost] = []
        do {
          try await withThrowingTaskGroup(of: RunUsageCost.self) { group in
            var nextToLaunch = 0
            var running = 0

            func launchNext() {
              let index = nextToLaunch
              nextToLaunch += 1
              running += 1
              group.addTask {
                try await Self.runChunk(
                  provider: provider,
                  profile: profile,
                  apiKey: apiKey,
                  // 标题只跟第一片走。每片都带标题会让模型把它重复译进正文。
                  title: index == 0 ? title : nil,
                  text: chunks[index],
                  targetLanguage: targetLanguage,
                  index: index,
                  assembler: assembler,
                  continuation: continuation
                )
              }
            }

            while nextToLaunch < chunks.count, running < concurrency { launchNext() }
            while running > 0 {
              let usage = try await group.next()
              running -= 1
              if let usage { usages.append(usage) }
              try Task.checkCancellation()
              if nextToLaunch < chunks.count { launchNext() }
            }
          }
          continuation.yield(.usage(RunUsageCost.summed(usages)))
          continuation.yield(.completed)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in work.cancel() }
    }
  }

  /// 跑一片。速率限制单独退避重试——免费档端点在并发下最常见的失败就是 429，
  /// 而它是暂时的：整条运行因为一片被限流就失败，用户看到的是"翻译失败"，
  /// 而真相只是"刚才挤了一下"。
  private static func runChunk(
    provider: any ModelProvider,
    profile: ProviderProfile,
    apiKey: String,
    title: String?,
    text: String,
    targetLanguage: String,
    index: Int,
    assembler: TranslationChunkAssembler,
    continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) async throws -> RunUsageCost {
    var attempt = 0
    while true {
      do {
        return try await sendChunk(
          provider: provider,
          profile: profile,
          apiKey: apiKey,
          title: title,
          text: text,
          targetLanguage: targetLanguage,
          index: index,
          assembler: assembler,
          continuation: continuation
        )
      } catch let failure as ModelProviderFailure where failure.code == .rateLimited && !failure.hadOutput && attempt < 2 {
        // 只重试还没吐出任何内容的片：已经放行过文字的片再跑一遍会重复。
        attempt += 1
        try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
        try Task.checkCancellation()
      }
    }
  }

  private static func sendChunk(
    provider: any ModelProvider,
    profile: ProviderProfile,
    apiKey: String,
    title: String?,
    text: String,
    targetLanguage: String,
    index: Int,
    assembler: TranslationChunkAssembler,
    continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) async throws -> RunUsageCost {
    var usage = RunUsageCost.unknown
    for try await event in provider.stream(
      profile: profile,
      apiKey: apiKey,
      intent: .translate(title: title, text: text, targetLanguage: targetLanguage)
    ) {
      try Task.checkCancellation()
      switch event {
      case let .delta(delta):
        if let releasable = await assembler.accept(index: index, delta: delta) {
          continuation.yield(.delta(releasable))
        }
      case .reasoning:
        // 只有队首那片的思考值得报出去——其余分片是并行跑的，把它们的思考混进
        // 同一个流只会让状态来回跳。队首的思考由上层统一呈现，这里直接丢弃。
        break
      case let .usage(value):
        usage = value
      case .completed:
        break
      }
    }
    if let tail = await assembler.complete(index: index) {
      continuation.yield(.delta(tail))
    }
    return usage
  }
}

/// 把并发到达的分片按原顺序放行。
///
/// 并发跑但必须按序显示：读者看到的顺序就是文章顺序，第 3 片先跑完也不能先出现。
/// 队首那一片直接透传增量（所以首字延迟和不分片时一样），其余片先攒着，轮到它
/// 时一次性放行已攒的部分，之后转为透传。
private actor TranslationChunkAssembler {
  private let total: Int
  private var next = 0
  private var buffers: [Int: String] = [:]
  private var finished: Set<Int> = []
  /// 已经写过分隔符的片，避免重复插入空行。
  private var opened: Set<Int> = []

  init(total: Int) { self.total = total }

  func accept(index: Int, delta: String) -> String? {
    guard index == next else {
      buffers[index, default: ""] += delta
      return nil
    }
    return open(index) + delta
  }

  func complete(index: Int) -> String? {
    finished.insert(index)
    var out = ""
    while next < total, finished.contains(next) {
      if let buffered = buffers.removeValue(forKey: next), !buffered.isEmpty {
        out += open(next) + buffered
      }
      next += 1
    }
    // 新队首可能已经在飞并攒了一段：立刻放行，此后它的增量走透传分支。
    if next < total, let buffered = buffers.removeValue(forKey: next), !buffered.isEmpty {
      out += open(next) + buffered
    }
    return out.isEmpty ? nil : out
  }

  private func open(_ index: Int) -> String {
    guard opened.insert(index).inserted else { return "" }
    return index == 0 ? "" : "\n\n"
  }
}

extension RunUsageCost {
  /// 分片用量求和。全片都没报用量时保持 unknown——0 会被读成"确实没花"，
  /// 而真相是服务商没说。
  static func summed(_ values: [RunUsageCost]) -> RunUsageCost {
    func total(_ keyPath: KeyPath<RunUsageCost, Int64?>) -> Int64? {
      let reported = values.compactMap { $0[keyPath: keyPath] }
      return reported.isEmpty ? nil : reported.reduce(0, +)
    }
    return RunUsageCost(
      inputTokens: total(\.inputTokens),
      outputTokens: total(\.outputTokens),
      totalTokens: total(\.totalTokens),
      costAmountMicros: total(\.costAmountMicros),
      costCurrencyCode: values.compactMap(\.costCurrencyCode).first
    )
  }
}
