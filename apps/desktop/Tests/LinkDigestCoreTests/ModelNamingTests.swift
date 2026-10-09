import XCTest
@testable import LinkDigestCore

/// 模型名统一成「模型名 · 厂商」，渠道只拿来分组（2026-10-09 Syc）。
final class ModelNamingTests: XCTestCase {
  private let magpie = "http://127.0.0.1:3425/v1"

  func testMagpieModelsSplitChannelFromVendor() {
    let viaClaudeCode = ModelNaming.label(baseURL: magpie, model: "claude/claude-haiku-5-5")
    XCTAssertEqual(viaClaudeCode.title, "Claude Haiku 5.5 · Anthropic")
    XCTAssertEqual(viaClaudeCode.channel, "Magpie · Claude Code")
    XCTAssertEqual(viaClaudeCode.titleWithChannel, "Claude Haiku 5.5 · Anthropic（Magpie · Claude Code）")

    let viaAPI = ModelNaming.label(baseURL: magpie, model: "anthropic/claude-haiku-5-5")
    XCTAssertEqual(viaAPI.title, viaClaudeCode.title, "同一个模型，名字一样")
    XCTAssertEqual(viaAPI.channel, "Magpie · Anthropic", "渠道不同，靠渠道区分")

    let grok = ModelNaming.label(baseURL: magpie, model: "cursor/grok-4.7-fast")
    XCTAssertEqual(grok.title, "Grok 4.7 Fast · xAI")
    XCTAssertEqual(grok.channel, "Magpie · Cursor")
  }

  func testServiceGivenNamesWin() {
    let label = ModelNaming.label(
      baseURL: magpie, model: "workbuddy/hy4-preview-f",
      hints: ModelNameHints(displayName: "Hy4 preview", channelLabel: "WorkBuddy")
    )
    XCTAssertEqual(label.title, "Hy4 preview · 腾讯")
    XCTAssertEqual(label.channel, "Magpie · WorkBuddy")
  }

  func testOpenRouterPrefixIsVendorNotChannel() {
    let label = ModelNaming.label(baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-5.5")
    XCTAssertEqual(label.title, "GPT 5.5 · OpenAI")
    XCTAssertEqual(label.channel, "OpenRouter")
    let qwen = ModelNaming.label(baseURL: "https://openrouter.ai/api/v1", model: "qwen/qwen3.7-plus")
    XCTAssertEqual(qwen.title, "Qwen3.7 Plus · 阿里")
  }

  func testDirectProvidersAndCustomHosts() {
    let deepseek = ModelNaming.label(baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-flash")
    XCTAssertEqual(deepseek.title, "DeepSeek V4 Flash · DeepSeek")
    XCTAssertEqual(deepseek.channel, "DeepSeek")
    let custom = ModelNaming.label(baseURL: "https://api.example.com/v1", model: "my-model")
    XCTAssertEqual(custom.title, "My Model", "厂商认不出就只有模型名")
    XCTAssertEqual(custom.channel, "example.com")
    XCTAssertEqual(ModelNaming.label(baseURL: nil, model: "glm-5.3").titleWithChannel, "GLM 5.3 · 智谱")
  }

  func testPrettifyKeepsVersionNumbersTogether() {
    XCTAssertEqual(ModelNaming.prettify("claude-haiku-5-5"), "Claude Haiku 5.5")
    XCTAssertEqual(ModelNaming.prettify("claude-opus-4-6-thinking"), "Claude Opus 4.6 Thinking")
    XCTAssertEqual(ModelNaming.prettify("deepseek-v4.1-flash"), "DeepSeek V4.1 Flash")
    XCTAssertEqual(ModelNaming.prettify("gemini-3.8-flash"), "Gemini 3.8 Flash")
    XCTAssertEqual(ModelNaming.prettify("gpt-4o-mini"), "GPT 4o Mini")
    XCTAssertEqual(ModelNaming.prettify("whisper-large-v3-turbo"), "Whisper Large V3 Turbo")
    XCTAssertTrue(ModelNaming.prettify("gpt-4o-2024-08-06").contains("2024"), "年份不能和后面的数字连成版本号")
  }

  func testExportKeepsRawID() {
    XCTAssertEqual(
      ModelNaming.label(baseURL: magpie, model: "claude/claude-haiku-5-5").exportText,
      "Claude Haiku 5.5 · Anthropic（claude/claude-haiku-5-5）"
    )
  }

  func testVendorHeuristicsDoNotOverreach() {
    XCTAssertNil(ModelNaming.label(baseURL: nil, model: "hybrid-search").vendor)
    XCTAssertEqual(ModelNaming.label(baseURL: nil, model: "hy4-preview").vendor, "腾讯")
  }
}
