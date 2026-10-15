import XCTest
@testable import LinkDigestCore

final class HistoryTagVocabularyTests: XCTestCase {
  func testTopNamesRanksByUsageAndSkipsSystemTags() {
    let tags = [
      Self.tag("折叠屏", 3),
      Self.tag(ContentOwnership.ownTagName, 99),
      Self.tag("AI 工具", 12),
      Self.tag("Claude Code", 12),
      Self.tag("冷门", 0),
    ]
    XCTAssertEqual(
      HistoryTagVocabulary.topNames(from: tags),
      ["AI 工具", "Claude Code", "折叠屏"]
    )
    XCTAssertEqual(HistoryTagVocabulary.topNames(from: tags, limit: 1), ["AI 工具"])
  }

  func testTopNamesCapsAtOneHundred() {
    let tags = (0..<150).map { Self.tag("标签\($0)", 150 - $0) }
    XCTAssertEqual(HistoryTagVocabulary.topNames(from: tags).count, 100)
  }

  func testAtMostOneNewTagIsKeptAndExistingSpellingWins() {
    let result = HistoryTagVocabulary.limitingNewTags(
      ["ai 工具", "新主题一", "新主题二", "折叠屏"].compactMap(HistoryTag.init(rawValue:)),
      existing: ["AI 工具", "折叠屏"]
    )
    XCTAssertEqual(result.map(\.name), ["AI 工具", "新主题一", "折叠屏"])
  }

  func testMindMapTagNamesFollowTheSameLimit() {
    XCTAssertEqual(
      HistoryTagVocabulary.limitingNewTagNames(
        ["Adobe", "ImageFlow", "Relight", "ai 工具"],
        existing: ["AI 工具", "折叠屏"]
      ),
      ["Adobe", "AI 工具"]
    )
  }

  func testEmptyLibraryKeepsAllTags() {
    let tags = ["甲", "乙", "丙"].compactMap(HistoryTag.init(rawValue:))
    XCTAssertEqual(HistoryTagVocabulary.limitingNewTags(tags, existing: []), tags)
  }

  func testSummaryPromptListsExistingTagsOnlyWhenPresent() {
    let plain = ModelPreferences.summaryPrompt(configuredPrompt: "", outputLanguage: "简体中文")
    XCTAssertFalse(plain.contains("existing list"))
    let withTags = ModelPreferences.summaryPrompt(
      configuredPrompt: "",
      outputLanguage: "简体中文",
      existingTags: ["AI 工具", "折叠屏"]
    )
    XCTAssertTrue(withTags.hasPrefix(plain), "已有标签只追加在末尾，原提示词不变")
    XCTAssertTrue(withTags.contains("AI 工具, 折叠屏"))
    XCTAssertTrue(withTags.contains("at most 1 new tag"))
  }

  private static func tag(_ name: String, _ count: Int) -> HistoryNavigationTag {
    HistoryNavigationTag(tag: HistoryTag(rawValue: name)!, count: count)
  }
}
