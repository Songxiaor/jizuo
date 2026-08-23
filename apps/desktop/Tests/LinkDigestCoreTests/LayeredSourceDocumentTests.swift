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
}
