import AppKit
import XCTest
@testable import LinkDigestApp

/// Markdown 编辑着色。
///
/// 裸 TextEditor 把标题、代码、引用画成同一片灰字，写超过几行就看不出结构。
/// 这些断言钉的是「结构可见」这个目标，不是具体颜色值。
final class MarkdownSyntaxHighlighterTests: XCTestCase {
  private let base = NSFont.systemFont(ofSize: 16)
  private let palette = MarkdownSyntaxHighlighter.Palette(
    primary: .black, secondary: .gray, accent: .blue, code: .darkGray
  )

  private func highlighted(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    MarkdownSyntaxHighlighter.apply(to: storage, baseFont: base, palette: palette, lineSpacing: 6)
    return storage
  }

  private func font(_ storage: NSTextStorage, at index: Int) -> NSFont? {
    storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
  }

  func testHeadingIsLargerThanBody() {
    let storage = highlighted("# 标题\n正文")
    // 采样标题的**文字**，跳过 `# ` 标记——标记有自己的样式。
    let heading = font(storage, at: 2)
    let body = font(storage, at: storage.string.count - 1)
    XCTAssertNotNil(heading)
    XCTAssertGreaterThan(heading!.pointSize, body!.pointSize, "标题必须比正文大，否则结构不可见")
  }

  /// `#` 要留着（删掉就成了所见即所得，写的和存的对不上），但它是结构标记不是
  /// 内容：跟标题一样黑、一样大时，一行的视觉重心会落在两个井号上。
  func testHeadingMarkerRecedesBehindTheHeadingText() {
    let storage = highlighted("# 标题\n正文")
    let marker = font(storage, at: 0)
    let headingText = font(storage, at: 2)
    XCTAssertNotNil(marker)
    XCTAssertLessThan(marker!.pointSize, headingText!.pointSize, "标记不该和标题文字一样大")

    let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let textColor = storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
    XCTAssertNotEqual(markerColor, textColor, "标记要淡下去，不能和标题同色")
  }

  func testInlineCodeUsesMonospace() {
    let storage = highlighted("这是 `code` 行内代码")
    let index = storage.string.distance(
      from: storage.string.startIndex,
      to: storage.string.range(of: "`code`")!.lowerBound
    )
    let codeFont = font(storage, at: index)
    XCTAssertTrue(
      codeFont?.fontName.lowercased().contains("mono") == true,
      "行内代码要用等宽字体，才能和正文一眼分开"
    )
  }

  func testBoldIsHeavierThanBody() {
    let storage = highlighted("普通 **加粗** 文字")
    let index = storage.string.distance(
      from: storage.string.startIndex,
      to: storage.string.range(of: "**加粗**")!.lowerBound
    )
    let boldTraits = font(storage, at: index)?.fontDescriptor.symbolicTraits
    XCTAssertTrue(boldTraits?.contains(.bold) == true)
  }

  /// 着色只改属性，绝不能动文字——否则输入法组字会被打断、内容会被改写。
  func testHighlightNeverMutatesText() {
    let source = "# 标题\n- 列表\n> 引用\n`code`\n**粗**\n[链接](https://example.com)"
    let storage = highlighted(source)
    XCTAssertEqual(storage.string, source, "着色改变了文字内容——这会破坏用户输入")
  }

  /// 空文本和纯空白不能崩。
  func testEmptyAndWhitespaceAreSafe() {
    XCTAssertEqual(highlighted("").string, "")
    XCTAssertEqual(highlighted("   \n\n").string, "   \n\n")
  }
}
