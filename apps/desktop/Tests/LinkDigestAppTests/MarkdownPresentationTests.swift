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

  func testReadingFontSelectionResolvesThemeAndNamedFamilies() {
    // 「跟随主题」在纸质主题下要衬线质感，但必须是**中文**衬线：原来解析成
    // system(design:.serif)（New York，无中文字形），中文逐字回退且不做标点挤压，
    // 每个「，」「。」后面都会裂开一道缝。
    XCTAssertEqual(
      ReadingFontSelection.theme.resolved(usesEditorialReadingTypography: true, bodySize: 16.5),
      ResolvedReadingFont(face: .named("Songti SC"), bodySize: 16.5)
    )
    XCTAssertEqual(
      ReadingFontSelection.theme.resolved(usesEditorialReadingTypography: false, bodySize: 16.5),
      ResolvedReadingFont(face: .named("PingFang SC"), bodySize: 16.5)
    )
    XCTAssertEqual(
      ReadingFontSelection.family("Kaiti SC").resolved(usesEditorialReadingTypography: true, bodySize: 18),
      ResolvedReadingFont(face: .named("Kaiti SC"), bodySize: 18)
    )
    // 内置命名字体在当前 macOS 上必须真实可解析，否则回退逻辑会吃掉用户选择。
    XCTAssertEqual(ResolvedReadingFont.named("Songti SC").nsFontDescriptor(size: 16).fontAttributes[.family] as? String, "Songti SC")
    XCTAssertEqual(ResolvedReadingFont.named("Kaiti SC").nsFontDescriptor(size: 16).fontAttributes[.family] as? String, "Kaiti SC")
    XCTAssertEqual(ResolvedReadingFont.named("PingFang SC").nsFontDescriptor(size: 16).fontAttributes[.family] as? String, "PingFang SC")
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
    // 灯箱：点击图外暗区退出、Esc 退出、捏合缩放、拖拽平移、双击切换。
    XCTAssertTrue(imaging.contains(".onTapGesture { InlineImageLightboxController.shared.dismiss() }"))
    XCTAssertTrue(imaging.contains(".keyboardShortcut(.cancelAction)"))
    XCTAssertTrue(imaging.contains("MagnificationGesture()"))
    XCTAssertTrue(imaging.contains("DragGesture()"))
    XCTAssertTrue(imaging.contains(".onTapGesture(count: 2) { toggleZoom() }"))
    // 滚动分派：触控板两指滑动平移、鼠标滚轮缩放，两种意图都要接上。
    // 断言写行为而不是类名——类名改一次就假失败一次，行为才是要守的东西。
    XCTAssertTrue(imaging.contains("hasPreciseScrollingDeltas"))
    XCTAssertTrue(imaging.contains("case let .pan(delta)"))
    XCTAssertTrue(imaging.contains("case let .zoom(delta)"))
    // 平移必须有边界，否则图能被滑出画布只剩空白。三条改变位置的路径
    // ——拖拽、滚动平移、缩放后回拉——都要钳制，少接一处就漏一个口子。
    XCTAssertGreaterThanOrEqual(
      imaging.components(separatedBy: "LightboxPanBounds.clamp(").count - 1, 3,
      "拖拽、滚动平移、缩放后回拉都必须经过平移边界"
    )
    // 查看框：图片与手势裁剪在框内；滚动只在框 frame 内消费，随视图离窗解绑。
    XCTAssertTrue(imaging.contains(".clipped()"))
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

  /// 任务列表要成为自己的块。
  ///
  /// 编辑器早就能续写 `- [ ]` 了，阅读区却把它当普通列表项，于是同一条清单在
  /// 「写」和「读」两侧长得不一样：读的时候是「• [ ] 买牛奶」，方括号裸露着。
  func testTaskListIsItsOwnBlockRatherThanBaresBrackets() {
    let blocks = MarkdownPresentation.blocks(from: "- [ ] 买牛奶\n- [x] 交房租")
    XCTAssertEqual(blocks.count, 1)
    guard case let .taskList(items) = blocks[0] else {
      return XCTFail("任务列表应当独立成块，实际是 \(blocks[0])")
    }
    XCTAssertEqual(items.map(\.text), ["买牛奶", "交房租"])
    XCTAssertEqual(items.map(\.isDone), [false, true])
  }

  /// 普通列表不该被任务列表规则吃掉，两种混排时各自成块。
  func testPlainAndTaskListsSplitIntoSeparateBlocks() {
    let blocks = MarkdownPresentation.blocks(from: "- 普通一项\n- [ ] 待办一项")
    XCTAssertEqual(blocks.count, 2)
    guard case let .list(plain) = blocks[0] else { return XCTFail("第一块应是普通列表") }
    XCTAssertEqual(plain, ["普通一项"])
    guard case let .taskList(tasks) = blocks[1] else { return XCTFail("第二块应是任务列表") }
    XCTAssertEqual(tasks.map(\.text), ["待办一项"])
  }

  /// `[` 开头但不是复选框的仍是普通列表项，别把 Markdown 链接当成待办。
  func testBracketsThatAreNotCheckboxesStayPlainItems() {
    for source in ["- [链接](https://example.test)", "- [无效] 标记", "- [] 空框"] {
      let blocks = MarkdownPresentation.blocks(from: source)
      guard case .list = blocks.first else {
        return XCTFail("「\(source)」不该被当成任务项，实际是 \(String(describing: blocks.first))")
      }
    }
  }

  /// 分隔线不单独成块的话会掉进段落，显示成一行光秃秃的横杠。
  func testThematicBreakBecomesADivider() {
    let blocks = MarkdownPresentation.blocks(from: "上面\n\n---\n\n下面")
    XCTAssertEqual(blocks.count, 3)
    XCTAssertEqual(blocks[1], .divider)
    XCTAssertEqual(blocks[0], .paragraph("上面"))
    XCTAssertEqual(blocks[2], .paragraph("下面"))
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

  func testQuotedTweetMarkerBecomesACardSegmentEvenWithoutLocalImages() {
    let markdown = """
    主帖正文在这里。

    <!--LDQUOTE author="Emanuele (@emanueledpt)" url="https://x.com/emanueledpt/status/2080282109277520028"-->
    被引正文第一段

    被引正文第二段
    <!--/LDQUOTE-->
    """
    // 纯文字引用（无本地图片）也要被解析成卡片，而不是把标记当字面文本。
    let segments = LocalMarkdownImageLayout.segments(markdown: markdown, localImageURLs: [])
    var quote: LocalMarkdownImageLayout.QuotedTweet?
    for segment in segments { if case let .quotedTweet(q) = segment { quote = q } }
    guard let quote else { return XCTFail("引用卡未被解析为 quotedTweet 段") }
    XCTAssertEqual(quote.author, "Emanuele (@emanueledpt)")
    XCTAssertEqual(quote.url?.absoluteString, "https://x.com/emanueledpt/status/2080282109277520028")
    XCTAssertTrue(quote.text.contains("被引正文第一段"))
    XCTAssertTrue(quote.text.contains("被引正文第二段"))
    XCTAssertTrue(quote.images.isEmpty)
    // 主帖正文仍作为独立文本段，且不含标记残留。
    let head = segments.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined()
    XCTAssertTrue(head.contains("主帖正文在这里"))
    XCTAssertFalse(head.contains("LDQUOTE"))
  }

  func testConsecutiveImagesBecomeAGalleryWhileProseKeepsSingleImagesInPlace() {
    let a = URL(fileURLWithPath: "/tmp/linkdigest-a")
    let b = URL(fileURLWithPath: "/tmp/linkdigest-b")
    let c = URL(fileURLWithPath: "/tmp/linkdigest-c")

    // 图集：图片之间只夹着 markdown 的空行，应并成一组走网格。
    XCTAssertEqual(
      LocalMarkdownImageLayout.galleryGrouped([
        .text("# 标题\n\n"), .image(a), .text("\n\n"), .image(b), .text("\n\n"), .image(c),
      ]),
      [.text("# 标题\n\n"), .gallery([a, b, c])]
    )

    // 正文穿插的单张插图：被真实文字打断，必须留在原位单排，阅读顺序不变。
    XCTAssertEqual(
      LocalMarkdownImageLayout.galleryGrouped([
        .text("前文"), .image(a), .text("中段"), .image(b), .text("后文"),
      ]),
      [.text("前文"), .image(a), .text("中段"), .image(b), .text("后文")]
    )

    // 只有一张连续图片不构成画廊。
    XCTAssertEqual(
      LocalMarkdownImageLayout.galleryGrouped([.text("前文"), .image(a)]),
      [.text("前文"), .image(a)]
    )
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

/// 灯箱里一次滚动事件该被判成平移还是缩放。
///
/// 原来所有 `scrollWheel` 一律当缩放，触控板上不管往哪滑都只会放大缩小，
/// 大图根本没法看到别的部分。
final class LightboxScrollIntentTests: XCTestCase {
  /// 触控板两指滑动是「移动内容」，必须平移——这是修复的核心。
  func testTrackpadTwoFingerScrollPans() {
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [], deltaX: 0, deltaY: -30),
      .pan(CGSize(width: 0, height: -30))
    )
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [], deltaX: 24, deltaY: 0),
      .pan(CGSize(width: 24, height: 0))
    )
  }

  /// 斜向滑动两个轴都要跟手，不能只取一个方向。
  func testDiagonalTrackpadScrollPansOnBothAxes() {
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [], deltaX: 12, deltaY: -8),
      .pan(CGSize(width: 12, height: -8))
    )
  }

  /// 鼠标没有捏合手势，滚轮是它唯一能表达缩放的方式，这一路不能被一起改掉。
  func testMouseWheelStillZooms() {
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: false, modifiers: [], deltaX: 0, deltaY: 6),
      .zoom(6)
    )
  }

  /// ⌘/⌥ + 滚动是通用的「强制缩放」，触控板用户也该能用。
  func testModifierForcesZoomEvenOnTrackpad() {
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [.command], deltaX: 0, deltaY: 10),
      .zoom(10)
    )
    XCTAssertEqual(
      lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [.option], deltaX: 3, deltaY: 10),
      .zoom(10)
    )
  }

  /// 零增量不产生动作，否则惯性尾巴会把图钉住不放。
  func testZeroDeltaProducesNoIntent() {
    XCTAssertNil(lightboxScrollIntent(hasPreciseScrollingDeltas: true, modifiers: [], deltaX: 0, deltaY: 0))
    XCTAssertNil(lightboxScrollIntent(hasPreciseScrollingDeltas: false, modifiers: [], deltaX: 0, deltaY: 0))
  }
}

/// 平移的边界。原来完全不设限，能把图一路滑出画布只剩空白。
final class LightboxPanBoundsTests: XCTestCase {
  /// 图比画布大时可以拖，但边缘不能离开画布——画布里永远填满图。
  func testLargeContentPansOnlyUntilItsEdgeMeetsTheCanvas() {
    // 内容 1000、画布 600 → 两侧各能拖 200。
    XCTAssertEqual(LightboxPanBounds.clampAxis(0, content: 1000, container: 600), 0)
    XCTAssertEqual(LightboxPanBounds.clampAxis(150, content: 1000, container: 600), 150)
    XCTAssertEqual(LightboxPanBounds.clampAxis(9999, content: 1000, container: 600), 200)
    XCTAssertEqual(LightboxPanBounds.clampAxis(-9999, content: 1000, container: 600), -200)
  }

  /// 图比画布小就没有多余部分可看，锁定居中，不能被推到角落。
  func testSmallContentStaysCentered() {
    XCTAssertEqual(LightboxPanBounds.clampAxis(500, content: 300, container: 600), 0)
    XCTAssertEqual(LightboxPanBounds.clampAxis(-500, content: 300, container: 600), 0)
  }

  /// 两个轴各判各的：横向能拖不代表纵向也能拖。
  func testAxesAreBoundedIndependently() {
    let clamped = LightboxPanBounds.clamp(
      CGSize(width: 9999, height: 9999),
      contentSize: CGSize(width: 1000, height: 300),
      containerSize: CGSize(width: 600, height: 600)
    )
    XCTAssertEqual(clamped, CGSize(width: 200, height: 0))
  }

  /// 缩小后原先合法的位置会越界，必须被拉回来，否则缩小时会留下空白。
  func testShrinkingPullsAnOutOfBoundsOffsetBack() {
    let atEdge = LightboxPanBounds.clampAxis(200, content: 1000, container: 600)
    XCTAssertEqual(atEdge, 200)
    // 缩到 700 后只剩 ±50 的余量。
    XCTAssertEqual(LightboxPanBounds.clampAxis(atEdge, content: 700, container: 600), 50)
  }
}
