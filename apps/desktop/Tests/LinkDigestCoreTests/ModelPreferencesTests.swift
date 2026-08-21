import XCTest
@testable import LinkDigestCore

final class ModelPreferencesTests: XCTestCase {
  func testSummaryPromptAppendsOutputLanguageForDefaultAndCustomTemplates() throws {
    let defaultPrompt = ModelPreferences.summaryPrompt(
      configuredPrompt: "",
      outputLanguage: "日本語"
    )
    XCTAssertTrue(defaultPrompt.hasPrefix(ModelPreferences.defaultSummaryPrompt))
    XCTAssertTrue(defaultPrompt.contains("Write the final answer in 日本語."))
    XCTAssertTrue(defaultPrompt.contains("TAGS:"))

    let custom = "Return a concise evidence table."
    let customPrompt = ModelPreferences.summaryPrompt(
      configuredPrompt: custom,
      outputLanguage: "Español"
    )
    XCTAssertTrue(customPrompt.hasPrefix(custom))
    XCTAssertTrue(customPrompt.contains("Write the final answer in Español."))
  }
}

extension ModelPreferencesTests {
  func testAutoPipelineFlagsNormalizeAndStayBackwardCompatible() throws {
    // 旧 JSON 没有管线键：解码后全部为 nil（= 关）。
    let legacy = """
      {"summaryPrompt":"总结","outputLanguage":"简体中文"}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ModelPreferences.self, from: legacy)
    XCTAssertNil(decoded.autoTranscribeNewCaptures)
    XCTAssertNil(decoded.autoSummarizeNewCaptures)
    XCTAssertNil(decoded.autoMindMapNewCaptures)

    // false 归一化为 nil；true 保留。
    let preferences = try ModelPreferences(
      autoTranscribeNewCaptures: true,
      autoSummarizeNewCaptures: false,
      autoMindMapNewCaptures: true
    )
    XCTAssertEqual(preferences.autoTranscribeNewCaptures, true)
    XCTAssertNil(preferences.autoSummarizeNewCaptures)
    XCTAssertEqual(preferences.autoMindMapNewCaptures, true)
  }
}
