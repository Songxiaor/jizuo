import XCTest
@testable import LinkDigestCore

/// 长文总结分片的风险：要点没按原文顺序进合并请求、片号错位、超长时没换路、
/// 用户的总结提示词没用在最后一步。断言围绕这几件事。
final class ChunkedSummaryTests: XCTestCase {
  func testShortTextIsNotChunked() {
    XCTAssertFalse(ChunkedSummaryStreamer.shouldChunk(Self.paragraphs(count: 4, charactersEach: 3_000)))
    XCTAssertTrue(ChunkedSummaryStreamer.shouldChunk(Self.paragraphs(count: 12, charactersEach: 3_000)))
  }

  func testTextWithoutBlankLinesIsStillSplit() {
    // 整篇没有空行的转写稿：只按段落切会得到一整片。
    let text = String(repeating: "这是一句转写。", count: 6_000)
    let chunks = ChunkedSummaryStreamer.chunks(of: text, limit: 12_000)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 12_000 })
    XCTAssertEqual(chunks.joined(), text, "补切不能丢字")
  }

  func testNotesAreMergedInSourceOrderWithUserPrompt() async throws {
    // 越靠后的片越快：不排序的实现会把最后一片的要点放到最前。
    let provider = SummaryFakeProvider(delayForPart: { part in UInt64((10 - part) * 15) })
    let text = Self.paragraphs(count: 6, charactersEach: 11_000)
    let streamer = ChunkedSummaryStreamer(provider: provider, concurrency: 3, retryBaseDelay: .zero)

    var output = ""
    var usage: RunUsageCost?
    var sawThinking = false
    for try await event in streamer.stream(
      profile: try Self.profile(),
      apiKey: "fixture-key",
      title: "长文",
      text: text,
      summaryPrompt: "USER-PROMPT",
      outputLanguage: "简体中文"
    ) {
      switch event {
      case let .delta(delta): output += delta
      case let .usage(value): usage = value
      case .reasoning: sawThinking = true
      case .completed: break
      }
    }

    XCTAssertEqual(output, "FINAL")
    XCTAssertTrue(sawThinking, "提要点阶段要报「正在思考」，否则界面像卡住")
    let merge = try XCTUnwrap(provider.mergeRequest)
    XCTAssertTrue(merge.prompt.hasPrefix("USER-PROMPT"), "合并一步必须用用户的总结提示词")
    let marks = Self.marks(in: merge.text)
    XCTAssertEqual(marks, marks.sorted())
    XCTAssertEqual(marks.count, provider.notesRequestCount)
    XCTAssertLessThanOrEqual(provider.peakConcurrency, 3)
    XCTAssertEqual(usage?.outputTokens, Int64((provider.notesRequestCount + 1) * 5))
  }

  func testInputTooLargeFallsBackToChunkedOnce() async throws {
    let primary = AsyncThrowingStream<ModelStreamEvent, Error> { continuation in
      continuation.finish(throwing: ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: false))
    }
    let fallbackCalls = Counter()
    let stream = ChunkedSummaryStreamer.fallingBackOnInputTooLarge(primary) {
      fallbackCalls.increment()
      return AsyncThrowingStream { continuation in
        continuation.yield(.delta("FALLBACK"))
        continuation.yield(.completed)
        continuation.finish()
      }
    }
    var output = ""
    for try await event in stream {
      if case let .delta(delta) = event { output += delta }
    }
    XCTAssertEqual(output, "FALLBACK")
    XCTAssertEqual(fallbackCalls.value, 1)
  }

  func testOtherFailuresDoNotFallBack() async {
    let primary = AsyncThrowingStream<ModelStreamEvent, Error> { continuation in
      continuation.finish(throwing: ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false))
    }
    let fallbackCalls = Counter()
    let stream = ChunkedSummaryStreamer.fallingBackOnInputTooLarge(primary) {
      fallbackCalls.increment()
      return AsyncThrowingStream { $0.finish() }
    }
    do {
      for try await _ in stream {}
      XCTFail("应原样抛出")
    } catch let failure as ModelProviderFailure {
      XCTAssertEqual(failure.code, .authInvalid)
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertEqual(fallbackCalls.value, 0)
  }

  func testFallbackChunkLimitSplitsIntoAtLeastThreeParts() {
    XCTAssertEqual(ChunkedSummaryStreamer.fallbackChunkLimit(forCharacterCount: 18_000), 6_000)
    XCTAssertEqual(ChunkedSummaryStreamer.fallbackChunkLimit(forCharacterCount: 3_000), 2_000)
    XCTAssertEqual(ChunkedSummaryStreamer.fallbackChunkLimit(forCharacterCount: 300_000), 12_000)
  }

  // MARK: - Fixtures

  private static func profile() throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://example.test/v1",
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "fixture-reference")
    )
  }

  private static func paragraphs(count: Int, charactersEach: Int) -> String {
    (0..<count)
      .map { "[[\($0)]]" + String(repeating: "字", count: charactersEach) }
      .joined(separator: "\n\n")
  }

  static func marks(in text: String) -> [Int] {
    let regex = try! NSRegularExpression(pattern: #"NOTE<(\d+)>"#)
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap {
      Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
    }
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

/// 提要点请求按片号回 `NOTE<片号>`，合并请求回 `FINAL`；记下并发峰值和合并请求。
private final class SummaryFakeProvider: ModelProvider, @unchecked Sendable {
  struct Request { let text: String; let prompt: String }
  private let lock = NSLock()
  private let delayForPart: @Sendable (Int) -> UInt64
  private var inFlight = 0
  private(set) var peakConcurrency = 0
  private(set) var notesRequestCount = 0
  private(set) var mergeRequest: Request?

  init(delayForPart: @escaping @Sendable (Int) -> UInt64) {
    self.delayForPart = delayForPart
  }

  func stream(profile: ProviderProfile, apiKey: String, intent: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    guard case let .summarize(_, text, prompt) = intent else {
      return AsyncThrowingStream { $0.finish() }
    }
    let part = Self.part(from: prompt)
    return AsyncThrowingStream { continuation in
      Task {
        if let part {
          self.lock.withLock {
            self.notesRequestCount += 1
            self.inFlight += 1
            self.peakConcurrency = max(self.peakConcurrency, self.inFlight)
          }
          try? await Task.sleep(nanoseconds: self.delayForPart(part) * 1_000_000)
          self.lock.withLock { self.inFlight -= 1 }
          continuation.yield(.delta("- NOTE<\(part)>"))
        } else {
          self.lock.withLock { self.mergeRequest = Request(text: text, prompt: prompt) }
          continuation.yield(.delta("FINAL"))
        }
        continuation.yield(.usage(RunUsageCost(inputTokens: nil, outputTokens: 5, totalTokens: nil, costAmountMicros: nil, costCurrencyCode: nil)))
        continuation.yield(.completed)
        continuation.finish()
      }
    }
  }

  func cancelActiveStreams() {}

  private static func part(from prompt: String) -> Int? {
    guard let range = prompt.range(of: #"part (\d+) of"#, options: .regularExpression) else { return nil }
    return Int(prompt[range].dropFirst(5).prefix { $0.isNumber })
  }
}
