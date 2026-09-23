import Foundation
import XCTest
@testable import LinkDigestCore

/// 本机导入素材（语音备忘录、本地文件）的身份与安全边界。
final class LocalImportDocumentTests: XCTestCase {
  func testLocalImportURLCarriesSourceAsHost() throws {
    let url = try CanonicalURL.localImport(source: "voicememos", identifier: "ABC-123")
    XCTAssertEqual(url.value, "linkdigest-local://voicememos/abc-123")
    XCTAssertTrue(url.isLocalImport)
    XCTAssertFalse(url.isNote)
    XCTAssertEqual(url.localImportSource, "voicememos")
    // 侧栏按 host 分组：URLComponents 必须能切出来源段。
    XCTAssertEqual(URLComponents(string: url.value)?.host, "voicememos")
  }

  func testLocalImportURLRejectsUnsafeSegments() {
    XCTAssertThrowsError(try CanonicalURL.localImport(source: "voice memos", identifier: "a"))
    XCTAssertThrowsError(try CanonicalURL.localImport(source: "voicememos", identifier: "a/b"))
    XCTAssertThrowsError(try CanonicalURL.localImport(source: "voicememos", identifier: ""))
  }

  func testVoiceMemoDocumentPassesValidationAndFallsBackToDateTitle() throws {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let document = try LocalImportDocument.voiceMemo(
      recordingID: "8F2C1D9E-0000-4000-8000-000000000001",
      title: nil,
      recordedAt: date,
      durationSeconds: 75
    )
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document))
    XCTAssertEqual(document.origin, .localImport)
    XCTAssertEqual(document.platform, LocalImportSource.voiceMemos.rawValue)
    XCTAssertTrue(document.title?.hasPrefix("语音备忘录 ") == true)
    XCTAssertTrue(document.text.contains("1:15"))
  }

  func testSameRecordingAlwaysMapsToSameEntry() throws {
    let first = try LocalImportDocument.voiceMemo(recordingID: "ID-1", title: "晨会", recordedAt: nil, durationSeconds: nil)
    let second = try LocalImportDocument.voiceMemo(recordingID: "ID-1", title: "改过名的晨会", recordedAt: nil, durationSeconds: nil)
    XCTAssertEqual(first.url, second.url)
  }

  func testStableIdentifierKeepsDistinctUnusualIDsDistinct() {
    XCTAssertEqual(LocalImportDocument.stableIdentifier("ABC_1.m4a"), "abc_1.m4a")
    let a = LocalImportDocument.stableIdentifier("录音 一")
    let b = LocalImportDocument.stableIdentifier("录音 二")
    XCTAssertNotEqual(a, b)
    XCTAssertNoThrow(try CanonicalURL.localImport(source: "voicememos", identifier: a))
  }

  func testOnlyLocalImportOriginMayCreateLocalImportEntries() throws {
    let url = try CanonicalURL.localImport(source: "localfiles", identifier: String(repeating: "a", count: 64)).value
    func document(_ origin: CapturedDocument.Origin) -> CapturedDocument {
      CapturedDocument(
        createdAt: "2026-09-23T00:00:00Z", origin: origin, url: url, title: "t",
        platform: "localfiles", method: "fixture", text: "正文",
        completeness: "complete", capturedAt: "2026-09-23T00:00:00Z", sourceLabel: "本地文件"
      )
    }
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document(.localImport)))
    // 转写稿挂回本机导入的条目。
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document(.localTranscription)))
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document(.burnedInSubtitles)))
    // 浏览器与手动链接不能借本机地址绕过 http(s) 边界。
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(.browserCapture)))
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(.manualLink)))
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(.userNote)))
  }

  func testLocalImportOriginCannotUseWebURL() {
    let document = CapturedDocument(
      createdAt: "2026-09-23T00:00:00Z", origin: .localImport, url: "https://example.com/a", title: "t",
      platform: "localfiles", method: "fixture", text: "正文",
      completeness: "complete", capturedAt: "2026-09-23T00:00:00Z", sourceLabel: "本地文件"
    )
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document))
  }

  func testLocalSourcesHaveReadablePlatformNames() {
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "voicememos"), "语音备忘录")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "localfiles"), "本地文件")
  }

  func testImageBodyKeepsRecognizedLinesApartAndDropsDotNoise() {
    let body = LocalImportDocument.imageBody(
      fileName: "shot.png",
      reference: "linkdigest-local://localfiles/abc",
      recognizedText: "IP查询\n•••.••.....。\n 104.30.175.37 \n\n152ms"
    )
    XCTAssertEqual(
      body,
      "![shot.png](linkdigest-local://localfiles/abc)\n\n## 图片里的文字\n\nIP查询  \n104.30.175.37  \n152ms"
    )
  }

  func testImageBodyWithoutTextSaysSo() {
    let body = LocalImportDocument.imageBody(fileName: "a.png", reference: "linkdigest-local://localfiles/a", recognizedText: "••••")
    XCTAssertEqual(body, "![a.png](linkdigest-local://localfiles/a)\n\n（图片里没有识别到文字。）")
  }

  func testPlainTextKeepsEachLineAndBlankLinesStillSplitParagraphs() {
    XCTAssertEqual(
      LocalImportDocument.preservingLineBreaks("第一行\n第二行  \t\n\n新段落"),
      "第一行  \n第二行\n\n新段落"
    )
  }

  func testWordParagraphsBecomeSeparateMarkdownParagraphs() {
    XCTAssertEqual(LocalImportDocument.documentParagraphs("一段\n\n二段\u{2028}三段\n"), "一段\n\n二段\n\n三段")
  }

  func testImageTextHeadingDoesNotLeakIntoListPreview() {
    let body = LocalImportDocument.imageBody(
      fileName: "a.png", reference: "linkdigest-local://localfiles/a", recognizedText: "你好\n世界"
    )
    let raw = MarkdownNoteFrontmatter.directorySourcePreview(fromBody: body)
    XCTAssertEqual(HistoryRowProjection.sanitizedDirectoryPreview(raw, isSummary: false), "你好 世界")
  }

  func testSplitImageBodySeparatesPictureFromRecognizedText() {
    let body = LocalImportDocument.imageBody(
      fileName: "a.png", reference: "linkdigest-local://localfiles/a", recognizedText: "你好\n世界"
    )
    let parts = LocalImportDocument.splitImageBody(body)
    XCTAssertEqual(parts.image, "![a.png](linkdigest-local://localfiles/a)")
    XCTAssertEqual(parts.recognizedText, "你好\n世界")
    let bare = LocalImportDocument.imageBody(fileName: "b.png", reference: "linkdigest-local://localfiles/b", recognizedText: nil)
    XCTAssertNil(LocalImportDocument.splitImageBody(bare).recognizedText)
  }

  /// 新系统语音备忘录库里有一列存的是录制时间串；它不能成为标题。
  func testVoiceMemoIgnoresMachineTimestampTitle() throws {
    XCTAssertTrue(LocalImportDocument.isMachineTimestamp("2021-06-22T14:37:55Z"))
    XCTAssertFalse(LocalImportDocument.isMachineTimestamp("录音 3"))
    let recordedAt = Date(timeIntervalSince1970: 1_624_372_675)
    let doc = try LocalImportDocument.voiceMemo(
      recordingID: "a", title: "2021-06-22T14:37:55Z", recordedAt: recordedAt, durationSeconds: 178
    )
    XCTAssertTrue(doc.title?.hasPrefix("语音备忘录 2021-06-2") == true)
    let named = try LocalImportDocument.voiceMemo(recordingID: "b", title: "滨文路", recordedAt: recordedAt, durationSeconds: 3)
    XCTAssertEqual(named.title, "滨文路")
  }

  func testDefaultNotesFolderIsNotShownAsSource() throws {
    let doc = try LocalImportDocument.appleNote(noteID: "x", title: "t", folder: "Notes", createdAt: nil, text: "正文")
    XCTAssertFalse(doc.text.contains("author:"))
    let named = try LocalImportDocument.appleNote(noteID: "y", title: "t", folder: "工作与项目", createdAt: nil, text: "正文")
    XCTAssertTrue(named.text.contains("工作与项目"))
  }
}
