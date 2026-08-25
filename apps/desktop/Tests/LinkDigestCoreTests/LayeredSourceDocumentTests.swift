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

  private func snapshot(
    taskID: TaskID,
    sequence: Int,
    sourceKind: String,
    body: String
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
      captureMethod: "page",
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
    XCTAssertEqual(LayeredSourceDocument.subtitleSnapshot(in: snapshots)?.id, subtitles.id)
    XCTAssertTrue(
      LayeredSourceDocument.derivedKinds.contains(CapturedDocument.Origin.burnedInSubtitles.rawValue),
      "新的派生来源必须登记到 derivedKinds"
    )
  }

  /// 三层同时存在时，顺序固定为 配文 → 画面字幕 → 视频转写。
  func testThreeLayersAppearInAFixedOrder() {
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
    let captionAt = input.range(of: LayeredSourceDocument.captionHeading)?.lowerBound
    let subtitleAt = input.range(of: LayeredSourceDocument.subtitleHeading)?.lowerBound
    let transcriptAt = input.range(of: LayeredSourceDocument.transcriptHeading)?.lowerBound
    XCTAssertNotNil(captionAt)
    XCTAssertNotNil(subtitleAt)
    XCTAssertNotNil(transcriptAt)
    XCTAssertLessThan(captionAt!, subtitleAt!)
    XCTAssertLessThan(subtitleAt!, transcriptAt!)
    // 听写没有因为字幕的加入而被挤掉——两条来源并存，不互相覆盖。
    XCTAssertTrue(input.contains("听写正文。"))
    XCTAssertTrue(input.contains("字幕正文。"))
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

    // 只有字幕、没有配文时同样不加标题。
    let subtitleOnly = snapshot(
      taskID: taskID,
      sequence: 2,
      sourceKind: CapturedDocument.Origin.burnedInSubtitles.rawValue,
      body: "只有字幕。"
    )
    XCTAssertEqual(LayeredSourceDocument.modelInput(from: [subtitleOnly]), "只有字幕。")
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
}
