import XCTest
@testable import LinkDigestCore

final class LayeredSourceDocumentTests: XCTestCase {
  func testModelInputKeepsCaptionAndTranscriptAsSeparateSections() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID,
      sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "---\nauthor: \"Linas\"\n---\n\n今晚别刷 Netflix。"
    )
    let transcript = snapshot(
      taskID: taskID,
      sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "00:00 这是讲座转写。"
    )

    let input = LayeredSourceDocument.modelInput(from: [caption, transcript])
    XCTAssertTrue(input.contains("## 配文"))
    XCTAssertTrue(input.contains("今晚别刷 Netflix。"))
    XCTAssertTrue(input.contains("## 视频转写"))
    XCTAssertTrue(input.contains("00:00 这是讲座转写。"))
    XCTAssertFalse(input.contains("author:"))
  }

  func testNeedsTranslationIfCaptionIsNotTargetLanguageEvenWhenTranscriptIs() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID,
      sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "Instead of watching Netflix tonight, watch this Stanford lecture."
    )
    let transcript = snapshot(
      taskID: taskID,
      sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "这是一段很长的中文转写内容，用来确认中文已经占主导。"
    )
    XCTAssertTrue(
      LayeredSourceDocument.needsTranslation(
        from: [caption, transcript],
        outputLanguage: "简体中文"
      )
    )
    XCTAssertFalse(
      LayeredSourceDocument.needsTranslation(
        from: [transcript],
        outputLanguage: "简体中文"
      )
    )
  }

  /// 2026-10-14 Syc 的 0.3.5 截图：X 视频帖，中文配文 + 英文转写 + 校对稿（英文正文里夹中文小标题）。
  /// 任一层不是中文就该提供翻译；校对稿里几行中文标题不能把整层带成「已经是中文」。
  func testChineseCaptionWithEnglishTranscriptAndProofreadStillNeedsTranslation() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID, sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "---\nauthor: \"小樱\"\n---\n\nAnthropic CEO 回答了大家最关心的问题：现在还能学编程吗？编程会最先被淘汰，下面是他的原话整理。"
    )
    let english = String(
      repeating: "A bunch of people at Anthropic write code. And so, you know, we may have special insight into how to best use the AI model. ",
      count: 6
    )
    let machine = snapshot(
      taskID: taskID, sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "00:00 " + english, captureMethod: "speech_analyzer_local"
    )
    let proofread = snapshot(
      taskID: taskID, sequence: 3,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "## 编程会怎样\n\n00:00 " + english + "\n\n## 什么行业还有跑道\n\n01:10 " + english + "\n\n## 创业今天该学什么\n\n02:20 " + english,
      captureMethod: "openai_compatible_chat_tidy"
    )
    // 只有中文配文：已经是中文，不用翻译。
    XCTAssertFalse(LayeredSourceDocument.needsTranslation(from: [caption], outputLanguage: "简体中文"))
    // 加上英文转写、再加校对稿：要翻译。
    XCTAssertTrue(LayeredSourceDocument.needsTranslation(from: [caption, machine], outputLanguage: "简体中文"))
    XCTAssertTrue(LayeredSourceDocument.needsTranslation(from: [caption, machine, proofread], outputLanguage: "简体中文"))
    // 阅读页和翻译读的转写层是校对稿（最新的一份），不是机器稿。
    XCTAssertEqual(LayeredSourceDocument.transcriptSnapshot(in: [caption, machine, proofread])?.id, proofread.id)
  }

  private func snapshot(
    taskID: TaskID,
    sequence: Int,
    sourceKind: String,
    body: String,
    captureMethod: String = "page"
  ) -> ContentSnapshot {
    ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: taskID,
      sequence: sequence,
      envelopeCreatedAtMilliseconds: 1,
      capturedAtMilliseconds: 1,
      sourceKind: sourceKind,
      sourceURL: "https://x.com/fixture/status/1",
      title: "fixture",
      platform: "x",
      captureMethod: captureMethod,
      completeness: "complete",
      bodyText: body,
      characterCount: body.unicodeScalars.count,
      bodySHA256: String(repeating: "a", count: 64),
      sourceLabel: "fixture",
      usedCookie: false
    )
  }
  /// 画面字幕是**派生层**，不能被当成配文。
  ///
  /// `captionSnapshot` 靠「不是派生层」来认配文。新来源一旦漏登记到
  /// `derivedKinds`，它就会顶替真正的配文——原配文再也取不到，作者、发布时间
  /// 这些只有配文才有的字段跟着一起消失，而且全程不报错。
  func testBurnedInSubtitlesAreNotMistakenForTheCaption() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID,
      sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "---\nauthor: \"某作者\"\n---\n\n原始配文。"
    )
    let subtitles = snapshot(
      taskID: taskID,
      sequence: 2,
      sourceKind: CapturedDocument.Origin.burnedInSubtitles.rawValue,
      body: "画面上烧录的字幕。"
    )
    let snapshots = [caption, subtitles]

    XCTAssertEqual(LayeredSourceDocument.captionSnapshot(in: snapshots)?.id, caption.id)
    // 字幕层已下线（2026-10-07）：旧快照留在库里，但不再作为一层取出。
    XCTAssertNil(LayeredSourceDocument.subtitleSnapshot(in: snapshots))
    XCTAssertTrue(
      LayeredSourceDocument.derivedKinds.contains(CapturedDocument.Origin.burnedInSubtitles.rawValue),
      "新的派生来源必须登记到 derivedKinds"
    )
  }

  /// 旧记录里还存着画面字幕时，发给模型的只有配文和视频转写（2026-10-07 字幕层下线）。
  func testLegacySubtitlesStayOutOfModelInput() {
    let taskID = TaskID()
    let snapshots = [
      snapshot(taskID: taskID, sequence: 1,
               sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
               body: "配文正文。"),
      snapshot(taskID: taskID, sequence: 2,
               sourceKind: CapturedDocument.Origin.burnedInSubtitles.rawValue,
               body: "字幕正文。"),
      snapshot(taskID: taskID, sequence: 3,
               sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
               body: "听写正文。")
    ]
    let input = LayeredSourceDocument.modelInput(from: snapshots)
    XCTAssertEqual(input, "## 配文\n\n配文正文。\n\n## 视频转写\n\n听写正文。")
    XCTAssertFalse(input.contains(LayeredSourceDocument.subtitleHeading))
    XCTAssertFalse(input.contains("字幕正文。"))
  }

  /// 只有一层时不加标题。给孤零零一段正文扣顶「## 配文」是纯噪声，
  /// 这个行为在加入第三层之前就有，不能因为重构而变。
  func testSingleLayerKeepsNoHeading() {
    let taskID = TaskID()
    let only = snapshot(
      taskID: taskID,
      sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "就这一段。"
    )
    let input = LayeredSourceDocument.modelInput(from: [only])
    XCTAssertEqual(input, "就这一段。")
    XCTAssertFalse(input.contains("##"))
  }

  // MARK: - split：把 modelInput 拼出去的文档拆回各层
  //
  // 这个拆分是翻译页分层显示的地基：翻译是整份文档一次翻完的，译文里同样带着
  // 「## 配文 / ## 画面字幕 / ## 视频转写」。拆错的表现很隐蔽——要么切换控件里
  // 少一层（那层内容直接看不到），要么正文被从中间截断。

  // 最重要的一条：modelInput 拼出去的，split 必须能原样拆回来。两者是一对，
  // 任何一边改了格式而另一边没跟上，翻译页就会退化成整篇平铺。
  func testSplitRoundTripsWhatModelInputComposes() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID, sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "配文第一段。\n\n配文第二段。"
    )
    let transcript = snapshot(
      taskID: taskID, sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "00:00 转写第一句。\n\n00:13 转写第二句。"
    )
    let composed = LayeredSourceDocument.modelInput(from: [caption, transcript])
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(
      layers.map(\.heading),
      [LayeredSourceDocument.captionHeading, LayeredSourceDocument.transcriptHeading]
    )
    XCTAssertTrue(layers[0].body.contains("配文第二段。"), "层内容被截断了")
    XCTAssertTrue(layers[1].body.contains("00:13 转写第二句。"))
  }

  // 只有一层时 modelInput 故意不加标题。拆分要原样返回、heading 为 nil——
  // 调用方靠这个判断「不显示切换控件，整篇渲染」。
  func testUnlabelledDocumentStaysAsOneAnonymousLayer() {
    let layers = LayeredSourceDocument.split("就是一段普通正文，没有任何小标题。")
    XCTAssertEqual(layers.count, 1)
    XCTAssertNil(layers[0].heading)
    XCTAssertEqual(layers[0].body, "就是一段普通正文，没有任何小标题。")
  }

  // 正文里出现同名的普通句子不能被当成分层点。「视频转写」这四个字在译文里
  // 完全可能作为一句话出现，只有整行的 `## 视频转写` 才算标题。
  func testOnlyRealHeadingLinesSplit() {
    let composed = """
      ## \(LayeredSourceDocument.captionHeading)

      这条记录的视频转写还没跑完。

      提到 \(LayeredSourceDocument.transcriptHeading) 的时候不该断开。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.count, 1)
    XCTAssertEqual(layers[0].heading, LayeredSourceDocument.captionHeading)
    XCTAssertTrue(layers[0].body.contains("不该断开"))
  }

  // 不认识的二级标题（模型自己加的、或正文本来就有的）必须留在正文里。
  // 吃掉的表现是译文凭空少一段。
  func testUnknownHeadingsStayInTheBody() {
    let composed = """
      ## \(LayeredSourceDocument.captionHeading)

      开头。

      ## 模型自己加的小标题

      这段必须留着。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.count, 1)
    XCTAssertTrue(layers[0].body.contains("## 模型自己加的小标题"))
    XCTAssertTrue(layers[0].body.contains("这段必须留着。"))
  }

  // 空层不产出：标题下面什么都没有时，多给一个空档只会让切换控件多一个死项。
  func testEmptySectionsAreDropped() {
    let composed = """
      ## \(LayeredSourceDocument.captionHeading)

      ## \(LayeredSourceDocument.transcriptHeading)

      有内容。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.map(\.heading), [LayeredSourceDocument.transcriptHeading])
  }

  // 真实译文的形状：开头有一行翻译过来的标题，然后才是 `## 配文`。
  //
  // 这一条是补出来的。原来的往返测试只喂 `modelInput` 的输出（没有标题行），
  // 于是没覆盖到这个形状——翻译页的分层控件因此一次都没出现过，译文照旧纵向
  // 叠着。不报错，只是「功能像没做」。
  func testLeadingTitleBecomesAnAnonymousFirstLayer() {
    let composed = """
      # 翻译过来的标题

      ## \(LayeredSourceDocument.captionHeading)

      配文正文。

      ## \(LayeredSourceDocument.transcriptHeading)

      00:00 转写正文。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.count, 3)
    XCTAssertNil(layers[0].heading, "标题行必须是无名层，调用方靠它认出「这是标题不是一层」")
    XCTAssertEqual(layers[0].body, "# 翻译过来的标题")
    XCTAssertEqual(
      layers.dropFirst().map(\.heading),
      [LayeredSourceDocument.captionHeading, LayeredSourceDocument.transcriptHeading]
    )
  }

  /// 本机导入的录音在转写前只有「点转写」的占位说明；转写完成后它不该再作为配文出现。
  func testLocalImportPlaceholderDropsOutOnceTranscribed() {
    let taskID = TaskID()
    let placeholder = snapshot(
      taskID: taskID, sequence: 1,
      sourceKind: CapturedDocument.Origin.localImport.rawValue,
      body: "从本机导入的音频：a.m4a\n\n点「转写」即可在本机把声音转成文字。",
      captureMethod: "local_file_audio"
    )
    XCTAssertTrue(LayeredSourceDocument.modelInput(from: [placeholder]).contains("点「转写」"))
    XCTAssertFalse(LayeredSourceDocument.isSupersededPlaceholder(placeholder, in: [placeholder]))

    let transcript = snapshot(
      taskID: taskID, sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "00:00 这是录音。"
    )
    let all = [placeholder, transcript]
    XCTAssertTrue(LayeredSourceDocument.isSupersededPlaceholder(placeholder, in: all))
    XCTAssertEqual(LayeredSourceDocument.modelInput(from: all), "00:00 这是录音。")
  }

  // MARK: 引用拆分

  func testSplittingQuotesSeparatesAuthorTextFromQuotedTweet() {
    let body = """
    我的话第一段

    <!--LDQUOTE author="@a" url="https://x.com/a/status/1"-->
    被引用的内容
    <!--/LDQUOTE-->

    我的话第二段
    """
    let parts = LayeredSourceDocument.splittingQuotes(body)
    XCTAssertEqual(parts.text, "我的话第一段\n\n我的话第二段")
    XCTAssertTrue(parts.quotes.hasPrefix("<!--LDQUOTE author=\"@a\""))
    XCTAssertTrue(parts.quotes.hasSuffix("<!--/LDQUOTE-->"))
    XCTAssertTrue(parts.quotes.contains("被引用的内容"))
    XCTAssertFalse(parts.text.contains("LDQUOTE"))
  }

  func testSplittingQuotesLeavesPlainBodyUntouched() {
    let parts = LayeredSourceDocument.splittingQuotes("只有自己的话\n\n还有一段")
    XCTAssertEqual(parts.text, "只有自己的话\n\n还有一段")
    XCTAssertEqual(parts.quotes, "")
  }

  func testSplittingQuotesKeepsAQuoteOnlyPostAsQuoteWithEmptyText() {
    let parts = LayeredSourceDocument.splittingQuotes(
      "<!--LDQUOTE author=\"@a\" url=\"u\"-->\n转发的内容\n<!--/LDQUOTE-->"
    )
    XCTAssertEqual(parts.text, "")
    XCTAssertTrue(parts.quotes.contains("转发的内容"))
  }

  func testSplittingQuotesCollectsEveryQuoteBlock() {
    let block = { (n: Int) in "<!--LDQUOTE author=\"@\(n)\" url=\"u\"-->\n第\(n)条\n<!--/LDQUOTE-->" }
    let parts = LayeredSourceDocument.splittingQuotes("正文\n\n\(block(1))\n\n\(block(2))")
    XCTAssertEqual(parts.text, "正文")
    XCTAssertTrue(parts.quotes.contains("第1条"))
    XCTAssertTrue(parts.quotes.contains("第2条"))
  }

  /// 没有收尾标记的残缺块不当引用拆：宁可多显示，也不能把后面的正文吞掉。
  func testSplittingQuotesIgnoresAnUnterminatedBlock() {
    let body = "开头\n\n<!--LDQUOTE author=\"@a\" url=\"u\"-->\n没有收尾\n\n后面的正文"
    let parts = LayeredSourceDocument.splittingQuotes(body)
    XCTAssertEqual(parts.text, body)
    XCTAssertEqual(parts.quotes, "")
  }
}
