import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class OpenAICompatibleProviderTests: XCTestCase {
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
        .init("data: [DONE]\n\n")
      ])
    ])
    let baseURL = try server.start()
    defer { server.stop() }

    let result = await collect(provider: makeProvider(), profile: try profile(baseURL), apiKey: key)

    XCTAssertEqual(result.events, [.delta("Hel"), .delta("lo"), .completed])
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

  func testSummarizeAndTranslatePromptsContainOnlyTitleBodyAndRequestedLanguage() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(chunks: [.init("data: [DONE]\n\n")]),
      .init(chunks: [.init("data: [DONE]\n\n")])
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let currentProfile = try profile(baseURL)

    _ = await collect(
      provider: makeProvider(),
      profile: currentProfile,
      apiKey: key,
      intent: .summarize(title: "Fixture title", text: "Fixture body")
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
    XCTAssertTrue(summarizeMessages[0]["content"]?.contains("do not invent facts") == true)
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
