import XCTest
import AppKit
@testable import LinkDigestApp

final class SourceCaptionPresentationTests: XCTestCase {
  func testRealCaptionOpeningSurvivesForIndependentTitlePlatforms() {
    let title = "一间温暖的房子"
    let body = title + "\n\n保留作者的描述与 #空间设计\n\n![](https://example.test/image.jpg)"
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: title, from: body, style: .stripSyntheticTitleHeadingOnly
    ), body)
  }

  func testGeneratedHeadingIsRemovedWithoutDeletingCaptionOrMedia() {
    let body = "# 视频标题\n\n视频标题\n补充介绍。\n\n![封面](https://example.test/cover.jpg)"
    let rendered = CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: "视频标题", from: body, style: .stripSyntheticTitleHeadingOnly
    )
    XCTAssertEqual(rendered, "视频标题\n补充介绍。\n\n![封面](https://example.test/cover.jpg)")
  }

  func testHashtagCaptionIsNotAHeading() {
    let body = "#家居\n今天的新发现"
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: "家居", from: body, style: .stripSyntheticTitleHeadingOnly
    ), body)
  }
  func testLegacySoleHeadingAndWhitespaceDoNotRepeat() {
    let name = CapturedContentNaming.Name(text: "Hello  world", origin: .caption)
    XCTAssertTrue(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "# Hello  world"))
    XCTAssertTrue(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "Hello world"))
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "Hello world\nMore details"))
  }

  func testCaptionLineBreaksSeparateTopicsAndMixedLanguage() {
    let source = "沉静之旅\n#海瑞温斯顿\nUltimate 胸针搭配\nOcean 腕表"
    let displayed = CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "xiaohongshu")
    let blocks = MarkdownPresentation.blocks(from: displayed)
    XCTAssertEqual(blocks.count, 1)
    guard let first = blocks.first, case let .paragraph(text) = first else { return XCTFail("Caption paragraph missing") }
    XCTAssertEqual(text, source)
    XCTAssertEqual(String(MarkdownPresentation.inlineAttributed(text).characters), source)
    XCTAssertEqual(CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "github"), source)
  }

  /// 「• 要点」写的列表转成 Markdown 列表，每条一行；推文也保留作者的换行（2026-10-01）。
  func testSymbolBulletsBecomeListItems() {
    let source = "它只做推荐：\n\n• 两阶段过滤：先筛描述\n• 安全隔离：独立运行\n· 低成本\n\n张三 · 李四"
    let displayed = CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "x")
    XCTAssertTrue(displayed.contains("- 两阶段过滤：先筛描述\n- 安全隔离：独立运行\n- 低成本"))
    XCTAssertTrue(displayed.contains("张三 · 李四"), "行中间的间隔号不动")
    XCTAssertEqual(
      CapturedSourceBodyPresentation.preservingCaptionParagraphs("• 一\n• 二", platform: "github"),
      "- 一\n- 二"
    )
    XCTAssertNil(CapturedSourceBodyPresentation.symbolBulletItem("•"))
    XCTAssertNil(CapturedSourceBodyPresentation.symbolBulletItem("```•"))
  }

  /// 推文配文：说完一句就分段，序号行成编号列表，横线行成分隔线（2026-10-03 走查）。
  func testSocialCaptionGetsParagraphsListsAndDividers() {
    let source = """
    卧槽，原子弹，瘫坐，爆炸。
    这tm是opus5.5自己剪的vlog，我真的只是试试，全程开着action瞎录，然后把资料给到它，提示词如下：
    「文件目录：自媒体项目-vlog/vlog02-汕头day1
    1.帮我把这些录制的内容剪辑成一段vlog。
    2.你需要根据我们聊天的内容，梳理出一个主题
    ————————
    然后，打着游戏呢，来看看进度。
    诸位自己看吧，人类剩下的阵地还有什么？
    """
    let blocks = MarkdownPresentation.blocks(
      from: CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "x")
    )
    let kinds = blocks.map { block -> String in
      switch block {
      case .paragraph: "p"
      case .orderedList: "ol"
      case .divider: "hr"
      default: "other"
      }
    }
    XCTAssertEqual(kinds, ["p", "p", "p", "ol", "hr", "p", "p"])
    if case let .orderedList(_, items) = blocks[3] {
      XCTAssertEqual(items.count, 2)
    }
    XCTAssertNil(CapturedSourceBodyPresentation.numberedCaptionItem("3.5 倍速播放"))
    XCTAssertEqual(CapturedSourceBodyPresentation.numberedCaptionItem("2、梳理主题"), "2. 梳理主题")
  }

  func testCommentAuthorSplitsNameAndHandle() {
    XCTAssertEqual(CommentThreadSectionView.splitAuthor("Panda | AI Agent @PandaAINative").name, "Panda | AI Agent")
    XCTAssertEqual(CommentThreadSectionView.splitAuthor("Panda | AI Agent @PandaAINative").handle, "@PandaAINative")
    XCTAssertEqual(CommentThreadSectionView.splitAuthor("WZH @wzh_cc").handle, "@wzh_cc")
    XCTAssertEqual(CommentThreadSectionView.splitAuthor("dotey @dotey").name, "@dotey")
    XCTAssertNil(CommentThreadSectionView.splitAuthor("u/thabxi").handle)
  }

  func testCommentAuthorBadgeMatchesPostAuthor() {
    let post = "大师的AI小灶 (@dashiAIxz)"
    XCTAssertTrue(CommentThreadSectionView.isPostAuthor("大师的AI小灶 @dashiAIxz", postAuthor: post))
    XCTAssertTrue(CommentThreadSectionView.isPostAuthor("改了昵称 @DashiAIxz", postAuthor: post), "账号一样就算，昵称可以改")
    XCTAssertFalse(CommentThreadSectionView.isPostAuthor("WZH @wzh_cc", postAuthor: post))
    XCTAssertTrue(CommentThreadSectionView.isPostAuthor("阿强", postAuthor: "阿强"), "抖音这类只有昵称")
    XCTAssertFalse(CommentThreadSectionView.isPostAuthor("阿强", postAuthor: nil))
  }

  /// 标题取自配文首句且显示在上方时，配文不再从同一句开始；只是前半句时不动。
  func testLeadingLineMatchingTitleIsStripped() {
    let body = "卧槽，原子弹，瘫坐，爆炸。\n这tm是opus5.5自己剪的vlog"
    XCTAssertEqual(
      CapturedSourceBodyPresentation.strippingLeadingLine(body, equalTo: "卧槽，原子弹，瘫坐，爆炸。"),
      "这tm是opus5.5自己剪的vlog"
    )
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingLeadingLine(body, equalTo: "卧槽"), body)
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingLeadingLine("只有一句。", equalTo: "只有一句。"), "只有一句。")
  }

  func testCaptionFormattingKeepsCodeAndImagesIntact() {
    let source = "配文\n```text\nline one\nline two\n```\n![](https://example.test/image.jpg)"
    let displayed = CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "douyin")
    XCTAssertTrue(displayed.contains("```text\nline one\nline two\n```"))
    XCTAssertTrue(displayed.contains("![](https://example.test/image.jpg)"))
  }

  func testReaderDatesKeepOriginalPrecisionAndWallClock() {
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-09-06 10:00:45"), "2026年9月6日 10:00")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-09-06"), "2026年9月6日")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-02-31"), "2026-02-31")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text(nil), "发布时间未获取")
  }

  func testHardBreakDoesNotAddAnotherParagraphGap() {
    let composed = ReadingTextComposer.attributed(
      blocks: [.paragraph("配文第一行\n#话题第二行"), .paragraph("下一段")],
      readingFont: .sans,
      palette: .init(primary: .black, secondary: .darkGray, accent: .blue)
    )
    XCTAssertEqual(composed.string, "配文第一行\u{2028}#话题第二行\n下一段\n")
  }

  /// 字幕段：长段在句末拆开、中文之间的空格去掉；其它段落原样不动（2026-10-03）。
  func testTranscriptSectionBecomesReadableParagraphs() {
    let sentence = "上大学那会儿，我是学政务专业的，意味着我得写很多论文。"
    let wall = String(repeating: sentence, count: 12) + "当一名普通的学生写论文时， 他们也许会像这样， 把任务分摊开。"
    let intro = "这是简介里很长的一段话，不属于字幕，也不该被拆开。" + String(repeating: "简介", count: 120)
    let markdown = "## 简介\n\n\(intro)\n\n## 字幕\n\n\(wall)"
    let result = CapturedSourceBodyPresentation.readableTranscriptSections(markdown)
    let blocks = result.components(separatedBy: "\n\n")
    XCTAssertTrue(blocks.contains(intro), "非字幕段不动")
    let transcript = blocks.drop(while: { $0 != "## 字幕" }).dropFirst()
    XCTAssertGreaterThan(transcript.count, 2, "长段被拆开")
    XCTAssertTrue(transcript.allSatisfy { $0.count < 260 })
    XCTAssertTrue(transcript.allSatisfy { $0.hasSuffix("。") }, "在句末拆")
    XCTAssertTrue(result.contains("像这样，把任务分摊开"), "中文之间的空格去掉")
  }

  func testEnglishTranscriptKeepsWordSpaces() {
    let english = String(repeating: "This is a sentence about procrastination and deadlines. ", count: 30)
    let result = CapturedSourceBodyPresentation.readableTranscriptSections("## 字幕\n\n" + english)
    XCTAssertTrue(result.contains("about procrastination and deadlines."))
    XCTAssertGreaterThan(result.components(separatedBy: "\n\n").count, 2)
  }

  /// 引用式链接改写成行内链接，定义行藏掉；代码里的同形文字不动（2026-10-04 走查 GitHub README）。
  func testReferenceLinksAreInlinedAndDefinitionsHidden() {
    let body = """
    Based on [The Elm Architecture][elm]. See the [examples][] and ![demo][img].
    Paradigms of [The Elm
    Architecture][elm] wrap across lines.
    Unknown [label][missing] stays. Code `x[a][elm]` stays.

    ```go
    m[i][elm]
    ```

    [elm]: https://guide.elm-lang.org/architecture/
    [Examples]: https://github.com/x/examples "Examples"
    [img]: <https://x.test/a.gif>
    """
    let result = CapturedSourceBodyPresentation.inliningReferenceLinks(body)
    XCTAssertTrue(result.contains("[The Elm Architecture](https://guide.elm-lang.org/architecture/)"), result)
    XCTAssertTrue(result.contains("[examples](https://github.com/x/examples)"), result)
    XCTAssertTrue(result.contains("[The Elm\nArchitecture](https://guide.elm-lang.org/architecture/) wrap"), result)
    XCTAssertTrue(result.contains("![demo](https://x.test/a.gif)"), result)
    XCTAssertTrue(result.contains("Unknown [label][missing] stays."), result)
    XCTAssertTrue(result.contains("`x[a][elm]`"), result)
    XCTAssertTrue(result.contains("m[i][elm]"), result)
    XCTAssertFalse(result.contains("[elm]: https"), result)
    XCTAssertEqual(CapturedSourceBodyPresentation.inliningReferenceLinks("没有定义的正文 [a][b]"), "没有定义的正文 [a][b]")
  }

  /// 备忘录截短的标题按正文第一行还原（2026-10-04 走查：截短标题下面又是同一句完整版）。
  func testTruncatedNoteTitleExpandsToItsFirstLine() {
    let body = "# 每一套课程都应该有逻辑和技法两个方面。所以，然后借助AI构建出任何一个赛道的解决方案。\n\n正文"
    let expanded = CapturedSourceBodyPresentation.expandedTruncatedTitle("每一套课程都应该有逻辑和技法两个方面。所以，然后借助AI构建…", firstLines: body)
    XCTAssertEqual(expanded, "每一套课程都应该有逻辑和技法两个方面。所以，然后借助AI构建出任何一个赛道的解决方案。")
    XCTAssertEqual(
      CapturedSourceBodyPresentation.strippingEchoedOpening(title: expanded, from: body, style: .stripSyntheticTitleHeadingOnly),
      "正文"
    )
    // 不是截短的、对不上的、第一行太长的，都保持原标题。
    XCTAssertEqual(CapturedSourceBodyPresentation.expandedTruncatedTitle("完整标题", firstLines: body), "完整标题")
    XCTAssertEqual(CapturedSourceBodyPresentation.expandedTruncatedTitle("另外一句话完全不同的开头…", firstLines: body), "另外一句话完全不同的开头…")
    let long = "# 每一套课程都应该有逻辑" + String(repeating: "字", count: 200)
    XCTAssertEqual(CapturedSourceBodyPresentation.expandedTruncatedTitle("每一套课程都应该有逻辑…", firstLines: long), "每一套课程都应该有逻辑…")
  }

  func testBackNavigationLinkBlocksAreHidden() {
    let body = "[Back to All Articles](https://arena.ai/blog)\n\n![cover](https://x.test/a.png)\n\n正文里的[返回](/x)链接留着。"
    let result = CapturedSourceBodyPresentation.strippingBackNavigationLinks(body)
    XCTAssertFalse(result.contains("Back to All Articles"))
    XCTAssertTrue(result.contains("正文里的[返回](/x)链接留着。"))
    XCTAssertTrue(result.contains("![cover]"))
  }
}

