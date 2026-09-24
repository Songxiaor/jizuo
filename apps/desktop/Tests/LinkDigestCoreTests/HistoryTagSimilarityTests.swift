import XCTest
@testable import LinkDigestCore

final class HistoryTagSimilarityTests: XCTestCase {
  private func tag(_ name: String, _ count: Int) -> HistoryNavigationTag {
    .init(tag: HistoryTag(rawValue: name)!, count: count)
  }

  func testOnlySpellingVariantsAreGrouped() {
    let groups = HistoryTagSimilarity.groups([
      tag("AI 编程", 2), tag("AI编程", 3), tag("开源", 2), tag("开源工具", 2),
      tag("Open-AI", 1), tag("openai", 4), tag("ＧＰＴ", 1), tag("GPT", 1),
    ])
    XCTAssertEqual(groups.map { $0.map(\.tag.name) }, [["AI编程", "AI 编程"], ["openai", "Open-AI"], ["GPT", "ＧＰＴ"]],
                   "只按写法归组：意思相近的「开源 / 开源工具」不建议；组内用得最多的排第一，组间总条数相同按名字排")
  }

  func testSystemTagsNeverAppear() {
    XCTAssertTrue(HistoryTagSimilarity.groups([tag("已使用", 3), tag("已 使用", 1)]).isEmpty)
  }
}
