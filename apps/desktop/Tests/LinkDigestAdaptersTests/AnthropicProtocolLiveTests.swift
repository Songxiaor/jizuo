import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 协议选了 Anthropic 时，对着本机 Magpie 的 `/v1/messages` 真发一次（2026-10-09）。
/// 默认跳过；要跑设 `LINKDIGEST_LIVE_MAGPIE=1`，并确保 Magpie 在 127.0.0.1:3425。
final class AnthropicProtocolLiveTests: XCTestCase {
  private func profile(_ baseURL: String) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: baseURL,
      model: "anthropic/claude-haiku-5-5",
      apiMode: .anthropicMessages,
      secretReference: SecretReference(rawValue: "live"),
      allowLoopbackHTTP: true
    )
  }

  /// Magpie 预设读到的模型信息：两种协议都能读，Claude 带上下文和来源（2026-10-09）。
  func testMagpieCatalogCarriesModelDetails() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_MAGPIE"] == "1")
    let provider = OpenAICompatibleProvider()
    for mode in [APIMode.chatCompletions, .anthropicMessages] {
      let entries = try await provider.listModelEntries(
        baseURL: URL(string: "http://127.0.0.1:3425/v1")!, apiKey: "magpie-local", apiMode: mode)
      let haiku = try XCTUnwrap(entries.first { $0.id == "anthropic/claude-haiku-5-5" })
      print("LIVE \(mode.rawValue): \(entries.count) models; haiku=\(haiku)")
      XCTAssertNotNil(haiku.contextWindow)
      XCTAssertEqual(haiku.sourceLabel, "Anthropic")
    }
  }

  func testTranslatesThroughMagpieMessagesEndpoint() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_MAGPIE"] == "1")
    let provider = OpenAICompatibleProvider()
    let models = try await provider.listModels(
      baseURL: URL(string: "http://127.0.0.1:3425/v1")!, apiKey: "magpie", apiMode: .anthropicMessages)
    XCTAssertTrue(models.contains("anthropic/claude-haiku-5-5"), "模型列表：\(models.prefix(5))")

    // 不带 /v1 的写法也要通。
    for base in ["http://127.0.0.1:3425/v1", "http://127.0.0.1:3425"] {
      var text = ""
      var completed = false
      for try await event in provider.stream(
        profile: try profile(base), apiKey: "magpie",
        intent: .translate(title: nil, text: "The quick brown fox jumps over the lazy dog.", targetLanguage: "简体中文")
      ) {
        switch event {
        case let .delta(chunk): text += chunk
        case .completed: completed = true
        default: break
        }
      }
      print("LIVE \(base): \(text)")
      XCTAssertTrue(completed)
      XCTAssertTrue(text.contains("狐狸"), text)
    }
  }
}
