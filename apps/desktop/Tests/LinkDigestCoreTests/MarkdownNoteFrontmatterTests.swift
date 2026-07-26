import XCTest
@testable import LinkDigestCore

final class MarkdownNoteFrontmatterTests: XCTestCase {
  func testParsesAuthorPublishedAndStripsHeaderFromBody() {
    let source = """
    ---
    author: "AI一天"
    published: "2026-05-02"
    description: "一段 SEO 摘要"
    ---

    ## 标题

    第一段正文。
    """
    let note = MarkdownNoteFrontmatter.parse(source)
    XCTAssertEqual(note.author, "AI一天")
    XCTAssertEqual(note.published, "2026-05-02")
    XCTAssertEqual(note.description, "一段 SEO 摘要")
    // description may parse for compatibility but does not count as UI properties.
    XCTAssertTrue(note.hasProperties)
    XCTAssertTrue(note.body.contains("## 标题"))
    XCTAssertFalse(note.body.hasPrefix("---"))
  }

  func testDescriptionAloneDoesNotCountAsProperties() {
    let source = """
    ---
    description: "仅有摘要"
    ---

    正文
    """
    let note = MarkdownNoteFrontmatter.parse(source)
    XCTAssertFalse(note.hasProperties)
    XCTAssertEqual(note.body.trimmingCharacters(in: .whitespacesAndNewlines), "正文")
  }

  func testParsesAllEngagementStatsWithoutAuthorOrPublishedProperties() {
    let note = MarkdownNoteFrontmatter.parse("""
    ---
    likes: "1.2万"
    comments: "345"
    shares: "67"
    collects: "890"
    ---

    正文
    """)
    XCTAssertNil(note.author)
    XCTAssertFalse(note.hasProperties)
    XCTAssertTrue(note.hasEngagementStats)
    XCTAssertEqual(note.likes, "1.2万")
    XCTAssertEqual(note.comments, "345")
    XCTAssertEqual(note.shares, "67")
    XCTAssertEqual(note.collects, "890")
  }

  func testMapsLegacyXRepliesAndRepostsToSharedDisplayFields() {
    let note = MarkdownNoteFrontmatter.parse("""
    ---
    replies: "12"
    reposts: "34"
    ---

    帖子正文
    """)
    XCTAssertEqual(note.comments, "12")
    XCTAssertEqual(note.shares, "34")
    XCTAssertTrue(note.hasEngagementStats)
  }

  func testMissingFrontmatterReturnsOriginalBody() {
    let source = "纯正文没有属性头。"
    let note = MarkdownNoteFrontmatter.parse(source)
    XCTAssertNil(note.author)
    XCTAssertEqual(note.body, source)
    XCTAssertFalse(note.hasProperties)
  }
}
