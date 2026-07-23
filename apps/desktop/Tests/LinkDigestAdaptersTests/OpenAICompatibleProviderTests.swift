import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class OpenAICompatibleProviderTests: XCTestCase {
  func testModelCatalogUsesValidatedBaseURLAndReturnsAtMostFiveHundredResults() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let payload = try JSONSerialization.data(withJSONObject: [
      "object": "list",
      "data": (0..<500).map { ["id": String(format: "model-%03d", $0), "ignored": "value"] }
    ])
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(contentType: "application/json", chunks: [.init(String(decoding: payload, as: UTF8.self))])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let catalogBaseURL = try ProviderProfile.validatedBaseURL(
      baseURL.appending(path: "api/v1").absoluteString,
      allowLoopbackHTTP: true
    )

    let models = try await makeProvider().listModels(
      baseURL: catalogBaseURL,
      apiKey: key
    )

    XCTAssertEqual(models.count, 500)
    XCTAssertEqual(models.first, "model-000")
    XCTAssertEqual(models.last, "model-499")
    let request = try XCTUnwrap(server.requests.first)
    XCTAssertEqual(request.method, "GET")
    XCTAssertEqual(request.path, "/api/v1/models")
    XCTAssertTrue(request.authorizationMatched)
    XCTAssertEqual(request.accept, "application/json")
    XCTAssertFalse(request.description.contains(key))
  }

  func testModelCatalogFailureAndTimeoutUseStableErrors() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let unavailable = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [.init(statusCode: 503)])
    let unavailableURL = try unavailable.start()
    defer { unavailable.stop() }
    do {
      _ = try await makeProvider().listModels(baseURL: unavailableURL, apiKey: key)
      XCTFail("503 must not become a usable catalog")
    } catch let error as ModelProviderFailure {
      XCTAssertEqual(error.code, .providerUnavailable)
      XCTAssertTrue(error.retryable)
    }

    let delayed = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(contentType: "application/json", chunks: [.init(#"{"data":[]}"#, delay: 1)])
    ])
    let delayedURL = try delayed.start()
    defer { delayed.stop() }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 0.1
    config.timeoutIntervalForResource = 0.1
    let timedProvider = OpenAICompatibleProvider(session: URLSession(configuration: config))
    do {
      _ = try await timedProvider.listModels(baseURL: delayedURL, apiKey: key)
      XCTFail("a stalled /models response must fall back safely")
    } catch let error as ModelProviderFailure {
      XCTAssertEqual(error.code, .networkInterrupted)
    }
  }

  func testModelCatalogRejectsMoreThanFiveHundredItemsWithFixedLimitError() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let payload = try JSONSerialization.data(withJSONObject: [
      "data": (0..<501).map { ["id": "model-\($0)"] }
    ])
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(contentType: "application/json", chunks: [.init(String(decoding: payload, as: UTF8.self))])
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    do {
      _ = try await makeProvider().listModels(baseURL: baseURL, apiKey: key)
      XCTFail("an oversized catalog must not be silently truncated")
    } catch let error as ModelProviderFailure {
      XCTAssertEqual(error.code, .inputTooLarge)
      XCTAssertFalse(error.retryable)
    }
  }

  func testAutomaticTagsUseNonStreamingRequestWithFixedPromptAndSameModel() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let response = #"{"choices":[{"message":{"content":"Swift, 本地优先\n忽略这一行"}}]}"#
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(contentType: "application/json", chunks: [.init(response)])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()

    let tags = try await provider.generateSummaryTags(
      profile: try profile(baseURL),
      apiKey: key,
      summary: "已经完成的总结文本"
    )

    XCTAssertEqual(tags, "Swift, 本地优先\n忽略这一行")
    let request = try XCTUnwrap(server.requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/api/v1/chat/completions")
    XCTAssertEqual(request.accept, "application/json")
    XCTAssertTrue(request.authorizationMatched)
    let bodyData = try XCTUnwrap(request.body.data(using: String.Encoding.utf8))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "fixture-model")
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["max_tokens"] as? Int, OpenAICompatibleProvider.automaticTagMaximumTokens)
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages, [
      // 标签必须是跨文章可复用的主题词，不是文中章节名；prompt 收紧于 7/23。
      ["role": "system", "content": "为以下摘要输出 1-5 个中文主题标签，逗号分隔，不要输出其他内容。标签必须是可用于归类多篇文章的领域名或实体名（如：AI 工具、折叠屏、Claude Code），严禁输出文中章节标题或“概述/建议/要点”这类结构词。"],
      ["role": "user", "content": "已经完成的总结文本"],
    ])
    XCTAssertFalse(request.description.contains(key))
  }

  func testEndpointPreservesPathPrefixAndRejectsCompletedEndpoint() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://example.test/openai/v1///"))
    let endpoint = try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: baseURL)
    XCTAssertEqual(endpoint.absoluteString, "https://example.test/openai/v1/chat/completions")

    let completedURL = try XCTUnwrap(URL(string: "https://example.test/v1/chat/completions/"))
    XCTAssertThrowsError(try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: completedURL)) { error in
      XCTAssertEqual((error as? ModelProviderFailure)?.code, .baseURLInvalid)
    }
  }

  func testRequestAndSuccessfulStreamingAreOpenAICompatible() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [
        .init("event: message\n"),
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
          + "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"),
        .init("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}\n\n"),
        .init("data: [DONE]\n\n")
      ])
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(result.events, [
      .delta("Hel"), .delta("lo"),
      .usage(RunUsageCost(inputTokens: 12, outputTokens: 3, totalTokens: 15)),
      .completed
    ])
    XCTAssertNil(result.failure)
    let request = try XCTUnwrap(server.requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/api/v1/chat/completions")
    XCTAssertTrue(request.authorizationPresent)
    XCTAssertTrue(request.authorizationMatched)
    XCTAssertEqual(request.contentType, "application/json")
    XCTAssertEqual(request.accept, "text/event-stream")

    let bodyData = try XCTUnwrap(request.body.data(using: .utf8))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "fixture-model")
    XCTAssertEqual(body["stream"] as? Bool, true)
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages, [["role": "user", "content": "Reply with OK."]])
    XCTAssertFalse(request.description.contains(key))
  }

  func testUsageOnlyTailWithoutChoicesAcceptsCountersAndDiscardsMalformedMetadata() throws {
    let decoder = ChatCompletionsStreamDecoder()
    XCTAssertEqual(
      try decoder.decode(line: "data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":5,\"total_tokens\":7}}"),
      .usage(RunUsageCost(inputTokens: 2, outputTokens: 5, totalTokens: 7))
    )
    for payload in [
      "{\"choices\":[],\"usage\":{\"total_tokens\":-1}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":\"seven\"}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":9223372036854775808}}",
      "{\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":\"bad\",\"total_tokens\":2}}"
    ] {
      XCTAssertNil(try decoder.decode(line: "data: \(payload)"), "Malformed optional usage must wait for [DONE], not fail the stream")
    }
    XCTAssertEqual(
      try decoder.decode(line: "data: {\"choices\":[{\"delta\":{\"content\":\"正文\"}}],\"usage\":{\"total_tokens\":\"bad\"}}"),
      .delta("正文"),
      "A valid delta remains primary when its co-located optional usage is malformed"
    )
  }

  func testMalformedUsageTailDoesNotInterruptProviderStream() async throws {
    let malformedUsagePayloads = [
      "{\"choices\":[],\"usage\":{\"total_tokens\":-1}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":\"seven\"}}",
      "{\"choices\":[],\"usage\":{\"total_tokens\":9223372036854775808}}",
      "{\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":\"bad\",\"total_tokens\":2}}"
    ]
    for payload in malformedUsagePayloads {
      let key = "sentinel-\(UUID().uuidString)"
      let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
        .init(chunks: [
          .init("data: {\"choices\":[{\"delta\":{\"content\":\"complete\"}}]}\n\n"),
          .init("data: \(payload)\n\n"),
          .init("data: [DONE]\n\n")
        ])
      ])
      let baseURL = try server.start()
      let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)
      server.stop()
      XCTAssertEqual(result.events, [.delta("complete"), .completed])
      XCTAssertNil(result.failure)
    }
  }

  func testSummarizeAndTranslatePromptsContainOnlyTitleBodyAndRequestedLanguage() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [.init("data: [DONE]\n\n")]),
      .init(chunks: [.init("data: [DONE]\n\n")])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let currentProfile = try profile(baseURL)

    let customPrompt = "Return a concise evidence table using only captured content."
    _ = await collect(
      provider: makeProvider(),
      profile: currentProfile,
      apiKey: key,
      intent: .summarize(
        title: "Fixture title",
        text: "Fixture body",
        prompt: customPrompt
      )
    )
    _ = await collect(
      provider: makeProvider(),
      profile: currentProfile,
      apiKey: key,
      intent: .translate(
        title: "Fixture title",
        text: "Fixture body",
        targetLanguage: "简体中文"
      )
    )

    XCTAssertEqual(server.requests.count, 2)
    let summarizeMessages = try messages(from: server.requests[0].body)
    XCTAssertEqual(summarizeMessages.map { $0["role"] }, ["system", "user"])
    XCTAssertEqual(summarizeMessages[0]["content"], customPrompt)
    XCTAssertTrue(summarizeMessages[1]["content"]?.contains("Fixture title") == true)
    XCTAssertTrue(summarizeMessages[1]["content"]?.contains("Fixture body") == true)
    XCTAssertFalse(summarizeMessages.description.contains("https://example.test/article"))

    let translateMessages = try messages(from: server.requests[1].body)
    XCTAssertTrue(translateMessages[0]["content"]?.contains("简体中文") == true)
    XCTAssertTrue(translateMessages[1]["content"]?.contains("Fixture title") == true)
    XCTAssertTrue(translateMessages[1]["content"]?.contains("Fixture body") == true)
    XCTAssertFalse(server.requests.description.contains(key))
  }

  func test401IsNotRetriedAndFailureDoesNotExposeSecret() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(statusCode: 401)
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(server.attemptCount, 1)
    XCTAssertEqual(result.failure?.code, .authInvalid)
    XCTAssertFalse(String(describing: result.failure).contains(key))
    XCTAssertFalse(server.requests.description.contains(key))
  }

  func test404And413MapToStableNonRetryableFailures() async throws {
    for (statusCode, expectedCode) in [
      (404, ModelProviderErrorCode.endpointNotFound),
      (413, ModelProviderErrorCode.inputTooLarge)
    ] {
      let key = "sentinel-\(UUID().uuidString)"
      let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
        .init(statusCode: statusCode)
      ])
      let baseURL = try server.start()

      let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

      server.stop()
      XCTAssertEqual(server.attemptCount, 1)
      XCTAssertEqual(result.failure?.code, expectedCode)
      XCTAssertEqual(result.failure?.retryable, false)
    }
  }

  func test429And5xxRetryAtMostTwiceBeforeAnyDelta() async throws {
    for statusCode in [429, 503] {
      let key = "sentinel-\(UUID().uuidString)"
      let sleeper = RecordingRetrySleeper()
      let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
        .init(statusCode: statusCode, headers: ["Retry-After": "99"]),
        .init(statusCode: statusCode),
        .init(statusCode: statusCode)
      ])
      let baseURL = try server.start()

      let result = await collect(
        provider: makeProvider(sleeper: sleeper),
        profile: try profile(baseURL),
        apiKey: key
      )

      server.stop()
      XCTAssertEqual(server.attemptCount, 3)
      XCTAssertEqual(result.failure?.code, statusCode == 429 ? .rateLimited : .providerUnavailable)
      let delays = await sleeper.delays
      XCTAssertEqual(delays.count, 2)
      XCTAssertEqual(delays.first, 10)
    }
  }

  func testInterruptionAfterDeltaIsMarkedAndNotRetried() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(
        chunks: [.init("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")],
        closesAbruptly: true
      )
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(result.events, [.delta("partial")])
    XCTAssertEqual(result.failure?.code, .networkInterrupted)
    XCTAssertEqual(result.failure?.hadOutput, true)
    XCTAssertEqual(server.attemptCount, 1)
  }

  func testMalformedStreamAndWrongContentTypeMapToStableFailures() async throws {
    let malformedKey = "sentinel-\(UUID().uuidString)"
    let malformedServer = FakeOpenAICompatibleServer(expectedAPIKey: malformedKey, scripts: [
      .init(chunks: [.init("data: {not-json}\n\n")])
    ])
    let malformedURL = try malformedServer.start()
    let malformed = await collect(
      provider: makeProvider(),
      profile: try profile(malformedURL),
      apiKey: malformedKey
    )
    malformedServer.stop()
    XCTAssertEqual(malformed.failure?.code, .streamMalformed)

    let protocolKey = "sentinel-\(UUID().uuidString)"
    let protocolServer = FakeOpenAICompatibleServer(expectedAPIKey: protocolKey, scripts: [
      .init(contentType: "application/json", chunks: [.init("{}")])
    ])
    let protocolURL = try protocolServer.start()
    let incompatible = await collect(
      provider: makeProvider(),
      profile: try profile(protocolURL),
      apiKey: protocolKey
    )
    protocolServer.stop()
    XCTAssertEqual(incompatible.failure?.code, .protocolIncompatible)
  }

  func testProviderClassifies4xxWithoutForwardingResponseBodies() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let bodyMarker = "provider-body-marker-\(UUID().uuidString)"
    let longDetail = "\(bodyMarker) " + String(repeating: "x", count: 260)
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(
        statusCode: 402,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"inference prohibited \#(bodyMarker)"}}"#)]
      ),
      .init(
        statusCode: 402,
        contentType: "application/json",
        chunks: [.init(#"{"error":{"message":"billing quota exhausted \#(bodyMarker)","code":"billing_hard_limit"}}"#)]
      ),
      .init(
        statusCode: 404,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"\#(bodyMarker)","code":"model_not_found"}}"#)]
      ),
      .init(
        statusCode: 404,
        contentType: "application/json",
        chunks: [.init(#"{"error":{"message":"\#(bodyMarker)","code":"invalid_endpoint"}}"#)]
      ),
      .init(
        statusCode: 404,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"model not found \#(bodyMarker)"}}"#)]
      ),
      .init(
        statusCode: 422,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"\#(bodyMarker)"}}"#)]
      ),
      .init(statusCode: 400, contentType: "application/json"),
      .init(
        statusCode: 400,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"\#(longDetail)"}}"#)]
      ),
      .init(
        statusCode: 400,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"Authorization: Bearer \#(bodyMarker)"}}"#)]
      ),
      .init(
        statusCode: 400,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"Set-Cookie: session=\#(bodyMarker)"}}"#)]
      ),
      .init(
        statusCode: 400,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"X-Provider-Trace: \#(bodyMarker)"}}"#)]
      )
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let currentProfile = try profile(baseURL)

    let deepInfra402 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(deepInfra402.failure?.code, .providerBillingLimited)
    XCTAssertFalse(String(describing: deepInfra402.failure).contains(bodyMarker))

    let openAI402 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(openAI402.failure?.code, .providerBillingLimited)
    XCTAssertFalse(String(describing: openAI402.failure).contains(bodyMarker))

    let missingModel = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(missingModel.failure?.code, .modelNotFound)
    XCTAssertFalse(String(describing: missingModel.failure).contains(bodyMarker))

    let missingEndpoint = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(missingEndpoint.failure?.code, .endpointNotFound)
    XCTAssertFalse(String(describing: missingEndpoint.failure).contains(bodyMarker))

    let messageOnly404 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(messageOnly404.failure?.code, .endpointNotFound)
    XCTAssertFalse(String(describing: messageOnly404.failure).contains(bodyMarker))

    let rejected422 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(rejected422.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: rejected422.failure).contains(bodyMarker))

    let empty400 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(empty400.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: empty400.failure).contains(bodyMarker))

    let truncated400 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(truncated400.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: truncated400.failure).contains(bodyMarker))

    let sensitive400 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(sensitive400.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: sensitive400.failure).contains(bodyMarker))

    let header400 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(header400.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: header400.failure).contains(bodyMarker))

    let trace400 = await collect(provider: provider, profile: currentProfile, apiKey: key)
    XCTAssertEqual(trace400.failure?.code, .providerRequestRejected)
    XCTAssertFalse(String(describing: trace400.failure).contains(bodyMarker))
  }

  func testProviderBodiesNeverReachFailures() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let leakedValue = "leak-marker-\(UUID().uuidString)"
    let unsafeSummaries = [
      "ordinary text\nKey: \(leakedValue)",
      "key=\(leakedValue)",
      "secret=\(leakedValue)",
      "token=\(leakedValue)",
      "password=\(leakedValue)",
      "https://user:\(leakedValue)@provider.example.test/help",
      "https://\(leakedValue)@provider.example.test/help",
      "https://provider.example.test/help?key=\(leakedValue)",
      "access_token=\(leakedValue)",
      "client_secret: \(leakedValue)",
      "privateKey=\(leakedValue)",
      "accessKey=\(leakedValue)",
      "refreshToken=\(leakedValue)",
      #"{"client_secret":"\#(leakedValue)"}"#,
      "ordinary https://user:\n\(leakedValue)@host.test/help",
      "X_API_KEY=\(leakedValue)",
      "api-key=\(leakedValue)",
      "sessionToken=\(leakedValue)",
      "Bearer \(leakedValue)",
      "pwd=\(leakedValue)",
      "Base64: \(leakedValue)",
      "sk-proj-\(leakedValue)"
    ]
    let scripts: [FakeOpenAICompatibleServer.ResponseScript] = try unsafeSummaries.map { summary in
      let body = try JSONSerialization.data(withJSONObject: ["detail": ["error": summary]])
      return .init(
        statusCode: 422,
        contentType: "application/json",
        chunks: [.init(String(decoding: body, as: UTF8.self))]
      )
    }
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: scripts)
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let currentProfile = try profile(baseURL)

    for summary in unsafeSummaries {
      let result = await collect(provider: provider, profile: currentProfile, apiKey: key)
      XCTAssertEqual(result.failure?.code, .providerRequestRejected, summary)
      XCTAssertFalse(String(describing: result.failure).contains(leakedValue), summary)
    }
  }

  func test5xxResponseBodiesNeverReachFailures() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let bodyMarker = "provider-body-marker-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: Array(repeating:
      .init(
        statusCode: 503,
        contentType: "application/json",
        chunks: [.init(#"{"detail":{"error":"\#(bodyMarker)"}}"#)]
      ),
      count: 3
    ))
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(result.failure?.code, .providerUnavailable)
    XCTAssertEqual(server.attemptCount, 3)
    XCTAssertFalse(String(describing: result.failure).contains(bodyMarker))
  }

  func testExplicitCancellationStopsURLSessionBeforeLaterDelta() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n"),
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n", delay: 0.5),
        .init("data: [DONE]\n\n")
      ])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let currentProfile = try profile(baseURL)
    let firstDelta = expectation(description: "first delta")
    let recorder = EventRecorder()

    let consumer = Task {
      do {
        for try await event in provider.stream(
          profile: currentProfile,
          apiKey: key,
          intent: .connectionTest
        ) {
          await recorder.append(event)
          if event == .delta("first") {
            firstDelta.fulfill()
          }
        }
      } catch {
        // Cancellation is the expected terminal path.
      }
    }
    await fulfillment(of: [firstDelta], timeout: 2)
    let cancellationStartedAt = ContinuousClock.now
    provider.cancelActiveStreams()
    _ = await consumer.result
    let cancellationElapsed = ContinuousClock.now - cancellationStartedAt
    try await Task.sleep(for: .milliseconds(650))

    let events = await recorder.events
    XCTAssertLessThan(cancellationElapsed, .milliseconds(500))
    XCTAssertEqual(events, [.delta("first")])
    XCTAssertEqual(server.attemptCount, 1)
    XCTAssertEqual(provider.activeStreamCount, 0)
  }

  private func profile(_ serverURL: URL) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: serverURL.appending(path: "api/v1").absoluteString,
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "test-reference"),
      allowLoopbackHTTP: true
    )
  }

  private func makeProvider(
    sleeper: any RetrySleeper = RecordingRetrySleeper()
  ) -> OpenAICompatibleProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    return OpenAICompatibleProvider(
      session: URLSession(configuration: configuration),
      sleeper: sleeper,
      maximumRetryCount: 2,
      defaultBackoff: 0
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
      for try await event in provider.stream(
        profile: profile,
        apiKey: apiKey,
        intent: intent
      ) {
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

  private func messages(from body: String) throws -> [[String: String]] {
    let data = try XCTUnwrap(body.data(using: .utf8))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(object["messages"] as? [[String: String]])
  }
}

private actor RecordingRetrySleeper: RetrySleeper {
  private(set) var delays: [TimeInterval] = []

  func sleep(for seconds: TimeInterval) async throws {
    delays.append(seconds)
  }
}

private actor EventRecorder {
  private(set) var events: [ModelStreamEvent] = []

  func append(_ event: ModelStreamEvent) {
    events.append(event)
  }
}
