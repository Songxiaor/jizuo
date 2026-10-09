import Foundation
import XCTest
@testable import LinkDigestCore

/// 读模型列表时把服务商多给的信息也读出来（2026-10-09 Syc：Magpie 的模型标出信息）。
final class ModelCatalogEntryTests: XCTestCase {
  func testParsesMagpieMetadata() throws {
    let json = #"""
    {"data":[
      {"id":"anthropic/claude-haiku-5-5","display_name":"Claude Haiku 5.5","magpie_label":"Claude Haiku 5.5 · Anthropic",
       "owned_by":"anthropic","context_window":1000000,"max_output_tokens":128000,"modalities":{"input":["text","image"]},
       "native_endpoints":["/v1/messages"],"reasoning":true,
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]},
      {"id":"cursor/grok-4.7-fast","display_name":"grok-4.7-fast","magpie_label":"grok-4.7-fast · Cursor","owned_by":"cursor",
       "native_endpoints":["/v1/chat/completions"],"reasoning":false,"supported_reasoning_levels":[]}
    ]}
    """#
    let entries = try XCTUnwrap(ModelCatalogEntry.parseCatalog(Data(json.utf8)))
    XCTAssertEqual(entries.count, 2)
    let haiku = entries[0]
    XCTAssertEqual(haiku.displayName, "Claude Haiku 5.5")
    XCTAssertEqual(haiku.sourceLabel, "Anthropic")
    XCTAssertEqual(haiku.ownedBy, "anthropic")
    XCTAssertEqual(haiku.contextWindow, 1_000_000)
    XCTAssertEqual(haiku.maxOutputTokens, 128_000)
    XCTAssertEqual(haiku.acceptsImages, true)
    XCTAssertEqual(haiku.supportsReasoning, true)
    XCTAssertEqual(haiku.reasoningLevels, ["low", "max"])
    XCTAssertEqual(haiku.nativeEndpoints, ["/v1/messages"])
    let grok = entries[1]
    XCTAssertNil(grok.displayName, "显示名就是 ID 末段，不重复标")
    XCTAssertEqual(grok.sourceLabel, "Cursor")
    XCTAssertEqual(grok.supportsReasoning, false)
  }

  func testParsesOpenRouterShapeAndToleratesJunk() throws {
    let json = #"""
    {"data":[
      {"id":"openai/gpt-5","name":"OpenAI: GPT-5","context_length":400000,
       "architecture":{"input_modalities":["text","image"]},"top_provider":{"max_completion_tokens":128000}},
      {"id":"  ","name":"blank id is skipped"},
      {"id":"weird","context_length":"not a number","reasoning":"yes","modalities":"text","max_output_tokens":true},
      {"id":"plain"}
    ]}
    """#
    let entries = try XCTUnwrap(ModelCatalogEntry.parseCatalog(Data(json.utf8)))
    XCTAssertEqual(entries.map(\.id), ["openai/gpt-5", "weird", "plain"])
    XCTAssertEqual(entries[0].contextWindow, 400_000)
    XCTAssertEqual(entries[0].maxOutputTokens, 128_000)
    XCTAssertEqual(entries[0].acceptsImages, true)
    XCTAssertNil(entries[1].contextWindow)
    XCTAssertNil(entries[1].maxOutputTokens, "布尔值不能当成数字 1")
    XCTAssertNil(entries[1].supportsReasoning)
    XCTAssertFalse(entries[2].hasDetails)
  }

  func testRejectsNonCatalogPayload() {
    XCTAssertNil(ModelCatalogEntry.parseCatalog(Data(#"{"models":[]}"#.utf8)))
    XCTAssertNil(ModelCatalogEntry.parseCatalog(Data("not json".utf8)))
  }
}
