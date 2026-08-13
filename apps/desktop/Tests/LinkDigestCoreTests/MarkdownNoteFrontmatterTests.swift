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

  /// 旧版翻译回显的元数据块卡在译文中段（前面是翻译后的标题），
  /// 显示层按白名单键清除，标题和正文保持连续。
  func testStripsEchoedMetadataBlockAfterTranslatedTitle() {
    let source = """
    停止为 Claude Code 和 Codex 付费。

    ---
    author: "aiko (@aikonect_)"
    published: "2026-08-12T11:09:50.000Z"
    likes: "217"
    replies: "14"
    ---

    别为 Claude Code 和 Codex 掏钱了。
    """
    let cleaned = MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: source)
    XCTAssertFalse(cleaned.contains("likes:"))
    XCTAssertFalse(cleaned.contains("---"))
    XCTAssertTrue(cleaned.hasPrefix("停止为 Claude Code 和 Codex 付费。"))
    XCTAssertTrue(cleaned.contains("别为 Claude Code 和 Codex 掏钱了。"))
    XCTAssertFalse(cleaned.contains("\n\n\n"), "删除位不应留下连续空行")
  }

  /// 真实旧译文的样子：模型把冒号翻成全角、author 的值折成两行、
  /// 收尾的 `---` 黏在最后一个值后面。三种畸形同时在场也要清得掉。
  func testStripsEchoedBlockWithFullwidthColonsWrappedValueAndGluedClose() {
    let source = """
    停止为Claude Code和Codex付费。

    ---
    author："aiko
    (@aikonect_)"
    published："2026-08-12T11:09:50.000Z"
    likes："217"
    replies："14"---

    别为Claude Code和Codex掏钱了。
    """
    let cleaned = MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: source)
    XCTAssertFalse(cleaned.contains("author"))
    XCTAssertFalse(cleaned.contains("likes"))
    XCTAssertFalse(cleaned.contains("---"))
    XCTAssertTrue(cleaned.hasPrefix("停止为Claude Code和Codex付费。"))
    XCTAssertTrue(cleaned.contains("别为Claude Code和Codex掏钱了。"))
  }

  /// 引文里孤零零一行 `author: 某某` 不够格：至少两个已知键才敢删。
  func testKeepsBlockWithSingleKnownKey() {
    let source = """
    题记。

    ---
    author: 王小波
    随后是一段引文正文，不是元数据。
    ---

    正文开始。
    """
    XCTAssertEqual(MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: source), source)
  }

  /// 正常的水平分隔线之间是普通正文，不满足白名单条件，必须原样保留。
  func testKeepsGenuineHorizontalRulesUntouched() {
    let source = """
    第一段。

    ---

    第二段：这里有冒号但不是元数据键。

    ---

    第三段。
    """
    XCTAssertEqual(MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: source), source)
  }

  /// 块出现在文档后段（前面超过 4 个非空行）时视为正文分隔线，不清除。
  func testIgnoresMetadataLookalikeDeepInDocument() {
    let source = """
    一
    二
    三
    四
    五

    ---
    likes: "1"
    ---
    尾段。
    """
    XCTAssertEqual(MarkdownNoteFrontmatter.strippingEchoedMetadataBlock(from: source), source)
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
