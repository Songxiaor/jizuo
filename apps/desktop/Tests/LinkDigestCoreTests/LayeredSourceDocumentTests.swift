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
}
