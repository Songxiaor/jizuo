import XCTest
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
}
