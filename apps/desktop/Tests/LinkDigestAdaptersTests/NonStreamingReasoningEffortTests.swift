import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestAdapters

/// 非流式请求（整理文稿、脑图）也必须请求最低推理档。
///
/// 这条路径此前漏了 `reasoning_effort`，而流式的总结/翻译带着。代价是实打实的：
/// 2026-08-19 一次真实的转写整理，输入 953 token、输出 **10419** token——绝大部分
/// 是用户看不见的思考，随后撞满 180 秒超时，那一片以原文回填，界面上表现为
/// 「整理完看着跟没整理一样」。
///
/// 同一个坑这个项目踩过第二次了（第一次是总结变慢 30 秒），所以钉死。
final class NonStreamingReasoningEffortTests: XCTestCase {
  private func profile(_ serverURL: URL) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: serverURL.appending(path: "api/v1").absoluteString,
      model: "fixture-model",
      secretReference: SecretReference(rawValue: "test-reference"),
      allowLoopbackHTTP: true
    )
  }

  private func completionScript() -> FakeOpenAICompatibleServer.ResponseScript {
    .init(
      statusCode: 200,
      contentType: "application/json",
      chunks: [.init(#"{"choices":[{"message":{"content":"整理后的文字"}}],"usage":{"prompt_tokens":10,"completion_tokens":12,"total_tokens":22}}"#)]
    )
  }

  private func body(_ request: FakeOpenAICompatibleServer.RecordedRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.body.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testTidyChunkRequestsLowReasoningEffort() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [completionScript()])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = OpenAICompatibleProvider()

    let outcome = try await provider.tidyTranscriptChunk(
      profile: try profile(baseURL), apiKey: key, model: "fixture-model", text: "一段转写文字"
    )
    XCTAssertEqual(outcome.text, "整理后的文字")
    XCTAssertEqual(server.requests.count, 1)
    let sent = try body(server.requests[0])
    XCTAssertEqual(sent["reasoning_effort"] as? String, "none", "整理是转述不是推理，必须请求最低档")
    // 校对改走流式（2026-10-04）：非流式的长请求被服务商网关在 15–125 秒间掐断，流式边收边算活着。
    // 服务端只回整段 JSON 时照样能收（上面 outcome.text 就是这样拿到的）。
    XCTAssertEqual(sent["stream"] as? Bool, true)
    // 只发 reasoning_effort 时实测仍有约六成 token 是思考：两种常见的关闭写法一起带上。
    XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    XCTAssertEqual(sent["enable_thinking"] as? Bool, false)
  }

  /// 服务端报了思考 token 就带回来，诊断日志靠它比较模型。
  func testReasoningTokensAreReportedWhenTheServerSendsThem() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let script = FakeOpenAICompatibleServer.ResponseScript(
      statusCode: 200,
      contentType: "application/json",
      chunks: [.init(#"{"choices":[{"message":{"content":"整理后的文字"}}],"usage":{"prompt_tokens":10,"completion_tokens":40,"total_tokens":50,"completion_tokens_details":{"reasoning_tokens":28}}}"#)]
    )
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [script])
    let baseURL = try server.start()
    defer { server.stop() }
    let outcome = try await OpenAICompatibleProvider().tidyTranscriptChunk(
      profile: try profile(baseURL), apiKey: key, model: "fixture-model", text: "一段转写文字"
    )
    XCTAssertEqual(outcome.reasoningTokens, 28)
    XCTAssertEqual(outcome.requestNote, "effort=none thinkingOff=1 stream=1")
  }

  /// 服务端不认这个参数时去掉重发一次，并记住这个目的地——和流式路径同一套规则。
  /// 不记住的话，长稿每一片都要白白多打一个往返。
  func testRejectedParameterIsDroppedAndRemembered() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [
      .init(statusCode: 400, contentType: "application/json"),
      .init(statusCode: 400, contentType: "application/json"),
      completionScript(),
      completionScript(),
    ])
    let baseURL = try server.start()
    defer { server.stop() }
    let provider = OpenAICompatibleProvider()
    let profile = try profile(baseURL)

    _ = try await provider.tidyTranscriptChunk(
      profile: profile, apiKey: key, model: "fixture-model", text: "第一片"
    )
    XCTAssertEqual(server.requests.count, 3, "先去掉关闭思考开关，再把 none 降到 low")
    XCTAssertNotNil(try body(server.requests[0])["thinking"])
    XCTAssertNil(try body(server.requests[1])["thinking"], "开关被拒就不再带")
    XCTAssertEqual(try body(server.requests[1])["reasoning_effort"] as? String, "none")
    XCTAssertEqual(try body(server.requests[2])["reasoning_effort"] as? String, "low")
    XCTAssertNil(try body(server.requests[2])["thinking"])

    _ = try await provider.tidyTranscriptChunk(
      profile: profile, apiKey: key, model: "fixture-model", text: "第二片"
    )
    XCTAssertEqual(server.requests.count, 4, "记住拒绝后，第二片只应发 1 个请求")
    XCTAssertEqual(
      try body(server.requests[3])["reasoning_effort"] as? String, "low",
      "已知拒绝的档位不该再试——那正是每片浪费一个往返的来源"
    )
    XCTAssertNil(try body(server.requests[3])["thinking"], "已知不认开关的目的地不再带开关")
  }
}
