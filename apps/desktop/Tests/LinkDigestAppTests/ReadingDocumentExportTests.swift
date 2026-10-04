import XCTest
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
}
