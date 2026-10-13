import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 2026-10-13 评论区改版：评论单独一个页签、条头、时间、回复省略规则。
final class CommentsTabTests: XCTestCase {
  // MARK: 时间

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }

  private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 20))! }

  private func label(_ raw: String) -> String {
    CommentPublishedTime.absoluteLabel(raw, now: now, calendar: calendar)
  }

  func testPlatformWrittenLocalTimesAreRecognized() {
    // 今年：「9月27日 19:36」；往年：「2025年1月8日」。
    XCTAssertEqual(label("2026-09-27 19:36"), "9月27日 19:36")
    XCTAssertEqual(label("2026-09-27 19:36:05"), "9月27日 19:36")
    XCTAssertEqual(label("2026/09/27 19:36"), "9月27日 19:36")
    XCTAssertEqual(label("2026/9/7 9:05"), "9月7日 09:05")
    XCTAssertEqual(label("2026年9月27日 19:36"), "9月27日 19:36")
    XCTAssertEqual(label("2025-01-08 08:30"), "2025年1月8日")
    XCTAssertEqual(label("2025-01-08"), "2025年1月8日")
    XCTAssertEqual(label("2025/01/08"), "2025年1月8日")
    // 只有日期、没有时间：今年写「9月27日」，不编一个时间出来。
    XCTAssertEqual(label("2026-09-27"), "9月27日")
    XCTAssertEqual(label("2026.9.27"), "9月27日")
  }

  func testISOAndOldFormsStillWork() {
    XCTAssertEqual(label("2026-09-28T10:41:12.000Z"), "9月28日 18:41")
    XCTAssertEqual(label("2025-01-08T02:00:00Z"), "2025年1月8日")
    XCTAssertEqual(label("01-08"), "1月8日")
  }

  func testUnrecognizedTimesStayAsWritten() {
    for raw in ["3 天前", "刚才", "2026-13-40", "2026-02-30 10:00", "2026-09-27 25:61", "上周三", ""] {
      XCTAssertEqual(label(raw), raw, raw)
    }
  }

  /// 导出用的 `localStamp` 只认 ISO、输出格式不变：平台写的本地时间原样返回。
  func testExportStampIsUnchanged() {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    XCTAssertEqual(
      CommentPublishedTime.localStamp("2026-10-03T23:30:06.000Z", timeZone: shanghai, calendar: calendar),
      "2026-10-04 07:30"
    )
    XCTAssertEqual(
      CommentPublishedTime.localStamp("2026-09-27 19:36", timeZone: shanghai, calendar: calendar),
      "2026-09-27 19:36"
    )
  }

  // MARK: 回复「回复 某某」

  private func item(_ sequence: Int, depth: Int, author: String) -> MarkdownPresentation.CommentItem {
    MarkdownPresentation.CommentItem(
      sequence: sequence, depth: depth, author: author, parentAuthor: nil, score: nil,
      published: nil, permalink: nil, body: "x", isDeleted: false
    )
  }

  func testReplyRightUnderTheRepliedPersonDoesNotSayWho() {
    let thread = [
      item(0, depth: 0, author: "甲"),
      item(1, depth: 1, author: "乙"),
      item(2, depth: 2, author: "丙"),
    ]
    // 乙回复根评论甲、丙回复紧挨着上面的乙：都不写。
    XCTAssertTrue(CommentThreadSectionView.replyTargets(in: thread).isEmpty)
  }

  func testReplyToTheRootIsNeverLabeledEvenWhenNotAdjacent() {
    let thread = [
      item(0, depth: 0, author: "甲"),
      item(1, depth: 1, author: "乙"),
      item(2, depth: 1, author: "丙"),
    ]
    // 丙也是回甲的，但中间隔着乙：回的是这串的主人，位置已经说明，不写。
    XCTAssertTrue(CommentThreadSectionView.replyTargets(in: thread).isEmpty)
  }

  func testReplyToAnotherPersonInTheThreadIsLabeled() {
    let thread = [
      item(0, depth: 0, author: "甲"),
      item(1, depth: 1, author: "乙"),
      item(2, depth: 2, author: "丙"),
      item(3, depth: 1, author: "丁"),
      item(4, depth: 2, author: "戊"),
      item(5, depth: 2, author: "己"),
    ]
    let targets = CommentThreadSectionView.replyTargets(in: thread)
    // 己回的是丁（深度 1），但上面紧挨着的是戊：要写「回复 丁」。戊紧跟在丁下面，不写。
    XCTAssertEqual(targets, [5: "丁"])
  }

  func testReplyTargetKeepsRedditUserNamesWithoutThePrefix() {
    let thread = [
      item(0, depth: 0, author: "u/root"),
      item(1, depth: 1, author: "u/mid"),
      item(2, depth: 2, author: "u/deep"),
      item(3, depth: 2, author: "u/other"),
    ]
    XCTAssertEqual(CommentThreadSectionView.replyTargets(in: thread), [3: "mid"])
  }

  // MARK: 正文换行

  func testBlankLinesInsideOneCommentCollapseToPlainLineBreaks() {
    XCTAssertEqual(
      CommentThreadSectionView.compactedBody("天理赢，我是生之执政\n\n至冬赢，我是坎瑞亚人\n \n\n旅行者赢"),
      "天理赢，我是生之执政\n至冬赢，我是坎瑞亚人\n旅行者赢"
    )
    XCTAssertEqual(CommentThreadSectionView.compactedBody("一行\n另一行"), "一行\n另一行")
  }

  // MARK: 评论拆成页签

  private let captionWithComments = """
  这是帖子文案

  ## 评论（已保存 2 条 / 页面显示 173）

  - **靖妖一心** · 赞 238 · 2026-09-27 19:36 · 回复层级 0
    第一条

  - **沃沃雅妮莎** · 赞 220 · 2026-09-27 19:02 · 回复层级 0
    第二条
  """

  func testCommentsAreSplitOffTheCaptionIntoTheirOwnPage() {
    let split = CommentsTabSplit.split(captionWithComments)
    XCTAssertEqual(split.article, "这是帖子文案")
    XCTAssertTrue(split.comments.hasPrefix("## 评论（已保存 2 条"))
    XCTAssertTrue(split.comments.contains("第二条"))
    XCTAssertEqual(CommentsTabSplit.count(inComments: split.comments), 2)
  }

  func testBodyWithoutRecognizableCommentsIsLeftWhole() {
    let body = "文案\n\n## 评论\n\n这不是评论格式，只是一个小标题"
    let split = CommentsTabSplit.split(body)
    XCTAssertEqual(split.article, body)
    XCTAssertEqual(split.comments, "")
    XCTAssertEqual(CommentsTabSplit.count(inComments: ""), 0)
  }

  func testSavedCountLabelNamesThePlatformTotal() {
    let blocks = MarkdownPresentation.blocks(from: CommentsTabSplit.split(captionWithComments).comments)
    guard case let .comments(section)? = blocks.first else { return XCTFail("没解析出评论段") }
    XCTAssertEqual(section.progressLabel, "已保存 2 条 · 平台共约 173 条")
  }

  // MARK: 界面源码

  func testReadingTabsGetACommentsPageAfterSummaryAndTranslation() throws {
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(content.contains("case comments"))
    XCTAssertTrue(content.contains("tabs.append(.source(.comments))"))
    XCTAssertTrue(content.contains("history-reading-comments"))
    // 评论不再接在转写稿下面。
    XCTAssertFalse(content.contains("transcript-comments"))
    // 评论页签上写条数。
    XCTAssertTrue(content.contains("readingTabCount"))
  }

  func testCommentViewDropsDividersAndSerifBody() throws {
    let view = try appSource("CommentThreadView.swift")
    XCTAssertFalse(view.contains("Divider()"), "串与串之间不再画分隔线")
    XCTAssertTrue(view.contains("readingFont: .sans"), "评论正文用系统无衬线")
    XCTAssertTrue(view.contains("static let collapsedReplyLimit = 2"))
    XCTAssertTrue(view.contains("static let initialRootLimit = 10"))
    XCTAssertTrue(view.contains("展开另外"))
    XCTAssertTrue(view.contains("♡"))
    XCTAssertTrue(view.contains(".opacity(hovering ? 1 : 0)"), "打开原评论的小箭头只在鼠标停上去时出现")
    // 性能保护：根评论仍然分批渲染。
    XCTAssertTrue(view.contains("visibleRootLimit"))
    XCTAssertTrue(view.contains("rootLoadStep"))
  }

  private func appSource(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("Sources/LinkDigestApp/\(name)"), encoding: .utf8)
  }
}
