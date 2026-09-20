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

  func testSplitRoundTripsModelInput() {
    let taskID = TaskID()
    let caption = snapshot(
      taskID: taskID,
      sequence: 1,
      sourceKind: CapturedDocument.Origin.browserCapture.rawValue,
      body: "配文第一段。\n\n配文第二段。"
    )
    let transcript = snapshot(
      taskID: taskID,
      sequence: 2,
      sourceKind: CapturedDocument.Origin.localTranscription.rawValue,
      body: "00:00 转写第一句。\n\n00:13 转写第二句。"
    )
    let composed = LayeredSourceDocument.modelInput(from: [caption, transcript])
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(
      layers.map(\.heading),
      [LayeredSourceDocument.captionHeading, LayeredSourceDocument.transcriptHeading]
    )
    XCTAssertTrue(layers[0].body.contains("配文第二段。"))
    XCTAssertTrue(layers[1].body.contains("00:13 转写第二句。"))
  }

  func testUnlabelledDocumentStaysAsOneAnonymousLayer() {
    let layers = LayeredSourceDocument.split("就是一段普通正文，没有任何小标题。")
    XCTAssertEqual(layers.count, 1)
    XCTAssertNil(layers[0].heading)
    XCTAssertEqual(layers[0].body, "就是一段普通正文，没有任何小标题。")
  }

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

  func testEmptySectionsAreDropped() {
    let composed = """
      ## \(LayeredSourceDocument.captionHeading)

      ## \(LayeredSourceDocument.transcriptHeading)

      有内容。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.map(\.heading), [LayeredSourceDocument.transcriptHeading])
  }

  func testLeadingTitleBecomesAnAnonymousFirstLayer() {
    let composed = """
      # 翻译过来的标题

      ## \(LayeredSourceDocument.captionHeading)

      配文正文。

      ## \(LayeredSourceDocument.transcriptHeading)

      转写正文。
      """
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.count, 3)
    XCTAssertNil(layers[0].heading)
    XCTAssertTrue(layers[0].body.contains("翻译过来的标题"))
    XCTAssertEqual(layers[1].heading, LayeredSourceDocument.captionHeading)
    XCTAssertEqual(layers[2].heading, LayeredSourceDocument.transcriptHeading)
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
}
