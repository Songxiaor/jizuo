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
    // 总结与翻译要的是转述不是推理。不发这个参数时，推理模型会拿七成的输出
    // token 去想，用户只能干等——这条钉住它确实发出去了。
    XCTAssertEqual(body["reasoning_effort"] as? String, "none")
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
    let translateSystem = try XCTUnwrap(translateMessages[0]["content"])
    XCTAssertTrue(translateSystem.contains("简体中文"))
    XCTAssertTrue(translateSystem.contains("one-way into 简体中文, never a language swap"))
    XCTAssertTrue(translateSystem.contains("If a sentence is already in 简体中文, copy it unchanged."))
    XCTAssertTrue(translateSystem.contains("Never translate 简体中文 into English or any other language."))
    XCTAssertTrue(translateSystem.contains("Do not output labels such as Captured title"))
    XCTAssertTrue(translateMessages[1]["content"]?.contains("Fixture body") == true)
    XCTAssertFalse(translateMessages[1]["content"]?.contains("Captured content") == true)
    XCTAssertTrue(translateSystem.contains("Fixture title"))
    XCTAssertFalse(server.requests.description.contains(key))
  }

  func testTranslationPromptProtectsCommentTreeMetadata() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [.init("data: [DONE]\n\n")])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let source = """
    ## 评论（当前页面已加载 2 / 页面显示 2）

    - **u/root** · score 5 · 2026-08-13T00:00:00Z · [原评论](https://www.reddit.com/comments/root/)
      Root comment.
      - **u/reply** · score 2 · 回复层级 1
        Reply body.
    """

    _ = await collect(
      provider: makeProvider(),
      profile: try profile(baseURL),
      apiKey: key,
      intent: .translate(title: "Reddit fixture", text: source, targetLanguage: "简体中文")
    )

    let request = try XCTUnwrap(server.requests.first)
    let translationMessages = try messages(from: request.body)
    let systemPrompt = try XCTUnwrap(translationMessages.first?["content"])
    XCTAssertTrue(systemPrompt.contains("one-way into 简体中文, never a language swap"))
    XCTAssertTrue(systemPrompt.contains("Preserve Markdown syntax and indentation exactly"))
    XCTAssertTrue(systemPrompt.contains("Copy unchanged every section heading beginning with `## 评论（`"))
    XCTAssertTrue(systemPrompt.contains("Copy unchanged every comment metadata line beginning with `- **`"))
    XCTAssertTrue(systemPrompt.contains("Translate only the prose body of each comment into 简体中文"))
    XCTAssertTrue(systemPrompt.contains("Never translate usernames or change comment nesting"))
    let userPrompt = try XCTUnwrap(translationMessages.last?["content"])
    XCTAssertTrue(userPrompt.contains("## 评论（当前页面已加载 2 / 页面显示 2）"))
    XCTAssertTrue(userPrompt.contains("  - **u/reply** · score 2 · 回复层级 1"))
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

  /// 状态码不是唯一依据：服务端说是余额问题时以它为准。
  ///
  /// 真实案例（2026-08-06）：opencode Zen 余额不足返回的是 **HTTP 401**，正文
  /// `{"error":{"type":"CreditsError",…}}`。只按状态码归类会显示「请更新 API Key」，
  /// 于是用户反复换 Key——而真正要做的是充值。这条断言守住「结构化错误类型
  /// 优先于状态码」。
  func test401WithCreditsErrorBodyIsBillingNotAuthFailure() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(
        statusCode: 401,
        contentType: "application/json",
        chunks: [.init(#"{"type":"error","error":{"type":"CreditsError","message":"余额不足。"}}"#)]
      )
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(result.failure?.code, .providerBillingLimited)
    XCTAssertEqual(result.failure?.retryable, false)
    // 正文里的原话不该跟着失败对象跑出来。
    XCTAssertFalse(String(describing: result.failure).contains("余额不足"))
  }

  func test403And404And413MapToStableNonRetryableFailures() async throws {
    for (statusCode, expectedCode) in [
      // 403 与 401 分开：Key 有效但没有该模型的权限，换 Key 修不了。
      (403, ModelProviderErrorCode.authForbidden),
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

/// 推理模型的思考过程。
///
/// 实测 `step-3.7-flash` 一次 13,402 字符的英译中输出 15,249 token，落到译文里的
/// 只有 5,982 字符——约七成 token 是思考。它必须被识别、被丢弃，且绝不能混进产物。
final class ReasoningStreamDecodingTests: XCTestCase {
  func testReasoningContentIsDecodedAsItsOwnEvent() throws {
    let decoder = ChatCompletionsStreamDecoder()
    // DeepSeek 起头、StepFun 跟进的兼容字段名。
    XCTAssertEqual(
      try decoder.decode(line: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"让我想想\"}}]}"),
      .reasoning("让我想想")
    )
    // StepFun 默认 reasoning_format=general 时用的字段名。
    XCTAssertEqual(
      try decoder.decode(line: "data: {\"choices\":[{\"delta\":{\"reasoning\":\"再想想\"}}]}"),
      .reasoning("再想想")
    )
  }

  /// 正文永远优先：同一个 chunk 里两者都有时，思考不能挤掉真正的输出。
  func testContentWinsWhenAChunkCarriesBoth() throws {
    XCTAssertEqual(
      try ChatCompletionsStreamDecoder().decode(
        line: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\",\"content\":\"译文\"}}]}"
      ),
      .delta("译文")
    )
  }

  /// 普通模型不发这两个字段，行为必须一个字都不变。
  func testOrdinaryDeltaIsUnaffected() throws {
    XCTAssertEqual(
      try ChatCompletionsStreamDecoder().decode(line: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"),
      .delta("hello")
    )
  }
}

/// 思考过程绝不能被当成生成结果。
final class ReasoningIsNeverOutputTests: XCTestCase {
  /// 这是最关键的一条：`.thinking` 状态的 `outputText` 必须是空的。
  /// 一旦它返回思考内容，那段文字就会被当成译文写进产物。
  func testThinkingStateCarriesNoOutputText() {
    XCTAssertEqual(RunState.thinking(intent: .translate).outputText, "")
    XCTAssertEqual(RunState.thinking(intent: .summarize).outputText, "")
  }

  /// 思考期间这次运行仍然是「进行中」，停止按钮等一切照常可用。
  func testThinkingCountsAsActive() {
    XCTAssertTrue(RunState.thinking(intent: .translate).isActive)
  }
}

/// `reasoning_effort` 被拒后的记忆。
///
/// 降级本身每次请求各自完成，但记忆必须跨请求：长文翻译会把正文切成多片、每片
/// 各发一次请求。若每片都重新试一遍这个参数，一个不接受它的服务商会让 9 片变成
/// 9 次「被拒」+ 9 次「重发」——一半请求纯属浪费，每次还要等一个完整往返。
final class ReasoningEffortRejectionMemoryTests: XCTestCase {
  /// 同一目的地的第二次请求必须不再带这个参数。
  func testSecondRequestToSameDestinationSkipsTheRejectedParameter() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    // 第 1 次：400 拒绝（模拟不认识该参数）。第 2 次起：正常返回。
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(statusCode: 400, contentType: "application/json"),
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"),
        .init("data: [DONE]\n\n"),
      ]),
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"),
        .init("data: [DONE]\n\n"),
      ]),
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let profile = try profile(baseURL)

    // 第一轮：none 被拒 → 降到 low 成功。共 2 个请求。
    _ = await collect(provider: provider, profile: profile, apiKey: key)
    XCTAssertEqual(server.requests.count, 2, "首轮应为 none 被拒 + low 重发")
    XCTAssertEqual(reasoningEffort(in: server.requests[0]), "none")
    XCTAssertEqual(reasoningEffort(in: server.requests[1]), "low")

    // 第二轮（下一个分片）：记住 none 被拒，直接从 low 起，只发一次。
    _ = await collect(provider: provider, profile: profile, apiKey: key)
    XCTAssertEqual(server.requests.count, 3, "记住拒绝后，第二轮只应发 1 个请求")
    XCTAssertEqual(reasoningEffort(in: server.requests[2]), "low")
  }

  func testLowThenOmittedIsRememberedAcrossRequests() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(statusCode: 400, contentType: "application/json"),
      .init(statusCode: 400, contentType: "application/json"),
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"),
        .init("data: [DONE]\n\n"),
      ]),
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"),
        .init("data: [DONE]\n\n"),
      ]),
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let profile = try profile(baseURL)

    _ = await collect(provider: provider, profile: profile, apiKey: key)
    XCTAssertEqual(server.requests.count, 3)
    XCTAssertEqual(reasoningEffort(in: server.requests[0]), "none")
    XCTAssertEqual(reasoningEffort(in: server.requests[1]), "low")
    XCTAssertNil(reasoningEffort(in: server.requests[2]))

    _ = await collect(provider: provider, profile: profile, apiKey: key)
    XCTAssertEqual(server.requests.count, 4)
    XCTAssertNil(reasoningEffort(in: server.requests[3]))
  }

  func testThinkingStallRetriesWithoutThinking() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}\n\n"),
        .init("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"还在想\"}}]}\n\n", delay: 0.4),
      ]),
      .init(chunks: [
        .init("data: {\"choices\":[{\"delta\":{\"content\":\"正文\"}}]}\n\n"),
        .init("data: [DONE]\n\n"),
      ]),
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    provider.thinkingStallRetryThreshold = 0.15
    provider.testingPreferredReasoningEffort = .low
    let profile = try profile(baseURL)

    let failure = await collect(provider: provider, profile: profile, apiKey: key)
    XCTAssertNil(failure)
    XCTAssertEqual(server.requests.count, 2)
    XCTAssertEqual(reasoningEffort(in: server.requests[0]), "low")
    XCTAssertEqual(reasoningEffort(in: server.requests[1]), "none")
  }

  /// 记忆按目的地隔离：换了模型要重新试，否则一次偶发拒绝会永久关掉这个提速。
  func testRejectionMemoryIsScopedToDestination() throws {
    let a = try ProviderProfile(
      baseURL: "https://example.com/v1",
      model: "model-a",
      secretReference: SecretReference(rawValue: "ref")
    )
    let b = try ProviderProfile(
      baseURL: "https://example.com/v1",
      model: "model-b",
      secretReference: SecretReference(rawValue: "ref")
    )
    XCTAssertNotEqual(
      OpenAICompatibleProvider.reasoningEffortDestinationKey(a),
      OpenAICompatibleProvider.reasoningEffortDestinationKey(b)
    )
  }

  private func profile(_ serverURL: URL) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: serverURL.appending(path: "api/v1").absoluteString,
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "test-reference"),
      allowLoopbackHTTP: true
    )
  }

  private func makeProvider() -> OpenAICompatibleProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    return OpenAICompatibleProvider(
      session: URLSession(configuration: configuration),
      sleeper: RecordingRetrySleeper(),
      maximumRetryCount: 0,
      defaultBackoff: 0
    )
  }

  private func collect(
    provider: OpenAICompatibleProvider,
    profile: ProviderProfile,
    apiKey: String
  ) async -> ModelProviderFailure? {
    do {
      for try await _ in provider.stream(profile: profile, apiKey: apiKey, intent: .connectionTest) {}
      return nil
    } catch let failure as ModelProviderFailure {
      return failure
    } catch {
      return nil
    }
  }

  /// 校对/整理走的是**非流式**那条路，它一样要带 `reasoning_effort`。
  ///
  /// 漏掉时不是「慢一点」：实测同一条 105 分钟视频的字幕校对，19 片跑了 14 分 23 秒，
  /// 其中 5 片撞满 180 秒超时被判失败——失败的恰好是乱码最密、最需要校对的那几片。
  /// 流式那边早就在传，只有这条漏着，而且它连诊断日志都不写，慢了都查不出来。
  func testNonStreamingCompletionCarriesReasoningEffortAndStepsDownWhenRejected() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let ok = FakeOpenAICompatibleServer.ResponseScript(
      contentType: "application/json",
      chunks: [.init("{\"choices\":[{\"message\":{\"content\":\"校对后的文字\"}}]}")]
    )
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(statusCode: 400, contentType: "application/json"),
      ok,
      ok,
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = makeProvider()
    let profile = try profile(baseURL)

    // 第一次：none 被拒 → 降到 low 重发并成功。
    let first = try await provider.tidyTranscriptChunk(
      profile: profile, apiKey: key, model: "fixture-model", text: "待校对"
    )
    XCTAssertEqual(first.text, "校对后的文字")
    XCTAssertEqual(server.requests.count, 2, "首轮应为 none 被拒 + low 重发")
    XCTAssertEqual(reasoningEffort(in: server.requests[0]), "none")
    XCTAssertEqual(reasoningEffort(in: server.requests[1]), "low")

    // 第二片：记忆跨请求，直接从 low 起，只发一次。校对会把长稿切十几片，
    // 每片都重试一遍等于把一半请求浪费在同一个已知答案上。
    _ = try await provider.tidyTranscriptChunk(
      profile: profile, apiKey: key, model: "fixture-model", text: "第二片"
    )
    XCTAssertEqual(server.requests.count, 3, "记住拒绝后，第二片只应发 1 个请求")
    XCTAssertEqual(reasoningEffort(in: server.requests[2]), "low")
  }

  private func bodyHasReasoningEffort(_ request: FakeOpenAICompatibleServer.RecordedRequest) -> Bool {
    reasoningEffort(in: request) != nil
  }

  private func reasoningEffort(in request: FakeOpenAICompatibleServer.RecordedRequest) -> String? {
    guard let data = request.body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["reasoning_effort"] as? String
  }
}
