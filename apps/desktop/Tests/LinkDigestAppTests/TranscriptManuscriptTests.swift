import XCTest
import LinkDigestCore
@testable import LinkDigestApp

/// 逐字稿版式：时间码拆到页边、朱批位置落在对的段落和字上、题跋的中文日期。
final class TranscriptManuscriptTests: XCTestCase {
  func testTimestampsMoveToTheGutterAndParagraphsKeepTheirText() {
    let text = "00:00 第一段。\n\n00:39 第二段，\n第二行。\n\n没有时间码的一段"
    let paragraphs = TranscriptManuscript.rawParagraphs(of: text)
    XCTAssertEqual(paragraphs.map(\.stamp), ["00:00", "00:39", nil])
    XCTAssertEqual(paragraphs.map(\.text), ["第一段。", "第二段，\n第二行。", "没有时间码的一段"])
    XCTAssertEqual(paragraphs.map(\.seconds), [0, 39, nil])
    XCTAssertTrue(TranscriptManuscript.looksLikeTranscript(text))
    XCTAssertFalse(TranscriptManuscript.looksLikeTranscript("# 一篇文章\n\n正文"))
  }

  func testMarksLandOnTheRevisedWordsInsideTheRightParagraph() {
    let original = "00:00 前三方重要\n\n00:39 其实他拍视频大部分都是工作计时"
    let revised = "00:00 前3秒重要。\n\n00:39 其实她拍视频，大部分都是工作纪实。"
    let revision = TranscriptRevision.compare(original: original, revised: revised)
    let paragraphs = TranscriptManuscript.paragraphs(of: revised, revision: revision)
    func marked(_ paragraph: TranscriptManuscript.Paragraph) -> [String] {
      let characters = Array(paragraph.text)
      return paragraph.marks.map { String(characters[$0]) }
    }
    XCTAssertEqual(marked(paragraphs[0]), ["3秒"])
    XCTAssertEqual(marked(paragraphs[1]), ["她", "纪实"])
    XCTAssertEqual(paragraphs[1].notes.map(\.original), ["他", "计时"])
    XCTAssertEqual(paragraphs[1].notes.map(\.revised), ["她", "纪实"])
  }

  /// 校对把 40 秒一大段拆成几段、并加小标题（2026-09-28）：每段都挂时间码，拆出来的按字数估。
  func testSplitParagraphsGetEstimatedStampsAndHeadingsTakeTheNextStamp() {
    let text = "## 文案会越来越不重要\n\n00:00 一二三四五六七八九十。\n\n一二三四五六七八九十。\n\n## 工作纪实就是内容\n\n00:40 后面一段。"
    let paragraphs = TranscriptManuscript.paragraphs(of: text)
    XCTAssertEqual(paragraphs.map(\.isHeading), [true, false, false, true, false])
    XCTAssertEqual(paragraphs[0].text, "文案会越来越不重要")
    XCTAssertEqual(paragraphs[0].stamp, "00:00", "小标题挂下一段的时间")
    XCTAssertEqual(paragraphs[2].stamp, "00:20", "两段字数相同，第二段估在 40 秒的一半")
    XCTAssertTrue(paragraphs[2].isEstimated)
    XCTAssertFalse(paragraphs[1].isEstimated)
    XCTAssertEqual(paragraphs[3].stamp, "00:40")
  }

  func testTrailingParagraphIsExtrapolatedWithAverageSpeed() {
    let text = "00:00 一二三四。\n\n00:40 一二三四五。\n\n一二三四五。"
    let paragraphs = TranscriptManuscript.paragraphs(of: text)
    XCTAssertEqual(paragraphs[2].isEstimated, true)
    XCTAssertGreaterThan(paragraphs[2].seconds ?? 0, 40)
  }

  /// 评论写在转写稿末尾（2026-09-28）：切出来单独排，不当转写段落、不挂估算时间码。
  func testCommentsAtTheEndAreSplitOffTheTranscript() {
    let text = "00:00 第一段。\n\n00:45 第二段。\n\n## 评论（已保存 2 条）\n\n- **范凯说AI** · 2026-09-28T10:41:12.000Z · 回复层级 0\n  完整工作流讨论："
    let split = TranscriptManuscript.splittingComments(text)
    XCTAssertEqual(split.transcript, "00:00 第一段。\n\n00:45 第二段。")
    XCTAssertTrue(split.comments?.hasPrefix("## 评论") ?? false)
    XCTAssertEqual(TranscriptManuscript.paragraphs(of: split.transcript).count, 2)
    XCTAssertNil(TranscriptManuscript.splittingComments("00:00 只有转写。").comments)
  }

  func testCommentTimesReadAsLocalDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 20))!
    XCTAssertEqual(CommentPublishedTime.absoluteLabel("2026-09-28T10:41:12.000Z", now: now, calendar: calendar), "9月28日 18:41")
    XCTAssertEqual(CommentPublishedTime.absoluteLabel("2025-01-08T02:00:00Z", now: now, calendar: calendar), "2025年1月8日")
    XCTAssertEqual(CommentPublishedTime.absoluteLabel("01-08", now: now, calendar: calendar), "1月8日")
    XCTAssertEqual(CommentPublishedTime.absoluteLabel("3 天前", now: now, calendar: calendar), "3 天前")
  }

  func testColophonUsesChineseDates() {
    XCTAssertEqual(ColophonView.chineseNumber(9), "九")
    XCTAssertEqual(ColophonView.chineseNumber(10), "十")
    XCTAssertEqual(ColophonView.chineseNumber(18), "十八")
    XCTAssertEqual(ColophonView.chineseNumber(28), "二十八")
    XCTAssertEqual(ColophonView.chineseNumber(30), "三十")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8))!
    XCTAssertEqual(ColophonView.chineseDate(date, calendar: calendar), "丙午年九月廿八日")
    XCTAssertEqual(ColophonView.ganzhiYear(2026), "丙午")
    XCTAssertEqual(ColophonView.ganzhiYear(1984), "甲子")
    XCTAssertEqual(ColophonView.ganzhiYear(2027), "丁未")
    XCTAssertEqual(["初一", "初九", "初十", "十一", "二十", "廿一", "廿九", "三十", "卅一"],
                   [1, 9, 10, 11, 20, 21, 29, 30, 31].map { ColophonView.chineseDay($0) })
  }
}
