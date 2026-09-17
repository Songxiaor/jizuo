import XCTest
@testable import LinkDigestCore

final class TranscriptReadingTextTests: XCTestCase {
  func testMergesShortLinesIntoParagraphsWithoutTimecodes() {
    let transcript = """
    00:00 Yes.

    00:01 Mr. Jobs, you're a bright and influential man.

    00:06 Here it comes.

    00:24 And when you're finished with that, perhaps you could tell us what you have been doing.
    """
    let text = TranscriptReadingText.removingTimecodes(from: transcript)
    XCTAssertFalse(text.contains("00:"))
    let paragraphs = text.components(separatedBy: "\n\n")
    XCTAssertEqual(paragraphs.first, "Yes. Mr. Jobs, you're a bright and influential man. Here it comes.")
    XCTAssertEqual(paragraphs.count, 2, "停顿 18 秒另起一段")
  }

  func testChineseSentencesJoinWithoutSpacesAndLongParagraphsSplit() {
    var lines: [String] = []
    for second in 0..<40 {
      lines.append(String(format: "00:%02d 这是一句用来凑长度的中文转写内容。", second))
    }
    let text = TranscriptReadingText.removingTimecodes(from: lines.joined(separator: "\n"))
    XCTAssertFalse(text.contains("。 这"), "中文句子之间不加空格")
    XCTAssertGreaterThan(text.components(separatedBy: "\n\n").count, 1, "太长会按句末拆段")
  }

  func testLeavesOrdinaryTextAndHeadingsAlone() {
    let article = "今天会议 10:30 开始。\n\n第二段"
    XCTAssertEqual(TranscriptReadingText.removingTimecodes(from: article), article, "没有段首时间码的正文原样返回")
    let layered = "## 视频转写\n\n00:00 第一句。\n00:02 第二句。"
    XCTAssertEqual(TranscriptReadingText.removingTimecodes(from: layered), "## 视频转写\n\n第一句。第二句。")
    XCTAssertTrue(TranscriptReadingText.hasLeadingTimecodes(layered))
    XCTAssertFalse(TranscriptReadingText.hasLeadingTimecodes(article))
  }
}
