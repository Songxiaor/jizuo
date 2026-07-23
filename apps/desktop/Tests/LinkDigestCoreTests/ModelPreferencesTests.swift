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

    let custom = "Return a concise evidence table."
    let customPrompt = ModelPreferences.summaryPrompt(
      configuredPrompt: custom,
      outputLanguage: "Español"
    )
    XCTAssertTrue(customPrompt.hasPrefix(custom))
    XCTAssertTrue(customPrompt.contains("Write the final answer in Español."))
  }
}
