import XCTest
import PDFKit
import LinkDigestCore
@testable import LinkDigestApp

final class ReadingDocumentExportTests: XCTestCase {
  private let markdown = """
  # 一、标题层级

  正文段落，包含 **加粗** 与 `行内代码`，中文标点保持不变。

  - 第一条
  - 第二条

  > 引用的一句话。

  ```
  let answer = 42
  ```
  """

  func testAttributedDocumentFollowsReadingLayout() {
    let attributed = ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .serif)
    let text = attributed.string
    XCTAssertTrue(text.contains("一、标题层级"))
    XCTAssertTrue(text.contains("• 第一条"))
    XCTAssertTrue(text.contains("let answer = 42"))
    // 标题字号大于正文；代码用等宽字体。
    let headingFont = attributed.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
    XCTAssertEqual(headingFont?.pointSize, 19)
    var codeFont: NSFont?
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      let sub = (attributed.string as NSString).substring(with: range)
      if sub.contains("answer"), let font = value as? NSFont { codeFont = font }
    }
    XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
  }

  func testPDFAndDocxCarryFormatMagicBytes() throws {
    let attributed = ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .sans)
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed))
    XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
    let docx = try ReadingDocumentExport.docxData(from: attributed)
    // OOXML 是 zip 容器：PK 魔数。
    XCTAssertTrue(docx.starts(with: [0x50, 0x4B]))
  }

  func testLongDocumentPaginatesIntoMultiplePages() throws {
    let long = Array(repeating: "这是一段用于分页测试的正文，长度足够把多页填满。", count: 400).joined(separator: "\n\n")
    let attributed = ReadingDocumentExport.attributedDocument(markdown: long, readingFont: .sans)
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed))
    XCTAssertGreaterThan(pdf.count, 10_000)
    XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
  }

  func testLocalImagesEmbedAsAttachmentsInPDFAndDocx() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-export-img-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 40x30 红色 PNG。
    let imageURL = dir.appendingPathComponent("shot.png")
    let png = NSImage(size: NSSize(width: 40, height: 30))
    png.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 40, height: 30).fill()
    png.unlockFocus()
    let rep = NSBitmapImageRep(data: png.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: imageURL)

    let markdown = "正文一段。\n\n![](https://x.test/shot.png)\n\n正文二段。"
    let attributed = ReadingDocumentExport.attributedDocument(
      markdown: markdown, readingFont: .sans, localImageURLs: [imageURL]
    )
    // 富文本里含图片附件字符（U+FFFC）。
    XCTAssertTrue(attributed.string.contains("\u{FFFC}"))
    var hasAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
      if value is NSTextAttachment { hasAttachment = true }
    }
    XCTAssertTrue(hasAttachment)
    // PDF 与 docx 都能生成（附件由各自渲染器嵌入）。
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed))
    XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
    let docx = try ReadingDocumentExport.docxData(from: attributed)
    XCTAssertTrue(docx.starts(with: [0x50, 0x4B]))
    // docx 是 zip，内嵌图片会让体积明显大于纯文本导出。
    let textOnly = try ReadingDocumentExport.docxData(
      from: ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .sans)
    )
    XCTAssertGreaterThan(docx.count, textOnly.count)
  }

  func testDocxEmbedsEachImageAttachment() throws {
    let first = try pngData(width: 40, height: 30, red: 200)
    let second = try pngData(width: 80, height: 20, red: 40)
    let text = NSMutableAttributedString(string: "前文\n")
    text.append(attachment(png: first, width: 40, height: 30))
    text.append(NSAttributedString(string: "\n中间\n"))
    text.append(attachment(png: second, width: 80, height: 20))
    text.append(NSAttributedString(string: "\n后文"))

    let docx = try ReadingDocumentExport.docxData(from: text)
    let unpacked = FileManager.default.temporaryDirectory
      .appendingPathComponent("jizuo-docx-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unpacked) }
    let zipURL = unpacked.appendingPathComponent("in.docx")
    try docx.write(to: zipURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", zipURL.path, "-d", unpacked.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)

    let media = try FileManager.default.contentsOfDirectory(
      at: unpacked.appendingPathComponent("word/media"),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(Set(media.map(\.lastPathComponent)), ["image1.png", "image2.png"])
    let xml = try String(contentsOf: unpacked.appendingPathComponent("word/document.xml"), encoding: .utf8)
    XCTAssertEqual(xml.components(separatedBy: "r:embed=\"rIdJZIMG").count - 1, 2)
    XCTAssertFalse(xml.contains("[[JZIMG:"))
    XCTAssertTrue(xml.contains("前文"))
    XCTAssertTrue(xml.contains("后文"))
    let types = try String(contentsOf: unpacked.appendingPathComponent("[Content_Types].xml"), encoding: .utf8)
    XCTAssertTrue(types.contains("Extension=\"png\""))
  }

  /// 正文导出带上最新一份总结和译文；更早的同一种不重复。
  func testExportBodyAppendsTheLatestSummaryAndTranslation() throws {
    let task = HistoryTask(
      id: TaskID(), canonicalURL: "https://example.com/a", canonicalizationVersion: 1,
      createdAtMilliseconds: 10, updatedAtMilliseconds: 20
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(), taskID: task.id, sequence: 1,
      envelopeCreatedAtMilliseconds: 10, capturedAtMilliseconds: 10,
      sourceKind: "browser_capture", sourceURL: task.canonicalURL, title: "例",
      platform: "generic", captureMethod: "browser_capture", completeness: "complete",
      bodyText: "原文很长", characterCount: 4, bodySHA256: String(repeating: "a", count: 64),
      sourceLabel: "网页", usedCookie: false
    )
    func run(_ kind: RunKind, body: String, at: Int64) -> HistoryDetailProjection.RunDetail {
      let value = HistoryRun(
        id: RunID(), taskID: task.id, snapshotID: snapshot.id, idempotencyKey: body,
        rerunOfRunID: nil, kind: kind, targetLanguage: nil, status: .completed,
        providerProfileID: nil, providerKind: nil, providerBaseURL: nil, providerAPIMode: nil,
        model: nil, createdAtMilliseconds: at, startedAtMilliseconds: at, finishedAtMilliseconds: at,
        failureCode: nil, failureRetryable: nil, usageCost: RunUsageCost()
      )
      let artifact = HistoryArtifact(
        id: ArtifactID(), runID: value.id, contentFormat: .markdown, completeness: .complete,
        bodyText: body, createdAtMilliseconds: at, updatedAtMilliseconds: at
      )
      return .init(run: value, artifact: artifact)
    }
    let detail = HistoryDetailProjection(
      task: task, snapshots: [snapshot],
      runs: [run(.summarize, body: "旧总结", at: 1), run(.summarize, body: "新总结", at: 2), run(.translate, body: "译文一句", at: 3)]
    )
    let body = HistoryViewModel.exportBody(from: detail)
    XCTAssertTrue(body.contains("原文很长"))
    XCTAssertTrue(body.contains("## 总结\n\n新总结"))
    XCTAssertTrue(body.contains("## 译文\n\n译文一句"))
    XCTAssertFalse(body.contains("旧总结"))
  }

  /// 引用卡的机器标记在 Markdown、纯文本、PDF 里都变成可读文字。
  @MainActor
  func testQuotedTweetMarkerBecomesReadableText() throws {
    let markdown = """
    # 帖子

    正文。

    <!--LDQUOTE author="StepFun (@StepFun_ai)" url="https://x.com/StepFun_ai/status/1"-->
    引用里的话。
    <!--/LDQUOTE-->
    """
    let presented = ReadingDocumentExport.presentingMachineMarkers(markdown)
    XCTAssertFalse(presented.contains("LDQUOTE"))
    XCTAssertTrue(presented.contains("引用 StepFun (@StepFun_ai)"))
    XCTAssertTrue(presented.contains("引用里的话。"))
    XCTAssertTrue(presented.contains("https://x.com/StepFun_ai/status/1"))
    let task = HistoryTask(
      id: TaskID(), canonicalURL: "linkdigest-note:abc", canonicalizationVersion: 1,
      createdAtMilliseconds: 10, updatedAtMilliseconds: 20
    )
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(), taskID: task.id, sequence: 1,
      envelopeCreatedAtMilliseconds: 10, capturedAtMilliseconds: 10,
      sourceKind: "user_note", sourceURL: task.canonicalURL, title: "帖子",
      platform: "note", captureMethod: "user_note", completeness: "complete",
      bodyText: markdown, characterCount: markdown.count, bodySHA256: String(repeating: "b", count: 64),
      sourceLabel: "笔记", usedCookie: false
    )
    let context = ReadingDocumentExport.ExportColophonContext(
      detail: HistoryDetailProjection(task: task, snapshots: [snapshot], runs: []), mindMap: nil
    )
    let plain = ReadingDocumentExport.cleanTextExport(composedMarkdown: markdown, format: .plainText, context: context)
    XCTAssertFalse(plain.contains("LDQUOTE"))
    XCTAssertTrue(plain.contains("引用里的话。"))
    let styled = ReadingDocumentExport.styledDocument(
      composedMarkdown: markdown, context: context, readingFont: .sans, localImageURLs: []
    )
    XCTAssertFalse(styled.string.contains("LDQUOTE"))
    XCTAssertTrue(styled.string.contains("引用里的话。"))
  }

  /// 含阿拉伯字母的段落从右往左，中文段落保持从左往右。
  func testArabicParagraphUsesRightToLeft() {
    let styled = ReadingDocumentExport.attributedDocument(
      markdown: "Charm loves open source\n\nنحنُ نحب المصادر المفتوحة",
      readingFont: .sans
    )
    let text = styled.string as NSString
    let arabic = text.range(of: "نحب").location
    let english = text.range(of: "Charm").location
    let arabicStyle = styled.attribute(.paragraphStyle, at: arabic, effectiveRange: nil) as? NSParagraphStyle
    let englishStyle = styled.attribute(.paragraphStyle, at: english, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(arabicStyle?.baseWritingDirection, .rightToLeft)
    XCTAssertNotEqual(englishStyle?.baseWritingDirection, .rightToLeft)
  }

  func testPreparedExportDropsARepeatedOpeningTitle() {
    let title = "Claude Code 工程师刚放出一条 28 分钟实操视频，干货密度有点夸张："
    let body = """
    ![image](https://pbs.twimg.com/media/x.png)

    # \(title)

    这是正文。
    """
    let prepared = ReadingDocumentExport.preparedExport(
      storedTitle: title, canonicalURL: "https://x.com/i/article/1", body: body
    )
    XCTAssertEqual(prepared.title, title)
    XCTAssertTrue(prepared.includesSource)
    XCTAssertFalse(prepared.body.contains("# \(title)"))
    XCTAssertTrue(prepared.body.contains("这是正文。"))
    XCTAssertTrue(prepared.body.contains("![image]"))
  }

  func testPreparedExportUsesTheNoteHeadingAndOmitsTheInternalSource() {
    let body = """
    # Claude Code 工程师刚放出一条 28 分钟实操视频，干货密度有点夸张：

    这是笔记正文。
    """
    let prepared = ReadingDocumentExport.preparedExport(
      storedTitle: UserNoteDocument.untitledTitle,
      canonicalURL: HistoryPlatformDisplay.noteURLPrefix + "abc",
      body: body
    )
    XCTAssertEqual(prepared.title, "Claude Code 工程师刚放出一条 28 分钟实操视频，干货密度有点夸张：")
    XCTAssertFalse(prepared.includesSource)
    XCTAssertFalse(prepared.body.contains("# Claude Code"))
    XCTAssertTrue(prepared.body.contains("这是笔记正文。"))
  }

  func testCommentHeadersDropDepthAndUseLocalTimeInTextExports() {
    let markdown = """
    # 帖子

    ## 评论（已保存 1 条）

    - **小明** · 赞 1 · 2026-10-03T23:30:06.000Z · [原评论](https://linux.do/t/1/2) · 回复层级 0
      评论正文
    """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let cleaned = ReadingDocumentExport.cleaningExportCommentHeaders(
      markdown, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!, calendar: calendar
    )
    XCTAssertTrue(cleaned.contains("- **小明** · 赞 1 · 2026-10-04 07:30 · [原评论](https://linux.do/t/1/2)"))
    XCTAssertFalse(cleaned.contains("回复层级"))
    XCTAssertFalse(cleaned.contains("2026-10-03T23:30:06"))

    let plain = MarkdownPresentation.plainTextPresentation(cleaned)
    XCTAssertFalse(plain.contains("回复层级"))
    XCTAssertFalse(plain.contains("# 帖子"))
    XCTAssertTrue(plain.contains("帖子"))
    XCTAssertTrue(plain.contains("原评论（https://linux.do/t/1/2）"))
  }

  func testTimecodeLinesUseOneSpaceAndTighterParagraphs() throws {
    let markdown = """
    ## 视频转写

    ## 开场

    26:57  And there are two spaces.

    00:01 Hello.

    后记还是普通段落。
    """
    let normalized = ReadingDocumentExport.normalizingLeadingTimecodes(markdown)
    XCTAssertTrue(normalized.contains("26:57 And there are two spaces."))
    XCTAssertFalse(normalized.contains("26:57  And"))
    XCTAssertTrue(normalized.contains("00:01 Hello."))

    let attributed = ReadingDocumentExport.attributedDocument(markdown: normalized, readingFont: .sans)
    let text = attributed.string as NSString
    let codeAt = text.range(of: "26:57").location
    let proseAt = text.range(of: "后记").location
    XCTAssertNotEqual(codeAt, NSNotFound)
    let codeStyle = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: codeAt, effectiveRange: nil) as? NSParagraphStyle)
    let proseStyle = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: proseAt, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(codeStyle.paragraphSpacing, 6, accuracy: 0.1)
    XCTAssertGreaterThan(proseStyle.paragraphSpacing, codeStyle.paragraphSpacing)
    let codeFont = try XCTUnwrap(attributed.attribute(.font, at: codeAt, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(codeFont, NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular))
    let codeColor = try XCTUnwrap(attributed.attribute(.foregroundColor, at: codeAt, effectiveRange: nil) as? NSColor)
    let wordAt = text.range(of: "And").location
    let wordColor = try XCTUnwrap(attributed.attribute(.foregroundColor, at: wordAt, effectiveRange: nil) as? NSColor)
    XCTAssertFalse(codeColor.isEqual(wordColor))
  }

  func testExportRendersLinksItalicsAndDropsUnresolvedImages() throws {
    let markdown = """
    见 [集中帖](https://linux.do/tag/x) 和 *斜体*。

    - 列表里的 *斜体*

    ![image](https://cdn.example/missing.png)

    ## 评论（已保存 1 条）

    - **小明** · 2026-10-03T23:30:06.000Z · 回复层级 0
      # 省流版本

      评论里的 [链接](https://example.test/a)。
    """
    let attributed = ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .sans)
    let text = attributed.string
    XCTAssertTrue(text.contains("集中帖"))
    XCTAssertFalse(text.contains("]("))
    XCTAssertFalse(text.contains("*斜体*"))
    XCTAssertFalse(text.contains("# 省流版本"))
    XCTAssertTrue(text.contains("省流版本"))
    XCTAssertFalse(text.contains("missing.png"))
    XCTAssertFalse(text.contains("!["))

    var sawLink = false
    attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      let absolute = (value as? URL)?.absoluteString
        ?? (value as? NSURL)?.absoluteString
        ?? (value as? String)
      guard absolute == "https://linux.do/tag/x" else { return }
      sawLink = true
      XCTAssertEqual((text as NSString).substring(with: range), "集中帖")
    }
    XCTAssertTrue(sawLink)
    // 不断言斜体字形：中文字体没有斜体，系统会回落成正体；要紧的是星号不再露出来。
  }

  private func pngData(width: Int, height: Int, red: CGFloat) throws -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(calibratedRed: red / 255, green: 0.2, blue: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "test", code: 1) }
    return png
  }

  private func attachment(png: Data, width: CGFloat, height: CGFloat) -> NSAttributedString {
    let attachment = NSTextAttachment()
    attachment.image = NSImage(data: png)
    attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
    return NSAttributedString(attachment: attachment)
  }

  /// 保存框先出现：PDF / Word 入口在弹框之前不再生成整份文件。
  /// 纯文本导出仍在弹框前写好内容，这条不能跟着改。
  func testStyledExportPresentsTheSavePanelBeforeGenerating() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8
    )
    let styled = try XCTUnwrap(source.range(of: "private func exportStyledDocument"))
    let next = source.range(of: "private static let noteTitleFontSize", range: styled.upperBound..<source.endIndex)?.lowerBound
      ?? source.endIndex
    let body = source[styled.lowerBound..<next]
    XCTAssertLessThan(
      body.range(of: "MenuSavePanel.present")?.lowerBound ?? body.endIndex,
      body.range(of: "startStyledExport")?.lowerBound ?? body.startIndex
    )
    XCTAssertFalse(body.contains("pdfData(from:"))
    XCTAssertFalse(body.contains("docxData(from:"))
    let model = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryViewModel.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(model.range(of: "func startStyledExport"))
    let generated = model[start.lowerBound...].prefix(1_600)
    XCTAssertTrue(generated.contains("styledDocument("))
    XCTAssertTrue(generated.contains("pdfData(from:"))
    XCTAssertTrue(generated.contains("docxData(from:"))
    XCTAssertLessThan(
      generated.range(of: "showGenerating")?.lowerBound ?? generated.endIndex,
      generated.range(of: "await Task.yield")?.lowerBound ?? generated.startIndex
    )
    XCTAssertLessThan(
      generated.range(of: "await Task.yield")?.lowerBound ?? generated.endIndex,
      generated.range(of: "pdfData(from:")?.lowerBound ?? generated.startIndex
    )
    let plain = try XCTUnwrap(source.range(of: "private func exportCleanText"))
    let plainBody = source[plain.lowerBound..<styled.lowerBound]
    XCTAssertLessThan(
      plainBody.range(of: "cleanTextExport")?.lowerBound ?? plainBody.endIndex,
      plainBody.range(of: "MenuSavePanel.present")?.lowerBound ?? plainBody.startIndex
    )
  }

  /// 选定路径后先显示「正在生成」，让出一拍给界面画出来，完成后再换成「已导出」。
  /// 失败时收起这句，改走原来的保存失败说明。生成本身不放转圈。
  func testGeneratingNoticeAppearsBeforeTheFileAndFailureUsesTheExistingAlert() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/HistoryViewModel.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(source.range(of: "func startStyledExport"))
    let body = source[start.lowerBound...].prefix(2_200)
    XCTAssertLessThan(
      body.range(of: "showGenerating")?.lowerBound ?? body.endIndex,
      body.range(of: "pdfData(from:")?.lowerBound ?? body.startIndex
    )
    XCTAssertLessThan(
      body.range(of: "writePreparedExport")?.lowerBound ?? body.endIndex,
      body.range(of: "showExported")?.lowerBound ?? body.startIndex
    )
    XCTAssertTrue(body.contains("CopyFeedbackController.shared.hide()"))
    XCTAssertTrue(body.contains("failExportSave()"))
    XCTAssertFalse(body.contains("ProgressView"))
    let feedback = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/CopyFeedback.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(feedback.contains("正在生成"))
    XCTAssertTrue(feedback.contains("已导出"))
    XCTAssertTrue(feedback.contains("PDF"))
    XCTAssertTrue(feedback.contains("Word"))
    XCTAssertFalse(feedback.contains("ProgressView"))
  }

  /// 保存框之后生成的文件必须和原来的排版一致：白底、时间戳仍是浅色、段落仍有间距。
  func testDeferredExportMatchesTheOriginalLayout() throws {
    let source = """
    00:01 Hello.

    后记还是普通段落。
    """
    let attributed = ReadingDocumentExport.attributedDocument(markdown: source, readingFont: .sans)
    let text = attributed.string as NSString
    let codeAt = text.range(of: "00:01").location
    let proseAt = text.range(of: "后记").location
    let codeColor = try XCTUnwrap(attributed.attribute(.foregroundColor, at: codeAt, effectiveRange: nil) as? NSColor)
    let proseColor = try XCTUnwrap(attributed.attribute(.foregroundColor, at: proseAt, effectiveRange: nil) as? NSColor)
    XCTAssertFalse(codeColor.isEqual(proseColor), "时间戳不能变成和正文一样的黑色")
    let codeStyle = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: codeAt, effectiveRange: nil) as? NSParagraphStyle)
    let proseStyle = try XCTUnwrap(attributed.attribute(.paragraphStyle, at: proseAt, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(codeStyle.paragraphSpacing, 6, accuracy: 0.1)
    XCTAssertGreaterThan(proseStyle.paragraphSpacing, 0)
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed))
    XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
    let document = PDFDocument(data: pdf)
    let page = try XCTUnwrap(document?.page(at: 0))
    let swatch = page.thumbnail(of: CGSize(width: 40, height: 40), for: .mediaBox)
    let rep = try XCTUnwrap(NSBitmapImageRep(data: swatch.tiffRepresentation!))
    let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
    XCTAssertGreaterThan(corner.redComponent, 0.95)
    XCTAssertGreaterThan(corner.greenComponent, 0.95)
    XCTAssertGreaterThan(corner.blueComponent, 0.95)
  }

  /// 手动计时，不进日常测试。设 LINKDIGEST_EXPORT_MEASURE=1 才跑。
  /// 正文从隔离副本只读取出，结果写到 /tmp，不碰正式库。
  func testMeasureLongArticleExportWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["LINKDIGEST_EXPORT_MEASURE"] == "1" else {
      throw XCTSkip("手动计时")
    }
    let markdown = try String(
      contentsOf: URL(fileURLWithPath: "/tmp/linkdigest-export-measure/long.md"),
      encoding: .utf8
    )
    let out = URL(fileURLWithPath: "/tmp/linkdigest-export-measure", isDirectory: true)
    let clock = ContinuousClock()
    func ms(_ duration: Duration) -> String {
      String(format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
    let oldStart = clock.now
    let attributed = ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .sans)
    let composed = clock.now
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed))
    let pdfDone = clock.now
    let docx = try ReadingDocumentExport.docxData(from: attributed)
    let docxDone = clock.now
    try pdf.write(to: out.appendingPathComponent("old.pdf"))
    try docx.write(to: out.appendingPathComponent("old.docx"))
    let newPDFStart = clock.now
    let newPDF = pdf
    try ReadingDocumentExport.writePreparedExport(newPDF, to: out.appendingPathComponent("new.pdf"))
    let newPDFDone = clock.now
    let newDocxStart = clock.now
    try ReadingDocumentExport.writePreparedExport(docx, to: out.appendingPathComponent("new.docx"))
    let newDocxDone = clock.now
    let writtenPDF = try Data(contentsOf: out.appendingPathComponent("new.pdf"))
    let marker = Data("/Type /Page".utf8)
    var pages = 0
    var cursor = newPDF.startIndex
    while let found = writtenPDF[cursor...].range(of: marker) {
      pages += 1
      cursor = found.upperBound
    }
    print("MEASURE chars \(markdown.count)")
    print("MEASURE old-compose-ms \(ms(composed - oldStart))")
    print("MEASURE old-pdf-ms \(ms(pdfDone - composed)) bytes \(pdf.count)")
    print("MEASURE old-docx-ms \(ms(docxDone - pdfDone)) bytes \(docx.count)")
    print("MEASURE old-before-panel-ms \(ms(docxDone - oldStart))")
    print("MEASURE new-pdf-ms \(ms(newPDFDone - newPDFStart)) bytes \(writtenPDF.count) pages \(pages)")
    print("MEASURE new-docx-ms \(ms(newDocxDone - newDocxStart))")
  }

  func testPreparedExportWritesOnlyAfterTheBytesExist() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("jizuo-bg-write-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("稿.pdf")
    let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(
      from: ReadingDocumentExport.attributedDocument(markdown: markdown, readingFont: .sans)
    ))
    try ReadingDocumentExport.writePreparedExport(pdf, to: destination)
    let written = try Data(contentsOf: destination)
    XCTAssertEqual(written, pdf)
    let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    XCTAssertEqual(leftovers.map(\.lastPathComponent), ["稿.pdf"])
  }
}
