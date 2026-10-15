import Foundation

/// 长正文总结：先分片提要点，再合并成一篇总结。
///
/// 为什么需要它：总结原来整篇一次发。几万字的转写稿要么撞上服务商的上下文上限
/// （413 / 超出上下文长度，用户只看到「内容太长」），要么塞得进去但模型对中段
/// 注意力明显变弱，总结只讲开头和结尾。分片后每一片都被认真读过一遍。
///
/// 流程：
/// 1. 按段落切片（复用 `TranscriptTidyChunker`，段落过长再按行、按句补切）；
/// 2. 各片并发请求「本片要点 + 支撑证据」，这一步不显示，界面只报「正在思考」；
/// 3. 把各片要点按原文顺序拼起来，套用户的总结提示词发一次合并请求，流式显示。
///
/// 短文不分片：分片多花请求、丢跨片上下文，只有长到单请求吃力时才划算。
public struct ChunkedSummaryStreamer: Sendable {
  private let provider: any ModelProvider
  private let concurrency: Int
  private let chunkCharacterLimit: Int
  /// 片级重试第 n 次先等 n × 这个时长。测试里传 0，不白等。
  private let retryBaseDelay: Duration

  /// 达到这个长度才分片。约 3 万字以下单请求在常见模型上质量和速度都没问题。
  public static let minimumCharactersToChunk = 30_000
  /// 默认片长。比翻译的 6000 大：提要点的输出远短于输入，片越大跨片损失越少。
  public static let defaultChunkCharacterLimit = 12_000
  /// 单请求报超长后改走分片时，片长不低于这个值。
  static let minimumFallbackChunkCharacters = 2_000

  public init(
    provider: any ModelProvider,
    concurrency: Int,
    chunkCharacterLimit: Int = ChunkedSummaryStreamer.defaultChunkCharacterLimit,
    retryBaseDelay: Duration = .seconds(2)
  ) {
    self.provider = provider
    self.concurrency = max(1, concurrency)
    self.chunkCharacterLimit = max(1, chunkCharacterLimit)
    self.retryBaseDelay = retryBaseDelay
  }

  /// 这段正文是否一开始就该分片总结。
  public static func shouldChunk(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumCharactersToChunk else { return false }
    return chunks(of: trimmed, limit: defaultChunkCharacterLimit).count > 1
  }

  /// 单请求已被服务商判为超长时用的片长：至少切成 3 片，避免再撞一次上限。
  public static func fallbackChunkLimit(forCharacterCount count: Int) -> Int {
    min(defaultChunkCharacterLimit, max(minimumFallbackChunkCharacters, count / 3))
  }

  /// 段落切片；单个段落超过上限时按行、再按句、最后硬切补齐。
  ///
  /// `TranscriptTidyChunker` 只在空行处切，而不少转写稿整篇没有空行——不补切的话
  /// 一整篇仍是一片，分片等于没做。
  static func chunks(of text: String, limit: Int) -> [String] {
    TranscriptTidyChunker.chunks(of: text, limit: limit)
      .flatMap { $0.count > limit ? splitOversized($0, limit: limit) : [$0] }
  }

  static func splitOversized(_ text: String, limit: Int) -> [String] {
    var pieces: [String] = []
    var current = ""
    func flush() {
      if !current.isEmpty { pieces.append(current) }
      current = ""
    }
    for unit in sentenceUnits(text) {
      if unit.count > limit {
        flush()
        var rest = Substring(unit)
        while !rest.isEmpty {
          let end = rest.index(rest.startIndex, offsetBy: min(limit, rest.count))
          pieces.append(String(rest[..<end]))
          rest = rest[end...]
        }
      } else if current.count + unit.count > limit {
        flush()
        current = unit
      } else {
        current += unit
      }
    }
    flush()
    return pieces
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// 按换行和句末标点切成保留分隔符的小段，拼回去与原文一致。
  private static func sentenceUnits(_ text: String) -> [String] {
    let terminators: Set<Character> = ["\n", "。", "！", "？", "!", "?", ".", "；", ";"]
    var units: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if terminators.contains(character) {
        units.append(current)
        current = ""
      }
    }
    if !current.isEmpty { units.append(current) }
    return units
  }

  /// 分片提要点用的提示词。只说本片，不下整篇结论，不出标签——这些交给合并那一步。
  static func notesPrompt(part: Int, of total: Int, outputLanguage: String) -> String {
    """
    The content below is part \(part) of \(total) of one long piece, in original order. Extract the key points of this part only, in the order they appear, as concise bullet points. Under each point keep the concrete evidence that supports it: numbers, names, examples, short quotes. If the text carries timestamps such as [12:34] or 12:34, start each point with the timestamp where it is discussed.

    Stay strictly within this part. Do not write an introduction, a conclusion about the whole piece, or tags. Write in \(outputLanguage).
    """
  }

  /// 合并请求的提示词：用户的总结提示词在前，后面说明输入是分片要点而不是原文。
  static func mergePrompt(summaryPrompt: String, chunkCount: Int) -> String {
    """
    \(summaryPrompt)

    The content you receive is not the original text. It is ordered notes (key points with their evidence) extracted from all \(chunkCount) consecutive parts of one long piece. Treat them together as the whole piece and summarize the piece itself. Never mention parts, notes, or this extraction step. Keep any timestamps the notes carry when the requested format uses them.
    """
  }

  public func stream(
    profile: ProviderProfile,
    apiKey: String,
    title: String?,
    text: String,
    summaryPrompt: String,
    outputLanguage: String
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    let chunks = Self.chunks(of: text, limit: chunkCharacterLimit)
    let provider = provider
    let concurrency = concurrency
    let retryBaseDelay = retryBaseDelay

    return AsyncThrowingStream { continuation in
      let work = Task {
        do {
          guard chunks.count > 1 else {
            // 切不开就照单请求跑，没有理由多绕一次。
            for try await event in provider.stream(
              profile: profile,
              apiKey: apiKey,
              intent: .summarize(title: title, text: chunks.first ?? text, prompt: summaryPrompt)
            ) {
              continuation.yield(event)
            }
            continuation.finish()
            return
          }

          // 提要点阶段不出正文；先报一次「正在思考」，界面才不像卡住。
          continuation.yield(.reasoning(""))
          var notes = Array(repeating: "", count: chunks.count)
          var usages: [RunUsageCost] = []
          try await withThrowingTaskGroup(of: (Int, String, RunUsageCost).self) { group in
            var nextToLaunch = 0
            var running = 0
            func launchNext() {
              let index = nextToLaunch
              nextToLaunch += 1
              running += 1
              // 片号显式捕获：见 ChunkedTranslationStreamer 里 Release 下片号错位的记录。
              group.addTask { [index] in
                let (note, usage) = try await Self.runNotes(
                  provider: provider,
                  profile: profile,
                  apiKey: apiKey,
                  intent: .summarize(
                    title: index == 0 ? title : nil,
                    text: chunks[index],
                    prompt: Self.notesPrompt(part: index + 1, of: chunks.count, outputLanguage: outputLanguage)
                  ),
                  retryBaseDelay: retryBaseDelay
                )
                return (index, note, usage)
              }
            }
            while nextToLaunch < chunks.count, running < concurrency { launchNext() }
            while running > 0 {
              guard let (index, note, usage) = try await group.next() else { break }
              running -= 1
              notes[index] = note
              usages.append(usage)
              try Task.checkCancellation()
              if nextToLaunch < chunks.count { launchNext() }
            }
          }

          let mergedNotes = notes.enumerated()
            .map { "### \($0.offset + 1)/\(chunks.count)\n\($0.element.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
          for try await event in provider.stream(
            profile: profile,
            apiKey: apiKey,
            intent: .summarize(
              title: title,
              text: mergedNotes,
              prompt: Self.mergePrompt(summaryPrompt: summaryPrompt, chunkCount: chunks.count)
            )
          ) {
            try Task.checkCancellation()
            switch event {
            case .delta, .reasoning:
              continuation.yield(event)
            case let .usage(value):
              usages.append(value)
            case .completed:
              break
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

  /// 跑一片提要点，收齐文字。没出字的片遇到暂时性故障在片内重试，规则同翻译分片。
  private static func runNotes(
    provider: any ModelProvider,
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent,
    retryBaseDelay: Duration
  ) async throws -> (String, RunUsageCost) {
    var attempt = 0
    while true {
      try Task.checkCancellation()
      do {
        var text = ""
        var usage = RunUsageCost.unknown
        for try await event in provider.stream(profile: profile, apiKey: apiKey, intent: intent) {
          try Task.checkCancellation()
          switch event {
          case let .delta(delta): text += delta
          case let .usage(value): usage = value
          case .reasoning, .completed: break
          }
        }
        return (text, usage)
      } catch let failure as ModelProviderFailure
        where attempt < ChunkedTranslationStreamer.chunkRetryBudget(for: failure) {
        attempt += 1
        try await Task.sleep(for: retryBaseDelay * attempt)
      }
    }
  }

  /// 单请求被服务商判为超长（还没出任何字）时，改走一次 `fallback`。
  ///
  /// 只换一次：分片路径再超长，说明是片长或合并输入的问题，再换也没用，原样报给用户。
  public static func fallingBackOnInputTooLarge(
    _ primary: AsyncThrowingStream<ModelStreamEvent, Error>,
    to fallback: @escaping @Sendable () -> AsyncThrowingStream<ModelStreamEvent, Error>
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let work = Task {
        var forwardedText = false
        do {
          do {
            for try await event in primary {
              if case .delta = event { forwardedText = true }
              continuation.yield(event)
            }
          } catch let failure as ModelProviderFailure
            where failure.code == .inputTooLarge && !failure.hadOutput && !forwardedText {
            for try await event in fallback() {
              continuation.yield(event)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in work.cancel() }
    }
  }
}
