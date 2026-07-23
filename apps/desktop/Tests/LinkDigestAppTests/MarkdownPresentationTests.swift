import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

final class MarkdownPresentationTests: XCTestCase {
  func testPaperThemeUsesOfficialClaudePaletteAndEditorialTypographyOnly() throws {
    let paper = AppearanceTheme.paper.tokens

    assertColor(paper.canvas, red: 0xFA, green: 0xF9, blue: 0xF5)
    assertColor(paper.primaryText, red: 0x14, green: 0x14, blue: 0x13)
    assertColor(paper.secondaryText, red: 0xB0, green: 0xAE, blue: 0xA5)
    assertColor(paper.hairline, red: 0xE8, green: 0xE6, blue: 0xDC)
    assertColor(paper.accent, red: 0xD9, green: 0x77, blue: 0x57)
    XCTAssertTrue(AppearanceTheme.paper.usesEditorialReadingTypography)
    XCTAssertFalse(AppearanceTheme.glass.usesEditorialReadingTypography)
    XCTAssertFalse(AppearanceTheme.ink.usesEditorialReadingTypography)
  }

  func testMarkdownReadingTypographySupportsSerifWithoutChangingCodeFont() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/MarkdownPresentation.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    // The reading area routes every text font through the user-selectable
    // reading font; code cards stay monospaced and never pass through it.
    XCTAssertTrue(source.contains("readingFont: ResolvedReadingFont = .sans"))
    XCTAssertTrue(source.contains("design: .monospaced"))
    XCTAssertFalse(source.contains("usesSerifTypography"), "The boolean serif flag must not return alongside the reading-font seam")

    // 连续选择：相邻文本块合成一个 NSTextView 段，代码卡独立；
    // 纯文本模式同样走连续选择视图。
    XCTAssertTrue(source.contains("SelectableReadingTextView("))
    XCTAssertTrue(source.contains("ReadingTextComposer.attributed("))
    XCTAssertTrue(source.contains("ReadingTextComposer.plain("))
    XCTAssertTrue(source.contains("onOpenLink: { url in openValidated(url) }"))
    let selectable = try String(
      contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("SelectableReadingText.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(selectable.contains("isSelectable = true"))
    XCTAssertTrue(selectable.contains("clickedOnLink"))
    XCTAssertTrue(selectable.contains("intrinsicContentSize"))
  }

  func testReadingFontPreferenceResolvesThemeFallbackAndNamedFamilies() {
    XCTAssertEqual(ReadingFontPreference.theme.resolved(usesEditorialReadingTypography: true), .serif)
    XCTAssertEqual(ReadingFontPreference.theme.resolved(usesEditorialReadingTypography: false), .sans)
    XCTAssertEqual(ReadingFontPreference.serif.resolved(usesEditorialReadingTypography: false), .serif)
    XCTAssertEqual(ReadingFontPreference.sansSerif.resolved(usesEditorialReadingTypography: true), .sans)
    XCTAssertEqual(ReadingFontPreference.songti.resolved(usesEditorialReadingTypography: false), .named("Songti SC"))
    XCTAssertEqual(ReadingFontPreference.kaiti.resolved(usesEditorialReadingTypography: true), .named("Kaiti SC"))
    // 内置命名字体在当前 macOS 上必须真实可解析，否则回退逻辑会吃掉用户选择。
    XCTAssertEqual(ResolvedReadingFont.named("Songti SC").nsFontDescriptor(size: 16).fontAttributes[.family] as? String, "Songti SC")
    XCTAssertEqual(ResolvedReadingFont.named("Kaiti SC").nsFontDescriptor(size: 16).fontAttributes[.family] as? String, "Kaiti SC")
  }

  func testInlineImageSaveSuggestsExtensionFromMagicBytes() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let webp = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
    XCTAssertEqual(MarkdownInlineImageActions.imageExtension(for: jpeg), "jpg")
    XCTAssertEqual(MarkdownInlineImageActions.imageExtension(for: png), "png")
    XCTAssertEqual(MarkdownInlineImageActions.imageExtension(for: webp), "webp")
    let url = URL(fileURLWithPath: "/tmp/b547fee0399faac946ab851f30d4fdf9b63886afd7a85646beaf68286421834e")
    XCTAssertEqual(MarkdownInlineImageActions.suggestedFilename(for: url, data: jpeg), "b547fee0399faac9.jpg")
  }

  func testInlineImagesRenderOnWhiteCardWithHairlineAndContextMenu() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/MarkdownPresentation.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    // 内联图片走异步下采样组件；同步 NSImage(contentsOf:) 不得回归主线程渲染路径。
    XCTAssertTrue(source.contains("InlineArticleImageView(url: url)"))
    XCTAssertFalse(source.contains("if let image = NSImage(contentsOf: url)"))

    let imaging = try String(
      contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("ArticleImageViewing.swift"),
      encoding: .utf8
    )
    // 白色衬卡 + 细边线 + 右键动作仍在异步组件里。
    XCTAssertTrue(imaging.contains(".background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))"))
    XCTAssertTrue(imaging.contains(".stroke(Color.primary.opacity(0.12), lineWidth: 1)"))
    XCTAssertTrue(imaging.contains("MarkdownInlineImageActions.saveImage(at: url)"))
    XCTAssertTrue(imaging.contains("存储图片为…"))
    XCTAssertTrue(imaging.contains("拷贝图片"))
    // 性能：CGImageSource 下采样 + NSCache；解码在后台 Task。
    XCTAssertTrue(imaging.contains("kCGImageSourceThumbnailMaxPixelSize"))
    XCTAssertTrue(imaging.contains("Task.detached(priority: .userInitiated)"))
    // 灯箱：点击图外暗区退出、Esc 退出、捏合 + 滚轮缩放、拖拽平移、双击切换。
    XCTAssertTrue(imaging.contains(".onTapGesture { InlineImageLightboxController.shared.dismiss() }"))
    XCTAssertTrue(imaging.contains(".keyboardShortcut(.cancelAction)"))
    XCTAssertTrue(imaging.contains("MagnificationGesture()"))
    XCTAssertTrue(imaging.contains("DragGesture()"))
    XCTAssertTrue(imaging.contains(".onTapGesture(count: 2) { toggleZoom() }"))
    // 查看框：图片与手势裁剪在框内；滚轮只在框 frame 内消费，随视图离窗解绑。
    XCTAssertTrue(imaging.contains(".clipped()"))
    XCTAssertTrue(imaging.contains("LightboxWheelZoomCatcher"))
    XCTAssertTrue(imaging.contains("self.bounds.contains(pointInSelf)"))
    XCTAssertTrue(imaging.contains("viewDidMoveToWindow"))
    XCTAssertTrue(imaging.contains("存储为…"))
    // 识别文字：与详情页同一 Apple Vision 本机管线；面板可选中、可拷贝。
    XCTAssertTrue(imaging.contains("AppleVisionTextRecognizer().recognizeText("))
    XCTAssertTrue(imaging.contains("识别文字"))
    XCTAssertTrue(imaging.contains("拷贝全部"))
    XCTAssertTrue(imaging.contains(".textSelection(.enabled)"))
  }

  func testGitHubREADMEPDFResolvesToRepositoryBlobAtHEAD() throws {
    let destination = try XCTUnwrap(URL(string: "book/guide.pdf"))
    let source = try XCTUnwrap(URL(string: "https://github.com/syc/linkdigest"))

    XCTAssertEqual(
      try MarkdownLinkResolver.resolve(destination, sourceURL: source).absoluteString,
      "https://github.com/syc/linkdigest/blob/HEAD/book/guide.pdf"
    )
  }

  func testOrdinaryRelativeLinkResolvesAgainstSourcePage() throws {
    let destination = try XCTUnwrap(URL(string: "downloads/guide.pdf"))
    let source = try XCTUnwrap(URL(string: "https://docs.example.com/articles/readme.html"))

    XCTAssertEqual(
      try MarkdownLinkResolver.resolve(destination, sourceURL: source).absoluteString,
      "https://docs.example.com/articles/downloads/guide.pdf"
    )
  }

  func testAbsoluteHTTPSLinkIsPreserved() throws {
    let destination = try XCTUnwrap(URL(string: "https://files.example.com/guide.pdf?download=1#page=2"))

    XCTAssertEqual(
      try MarkdownLinkResolver.resolve(destination, sourceURL: URL(string: "https://source.example.com/readme")),
      destination
    )
  }

  func testDangerousSchemeStillFailsSharedSyntaxPolicy() throws {
    let destination = try XCTUnwrap(URL(string: "javascript:alert(1)"))

    XCTAssertThrowsError(
      try MarkdownLinkResolver.resolve(destination, sourceURL: URL(string: "https://example.com/readme"))
    )
  }

  func testRichAndPlainPresentationsNeverExposeRawHTMLWhileKeepingMappedAndOmittedContent() {
    let source = "Before <strong>bold</strong> <img src=\"https://example.test/image.png\"> <script>alert(1)</script> After"

    let plain = MarkdownPresentation.plainTextPresentation(source)
    let rich = String(MarkdownPresentation.attributed(source).characters)

    for visible in [plain, rich] {
      XCTAssertFalse(visible.contains("<strong>"))
      XCTAssertFalse(visible.contains("</strong>"))
      XCTAssertFalse(visible.contains("<img"))
      XCTAssertFalse(visible.contains("<script>"))
      XCTAssertTrue(visible.contains("**bold**") || visible.contains("bold"))
      XCTAssertTrue(visible.contains(MarkdownPresentation.omittedHTML))
    }
  }

  func testAttributeQuotedDelimiterNeverLeaksIntoRichOrPlainPresentation() {
    let source = "Before <strong data-caption=\"a > b\">bold</strong> After"

    assertSafeInBothPresentations(
      source,
      forbiddenFragments: ["<strong", "</strong>", "data-caption=", "a > b", "b\">"],
      expectedVisibleText: "bold"
    )
  }

  func testMultilineAttributeNeverLeaksIntoRichOrPlainPresentation() {
    let source = "Before <em\n data-note=\"first line\nsecond > delimiter\"\n class=\"note\">emphasized</em> After"

    assertSafeInBothPresentations(
      source,
      forbiddenFragments: ["<em", "</em>", "data-note=", "class=", "second > delimiter", "note\">"],
      expectedVisibleText: "emphasized"
    )
  }

  func testTruncatedTagIsOmittedAsOneWholeFragmentInRichAndPlainPresentation() {
    let source = "Lead <img src=\"https://example.test/asset?next=a>b\" alt=\"unfinished"
    let plain = MarkdownPresentation.plainTextPresentation(source)

    XCTAssertEqual(plain, "Lead \(MarkdownPresentation.omittedHTML)")
    assertSafeInBothPresentations(
      source,
      forbiddenFragments: ["<img", "src=", "alt=", "example.test", "unfinished", "a>b"],
      expectedVisibleText: MarkdownPresentation.omittedHTML
    )
  }

  func testBlocksSplitHeadingsParagraphsListsAndQuotesWithVisibleStructure() {
    let source = """
    开篇段落，包含中文标点。

    ## 一、先纠正一个认知

    第二段正文。

    - **客户只为交付物付费**
    - 没有平台内核就没有杠杆

    > 引用一句结论。
    """
    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 5)
    guard case let .paragraph(p0) = blocks[0] else { return XCTFail("expected paragraph \(blocks[0])") }
    XCTAssertTrue(p0.contains("开篇段落"))
    XCTAssertTrue(p0.contains("。"))
    guard case let .heading(level, title) = blocks[1] else { return XCTFail("expected heading") }
    XCTAssertEqual(level, 2)
    XCTAssertTrue(title.contains("先纠正一个认知"))
    guard case let .paragraph(p1) = blocks[2] else { return XCTFail("expected paragraph") }
    XCTAssertTrue(p1.contains("第二段正文"))
    guard case let .list(items) = blocks[3] else { return XCTFail("expected list") }
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items[0].contains("交付物付费"))
    guard case let .quote(q) = blocks[4] else { return XCTFail("expected quote") }
    XCTAssertTrue(q.contains("引用一句结论"))
  }

  func testBlocksPreserveFencedCodeLanguageNewlinesIndentationAndFollowingContent() {
    let source = """
    ## 四、怎么放进 Codex 执行

    ```markdown
    project/
    ├── inputs/
    │   ├── portrait.jpg
    │   └── script.md
    └── outputs/
        └── final-1080p.mp4
    ```

    然后对 Codex 说：
    """

    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 3)
    guard case let .code(language, content) = blocks[1] else { return XCTFail("expected fenced code") }
    XCTAssertEqual(language, "markdown")
    XCTAssertTrue(content.contains("│   ├── portrait.jpg"))
    XCTAssertTrue(content.contains("    └── final-1080p.mp4"))
    XCTAssertFalse(content.contains("```"))
    guard case let .paragraph(after) = blocks[2] else { return XCTFail("expected paragraph after code") }
    XCTAssertEqual(after, "然后对 Codex 说：")
  }

  func testBlocksRepairLegacyXCodeLanguageHeaderWithoutFlatteningTree() {
    let source = """
    markdown
    project/
    ├── inputs/
    │   └── script.md
    └── outputs/
        └── final.mp4

    后续正文
    """

    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 2)
    guard case let .code(language, content) = blocks[0] else { return XCTFail("expected repaired code block") }
    XCTAssertEqual(language, "markdown")
    XCTAssertTrue(content.contains("│   └── script.md"))
    guard case let .paragraph(after) = blocks[1] else { return XCTFail("expected following paragraph") }
    XCTAssertEqual(after, "后续正文")
  }

  func testBlocksRecognizeOrderedLists() {
    let blocks = MarkdownPresentation.blocks(from: "1. 第一步\n2. **第二步**")
    XCTAssertEqual(blocks, [.orderedList(["第一步", "**第二步**"])])
  }

  func testMarkdownContentViewOwnsSelectableMonospacedCodeCard() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/MarkdownPresentation.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("case let .code(language, content)"))
    XCTAssertTrue(source.contains("codeBlock(language: language, content: content)"))
    XCTAssertTrue(source.contains("design: .monospaced"))
    XCTAssertTrue(source.contains("history-content-code-block"))
    XCTAssertTrue(source.contains("复制代码"))
  }

  func testWeChatInlineImagesStayAtMarkersAndCoverOnlyFilesDoNotBecomeGalleryItems() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-markdown-layout.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bodyRemote = "https://mmbiz.qpic.cn/body.png"
    let coverRemote = "https://mmbiz.qpic.cn/cover.png"
    func file(_ remote: String) -> URL {
      let digest = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
      return root.appendingPathComponent(digest)
    }
    let body = file(bodyRemote), cover = file(coverRemote)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! Data().write(to: body); try! Data().write(to: cover)
    let segments = LocalMarkdownImageLayout.segments(markdown: "前文\n\n![](\(bodyRemote))\n\n中段\n\n![](\(bodyRemote))\n\n后文", localImageURLs: [body, cover], appendsUnusedLocalImages: false)
    XCTAssertEqual(segments, [.text("前文\n\n"), .image(body), .text("\n\n中段\n\n"), .image(body), .text("\n\n后文")])
  }

  private func assertSafeInBothPresentations(
    _ source: String,
    forbiddenFragments: [String],
    expectedVisibleText: String
  ) {
    let plain = MarkdownPresentation.plainTextPresentation(source)
    let rich = String(MarkdownPresentation.attributed(source).characters)

    for visible in [plain, rich] {
      XCTAssertFalse(visible.contains("<"), "raw tag start leaked: \(visible)")
      for fragment in forbiddenFragments {
        XCTAssertFalse(visible.contains(fragment), "raw HTML fragment leaked: \(fragment)")
      }
      XCTAssertTrue(visible.contains(expectedVisibleText), "expected mapped or omitted content is missing: \(visible)")
    }
  }

  private func assertColor(
    _ color: Color,
    red: Int,
    green: Int,
    blue: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
      return XCTFail("color cannot convert to sRGB", file: file, line: line)
    }
    XCTAssertEqual(converted.redComponent, CGFloat(red) / 255, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(converted.greenComponent, CGFloat(green) / 255, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(converted.blueComponent, CGFloat(blue) / 255, accuracy: 0.001, file: file, line: line)
  }
}
