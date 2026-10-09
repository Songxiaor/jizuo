import AppKit
import XCTest
@testable import LinkDigestApp

/// 阅读区正文要一直留在 TextKit 2：只要有人读一下 `layoutManager`，NSTextView 就悄悄退回
/// TextKit 1，打开长文又变成全文排版（2026-10-06 滑动性能第二批）。
@MainActor
final class ReadingTextHostViewTests: XCTestCase {
  func testStaysOnTextKit2AfterLayoutAndSizing() {
    let host = ReadingTextHostView(frame: NSRect(x: 0, y: 0, width: 480, height: 10))
    let text = NSMutableAttributedString(string: String(repeating: "长文一段。", count: 2_000) + " code ", attributes: [
      .font: NSFont.systemFont(ofSize: 15),
    ])
    text.addAttribute(.readingInlineCodeChip, value: true, range: NSRange(location: text.length - 5, length: 4))
    text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 4))
    host.textView.textStorage?.setAttributedString(text)
    host.layoutSubtreeIfNeeded()
    _ = host.intrinsicContentSize
    _ = host.textView.intrinsicContentSize
    host.textView.mouseDownPointForTesting(NSPoint(x: 2, y: 2))
    XCTAssertNotNil(host.textView.textLayoutManager, "阅读区正文退回了 TextKit 1")
    XCTAssertGreaterThan(host.intrinsicContentSize.height, 1)
  }
}

/// 整篇文章一个文字视图（2026-10-07 第二批）：嵌入块的两条硬规矩。
final class ArticleDocumentSourceTests: XCTestCase {
  private func source(_ file: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(file)"),
      encoding: .utf8
    )
  }

  /// 为 false 时文字引擎不理会算好的尺寸，给每个块套默认 32pt 宽：大图压成小灰条、标题被推开。
  func testEmbeddedBlocksTrackTheirViewBounds() throws {
    let article = try source("ArticleDocument.swift")
    XCTAssertTrue(article.contains("provider.tracksTextAttachmentViewBounds = true"))
    XCTAssertTrue(article.contains("view.setFrameSize(rect.size)"), "宽度变了要在 attachmentBounds 里把框跟上")
  }

  /// 正文、图片、表格、评论、转写稿都铺满阅读列，左右边缘和标题、页签对齐（Syc 2026-10-07）。
  /// 另收约 36 字的版心会让正文只到列宽三分之二、靠左，右边空一大块。
  func testReadingBlocksFillTheColumn() throws {
    let markdown = try source("MarkdownPresentation.swift")
    XCTAssertFalse(markdown.contains("appendBlock(.measure"), "块要铺满阅读列")
    XCTAssertFalse(markdown.contains("tailIndent"), "正文段不能另设行宽上限")
    for file in ["MarkdownPresentation.swift", "CommentThreadView.swift", "TranscriptManuscriptView.swift",
                 "TranscriptTimelineView.swift", "DesignTokens.swift"] {
      XCTAssertFalse(try source(file).contains("readingTextMeasure"), "\(file) 不能再收版心")
    }
  }

  /// 比列窄的插图左缘贴正文，不居中（Syc 2026-10-07）。
  func testNarrowImagesAlignToTheTextEdge() throws {
    let images = try source("ArticleImageViewing.swift")
    XCTAssertFalse(images.contains("layout == .gallery ? .leading : .center"), "小图不能居中")
  }
}

/// 2026-10-07 检查修复：正文清洗。
final class ReadingSanitizeChecksTests: XCTestCase {
  func testBoxDrawingDiagramInQuoteBecomesMonospacedBlock() {
    let source = "前文。\n\n> │ 渠道数据 │  │ 脚本 │\n> │          │  │      │\n> │ 广告 + CRM ├─▶│ 抓取 │\n\n后文。"
    let blocks = MarkdownPresentation.blocks(from: source)
    let code = blocks.first { if case .code = $0 { return true } else { return false } }
    guard case let .code(language, content)? = code else { return XCTFail("流程图没有按等宽块排：\(blocks)") }
    XCTAssertEqual(language, "diagram")
    XCTAssertTrue(content.hasPrefix("│ 渠道数据"), "引用记号要去掉")
    XCTAssertFalse(ReadingSpecialCode.isProse(language: language, content: content), "不能按宋体文字块排")
  }

  func testSingleArrowInProseStaysProse() {
    let blocks = MarkdownPresentation.blocks(from: "A → B 是一种关系。\n\n下一段。")
    XCTAssertFalse(blocks.contains { if case .code = $0 { return true } else { return false } })
  }

  func testWikipediaEditLinksAreDropped() {
    let source = "## History\n\n[ [edit](https://en.wikipedia.org/w/index.php?title=GIF&action=edit&section=1) ]\n\nText."
    XCTAssertFalse(MarkdownPresentation.sanitized(source).contains("edit"))
  }
}

/// 没解码过的图也要按真实比例占位（2026-10-07 检查：目录跳转落点偏、滑动时内容一跳）。
final class InlineImageHeaderSizeTests: XCTestCase {
  func testKnownSizeReadsTheFileHeaderBeforeDecoding() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jz-header-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let rep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    let size = try XCTUnwrap(InlineImageMemoryCache.knownSize(for: url, maxPixelSize: 1600))
    XCTAssertEqual(size.width, 1600)
    XCTAssertEqual(size.height, 400)
  }
}

final class DiagramBlankLineTests: XCTestCase {
  func testNotesStyleBlankLinesInsideTreeAreDropped() {
    let source = "├── 01-用户/\n\n│   ├── 用户画像.md\n\n│   └── 阶段目标.md\n\n├── 02-方法论/\n\n之后的正文。"
    guard case let .code(_, content)? = MarkdownPresentation.blocks(from: source).first else { return XCTFail() }
    XCTAssertEqual(content.components(separatedBy: "\n").count, 4)
  }
}

final class DiagramPipelineTests: XCTestCase {
  /// X 配文按行分段会在每行之间插空行：图要在那之前包好（2026-10-07 检查）。
  func testXCaptionDiagramSurvivesLineBreakPreservation() {
    let body = "正文。\n\n> ┌──────┐\n> │ 调研 │\n> └──┬───┘\n>    ▼\n\n下文。"
    let shown = CapturedSourceBodyPresentation.preservingCaptionParagraphs(
      MarkdownPresentation.fencingTextDiagrams(body), platform: "x"
    )
    let diagram = MarkdownPresentation.blocks(from: shown).first { if case .code = $0 { return true } else { return false } }
    guard case let .code(_, content)? = diagram else { return XCTFail("图被拆散了") }
    XCTAssertEqual(content.components(separatedBy: "\n").count, 4)
  }

  /// 备忘录：没写语言的代码块里是目录树，中文多也要按等宽排。
  func testUnlabelledCodeBlockWithTreeIsDiagram() {
    let source = "```\nANN-知识库/\n\n│\n\n├── 00-系统/\n\n│   ├── AI启动索引.md\n\n│   └── 用户画像.md\n```"
    guard case let .code(language, content)? = MarkdownPresentation.blocks(from: source).first else { return XCTFail() }
    XCTAssertEqual(language, "diagram")
    XCTAssertEqual(content.components(separatedBy: "\n").count, 5)
  }
}
