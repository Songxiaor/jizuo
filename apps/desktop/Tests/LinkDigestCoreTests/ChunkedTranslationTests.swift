import XCTest
@testable import LinkDigestCore

/// 分片并发翻译的核心风险不是"能不能跑完"，而是**并发到达的片有没有按原顺序落地**。
/// 这类错误不会崩、不会报错，只会让译文段落错位——读起来像模型翻乱了，最难归因。
/// 所以这里的断言都围绕顺序、并发上限和用量汇总，而不是文本内容本身。
final class ChunkedTranslationTests: XCTestCase {
  func testChunksFinishingOutOfOrderStillEmitInSourceOrder() async throws {
    // 让越靠后的片跑得越快：不做排序的实现会先吐最后一段。
    let provider = OrderScrambledProvider(delayForChunkIndex: { index in
      UInt64((10 - index) * 20)
    })
    let text = Self.paragraphs(count: 6, charactersEach: 3_000)
    let streamer = ChunkedTranslationStreamer(provider: provider, concurrency: 6)

    let output = try await Self.collectText(
      streamer.stream(
        profile: try Self.profile(),
        apiKey: "fixture-key",
        title: nil,
        text: text,
        targetLanguage: "简体中文"
      )
    )

    let marks = Self.chunkMarks(in: output)
    XCTAssertEqual(marks, marks.sorted(), "分片必须按原文顺序输出，实际顺序：\(marks)")
    XCTAssertEqual(Set(marks).count, marks.count, "同一片不能出现两次")
  }

  func testConcurrencyNeverExceedsTheConfiguredLimit() async throws {
    let provider = OrderScrambledProvider(delayForChunkIndex: { _ in 30 })
    let text = Self.paragraphs(count: 8, charactersEach: 3_000)
    let streamer = ChunkedTranslationStreamer(provider: provider, concurrency: 3)

    _ = try await Self.collectText(
      streamer.stream(
        profile: try Self.profile(),
        apiKey: "fixture-key",
        title: nil,
        text: text,
        targetLanguage: "简体中文"
      )
    )

    XCTAssertLessThanOrEqual(
      provider.peakConcurrency,
      3,
      "并发上限是对服务商的承诺：超了就会在限流的端点上换来一片 429"
    )
    XCTAssertGreaterThan(provider.peakConcurrency, 1, "配了并发却仍然串行，等于这次改动白做")
  }

  func testUsageIsSummedAcrossChunks() async throws {
    let provider = OrderScrambledProvider(delayForChunkIndex: { _ in 0 }, outputTokensPerChunk: 7)
    let text = Self.paragraphs(count: 4, charactersEach: 3_000)
    let streamer = ChunkedTranslationStreamer(provider: provider, concurrency: 2)

    var usage: RunUsageCost?
    for try await event in streamer.stream(
      profile: try Self.profile(),
      apiKey: "fixture-key",
      title: nil,
      text: text,
      targetLanguage: "简体中文"
    ) {
      if case let .usage(value) = event { usage = value }
    }

    XCTAssertEqual(usage?.outputTokens, Int64(provider.startedChunkCount * 7))
  }

  func testChunkLimitRoundsChunkCountToAMultipleOfConcurrency() {
    // 实测那篇 38,487 字：固定 6000 字会切出 7 片，并发 3 要跑 3 波，
    // 最后一波只有 1 片，另外两条通道空转。
    let limit = ChunkedTranslationStreamer.chunkLimit(
      forCharacterCount: 38_487,
      concurrency: 3,
      maximum: 6_000
    )
    let chunkCount = Int((38_487.0 / Double(limit)).rounded(.up))
    XCTAssertEqual(chunkCount % 3, 0, "片数必须是并发的整数倍，否则最后一波在空转")
    XCTAssertLessThanOrEqual(limit, 6_000, "不得突破片长上限")

    let wavesBefore = Int((7.0 / 3.0).rounded(.up))
    let wavesAfter = chunkCount / 3
    XCTAssertEqual(wavesAfter, wavesBefore, "波数不该变多")
    XCTAssertLessThan(
      wavesAfter * limit,
      wavesBefore * 6_000,
      "同样的波数下每片更短，总时长才会真的下降"
    )
  }

  func testChunkLimitLeavesSingleConcurrencyAlone() {
    // 并发 1 时片数与波数一一对应，重算片长只会平白切碎上下文。
    XCTAssertEqual(
      ChunkedTranslationStreamer.chunkLimit(forCharacterCount: 38_487, concurrency: 1, maximum: 6_000),
      6_000
    )
  }

  func testChunkLimitNeverGoesBelowTheFloor() {
    // 并发远大于内容量时，反算会得出极小的片长——切得太碎，跨片上下文全丢，
    // 每请求固定开销也开始反噬。
    let limit = ChunkedTranslationStreamer.chunkLimit(
      forCharacterCount: 9_000,
      concurrency: 6,
      maximum: 6_000
    )
    XCTAssertGreaterThanOrEqual(limit, ChunkedTranslationStreamer.minimumChunkCharacters)
  }

  func testShortTextIsNotChunked() {
    let short = Self.paragraphs(count: 2, charactersEach: 500)
    XCTAssertFalse(
      ChunkedTranslationStreamer.shouldChunk(short),
      "短文分片只会多花请求、多丢上下文，换不回时间"
    )
  }

  func testLongSingleParagraphIsNotChunkedBecauseItCannotBeSplitSafely() {
    // 段落是唯一的切分边界；一整段超长时宁可整段发，也不从句子中间切开。
    let single = String(repeating: "字", count: 20_000)
    XCTAssertFalse(ChunkedTranslationStreamer.shouldChunk(single))
  }

  // MARK: - Helpers

  private static func profile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "fixture-reference")
    )
  }

  /// 每段开头带一个可识别的序号标记，用来验证输出顺序。
  private static func paragraphs(count: Int, charactersEach: Int) -> String {
    (0..<count)
      .map { "[[\($0)]]" + String(repeating: "字", count: charactersEach) }
      .joined(separator: "\n\n")
  }

  private static func chunkMarks(in text: String) -> [Int] {
    let pattern = try! NSRegularExpression(pattern: #"\[\[(\d+)\]\]"#)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return pattern.matches(in: text, range: range).compactMap { match in
      guard let r = Range(match.range(at: 1), in: text) else { return nil }
      return Int(text[r])
    }
  }

  private static func collectText(
    _ stream: AsyncThrowingStream<ModelStreamEvent, Error>
  ) async throws -> String {
    var output = ""
    for try await event in stream {
      if case let .delta(delta) = event { output += delta }
    }
    return output
  }

  /// 整篇装得下的稿子，不能被「按并发凑整」切开。
  ///
  /// 实测：一份 1557 字的画面字幕稿，单片上限本是 2000、整篇发绰绰有余，却因为
  /// `chunkLimit` 的下限 1500 被切成两片——大片失败、只剩几十字的尾巴片成功，
  /// 界面报「2 段中有 1 段失败」，用户看到校对完几乎没变，配额还白扣一次。
  ///
  /// 这里守的是**调用方的判据**：短于单片上限时必须整篇一片。反算函数本身没错，
  /// 错在不该对这种长度调用它。
  func testShortTextIsNotSplitByConcurrencyRounding() {
    let maximum = 2_000
    let concurrency = 3
    // 文本必须**分段**，否则测不出东西：分段器遇到超长的单个段落会整段保留，
    // 一整块无分隔的字符无论门槛多低都只会得到一片，断言于是永远为真。真实的
    // 字幕稿和听写稿都按时间码分段，段间是空行。
    func paragraphed(_ count: Int) -> String {
      let perParagraph = 170
      var paragraphs: [String] = []
      var remaining = count
      while remaining > 0 {
        let take = min(perParagraph, remaining)
        paragraphs.append(String(repeating: "字", count: take))
        remaining -= take
        if remaining > 0 { remaining -= 2 }  // 抵掉分隔符自身占的长度
      }
      return paragraphs.joined(separator: "\n\n")
    }

    // 1557 是触发过真实故障的长度：单片上限 2000 装得下，却被下限 1500 切成两片。
    for count in [1_501, 1_557, 1_999, maximum] {
      let text = paragraphed(count)
      XCTAssertLessThanOrEqual(text.count, maximum, "构造的样本本身就超了上限，测不到点子上")
      let limit = text.count <= maximum
        ? maximum
        : ChunkedTranslationStreamer.chunkLimit(
            forCharacterCount: text.count, concurrency: concurrency, maximum: maximum)
      XCTAssertEqual(
        TranscriptTidyChunker.chunks(of: text, limit: limit).count, 1,
        "\(text.count) 字装得下一片却被切开了"
      )
    }
  }

  /// 反算依然要对超长稿生效——修短稿不能把长稿的吞吐优化一起关掉。
  func testLongTextStillRoundsChunkCountToConcurrency() {
    let limit = ChunkedTranslationStreamer.chunkLimit(
      forCharacterCount: 34_406, concurrency: 3, maximum: 2_000)
    XCTAssertGreaterThan(limit, 1_500, "超长稿仍应按并发反算出接近上限的片长")
    XCTAssertLessThanOrEqual(limit, 2_000)
  }
}

/// 回声 Provider：把收到的分片原样吐回，但故意让不同片以不同速度完成。
private final class OrderScrambledProvider: ModelProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let delayForChunkIndex: @Sendable (Int) -> UInt64
  private let outputTokensPerChunk: Int64?
  private var inFlight = 0
  private(set) var peakConcurrency = 0
  private(set) var startedChunkCount = 0

  init(
    delayForChunkIndex: @escaping @Sendable (Int) -> UInt64,
    outputTokensPerChunk: Int64? = nil
  ) {
    self.delayForChunkIndex = delayForChunkIndex
    self.outputTokensPerChunk = outputTokensPerChunk
  }

  func stream(
    profile _: ProviderProfile,
    apiKey _: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    guard case let .translate(_, text, _) = intent else {
      return AsyncThrowingStream { $0.finish() }
    }
    // 分片自带序号标记，直接用它决定这一片跑多久。
    let index = Self.mark(in: text) ?? 0
    let delay = delayForChunkIndex(index)
    let tokens = outputTokensPerChunk

    lock.withLock {
      inFlight += 1
      startedChunkCount += 1
      peakConcurrency = max(peakConcurrency, inFlight)
    }

    return AsyncThrowingStream { continuation in
      let producer = Task {
        defer { lock.withLock { inFlight -= 1 } }
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        continuation.yield(.delta(text))
        if let tokens {
          continuation.yield(.usage(RunUsageCost(outputTokens: tokens)))
        }
        continuation.yield(.completed)
        continuation.finish()
      }
      continuation.onTermination = { _ in producer.cancel() }
    }
  }

  func cancelActiveStreams() {}

  private static func mark(in text: String) -> Int? {
    guard let open = text.range(of: "[["), let close = text.range(of: "]]") else { return nil }
    return Int(text[open.upperBound..<close.lowerBound])
  }

}
