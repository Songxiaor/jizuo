import AppKit
import XCTest
@testable import LinkDigestApp

/// 流式阶段每写完一行就收掉 Markdown 符号，正文结束换成正式排版时不再整页一跳。
@MainActor
final class StreamingMarkdownLiteTests: XCTestCase {
  private let view = StreamingReadingTextView(
    text: "", font: .systemFont(ofSize: 15), color: .labelColor, lineSpacing: 4
  )

  func testCompletedLinesDropMarkdownSyntax() {
    let document = view.styledDocument("## 小标题\n- 第一点 **重点** 在这\n> 引用\n---\n半行 **还没")
    XCTAssertEqual(document.text.string, "小标题\n•  第一点 重点 在这\n引用\n\n半行 **还没")
    // 还在长的最后一行原样保留，从它开头算起。
    XCTAssertEqual(document.openLineStart, (document.text.string as NSString).length - ("半行 **还没" as NSString).length)
  }

  func testHeadingIsBiggerAndBold() {
    let document = view.styledDocument("# 标题\n正文\n")
    let headingFont = document.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertGreaterThan(headingFont?.pointSize ?? 0, 15)
    XCTAssertTrue(headingFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
  }

  /// 实时转写：行首时间码排成页边的灰色等宽小字，正文跳到正文栏，和成稿一个样子。
  func testLiveTranscriptHangsTimecodesInTheGutter() {
    let live = StreamingReadingTextView(
      text: "", font: .systemFont(ofSize: 15), color: .labelColor, lineSpacing: 4, hangsTimecodes: true
    )
    let document = live.styledDocument("1:09:34 一般电影都是配乐\n\n1:10:39 还在长")
    XCTAssertTrue(document.text.string.hasPrefix("1:09:34\t一般电影都是配乐\n"))
    let stampFont = document.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertEqual(stampFont?.pointSize, 11)
    let style = document.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(style?.headIndent, TranscriptGutter.textInset)
    // 普通生成（总结、翻译）不受影响。
    XCTAssertEqual(view.styledDocument("54:40 不是时间码栏\n").text.string, "54:40 不是时间码栏\n")
  }

  /// 时间码栏放得下超过一小时的 `1:09:34`，不会折成两行（2026-10-06 实测折行）。
  func testTimecodeGutterFitsHourLongStamps() {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let width = ("1:09:34" as NSString).size(withAttributes: [.font: font]).width
    XCTAssertLessThanOrEqual(width, TranscriptGutter.timecodeWidth)
  }
}
