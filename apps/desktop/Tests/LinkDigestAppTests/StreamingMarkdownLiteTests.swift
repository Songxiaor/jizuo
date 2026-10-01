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
}
