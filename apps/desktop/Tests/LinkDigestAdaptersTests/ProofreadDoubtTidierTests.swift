import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 校对请求附带名字表、同一次调用里带回存疑清单（不新增模型调用）。
final class ProofreadDoubtTidierTests: XCTestCase {
  private let transcript = "今天张总讲了奥利克的新方案，大家觉得很有意思，后面还有一段很长的内容需要慢慢听。"

  override func setUp() {
    super.setUp()
    OpenAICompatibleTranscriptTidier.chunkRetryBaseDelaySeconds = 0
    OpenAICompatibleTranscriptTidier.diagnosticsLogURL = nil
  }

  override func tearDown() {
    OpenAICompatibleTranscriptTidier.chunkRetryBaseDelaySeconds = 3
    super.tearDown()
  }

  private func makeTidier(baseURL: URL, apiKey: String) async throws -> OpenAICompatibleTranscriptTidier {
    let profileStore = TidyProfileStore()
    let secretStore = TidySecretStore()
    let reference = SecretReference(rawValue: "doubt-reference")
    try await profileStore.save(try ProviderProfile(
      baseURL: baseURL.appending(path: "v1").absoluteString, model: "fixture-model",
      secretReference: reference, allowLoopbackHTTP: true
    ))
    try await secretStore.save(apiKey, for: reference)
    return OpenAICompatibleTranscriptTidier(
      configurationService: ProviderConfigurationService(profileStore: profileStore, secretStore: secretStore)
    )
  }

  private func response(content: String) throws -> FakeOpenAICompatibleServer.ResponseScript {
    let payload: [String: Any] = [
      "choices": [["message": ["content": content]]],
      "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return .init(contentType: "application/json", chunks: [.init(String(decoding: data, as: UTF8.self))])
  }

  func testRequestCarriesNameTableAndDoubtsAreVerified() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let json = #"[{"original":"奥利克","suggestion":"欧立克","reason":"像品牌名"},{"original":"稿子里根本没有","suggestion":"随便","reason":"编的"}]"#
    let script = try response(content: transcript + "\n" + TranscriptDoubtParser.marker + "\n" + json)
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [script])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(
      text: transcript, model: nil, style: .transcript,
      context: TranscriptTidyContext(title: "访谈", knownNames: ["张总", "欧立克"]), phase: nil
    )

    XCTAssertEqual(server.attemptCount, 1, "存疑清单在同一次调用里，不新增模型调用")
    let body = try XCTUnwrap(server.requests.first?.body)
    XCTAssertTrue(body.contains("常用名字"), "请求要带名字表")
    XCTAssertTrue(body.contains("欧立克") && body.contains("张总"))
    XCTAssertEqual(outcome.text, transcript, "存疑标记之后的内容不进正文")
    XCTAssertEqual(outcome.doubts.map(\.original), ["奥利克"], "找不到的片段被丢掉")
    XCTAssertEqual(outcome.doubts.first?.suggestion, "欧立克")
  }

  func testNoNameTableMeansNoNameLine() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let script = try response(content: transcript)
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [script])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)
    let outcome = try await tidier.tidy(text: transcript, model: nil, style: .transcript, context: TranscriptTidyContext(title: "访谈"), phase: nil)
    let body = try XCTUnwrap(server.requests.first?.body)
    XCTAssertFalse(body.contains("常用名字："), "空表不多发那一行")
    XCTAssertTrue(outcome.doubts.isEmpty)
  }
}

private actor TidyProfileStore: ProviderProfileStore {
  private var value: ProviderProfile?
  func load() async throws -> ProviderProfile? { value }
  func save(_ profile: ProviderProfile) async throws { value = profile }
  func delete() async throws { value = nil }
}

private actor TidySecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  func save(_ secret: String, for reference: SecretReference) async throws { values[reference] = secret }
  func read(_ reference: SecretReference) async throws -> String? { values[reference] }
  func contains(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
  func delete(_ reference: SecretReference) async throws { values.removeValue(forKey: reference) }
}
