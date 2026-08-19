import AppKit
import CoreText
import LinkDigestCore
import UniformTypeIdentifiers

/// App 层富格式导出：把与阅读区同源的 Markdown 按 App 排版（标题层级、
/// 正文行距、引用缩进、等宽代码）渲染为 PDF / Word。Core 的 md/txt/json
/// 导出保持原样；本文件只做展示格式，绝不改写存储内容。
enum StyledExportKind: String, CaseIterable {
  case pdf
  case docx

  var fileExtension: String { rawValue }
  var displayName: String {
    switch self {
    case .pdf: "PDF (.pdf)"
    case .docx: "Word (.docx)"
    }
  }

  var contentType: UTType {
    switch self {
    case .pdf: .pdf
    case .docx: UTType(filenameExtension: "docx") ?? .data
    }
  }
}

enum ReadingDocumentExport {
  // 阅读区同源的字号体系（MarkdownPresentation / HistoryDetailView）。
  private static let bodySize: CGFloat = 13
  private static let codeSize: CGFloat = 11

  /// Markdown → 按 App 阅读排版的富文本。本地图片以内嵌附件渲染进 PDF/Word；
  /// 代码块保持逐行等宽，引用块整体缩进。
  static func attributedDocument(
    markdown: String,
    readingFont: ResolvedReadingFont,
    localImageURLs: [URL] = []
  ) -> NSAttributedString {
    // 有本地图片时按图片标记切段，逐段渲染文字、在标记处插入图片附件；
    // 无本地图片时整篇按块渲染（旧行为）。
    guard !localImageURLs.isEmpty else {
      return attributedTextOnly(markdown: markdown, readingFont: readingFont)
    }
    let result = NSMutableAttributedString()
    for segment in LocalMarkdownImageLayout.segments(markdown: markdown, localImageURLs: localImageURLs) {
      switch segment {
      case let .text(chunk):
        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result.append(attributedTextOnly(markdown: chunk, readingFont: readingFont))
        }
      case let .image(url):
        if let attachment = imageAttachment(url: url) {
          result.append(attachment)
          result.append(NSAttributedString(string: "\n\n"))
        }
      case let .gallery(urls):
        // 导出是线性文档：画廊的双排只是屏幕布局，落到 PDF/Word 仍逐张顺排。
        for url in urls {
          if let attachment = imageAttachment(url: url) {
            result.append(attachment)
            result.append(NSAttributedString(string: "\n\n"))
          }
        }
      case let .quotedTweet(quote):
        // 导出成线性文档：引用作者一行 + 正文引用块 + 图片顺排 + 原推链接。
        if let author = quote.author {
          result.append(attributedTextOnly(markdown: "**引用 \(author)：**", readingFont: readingFont))
          result.append(NSAttributedString(string: "\n\n"))
        }
        let quotedBody = quote.text
          .components(separatedBy: "\n")
          .map { $0.isEmpty ? ">" : "> \($0)" }
          .joined(separator: "\n")
        result.append(attributedTextOnly(markdown: quotedBody, readingFont: readingFont))
        result.append(NSAttributedString(string: "\n\n"))
        for url in quote.images {
          if let attachment = imageAttachment(url: url) {
            result.append(attachment)
            result.append(NSAttributedString(string: "\n\n"))
          }
        }
        if let url = quote.url {
          result.append(attributedTextOnly(markdown: url.absoluteString, readingFont: readingFont))
          result.append(NSAttributedString(string: "\n\n"))
        }
      }
    }
    return result
  }

  private static func attributedTextOnly(markdown: String, readingFont: ResolvedReadingFont) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let blocks = MarkdownPresentation.blocks(from: markdown)
    for block in blocks {
      switch block {
      case let .heading(level, text):
        let size: CGFloat = [1: 19.0, 2: 16.0, 3: 14.0][level] ?? 13.5
        let weight: NSFont.Weight = level == 1 ? .bold : .semibold
        result.append(styledParagraph(
          plain(text),
          font: font(readingFont, size: size, weight: weight),
          spacingBefore: 14, spacingAfter: 6
        ))
      case let .paragraph(text):
        result.append(inlineStyled(text, readingFont: readingFont))
      case let .list(entries):
        for entry in entries {
          // 编号取解析时算好的值，不用数组下标：嵌套之后「第几项」和下标不再
          // 是同一件事，各数各的会让导出稿和屏幕上的编号对不上。
          let marker = entry.number.map { "\($0). " } ?? "• "
          let indent = CGFloat(entry.depth) * 16
          result.append(styledParagraph(
            String(repeating: " ", count: entry.depth * 2) + marker + plain(entry.text),
            font: font(readingFont, size: bodySize, weight: .regular),
            spacingBefore: 0, spacingAfter: 4, headIndent: 14 + indent
          ))
        }
      case let .taskList(items):
        for item in items {
          // 导出成字符而不是画复选框：产物要能贴进邮件、文档、聊天窗口，
          // 那些地方没有我们的图形，字符到哪都还是同一个意思。
          result.append(styledParagraph(
            (item.isDone ? "☑ " : "☐ ") + plain(item.text),
            font: font(readingFont, size: bodySize, weight: .regular),
            spacingBefore: 0, spacingAfter: 4, headIndent: 14
          ))
        }
      case .divider:
        result.append(styledParagraph(
          String(repeating: "─", count: 24),
          font: font(readingFont, size: bodySize, weight: .regular),
          spacingBefore: 8, spacingAfter: 8
        ))
      case let .quote(text):
        result.append(styledParagraph(
          plain(text),
          font: font(readingFont, size: bodySize, weight: .regular),
          color: .secondaryLabelColor,
          spacingBefore: 6, spacingAfter: 6, headIndent: 18, firstLineIndent: 18
        ))
      case let .callout(kind, text):
        let label = MarkdownPresentation.calloutLabel(kind)
        result.append(styledParagraph(
          plain(text.isEmpty ? label : "\(label)  \(text)"),
          font: font(readingFont, size: bodySize, weight: .regular),
          color: .secondaryLabelColor,
          spacingBefore: 6, spacingAfter: 6, headIndent: 18, firstLineIndent: 18
        ))
      case let .comments(section):
        result.append(styledParagraph(
          section.countTitle,
          font: font(readingFont, size: 16, weight: .semibold),
          spacingBefore: 14, spacingAfter: 8
        ))
        for item in section.items {
          let indent = CGFloat(min(item.depth, 3)) * 18
          var metadata = item.displayAuthor
          if let score = item.score { metadata += " · \(score) 分" }
          if let published = item.published { metadata += " · \(published)" }
          result.append(styledParagraph(
            metadata,
            font: font(readingFont, size: bodySize, weight: .semibold),
            color: .secondaryLabelColor,
            spacingBefore: 4, spacingAfter: 3, headIndent: indent, firstLineIndent: indent
          ))
          if !item.body.isEmpty {
            result.append(styledParagraph(
              plain(item.body),
              font: font(readingFont, size: bodySize, weight: .regular),
              spacingBefore: 0, spacingAfter: 7, headIndent: indent, firstLineIndent: indent
            ))
          }
        }
      case let .table(headers, rows):
        result.append(styledParagraph(
          headers.joined(separator: " · "),
          font: font(readingFont, size: bodySize, weight: .semibold),
          spacingBefore: 8, spacingAfter: 4
        ))
        for row in rows {
          result.append(styledParagraph(
            row.joined(separator: " · "),
            font: font(readingFont, size: bodySize, weight: .regular),
            spacingBefore: 0, spacingAfter: 3, headIndent: 12
          ))
        }
      case let .code(_, content):
        result.append(styledParagraph(
          content,
          font: .monospacedSystemFont(ofSize: codeSize, weight: .regular),
          spacingBefore: 8, spacingAfter: 8, headIndent: 12, firstLineIndent: 12,
          lineSpacing: 2
        ))
      }
    }
    return result
  }

  /// A4 纵向分页 PDF。用 NSLayoutManager 而非纯 CoreText——后者不绘制
  /// NSTextAttachment 图片；NSLayoutManager 原生画附件且天然支持多容器分页。
  static func pdfData(from attributed: NSAttributedString) -> Data? {
    let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 @72dpi
    let contentRect = pageRect.insetBy(dx: 56, dy: 56)
    let textStorage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)

    // 每页一个文本容器；预先建满,直到所有字形都被排入。
    var containers: [NSTextContainer] = []
    while true {
      let container = NSTextContainer(size: contentRect.size)
      container.lineFragmentPadding = 0
      layoutManager.addTextContainer(container)
      containers.append(container)
      layoutManager.ensureLayout(for: container)
      let glyphRange = layoutManager.glyphRange(for: container)
      let laidOut = glyphRange.location + glyphRange.length
      if laidOut >= layoutManager.numberOfGlyphs || glyphRange.length == 0 {
        break
      }
      if containers.count > 2000 { break } // 安全阀
    }

    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var mediaBox = pageRect
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
    for container in containers {
      let glyphRange = layoutManager.glyphRange(for: container)
      if glyphRange.length == 0 { continue }
      context.beginPDFPage(nil)
      context.saveGState()
      // PDF 原点在左下、y 向上；文本排版坐标 y 向下，翻转并平移到内容区。
      context.translateBy(x: contentRect.minX, y: pageRect.height - contentRect.minY)
      context.scaleBy(x: 1, y: -1)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphicsContext
      layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
      layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
      NSGraphicsContext.restoreGraphicsState()
      context.restoreGState()
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  /// AppKit 原生 OOXML 写出：零第三方依赖的 .docx。
  static func docxData(from attributed: NSAttributedString) throws -> Data {
    try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
    )
  }

  /// 本地图片 → 居中的图文附件段；按导出正文宽度（A4 内容区 ~483pt）等比缩放。
  private static func imageAttachment(url: URL) -> NSAttributedString? {
    guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
    let maxWidth: CGFloat = 460
    let scale = min(1, maxWidth / image.size.width)
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    let string = NSMutableAttributedString(attachment: attachment)
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacingBefore = 8
    paragraph.paragraphSpacing = 8
    string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
    return string
  }

  // MARK: - styling helpers

  private static func font(_ readingFont: ResolvedReadingFont, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    var descriptor = readingFont.nsFontDescriptor(size: size)
    if weight == .bold || weight == .semibold {
      descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold])
    }
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
  }

  private static func plain(_ markdown: String) -> String {
    markdown
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "`", with: "")
  }

  /// 段内 Markdown（加粗/斜体/行内代码）经系统解析保留 trait，再统一基底字体。
  private static func inlineStyled(_ text: String, readingFont: ResolvedReadingFont) -> NSAttributedString {
    let parsed = MarkdownPresentation.inlineAttributed(text)
    let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let full = NSRange(location: 0, length: mutable.length)
    mutable.enumerateAttribute(.font, in: full) { value, range, _ in
      let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      var descriptor = readingFont.nsFontDescriptor(size: bodySize)
      if traits.contains(.bold) { descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold]) }
      if traits.contains(.italic) { descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .italic]) }
      let resolved = traits.contains(.monoSpace)
        ? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        : (NSFont(descriptor: descriptor, size: bodySize) ?? NSFont.systemFont(ofSize: bodySize))
      mutable.addAttribute(.font, value: resolved, range: range)
    }
    if mutable.length == 0 { return mutable }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    paragraph.paragraphSpacing = 10
    mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
    mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: mutable.length))
    mutable.append(NSAttributedString(string: "\n"))
    return mutable
  }

  private static func styledParagraph(
    _ text: String,
    font: NSFont,
    color: NSColor = .labelColor,
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat = 10,
    headIndent: CGFloat = 0,
    firstLineIndent: CGFloat = 0,
    lineSpacing: CGFloat = 4
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacingBefore = spacingBefore
    paragraph.paragraphSpacing = spacingAfter
    paragraph.headIndent = headIndent
    paragraph.firstLineHeadIndent = firstLineIndent
    paragraph.lineSpacing = lineSpacing
    return NSAttributedString(string: text + "\n", attributes: [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ])
  }
}
