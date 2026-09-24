import XCTest
@testable import LinkDigestApp

/// 正文显示对齐 Tolaria（2026-09-24）的回归测试。
final class ReadingRichDisplayTests: XCTestCase {
  func testPromptLikeTagsStayVisibleAsText() {
    let plain = MarkdownPresentation.plainTextPresentation("把规则放进 <instructions>先列事实</instructions> 里。")
    let rich = String(MarkdownPresentation.attributed("把规则放进 <instructions>先列事实</instructions> 里。").characters)
    XCTAssertEqual(rich, "把规则放进 <instructions>先列事实</instructions> 里。")
    XCTAssertFalse(plain.contains(MarkdownPresentation.omittedHTML))
  }

  func testUnclosedLessThanNoLongerSwallowsTheRestOfTheDocument() {
    let rich = String(MarkdownPresentation.attributed("当 a<b 时成立，后面还有很长的正文。").characters)
    XCTAssertEqual(rich, "当 a<b 时成立，后面还有很长的正文。")
  }

  func testCommentsAndScriptsDisappearSilently() {
    let plain = MarkdownPresentation.plainTextPresentation("前<!-- 注释 -->后<style>p{}</style>。")
    XCTAssertEqual(plain, "前后。")
  }

  func testDetailsBecomeACollapsedCallout() {
    let blocks = MarkdownPresentation.blocks(from: "<details><summary>展开看</summary>隐藏内容</details>")
    XCTAssertEqual(blocks, [.callout(kind: "details", title: "展开看", text: "隐藏内容", fold: .collapsed)])
  }

  func testInlineFormattingTagsMapToReadableStyles() {
    let rich = MarkdownPresentation.attributed("按 <kbd>Cmd</kbd>，看 <mark>重点</mark>，H<sub>2</sub>O 与 x<sup>2</sup>")
    XCTAssertEqual(String(rich.characters), "按 Cmd，看 重点，H2O 与 x2")
    let offsets = rich.runs.compactMap { $0.appKit.baselineOffset }
    XCTAssertTrue(offsets.contains { $0 > 0 }, "上标要有正的基线偏移")
    XCTAssertTrue(offsets.contains { $0 < 0 }, "下标要有负的基线偏移")
  }

  func testTildeAndCaretScriptsAreNotStrikethrough() {
    let rich = MarkdownPresentation.attributed("H~2~O、x^2^ 与 ~~删除~~")
    XCTAssertEqual(String(rich.characters), "H2O、x2 与 删除")
    let struck = rich.runs.filter { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
      .map { String(rich[$0.range].characters) }
    XCTAssertEqual(struck, ["删除"])
  }

  func testCalloutTitleAndFoldMarker() {
    let blocks = MarkdownPresentation.blocks(from: "> [!TIP]- 可选细节\n> 默认收起的内容")
    XCTAssertEqual(blocks, [.callout(kind: "tip", title: "可选细节", text: "默认收起的内容", fold: .collapsed)])
    let plain = MarkdownPresentation.blocks(from: "> [!NOTE]\n> 正文")
    XCTAssertEqual(plain, [.callout(kind: "note", title: "", text: "正文", fold: .none)])
  }

  func testShortTableSeparatorStillMakesATable() {
    let blocks = MarkdownPresentation.blocks(from: "| 改动 | 依据 |\n| :-- | --: |\n| a | b |")
    guard case let .table(headers, rows, alignments) = blocks.first else { return XCTFail("应当是表格 \(blocks)") }
    XCTAssertEqual(headers, ["改动", "依据"])
    XCTAssertEqual(rows, [["a", "b"]])
    XCTAssertEqual(alignments, [.leading, .trailing])
  }

  func testFootnotesBecomeSuperscriptNumbersAndAnEndList() {
    let source = "第一处[^a]，第二处[^b]。\n\n[^b]: 后定义的说明\n[^a]: 先引用的说明"
    let blocks = MarkdownPresentation.blocks(from: source)
    guard case let .paragraph(body) = blocks.first else { return XCTFail("\(blocks)") }
    XCTAssertFalse(body.contains("[^"))
    XCTAssertEqual(blocks.last, .orderedList(start: 1, items: ["先引用的说明", "后定义的说明"]))
    XCTAssertTrue(blocks.contains(.divider))
  }

  func testFootnoteSyntaxInsideCodeIsLeftAlone() {
    let source = "```\nlet x = a[^b]\n[^b]: 不是脚注\n```"
    XCTAssertEqual(MarkdownPresentation.resolvingFootnotes(source), source)
  }

  func testCodeHighlighterFindsKeywordsStringsAndComments() {
    let code = "let name = \"汲作\" // 注释\nreturn 42"
    let tokens = CodeSyntaxHighlighter.tokens(in: code, language: .swift)
    let pieces = tokens.map { (String(code[$0.range]), $0.kind) }
    XCTAssertTrue(pieces.contains { $0 == ("let", .keyword) })
    XCTAssertTrue(pieces.contains { $0 == ("\"汲作\"", .string) })
    XCTAssertTrue(pieces.contains { $0 == ("// 注释", .comment) })
    XCTAssertTrue(pieces.contains { $0 == ("42", .number) })
    XCTAssertTrue(pieces.contains { $0 == ("return", .keyword) })
    XCTAssertNil(CodeSyntaxHighlighter.language(for: "brainfuck"))
    XCTAssertEqual(CodeSyntaxHighlighter.language(for: "TS"), .javascript)
  }

  func testCollapsingAHeadingHidesItsSectionUntilTheNextPeerHeading() {
    let entries = [
      MarkdownOutline.Entry(blockIndex: 0, level: 2, text: "一"),
      MarkdownOutline.Entry(blockIndex: 2, level: 3, text: "一·1"),
      MarkdownOutline.Entry(blockIndex: 4, level: 2, text: "二"),
    ]
    let folding = SectionFolding(entries: entries, collapsed: [0])
    XCTAssertFalse(folding.isHeadingHidden(0))
    XCTAssertTrue(folding.isContentHidden(after: 0))
    XCTAssertTrue(folding.isHeadingHidden(1), "子标题跟着收起")
    XCTAssertTrue(folding.isContentHidden(after: 1))
    XCTAssertFalse(folding.isHeadingHidden(2), "同级的下一节不受影响")
    XCTAssertFalse(folding.isContentHidden(after: 2))
    XCTAssertFalse(folding.isContentHidden(after: -1), "第一个标题之前的导语永远可见")
    XCTAssertFalse(SectionFolding(entries: entries, collapsed: []).isContentHidden(after: 0))
  }

  /// GitHub 说明文档常见：折叠块里包着代码。代码要留在折叠块里、原样不动。
  func testDetailsWrappingACodeFenceStaysOneCollapsedCallout() {
    let source = "<details>\n<summary>CLAUDE.md</summary>\n\n```bash\nln -s AGENTS.md CLAUDE.md\n```\n\n</details>\n\n后面一段"
    let blocks = MarkdownPresentation.blocks(from: source)
    guard case let .callout(kind, title, text, fold) = blocks.first else { return XCTFail("\(blocks)") }
    XCTAssertEqual(kind, "details")
    XCTAssertEqual(title, "CLAUDE.md")
    XCTAssertEqual(fold, .collapsed)
    XCTAssertEqual(MarkdownPresentation.blocks(from: text), [.code(language: "bash", content: "ln -s AGENTS.md CLAUDE.md")])
    XCTAssertEqual(blocks.last, .paragraph("后面一段"))
  }

  func testDetailsShownAsCodeExampleIsNotConverted() {
    let source = "```html\n<details><summary>示例</summary>内容</details>\n```"
    XCTAssertEqual(MarkdownPresentation.blocks(from: source), [.code(language: "html", content: "<details><summary>示例</summary>内容</details>")])
  }

  // MARK: - 公式与流程图

  func testInlineMathRecognitionFollowsPandocRules() {
    let marked = InlineMath.marking("质能方程 $E=mc^2$ 很有名，价格 $5 到 $10 不是公式，`$x$` 是代码。")
    XCTAssertEqual(marked.filter { $0 == InlineMath.open }.count, 1, marked)
    XCTAssertTrue(marked.contains("$5 到 $10"))
    XCTAssertTrue(marked.contains("`$x$`"))
    guard let open = marked.firstIndex(of: InlineMath.open),
          let close = marked.firstIndex(of: InlineMath.close) else { return XCTFail() }
    XCTAssertEqual(InlineMath.decode(marked[marked.index(after: open)..<close]), "E=mc^2")
  }

  func testInlineMathSurvivesMarkdownParsingUntouched() {
    let parsed = MarkdownPresentation.inlineAttributed("设 $a_1 * b_2$ 成立", marksMath: true)
    let text = String(parsed.characters)
    XCTAssertTrue(text.contains(InlineMath.open))
    let plain = String(MarkdownPresentation.inlineAttributed("设 $a_1 * b_2$ 成立").characters)
    XCTAssertEqual(plain, "设 $a_1 * b_2$ 成立", "不开公式时（导出、界面文字）原样保留")
  }

  func testDisplayMathBlocksBecomeMathCode() {
    XCTAssertEqual(
      MarkdownPresentation.blocks(from: "前\n\n$$\n\\int_0^1 x\\,dx\n$$\n\n后"),
      [.paragraph("前"), .code(language: "math", content: "\\int_0^1 x\\,dx"), .paragraph("后")]
    )
    XCTAssertEqual(MarkdownPresentation.blocks(from: "$$a+b$$"), [.code(language: "math", content: "a+b")])
    XCTAssertEqual(ReadingSpecialCode.kind(of: "LaTeX"), .math)
    XCTAssertEqual(ReadingSpecialCode.kind(of: "mermaid"), .mermaid)
    XCTAssertEqual(ReadingSpecialCode.kind(of: "html"), .html)
    XCTAssertNil(ReadingSpecialCode.kind(of: "swift"))
  }

  func testPlainTextDropsInternalMarkers() {
    XCTAssertEqual(MarkdownPresentation.plainTextPresentation("H<sub>2</sub>O"), "H2O")
  }

  /// 真的起一个网页把公式和流程图排出来：验证打包的 KaTeX、Mermaid、字体、页面安全策略都通。
  @MainActor
  func testOffscreenRendererDrawsMathAndMermaid() async throws {
    let renderer = ReadingWebRenderer.shared
    func request(_ kind: ReadingWebRenderer.Kind, _ source: String) -> ReadingWebRenderer.Request {
      .init(kind: kind, source: source, color: "#222222", fontSize: 17, isDark: false, width: 600)
    }
    let math = request(.blockMath, "\\int_0^1 x^2\\,dx = \\frac{1}{3}")
    let inline = request(.inlineMath, "E=mc^2")
    let diagram = request(.mermaid, "flowchart LR\n  A[收藏] --> B[整理] --> C[产出]")
    let html = request(.html, "<h3>标题</h3><p>段落<script>document.body.innerHTML='x'</script></p>")
    let broken = request(.blockMath, "\\frac{")
    for item in [math, inline, diagram, html, broken] { _ = renderer.outcome(for: item) }
    let deadline = Date().addingTimeInterval(40)
    while Date() < deadline, [math, inline, diagram, html, broken].contains(where: { renderer.outcome(for: $0) == nil }) {
      try await Task.sleep(for: .milliseconds(200))
    }
    func size(_ item: ReadingWebRenderer.Request) -> CGSize? {
      if case let .rendered(result) = renderer.outcome(for: item) { return result.size }
      if case let .failed(message) = renderer.outcome(for: item) { XCTFail("\(item.kind) 失败：\(message)") }
      return nil
    }
    let mathSize = try XCTUnwrap(size(math))
    XCTAssertGreaterThan(mathSize.width, 60)
    XCTAssertGreaterThan(mathSize.height, 20)
    let inlineSize = try XCTUnwrap(size(inline))
    XCTAssertLessThan(inlineSize.height, 40, "行内公式高度应接近一行字")
    if case let .rendered(result) = renderer.outcome(for: inline) {
      XCTAssertGreaterThan(result.descent, 0, "行内公式要量出基线，和正文对齐")
    }
    let diagramSize = try XCTUnwrap(size(diagram))
    XCTAssertGreaterThan(diagramSize.width, 150)
    let htmlSize = try XCTUnwrap(size(html))
    XCTAssertEqual(htmlSize.width, 600)
    XCTAssertLessThan(htmlSize.height, 300, "按内容量高度，不是整个网页视图的高度")
    guard case .failed = renderer.outcome(for: broken) else { return XCTFail("错误的公式应当报失败，而不是画出东西") }
  }
}
