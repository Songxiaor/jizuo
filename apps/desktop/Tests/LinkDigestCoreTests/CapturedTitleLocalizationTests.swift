import XCTest
@testable import LinkDigestCore

final class CapturedTitleLocalizationTests: XCTestCase {
  func testShouldLocalizeForeignTitleForChineseReading() {
    XCTAssertTrue(
      CapturedTitleLocalization.shouldLocalize(
        title: "How to learn faster",
        outputLanguage: "简体中文"
      )
    )
    XCTAssertFalse(
      CapturedTitleLocalization.shouldLocalize(
        title: "中文标题也足够长一些",
        outputLanguage: "简体中文"
      )
    )
  }

  func testNeedsLocalizationRespectsOriginalTitleFrontmatter() {
    let body = """
    ---
    original_title: "How to learn faster"
    ---
    Body text
    """
    XCTAssertFalse(
      CapturedTitleLocalization.needsLocalization(
        title: "如何更快学习",
        bodyText: body,
        outputLanguage: "简体中文"
      )
    )
  }

  func testBodyWithPreservedOriginalAddsFrontmatterOnce() {
    let updated = CapturedTitleLocalization.bodyWithPreservedOriginal(
      bodyText: "plain body",
      originalTitle: "Original EN Title"
    )
    let parsed = MarkdownNoteFrontmatter.parse(updated)
    XCTAssertEqual(parsed.originalTitle, "Original EN Title")
    XCTAssertEqual(parsed.body.trimmingCharacters(in: .whitespacesAndNewlines), "plain body")
    let again = CapturedTitleLocalization.bodyWithPreservedOriginal(
      bodyText: updated,
      originalTitle: "Other"
    )
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(again).originalTitle, "Original EN Title")
  }

  func testSanitizedModelTitleStripsMarkdownAndQuotes() {
    let title = CapturedTitleLocalization.sanitizedModelTitle("""
      # "如何更快学习"

      extra line ignored
      """)
    XCTAssertEqual(title, "如何更快学习")
  }
}
