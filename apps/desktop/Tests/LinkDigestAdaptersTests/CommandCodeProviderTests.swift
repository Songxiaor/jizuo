import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// Command Code Claude → Anthropic `/messages` 的脱敏 URLProtocol 测试。
/// 不触网、不用真实密钥；断言端点/头/体与三入口（stream/probe、自动标签、非 Claude）。
final class CommandCodeProviderTests: XCTestCase {
  override func tearDown() {
    CommandCodeURLProtocol.reset()
    super.tearDown()
  }

  func testRoutingOnlyMatchesCommandCodeRootPlusClaudeLeaf() {
    let root = URL(string: "https://api.commandcode.ai/provider/v1")!
    XCTAssertTrue(CommandCodeProviderRouting.usesAnthropicMessages(baseURL: root, model: "claude-sonnet-4-6"))
    XCTAssertTrue(CommandCodeProviderRouting.usesAnthropicMessages(baseURL: root, model: "claude-opus-4-6"))
    XCTAssertFalse(CommandCodeProviderRouting.usesAnthropicMessages(
      baseURL: root,
      model: "deepseek/deepseek-v4-flash"
    ))
    XCTAssertFalse(CommandCodeProviderRouting.usesAnthropicMessages(
      baseURL: URL(string: "https://openrouter.ai/api/v1")!,
      model: "claude-sonnet-4-6"
    ))
    XCTAssertFalse(CommandCodeProviderRouting.usesAnthropicMessages(
      baseURL: URL(string: "https://api.commandcode.ai/v1")!,
      model: "claude-sonnet-4-6"
    ))
  }

  func testClaudeProbeUsesMessagesEndpointAndAnthropicBody() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let sse = """
    data: {"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":0}}}

    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}

    data: {"type":"message_delta","usage":{"output_tokens":2}}

    data: {"type":"message_stop"}

    """
    CommandCodeURLProtocol.handler = { request in
      Self.assertNoSecretLeak(request: request, key: key)
      return (
        Self.httpResponse(
          request: request,
          status: 200,
          contentType: "text/event-stream"
        ),
        Data(sse.utf8)
      )
    }
    let provider = makeProvider()
    let profile = try commandCodeProfile(model: "claude-sonnet-4-6")

    let result = await collect(provider: provider, profile: profile, apiKey: key, intent: .connectionTest)

    XCTAssertNil(result.failure)
    XCTAssertEqual(result.events, [
      .delta("OK"),
      .usage(RunUsageCost(inputTokens: 11, outputTokens: 2, totalTokens: 13)),
      .completed,
    ])
    let request = try XCTUnwrap(CommandCodeURLProtocol.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://api.commandcode.ai/provider/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    let body = try jsonObject(request.httpBody)
    XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["max_tokens"] as? Int, 64)
    XCTAssertNil(body["system"])
    XCTAssertNil(body["reasoning_effort"])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages, [["role": "user", "content": "Reply with OK."]])
  }

  func testClaudeSummarizeMovesSystemToTopLevelWithoutReasoningFields() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let sse = """
    data: {"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":0}}}

    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"摘要"}}

    data: {"type":"message_delta","usage":{"output_tokens":4}}

    data: {"type":"message_stop"}

    """
    CommandCodeURLProtocol.handler = { request in
      (
        Self.httpResponse(request: request, status: 200, contentType: "text/event-stream"),
        Data(sse.utf8)
      )
    }
    let provider = makeProvider()
    let profile = try commandCodeProfile(model: "claude-sonnet-4-6")
    let result = await collect(
      provider: provider,
      profile: profile,
      apiKey: key,
      intent: .summarize(title: "T", text: "正文", prompt: "系统提示词")
    )

    XCTAssertNil(result.failure)
    XCTAssertEqual(result.events.first, .delta("摘要"))
    XCTAssertTrue(result.events.contains(.completed))
    let body = try jsonObject(try XCTUnwrap(CommandCodeURLProtocol.requests.first?.httpBody))
    XCTAssertEqual(body["system"] as? String, "系统提示词")
    XCTAssertEqual(body["max_tokens"] as? Int, CommandCodeMessagesCodec.defaultMaxTokens)
    XCTAssertNil(body["reasoning_effort"])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0]["role"], "user")
    XCTAssertFalse(messages.contains { $0["role"] == "system" })
  }

  func testClaudeAutomaticTagsUseMessagesNonStreamingShape() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let payload = """
    {"content":[{"type":"text","text":"AI 工具, 本地优先"}],"usage":{"input_tokens":9,"output_tokens":3}}
    """
    CommandCodeURLProtocol.handler = { request in
      (
        Self.httpResponse(request: request, status: 200, contentType: "application/json"),
        Data(payload.utf8)
      )
    }
    let tags = try await makeProvider().generateSummaryTags(
      profile: try commandCodeProfile(model: "claude-sonnet-4-6"),
      apiKey: key,
      summary: "已经完成的总结文本"
    )

    XCTAssertEqual(tags, "AI 工具, 本地优先")
    let request = try XCTUnwrap(CommandCodeURLProtocol.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.commandcode.ai/provider/v1/messages")
    let body = try jsonObject(request.httpBody)
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["max_tokens"] as? Int, OpenAICompatibleProvider.automaticTagMaximumTokens)
    let system = try XCTUnwrap(body["system"] as? String)
    XCTAssertTrue(system.contains("主题标签"))
    XCTAssertNil(body["reasoning_effort"])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages, [["role": "user", "content": "已经完成的总结文本"]])
  }

  func testNonClaudeOnCommandCodeStaysOnChatCompletions() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let sse = """
    data: {"choices":[{"delta":{"content":"Hi"}}]}

    data: [DONE]

    """
    CommandCodeURLProtocol.handler = { request in
      (
        Self.httpResponse(request: request, status: 200, contentType: "text/event-stream"),
        Data(sse.utf8)
      )
    }
    let result = await collect(
      provider: makeProvider(),
      profile: try commandCodeProfile(model: "deepseek/deepseek-v4-flash"),
      apiKey: key
    )

    XCTAssertNil(result.failure)
    XCTAssertEqual(result.events, [.delta("Hi"), .completed])
    let request = try XCTUnwrap(CommandCodeURLProtocol.requests.first)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api.commandcode.ai/provider/v1/chat/completions"
    )
    let body = try jsonObject(request.httpBody)
    XCTAssertNotNil(body["messages"])
    XCTAssertNil(body["system"])
  }

  func testOtherMerchantClaudeStaysOnChatCompletions() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let sse = """
    data: {"choices":[{"delta":{"content":"Hi"}}]}

    data: [DONE]

    """
    CommandCodeURLProtocol.handler = { request in
      (
        Self.httpResponse(request: request, status: 200, contentType: "text/event-stream"),
        Data(sse.utf8)
      )
    }
    let profile = try ProviderProfile(
      baseURL: "https://openrouter.ai/api/v1",
      model: "claude-sonnet-4-6",
      secretReference: SecretReference(rawValue: "test-reference")
    )
    let result = await collect(provider: makeProvider(), profile: profile, apiKey: key)
    XCTAssertNil(result.failure)
    let request = try XCTUnwrap(CommandCodeURLProtocol.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
  }

  func testMergedUsageKeepsInputFromMessageStart() throws {
    let decoder = CommandCodeMessagesStreamDecoder()
    XCTAssertEqual(
      try decoder.decode(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":42,"output_tokens":0}}}"#),
      []
    )
    XCTAssertEqual(
      try decoder.decode(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"A"}}"#),
      [.delta("A")]
    )
    XCTAssertEqual(
      try decoder.decode(line: #"data: {"type":"message_delta","usage":{"output_tokens":7}}"#),
      [.usage(RunUsageCost(inputTokens: 42, outputTokens: 7, totalTokens: 49))]
    )
    XCTAssertEqual(
      try decoder.decode(line: #"data: {"type":"message_stop"}"#),
      [.completed]
    )
  }

  func testErrorSSEFailsWithHadOutputAfterDelta() throws {
    let decoder = CommandCodeMessagesStreamDecoder()
    _ = try decoder.decode(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"部分"}}"#)
    do {
      _ = try decoder.decode(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
      XCTFail("error SSE must fail")
    } catch let failure as ModelProviderFailure {
      XCTAssertEqual(failure.code, .providerUnavailable)
      XCTAssertTrue(failure.retryable)
      XCTAssertTrue(failure.hadOutput)
      XCTAssertFalse(String(describing: failure).contains("busy"))
    }
  }

  func testErrorSSEBeforeDeltaAllowsRetryableFailureWithoutHadOutput() throws {
    let decoder = CommandCodeMessagesStreamDecoder()
    do {
      _ = try decoder.decode(line: #"data: {"type":"error","error":{"type":"overloaded_error"}}"#)
      XCTFail("error SSE must fail")
    } catch let failure as ModelProviderFailure {
      XCTAssertEqual(failure.code, .providerUnavailable)
      XCTAssertTrue(failure.retryable)
      XCTAssertFalse(failure.hadOutput)
    }
  }

  func testClaudeStreamHTTPFailureUsesExistingStatusMapping() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    CommandCodeURLProtocol.handler = { request in
      (
        Self.httpResponse(request: request, status: 403, contentType: "application/json"),
        Data(#"{"type":"error","error":{"type":"permission_error","message":"upgrade_required"}}"#.utf8)
      )
    }
    let result = await collect(
      provider: makeProvider(),
      profile: try commandCodeProfile(model: "claude-sonnet-4-6"),
      apiKey: key
    )
    XCTAssertEqual(result.failure?.code, .authForbidden)
    XCTAssertFalse(result.failure?.retryable ?? true)
    XCTAssertFalse(result.failure?.hadOutput ?? true)
  }

  func testStopWithoutFollowingLineEmitsUsageAndCompletionTogether() throws {
    let decoder = CommandCodeMessagesStreamDecoder()
    _ = try decoder.decode(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}"#)
    XCTAssertEqual(try decoder.decode(line: #"data: {"type":"message_stop"}"#), [
      .usage(RunUsageCost(inputTokens: 4, outputTokens: 0, totalTokens: 4)), .completed
    ])
  }

  func testUsageUpdatesAndOverflowRemainSafe() throws {
    let decoder = CommandCodeMessagesStreamDecoder()
    _ = try decoder.decode(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}"#)
    _ = try decoder.decode(line: #"data: {"type":"message_delta","usage":{"output_tokens":2}}"#)
    XCTAssertEqual(try decoder.decode(line: #"data: {"type":"message_delta","usage":{"output_tokens":8}}"#), [
      .usage(RunUsageCost(inputTokens: 4, outputTokens: 8, totalTokens: 12))
    ])
    let large = CommandCodeMessagesStreamDecoder()
    _ = try large.decode(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":9223372036854775807}}}"#)
    XCTAssertEqual(try large.decode(line: #"data: {"type":"message_delta","usage":{"output_tokens":1}}"#), [
      .usage(RunUsageCost(inputTokens: Int64.max, outputTokens: 1, totalTokens: nil))
    ])
  }

  func testStreamStopsAtEOFAndPartialErrorDoesNotRetry() async throws {
    let profile = try commandCodeProfile(model: "claude-sonnet-4-6")
    CommandCodeURLProtocol.handler = { request in
      (Self.httpResponse(request: request, status: 200, contentType: "text/event-stream"),
       Data(#"data: {"type":"message_stop"}"#.utf8))
    }
    let stopped = await collect(provider: makeProvider(), profile: profile, apiKey: "not-a-real-key")
    XCTAssertNil(stopped.failure)
    XCTAssertEqual(stopped.events, [.completed])
    CommandCodeURLProtocol.reset()
    CommandCodeURLProtocol.handler = { request in
      (Self.httpResponse(request: request, status: 200, contentType: "text/event-stream"), Data((
        #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"部分"}}"# + "\n\n" +
        #"data: {"type":"error","error":{"type":"overloaded_error"}}"#
      ).utf8))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CommandCodeURLProtocol.self]
    let provider = OpenAICompatibleProvider(session: URLSession(configuration: configuration), maximumRetryCount: 2, defaultBackoff: 0)
    let failed = await collect(provider: provider, profile: profile, apiKey: "not-a-real-key")
    XCTAssertEqual(failed.events, [.delta("部分")])
    XCTAssertEqual(failed.failure?.hadOutput, true)
    XCTAssertEqual(CommandCodeURLProtocol.requests.count, 1)
  }

  func testNonStreamingClaudeUsesMessagesForTextProcessing() async throws {
    CommandCodeURLProtocol.handler = { request in
      (Self.httpResponse(request: request, status: 200, contentType: "application/json"),
       Data(#"{"content":[{"type":"text","text":"整理后的文本"}],"usage":{"input_tokens":5,"output_tokens":3}}"#.utf8))
    }
    let result = try await makeProvider().tidyTranscriptChunk(
      profile: commandCodeProfile(model: "deepseek/deepseek-v4-flash"), apiKey: "not-a-real-key",
      model: "claude-sonnet-4-6", text: "原文", systemPrompt: "整理")
    XCTAssertEqual(result.text, "整理后的文本")
    XCTAssertEqual(result.totalTokens, 8)
    XCTAssertEqual(CommandCodeURLProtocol.requests.first?.url?.path, "/provider/v1/messages")
  }

  // MARK: - Helpers

  private func makeProvider() -> OpenAICompatibleProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CommandCodeURLProtocol.self]
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    return OpenAICompatibleProvider(
      session: URLSession(configuration: configuration),
      sleeper: CommandCodeNoSleepSleeper(),
      maximumRetryCount: 0,
      defaultBackoff: 0
    )
  }

  private func commandCodeProfile(model: String) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "https://api.commandcode.ai/provider/v1",
      model: model,
      secretReference: SecretReference(rawValue: "test-reference")
    )
  }

  private func collect(
    provider: OpenAICompatibleProvider,
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent = .connectionTest
  ) async -> (events: [ModelStreamEvent], failure: ModelProviderFailure?) {
    var events: [ModelStreamEvent] = []
    do {
      for try await event in provider.stream(profile: profile, apiKey: apiKey, intent: intent) {
        events.append(event)
      }
      return (events, nil)
    } catch let failure as ModelProviderFailure {
      return (events, failure)
    } catch {
      XCTFail("Unexpected non-stable failure type")
      return (events, nil)
    }
  }

  private func jsonObject(_ data: Data?) throws -> [String: Any] {
    let data = try XCTUnwrap(data)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func httpResponse(
    request: URLRequest,
    status: Int,
    contentType: String
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType]
    )!
  }

  private static func assertNoSecretLeak(request: URLRequest, key: String) {
    let bodyText = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    XCTAssertFalse(bodyText.contains(key))
  }
}

private final class CommandCodeNoSleepSleeper: RetrySleeper, @unchecked Sendable {
  func sleep(for seconds: TimeInterval) async throws {}
}

/// 脱敏录制用 URLProtocol：只服务本测试，不落真实网络。
private final class CommandCodeURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var requests: [URLRequest] = []
  private static let lock = NSLock()

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    handler = nil
    requests = []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var request = self.request
    if request.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var body = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
      request.httpBody = body
    }
    Self.lock.lock()
    Self.requests.append(request)
    let handler = Self.handler
    Self.lock.unlock()

    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
