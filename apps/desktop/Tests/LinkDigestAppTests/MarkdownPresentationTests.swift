import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

final class MarkdownPresentationTests: XCTestCase {
  func testPaperThemeUsesOfficialClaudePaletteAndEditorialTypographyOnly() throws {
    let paper = AppearanceTheme.paper.tokens

    // canvas 是 sunken(#EFEDE5) 而不是最亮的 #FAF9F5：三栏要能分层。首版给
    // canvas 用亮底时，中栏到详情卡片只差 1.2% 灰阶，实机上根本看不出是两层。
    assertColor(paper.canvas, red: 0xEF, green: 0xED, blue: 0xE5)
    assertColor(paper.primaryText, red: 0x14, green: 0x14, blue: 0x13)
    // 次要文字偏离官方 palette 的 #B0AEA5：那个值在正文卡上对比度只有 2.2:1，
    // 真实信息（批量进度、引导文字）读不清。#6E6C63 在卡面 5.1:1、画布 4.5:1，
    // 是同色相里能过 WCAG AA 的最浅一档。
    assertColor(paper.secondaryText, red: 0x6E, green: 0x6C, blue: 0x63)
    assertColor(paper.hairline, red: 0xE8, green: 0xE6, blue: 0xDC)
    assertColor(paper.accent, red: 0xD9, green: 0x77, blue: 0x57)
    XCTAssertTrue(AppearanceTheme.paper.usesEditorialReadingTypography)
    XCTAssertFalse(AppearanceTheme.glass.usesEditorialReadingTypography)
    XCTAssertFalse(AppearanceTheme.ink.usesEditorialReadingTypography)
    // 暖褐和浅色同属「读长文」的纸系主题，跟着用宋体；高对比要的是笔画清晰。
    XCTAssertTrue(AppearanceTheme.sepia.usesEditorialReadingTypography)
    XCTAssertFalse(AppearanceTheme.mono.usesEditorialReadingTypography)
  }

  /// 自绘主题必须真的有底色。
  ///
  /// `isNative == false` 的主题会被各视图当成「我来画背景」，一旦某套主题
  /// 漏填 canvas（或误抄成 `.clear`），表现是窗口透出后面的桌面或系统灰，
  /// 而不是编译错误。
  func testNonNativeThemesAllPaintAnOpaqueCanvas() throws {
    for theme in AppearanceTheme.allCases where !theme.tokens.isNative {
      let canvas = try XCTUnwrap(
        NSColor(theme.tokens.canvas).usingColorSpace(.sRGB),
        "\(theme.rawValue) canvas cannot convert to sRGB")
      XCTAssertEqual(
        canvas.alphaComponent, 1, accuracy: 0.001,
        "\(theme.rawValue) 是自绘主题，canvas 必须不透明")
    }
    // glass 反过来：它的意义就是交还系统 material，画布必须是透明的。
    XCTAssertTrue(AppearanceTheme.glass.tokens.isNative)
  }

  /// 「高对比」这三个字得当真。
  ///
  /// 这套主题唯一的存在理由就是对比度。如果哪天有人顺手把 secondaryText
  /// 调成和别的浅色主题一样的浅灰（paper 的 #B0AEA5 对白底只有 2 出头），
  /// 主题名就成了假的，而肉眼扫一眼设置页是看不出来的。
  func testMonoThemeActuallyMeetsHighContrastRatios() throws {
    let mono = AppearanceTheme.mono.tokens
    // WCAG AA：正文 4.5:1。高对比主题对自己要求高些，正文直接钉到 15:1。
    XCTAssertGreaterThan(try contrastRatio(mono.primaryText, mono.canvas), 15)
    // 次要文字也必须过 AA，这正是它和其它浅色主题分道扬镳的地方。
    XCTAssertGreaterThan(try contrastRatio(mono.secondaryText, mono.canvas), 4.5)
    // 选中态是反白块，块上的字同样要能读。
    XCTAssertGreaterThan(try contrastRatio(mono.selectionText, mono.selectionFill), 15)
    // 分隔线要看得见——AA 对非文字元素是 3:1。
    XCTAssertGreaterThan(try contrastRatio(mono.hairline, mono.canvas), 3)
  }

  /// 高对比主题不靠色相传状态。
  ///
  /// 列表状态点是行里唯一的语义色。绿/橙在有色相的主题里读得出来，但在纯黑白
  /// 主题里既扎眼又违背前提，所以那一套改用实心/空心。这里钉住的是「只有 mono
  /// 换编码方式」，避免以后加主题时顺手抄成 true 把语义色一起丢了。
  func testOnlyMonoThemeEncodesRowStatusByShapeInsteadOfColor() throws {
    XCTAssertTrue(AppearanceTheme.mono.tokens.encodesStatusByShape)
    for theme in AppearanceTheme.allCases where theme != .mono {
      XCTAssertFalse(
        theme.tokens.encodesStatusByShape,
        "\(theme.rawValue) 有色相可用，状态点仍该走绿/橙")
    }
  }

  /// 暖褐是「低对比护眼」，但低对比不等于读不清。
  func testSepiaStaysReadableWhileLoweringContrast() throws {
    let sepia = AppearanceTheme.sepia.tokens
    let paper = AppearanceTheme.paper.tokens
    let sepiaBody = try contrastRatio(sepia.primaryText, sepia.canvas)
    // 正文仍要远超 AA 的 4.5:1。
    XCTAssertGreaterThan(sepiaBody, 7)
    // 但要确实比 paper 柔和——否则「护眼」只是换了个色相而已。
    XCTAssertLessThan(sepiaBody, try contrastRatio(paper.primaryText, paper.canvas))
  }

  /// WCAG 相对亮度对比度。
  private func contrastRatio(
    _ foreground: Color, _ background: Color
  ) throws -> Double {
    let first = try relativeLuminance(foreground)
    let second = try relativeLuminance(background)
    let lighter = max(first, second)
    let darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func relativeLuminance(_ color: Color) throws -> Double {
    let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
    func linear(_ channel: CGFloat) -> Double {
      let value = Double(channel)
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(resolved.redComponent)
      + 0.7152 * linear(resolved.greenComponent)
      + 0.0722 * linear(resolved.blueComponent)
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
    // 组装经渲染缓存进入同一个 composer：内容/字体/配色不变时不重复
    // 解析（性能），排版与连续选择行为不变。
    XCTAssertTrue(source.contains("ReadingRenderCache.attributed("))
    XCTAssertTrue(source.contains("ReadingRenderCache.plainAttributed("))
    let cache = try String(
      contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("ReadingRenderCache.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(cache.contains("ReadingTextComposer.attributed("))
    XCTAssertTrue(cache.contains("ReadingTextComposer.plain("))
    XCTAssertTrue(source.contains("onOpenLink: { url in _ = openValidated(url) }"))
    let selectable = try String(
      contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("SelectableReadingText.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(selectable.contains("isSelectable = true"))
    XCTAssertTrue(selectable.contains("clickedOnLink"))
    XCTAssertTrue(selectable.contains("intrinsicContentSize"))
    // NSTextView 会在 mouseDown 里吃掉 mouseUp；可写正文必须在 mouseDown 进编辑。
    XCTAssertTrue(selectable.contains("override func mouseDown(with event: NSEvent)"))
    XCTAssertTrue(selectable.contains("onRequestEdit(ReadingEditLocator.displayedSnippet"))
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
  }

  /// 内置命名字体在**装了这些字体的机器上**必须真实可解析，否则回退逻辑会悄悄
  /// 吃掉用户的选择：设置里选了楷体，正文还是黑体，而且不报任何错。
  ///
  /// 先查字体家族列表再断言，有两个原因：
  ///
  /// 1. 这是平台假设，不是代码逻辑。CI 的无头 runner 没装中文补充字体，在那里
  ///    断言「Kaiti SC 必须存在」只是在检查 GitHub 的镜像装了什么。
  /// 2. 直接对不存在的字体建 descriptor 会去问字体服务，而无头环境下那次查询
  ///    要跑十几分钟才超时——2026-08-07 CI 上实测**单条测试 1000 秒**，整个
  ///    job 因此撞上 20 分钟上限被掐断。列举家族只要 60 毫秒。
  ///
  /// 上面那条测试管「选择 → 解析」的映射，环境无关、任何机器上都跑。
  func testBundledReadingFontsAreRealFamiliesOnThisMachine() throws {
    let required = ["Songti SC", "Kaiti SC", "PingFang SC"]
    let installed = Set(NSFontManager.shared.availableFontFamilies)
    let missing = required.filter { !installed.contains($0) }
    try XCTSkipUnless(
      missing.isEmpty,
      "这台机器没装 \(missing.joined(separator: "、"))；字体是否随系统安装是平台假设，不由本仓库决定"
    )
    for family in required {
      XCTAssertEqual(
        ResolvedReadingFont.named(family).nsFontDescriptor(size: 16).fontAttributes[.family] as? String,
        family,
        "\(family) 装着却解析不出来，用户的字体选择会被静默回退"
      )
    }
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
    XCTAssertTrue(imaging.contains(".background(Color.white, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))"))
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

  func testRedditCommentsPreserveHierarchyAuthorsAndMetadata() throws {
    let source = """
    正文结尾。

    ## 评论（当前页面已加载 4 / 页面显示 10）

    - **u/thabxi** · score 45 · 2026-08-13T00:50:58.981000+00:00 · [原评论](https://www.reddit.com/r/test/comments/abc/comment/one/)
      第一条评论。
      第二段仍属于第一条。
      - **u/LividCan4323** · score 3 · 2026-08-13T09:49:24.096000+00:00 · [原评论](https://www.reddit.com/r/test/comments/abc/comment/two/)
        回复内容。
        - **u/thabxi** · score 2 · 2026-08-13T09:50:49.642000+00:00
          再次回复。
    - **u/[deleted]** · score 1
      已删除用户的正文仍应保留。
    """

    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 2)
    guard case let .comments(section) = blocks[1] else {
      return XCTFail("评论区应成为独立结构块，实际是 \(blocks[1])")
    }
    XCTAssertEqual(section.countTitle, "评论 4/10")
    XCTAssertEqual(section.progressLabel, "已加载 40%")
    XCTAssertEqual(section.items.count, 4)
    XCTAssertEqual(section.items.map(\.depth), [0, 1, 2, 0])
    XCTAssertEqual(section.items.map(\.parentAuthor), [nil, "thabxi", "LividCan4323", nil])
    XCTAssertEqual(section.items[0].author, "u/thabxi")
    XCTAssertEqual(section.items[0].displayAuthor, "thabxi")
    XCTAssertEqual(section.items[1].displayAuthor, "LividCan4323")
    XCTAssertEqual(section.items[0].score, "45")
    XCTAssertEqual(section.items[0].published, "2026-08-13T00:50:58.981000+00:00")
    XCTAssertEqual(
      section.items[0].permalink,
      URL(string: "https://www.reddit.com/r/test/comments/abc/comment/one/")
    )
    XCTAssertEqual(section.items[0].body, "第一条评论。\n第二段仍属于第一条。")
    XCTAssertEqual(section.items[1].body, "回复内容。")
    XCTAssertEqual(section.items[3].displayAuthor, "已删除用户")
    XCTAssertTrue(section.items[3].body.contains("正文仍应保留"))
  }

  func testTranslatedRedditCommentBodiesRemainACommentTree() {
    let translated = """
    已翻译正文。

    ## 评论（当前页面已加载 3 / 页面显示 3）

    - **u/root** · score 5 · 2026-08-13T00:00:00Z · [原评论](https://www.reddit.com/comments/root/)
      这是已经翻译的根评论。
      - **u/reply** · score 2 · 2026-08-13T01:00:00Z · [原评论](https://www.reddit.com/comments/reply/)
        这是已经翻译的回复。
        - **u/deep** · score 1 · 回复层级 2
          这是第二层回复。
    """

    let blocks = MarkdownPresentation.blocks(from: translated)
    XCTAssertEqual(blocks.count, 2)
    guard case let .comments(section) = blocks[1] else {
      return XCTFail("保留结构元数据的译文必须继续显示为评论树")
    }
    XCTAssertEqual(section.items.map(\.displayAuthor), ["root", "reply", "deep"])
    XCTAssertEqual(section.items.map(\.depth), [0, 1, 2])
    XCTAssertEqual(section.items.map(\.parentAuthor), [nil, "root", "reply"])
    XCTAssertEqual(
      section.items.map(\.body),
      ["这是已经翻译的根评论。", "这是已经翻译的回复。", "这是第二层回复。"]
    )
    XCTAssertEqual(section.items[1].permalink, URL(string: "https://www.reddit.com/comments/reply/"))
  }

  func testCommentSectionStaysAtomicWhenAReplyContainsCachedImage() {
    let remote = "https://preview.redd.it/comment-shot.png"
    let digest = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
    let local = URL(fileURLWithPath: "/tmp/\(digest)")
    let source = """
    正文在评论之前。

    ## 评论（当前页面已加载 3 / 页面显示 3）

    - **u/root** · score 2
      根评论
      - **u/with-image** · score 1
        图片在这条回复里：
        ![截图](\(remote))
    - **u/after-image** · score 1
      图片后的根评论也必须保留层级。
    """

    let segments = LocalMarkdownImageLayout.segments(
      markdown: source,
      localImageURLs: [local],
      appendsUnusedLocalImages: false
    )
    XCTAssertEqual(segments.count, 2)
    guard case let .text(commentTail) = segments[1] else {
      return XCTFail("评论区不应在评论图片处切段")
    }
    let blocks = MarkdownPresentation.blocks(from: commentTail)
    guard case let .comments(section) = blocks.first else {
      return XCTFail("完整评论尾段应继续进入结构化评论组件")
    }
    XCTAssertEqual(section.items.map(\.author), ["u/root", "u/with-image", "u/after-image"])
    XCTAssertEqual(section.items.map(\.depth), [0, 1, 0])
    XCTAssertTrue(section.items[1].body.contains(remote))
    XCTAssertEqual(
      LocalMarkdownImageLayout.segments(
        markdown: section.items[1].body,
        localImageURLs: [local],
        appendsUnusedLocalImages: false
      ).compactMap { segment in
        if case let .image(url) = segment { return url }
        return nil
      },
      [local]
    )
  }

  func testOrdinaryParenthesizedCommentHeadingDoesNotDisableImageLayout() {
    let remote = "https://example.test/ordinary.png"
    let digest = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
    let local = URL(fileURLWithPath: "/tmp/\(digest)")
    let source = """
    ## 评论（写作示例）

    - **重要结论**

    ![普通正文图片](\(remote))
    """
    let segments = LocalMarkdownImageLayout.segments(
      markdown: source,
      localImageURLs: [local],
      appendsUnusedLocalImages: false
    )
    XCTAssertTrue(segments.contains(.image(local)))
  }

  func testCommentDepthLabelRestoresLevelsBeyondMarkdownIndentCap() {
    let source = """
    ## 评论（当前页面已加载 2）

    - **u/root** · score 1
      根评论
                - **u/deep** · score 1 · 回复层级 8
                  深层回复
    """
    let blocks = MarkdownPresentation.blocks(from: source)
    guard case let .comments(section) = blocks.first else {
      return XCTFail("expected comment section")
    }
    XCTAssertEqual(section.items.map(\.depth), [0, 8])
    XCTAssertEqual(section.items[1].parentAuthor, "root")
  }

  func testOrdinaryCommentHeadingAndBoldListRemainOrdinaryMarkdown() {
    let blocks = MarkdownPresentation.blocks(from: "## 评论\n\n- **重要结论**\n- 普通列表")
    XCTAssertEqual(blocks.count, 2)
    guard case .heading = blocks[0] else { return XCTFail("标题不应被误判为结构化评论") }
    guard case let .list(items) = blocks[1] else { return XCTFail("普通列表不应被评论解析器接管") }
    XCTAssertEqual(items.count, 2)
  }

  func testBoldBulletInsideRedditCommentBodyDoesNotBecomeAUser() {
    let source = """
    ## 评论（当前页面已加载 1）

    - **u/root** · score 2
      这是一条评论。
      - **重点结论**
      - 普通子项
    """
    let blocks = MarkdownPresentation.blocks(from: source)
    guard case let .comments(section) = blocks.first else { return XCTFail("expected comments") }
    XCTAssertEqual(section.items.count, 1)
    XCTAssertTrue(section.items[0].body.contains("**重点结论**"))
    XCTAssertTrue(section.items[0].body.contains("普通子项"))
  }

  func testCommentPublishedTimeUsesCompactChineseRelativeLabels() {
    let raw = "2026-08-13T00:00:00+00:00"
    let published = ISO8601DateFormatter().date(from: raw)!
    XCTAssertEqual(
      CommentPublishedTime.relativeLabel(raw, now: published.addingTimeInterval(3 * 86_400)),
      "3 天前"
    )
    XCTAssertEqual(CommentPublishedTime.relativeLabel("3 days ago", now: published), "3 days ago")
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

  func testEscapedPipeStaysInsideOneTableCell() {
    let blocks = MarkdownPresentation.blocks(from: """
      | 命令 | 用途 |
      | --- | --- |
      | ps \\| grep swift | 查进程 |
      """)
    guard case let .table(headers, rows) = blocks[0] else { return XCTFail("应当是表格") }
    XCTAssertEqual(headers, ["命令", "用途"])
    XCTAssertEqual(rows, [["ps | grep swift", "查进程"]])
  }

  /// 反斜杠本身不是转义符，只有 `\|` 是。否则正则和 Windows 路径会被吃掉字符。
  func testLoneBackslashInCellSurvives() {
    let blocks = MarkdownPresentation.blocks(from: """
      | 模式 | 说明 |
      | --- | --- |
      | \\d+ | 数字 |
      """)
    guard case let .table(_, rows) = blocks[0] else { return XCTFail("应当是表格") }
    XCTAssertEqual(rows, [["\\d+", "数字"]])
  }

  /// 有序列表要保留原文的起始编号。
  ///
  /// 渲染侧原本按数组下标重编（`index + 1`），抽取侧刚按 `<ol start>` 算好的
  /// `3.` 到了阅读区就变回 `1.`——真实 App 里实测到的就是这个。
  func testOrderedListKeepsItsOriginalStartNumber() {
    let blocks = MarkdownPresentation.blocks(from: "3. 第三步\n4. 第四步")
    XCTAssertEqual(blocks, [.orderedList(start: 3, items: ["第三步", "第四步"])])
  }

  /// 没写起始编号时仍从 1 起。
  func testOrderedListWithoutExplicitStartBeginsAtOne() {
    let blocks = MarkdownPresentation.blocks(from: "1. 甲\n2. 乙")
    XCTAssertEqual(blocks, [.orderedList(start: 1, items: ["甲", "乙"])])
  }

  func testBlocksRecognizeOrderedLists() {
    let blocks = MarkdownPresentation.blocks(from: "1. 第一步\n2. **第二步**")
    XCTAssertEqual(blocks, [.orderedList(start: 1, items: ["第一步", "**第二步**"])])
  }

  /// 代码里的尖括号是字面量。整篇当 HTML 洗会把开发文变成「已省略 HTML 片段」。
  func testSanitizerKeepsAngleBracketsInsideFencedAndInlineCode() {
    let source = """
    正文 `<task>` 是标签名。

    ```xml
    <task>
    hello
    </task>
    ```

    后面还有 <script>alert(1)</script>。
    """
    let plain = MarkdownPresentation.plainTextPresentation(source)
    XCTAssertTrue(plain.contains("`<task>`"))
    XCTAssertTrue(plain.contains("<task>"))
    XCTAssertTrue(plain.contains("</task>"))
    XCTAssertFalse(plain.contains("<script>"))
    XCTAssertTrue(plain.contains(MarkdownPresentation.omittedHTML))

    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 3)
    guard case let .paragraph(paragraph) = blocks[0] else { return XCTFail("expected paragraph \(blocks[0])") }
    XCTAssertTrue(paragraph.contains("`<task>`"))
    XCTAssertFalse(paragraph.contains(MarkdownPresentation.omittedHTML))
    guard case let .code(_, content) = blocks[1] else { return XCTFail("expected fenced code \(blocks[1])") }
    XCTAssertTrue(content.contains("<task>"))
    XCTAssertTrue(content.contains("</task>"))
    guard case let .paragraph(after) = blocks[2] else { return XCTFail("expected trailing paragraph") }
    XCTAssertTrue(after.contains(MarkdownPresentation.omittedHTML))
    XCTAssertFalse(after.contains("<script>"))
  }

  /// 没闭合的围栏不能整段当代码，否则截断的 `<script>` 会漏到屏幕上。
  func testUnclosedFenceStillOmitsHTMLLikeTokens() {
    let source = "```\n<script>alert(1)</script>\n还在围栏里"
    let plain = MarkdownPresentation.plainTextPresentation(source)
    XCTAssertTrue(plain.contains(MarkdownPresentation.omittedHTML))
    XCTAssertFalse(plain.contains("<script>"))
  }

  func testGFMTableBecomesItsOwnBlock() {
    let source = """
    前面一段。

    | 维度 | 传统SEO | GEO |
    | --- | --- | --- |
    | 目标 | 搜索引擎排名 | 成为 AI 引用源 |
    | 内容 | 关键词优化 | 结构化、可引用 |

    后面一段。
    """
    let blocks = MarkdownPresentation.blocks(from: source)
    XCTAssertEqual(blocks.count, 3)
    guard case let .paragraph(before) = blocks[0] else { return XCTFail("expected lead paragraph") }
    XCTAssertTrue(before.contains("前面一段"))
    guard case let .table(headers, rows) = blocks[1] else { return XCTFail("expected table \(blocks[1])") }
    XCTAssertEqual(headers, ["维度", "传统SEO", "GEO"])
    XCTAssertEqual(rows, [
      ["目标", "搜索引擎排名", "成为 AI 引用源"],
      ["内容", "关键词优化", "结构化、可引用"],
    ])
    guard case let .paragraph(after) = blocks[2] else { return XCTFail("expected trailing paragraph") }
    XCTAssertTrue(after.contains("后面一段"))
  }

  func testCalloutIsDistinctFromOrdinaryQuote() {
    let callout = MarkdownPresentation.blocks(from: """
    > [!WARNING]
    > 不要把密钥写进仓库。
    """)
    XCTAssertEqual(callout.count, 1)
    guard case let .callout(kind, text) = callout[0] else { return XCTFail("expected callout \(callout[0])") }
    XCTAssertEqual(kind, "warning")
    XCTAssertTrue(text.contains("不要把密钥写进仓库"))

    let quote = MarkdownPresentation.blocks(from: "> 引用一句结论。")
    XCTAssertEqual(quote, [.quote("引用一句结论。")])
  }

  func testReadingEditLocatorMapsDisplayedSnippetToSourceOffset() {
    let source = "申哥的公司已经从项目型转向了未来"
    let offset = ReadingEditLocator.caretUTF16Offset(in: source, displayedSnippet: "哥的公司已经从项目")
    XCTAssertGreaterThan(offset, 0)
    let index = source.utf16.index(source.utf16.startIndex, offsetBy: offset)
    let tail = String(source[index...])
    XCTAssertTrue(tail.contains("公司"), "光标应落在点到的那一段，而不是文首")

    XCTAssertEqual(ReadingEditLocator.caretUTF16Offset(in: source, displayedSnippet: nil), 0)
    XCTAssertEqual(ReadingEditLocator.caretUTF16Offset(in: source, displayedSnippet: "x"), 0)

    let around = ReadingEditLocator.displayedSnippet(in: source, utf16Index: 2, radius: 2)
    XCTAssertTrue(around.contains("申") || around.contains("哥"))
  }

  func testStreamingTextUpdateReturnsOnlyTheAppendedUTF16Suffix() {
    XCTAssertEqual(
      StreamingTextUpdate.appendedSuffix(previous: "第一段🙂", next: "第一段🙂第二段"),
      "第二段"
    )
    XCTAssertEqual(
      StreamingTextUpdate.appendedSuffix(previous: "相同", next: "相同"),
      ""
    )
    XCTAssertNil(
      StreamingTextUpdate.appendedSuffix(previous: "旧内容", next: "新内容")
    )
  }

  func testWikiLinksBecomeInAppMarkdownLinksAndStayOutOfCode() throws {
    let rewritten = MarkdownPresentation.rewritingWikiLinksAsMarkdown(
      "见 [[知识库构建]] 与 `[[字面量]]`"
    )
    XCTAssertTrue(rewritten.contains("](\(WikiLinkURL.url(forTitle: "知识库构建").absoluteString))"))
    XCTAssertTrue(rewritten.contains("`[[字面量]]`"))
    XCTAssertFalse(rewritten.contains("[[知识库构建]]"))

    let attributed = MarkdownPresentation.inlineAttributed("见 [[知识库构建]]")
    var found: URL?
    for run in attributed.runs {
      if let link = run.link { found = link }
    }
    XCTAssertEqual(WikiLinkURL.title(from: try XCTUnwrap(found)), "知识库构建")
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

    // 公众号相邻图中间只有空行，不能并成两列。
    XCTAssertEqual(
      LocalMarkdownImageLayout.galleryGrouped(
        [.text("# 标题\n\n"), .image(a), .text("\n\n"), .image(b), .text("\n\n"), .image(c)],
        groupsConsecutiveImages: false
      ),
      [.text("# 标题\n\n"), .image(a), .text("\n\n"), .image(b), .text("\n\n"), .image(c)]
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

  /// 长文阅读面板冷渲染成本的回归护栏：块解析、富文本组装、TextKit 全文
  /// 排版三段分别计时。库里最长条目约 7.3 万字，切换阅读页签时整棵面板
  /// 视图树销毁重建，这些成本逐段全量重付——预算取实测的宽松上限，
  /// 主要防的是数量级回退（如解析退回 O(n²)），不是防 10% 的抖动。
  @MainActor
  func testLongDocumentColdRenderCostStaysWithinBudget() {
    var paragraphs: [String] = []
    var characters = 0
    let sentence = "这是一段用于性能护栏的合成正文，模拟真实长文的密度与标点分布，内容本身没有意义。"
    while characters < 73_000 {
      if paragraphs.count % 12 == 0 {
        paragraphs.append("## 第\(paragraphs.count / 12 + 1) 节 标题")
        paragraphs.append(sentence + sentence)
      } else if paragraphs.count % 12 == 7 {
        paragraphs.append("- 要点一：" + sentence)
        paragraphs.append("- 要点二：" + sentence)
        paragraphs.append("- 要点三：" + sentence)
      } else if paragraphs.count % 12 == 10 {
        paragraphs.append("> 引用：" + sentence)
      } else {
        paragraphs.append(sentence + sentence + sentence)
      }
      characters = paragraphs.joined().count
    }
    let source = paragraphs.joined(separator: "\n\n")
    XCTAssertGreaterThan(source.count, 70_000, "合成文档要达到真实最长条目的量级")

    let parseStart = CFAbsoluteTimeGetCurrent()
    let blocks = MarkdownPresentation.blocks(from: source)
    let parseElapsed = CFAbsoluteTimeGetCurrent() - parseStart

    let composeStart = CFAbsoluteTimeGetCurrent()
    let attributed = ReadingTextComposer.attributed(
      blocks: blocks,
      readingFont: .sans,
      palette: .init(primary: .black, secondary: .darkGray, accent: .blue)
    )
    let composeElapsed = CFAbsoluteTimeGetCurrent() - composeStart

    let layoutStart = CFAbsoluteTimeGetCurrent()
    let storage = NSTextStorage(attributedString: attributed)
    let manager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(width: 590, height: CGFloat.greatestFiniteMagnitude)
    )
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    _ = manager.usedRect(for: container)
    let layoutElapsed = CFAbsoluteTimeGetCurrent() - layoutStart

    print(
      "long-document cold render: parse \(String(format: "%.0f", parseElapsed * 1000))ms, "
        + "compose \(String(format: "%.0f", composeElapsed * 1000))ms, "
        + "layout \(String(format: "%.0f", layoutElapsed * 1000))ms"
    )
    // 宽松预算：三段合计留给 CI 机器与本地差异的余量。
    XCTAssertLessThan(parseElapsed, 1.0, "块解析回退到秒级")
    XCTAssertLessThan(composeElapsed, 1.0, "富文本组装回退到秒级")
    XCTAssertLessThan(layoutElapsed, 1.0, "TextKit 全文排版回退到秒级")
  }
}
