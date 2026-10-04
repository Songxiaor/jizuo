import AppKit
import CoreText
import SwiftUI
import LinkDigestCore
import UniformTypeIdentifiers

/// App 层富格式导出：把与阅读区同源的 Markdown 按 App 排版（标题层级、
/// 正文行距、引用缩进、等宽代码）渲染为 PDF / Word。Core 的 md/txt/json
/// 导出保持原样；本文件只做展示格式，绝不改写存储内容。
enum ReadingDocumentExportError: Error {
  case docxImageEmbeddingFailed
}

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

  // MARK: - 题跋拼装（导出专用，从 HistoryContentView 提升，行为不变）

  /// 题跋各件共用的小投影：是否是用户自己写的东西（笔记/稿件/作品）、归属印、下载来源。
  /// 与详情页阅读区底部的落款同一套判断，导出与屏幕看到的一致。
  struct ExportColophonContext {
    let isOwnWriting: Bool
    let records: [ProcessStepRecord]
    let downloadSource: LocalFileProvenance?
    let glyph: SealMark.Glyph
    let text: String

    init(detail: HistoryDetailProjection, mindMap: TaskMindMapRecord?) {
      let lastKind = detail.snapshots.last?.sourceKind
      isOwnWriting = lastKind == CapturedDocument.Origin.userNote.rawValue
        || lastKind == CapturedDocument.Origin.pieceDraft.rawValue
        || lastKind == CapturedDocument.Origin.work.rawValue
      records = ProcessStepRecord.completed(in: detail, mindMap: mindMap)
      let host = HistoryPlatformRegistry.canonicalHost(
        for: URLComponents(string: detail.task.canonicalURL)?.host ?? ""
      )
      let ownership = ContentOwnership.resolve(
        canonicalURL: detail.task.canonicalURL, host: host, tagNames: detail.tags.map(\.name)
      )
      glyph = ownership == .own ? .own : .external
      if glyph == .external,
         let label = detail.snapshots.first(where: { $0.platform == LocalImportSource.files.rawValue })?.sourceLabel {
        downloadSource = LocalFileProvenance.parse(sourceLabel: label)
      } else {
        downloadSource = nil
      }
      let date = ColophonView.chineseDate(Date(timeIntervalSince1970: Double(detail.task.createdAtMilliseconds) / 1_000))
      let platform = downloadSource?.displaySourceName ?? HistoryPlatformDisplay.name(forHost: host)
      text = glyph == .external ? LocalFileProvenance.joined("\(date)　汲录自", platform) : "\(date)　记"
    }

    /// 题跋正文：「丙午年九月廿八日　汲录自抖音　录 · 校 · 评 · 摘」。笔记不加。
    var colophonLine: String? {
      guard !isOwnWriting else { return nil }
      let glyphs = records.map(\.step.glyph.rawValue)
      return glyphs.isEmpty ? text : text + "　" + glyphs.joined(separator: " · ")
    }
  }

  /// md / txt 的完整导出文本：正文 + （外部内容）末尾题跋行。
  /// `composed` 与界面导出同源（`HistoryViewModel.composeExportMarkdown()`）。
  static func cleanTextExport(
    composedMarkdown: String,
    format: HistoryExportFormat,
    context: ExportColophonContext
  ) -> String {
    let presented = cleaningExportCommentHeaders(composedMarkdown)
    let content: String
    switch format {
    case .plainText:
      // 纯文本：剥 Markdown 标记与 frontmatter，只留可读正文。
      let body = MarkdownNoteFrontmatter.parse(presented).body
      content = MarkdownPresentation.plainTextPresentation(body.isEmpty ? presented : body)
    default:
      content = presented
    }
    // 题跋跟着文件走：何时从哪里来、做过哪些工序（2026-09-28 工序印）。
    return context.colophonLine.map { content + "\n\n---\n\n" + $0 + "\n" } ?? content
  }

  /// PDF / Word 末尾的题跋：右对齐一行小字，后面画出真的章（渲染成图片放进去）。
  @MainActor
  static func exportColophonAttributed(
    context: ExportColophonContext,
    readingFont: ResolvedReadingFont
  ) -> NSAttributedString? {
    guard !context.isOwnWriting else { return nil }
    let style = NSMutableParagraphStyle()
    style.alignment = .right
    style.paragraphSpacingBefore = 28
    let result = NSMutableAttributedString(string: "\n" + context.text + "  ", attributes: [
      .font: NSFont(descriptor: readingFont.nsFontDescriptor(size: 11), size: 11) ?? NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: style,
    ])
    let seals = HStack(spacing: 5) {
      ForEach(context.records) { record in
        SealMark(glyph: record.step.glyph, size: 22, color: ExportPalette.seal, style: .stamped, rotation: record.step.rotation)
      }
      SealMark(glyph: context.glyph, size: 30, color: ExportPalette.seal, style: .stamped, rotation: -0.8)
    }
    .padding(2)
    let renderer = ImageRenderer(content: seals)
    renderer.scale = 3
    if let image = renderer.nsImage {
      let attachment = NSTextAttachment()
      attachment.image = image
      attachment.bounds = CGRect(x: 0, y: -9, width: image.size.width, height: image.size.height)
      let attached = NSMutableAttributedString(attachment: attachment)
      attached.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attached.length))
      result.append(attached)
    } else if let line = context.colophonLine {
      return NSAttributedString(string: "\n" + line, attributes: [.paragraphStyle: style])
    }
    return result
  }

  /// PDF / Word 的完整富文本：正文排版稿 + （外部内容）题跋与印章。
  @MainActor
  static func styledDocument(
    composedMarkdown: String,
    context: ExportColophonContext,
    readingFont: ResolvedReadingFont,
    localImageURLs: [URL]
  ) -> NSAttributedString {
    let body = MarkdownNoteFrontmatter.parse(composedMarkdown).body
    let document = NSMutableAttributedString(attributedString: attributedDocument(
      markdown: body.isEmpty ? composedMarkdown : body,
      readingFont: readingFont,
      localImageURLs: localImageURLs
    ))
    if let colophon = exportColophonAttributed(context: context, readingFont: readingFont) {
      let tagged = NSMutableAttributedString(attributedString: colophon)
      tagged.addAttribute(keepsWithPreviousPage, value: true, range: NSRange(location: 0, length: tagged.length))
      document.append(tagged)
    }
    return document
  }

  /// 题跋不能独占一页：正文正好写满上一页时，题跋会被挤到新的一页、孤零零一行，
  /// 收件人看着像排版出错（2026-10-04 实导：28 分钟转写稿第 19 页只剩落款）。
  static let keepsWithPreviousPage = NSAttributedString.Key("JizuoKeepsWithPreviousPage")

  /// 最后一页只剩带 `keepsWithPreviousPage` 的内容时，把上一页末尾几行让到最后一页，
  /// 落款跟着正文结尾走，照书的做法。
  private static func pullTailOntoLastPage(
    layoutManager: NSLayoutManager,
    textStorage: NSTextStorage,
    containers: [NSTextContainer],
    contentHeight: CGFloat
  ) {
    let filled = containers.filter { layoutManager.glyphRange(for: $0).length > 0 }
    guard filled.count >= 2, let last = filled.last else { return }
    let characters = layoutManager.characterRange(
      forGlyphRange: layoutManager.glyphRange(for: last), actualGlyphRange: nil
    )
    var onlyTail = true
    textStorage.enumerateAttribute(keepsWithPreviousPage, in: characters) { value, _, stop in
      if value == nil { onlyTail = false; stop.pointee = true }
    }
    guard onlyTail else { return }
    let previous = filled[filled.count - 2]
    // 让出约四行正文；末页本来只有一行落款，放得下。
    previous.size = CGSize(width: previous.size.width, height: max(contentHeight * 0.5, contentHeight - 96))
    layoutManager.ensureLayout(for: last)
  }

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
      return attributedTextOnly(markdown: markdown, readingFont: readingFont, localImageURLs: localImageURLs)
    }
    let result = NSMutableAttributedString()
    for segment in LocalMarkdownImageLayout.segments(markdown: markdown, localImageURLs: localImageURLs) {
      switch segment {
      case let .text(chunk):
        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result.append(attributedTextOnly(markdown: chunk, readingFont: readingFont, localImageURLs: localImageURLs))
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
      case let .video(video):
        let label = video.title?.isEmpty == false ? video.title! : video.platformLabel
        if let url = video.openURL {
          result.append(attributedTextOnly(markdown: "[\(label)](\(url.absoluteString))", readingFont: readingFont))
        } else {
          result.append(attributedTextOnly(markdown: label, readingFont: readingFont))
        }
        result.append(NSAttributedString(string: "\n\n"))
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

  private static func attributedTextOnly(
    markdown: String,
    readingFont: ResolvedReadingFont,
    localImageURLs: [URL] = []
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let blocks = MarkdownPresentation.blocks(from: markdown)
    for block in blocks {
      switch block {
      case let .heading(level, text):
        let size: CGFloat = [1: 19.0, 2: 16.0, 3: 14.0][level] ?? 13.5
        let weight: NSFont.Weight = level == 1 ? .bold : .semibold
        result.append(inlineBlock(
          text, readingFont: readingFont, baseSize: size, weight: weight,
          spacingBefore: 14, spacingAfter: 6
        ))
      case let .paragraph(text):
        let cleaned = MarkdownPresentation.droppingUnresolvedImages(text)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if let timecode = timecodeParagraph(trimmed, readingFont: readingFont) {
          result.append(timecode)
        } else {
          result.append(inlineStyled(cleaned, readingFont: readingFont))
        }
      case let .list(items):
        for item in items {
          let cleaned = MarkdownPresentation.droppingUnresolvedImages(item.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if cleaned.isEmpty { continue }
          let marker = String(repeating: "    ", count: item.depth) + (item.depth == 0 ? "• " : "◦ ")
          result.append(inlineBlock(
            cleaned, readingFont: readingFont, prefix: marker,
            spacingBefore: 0, spacingAfter: 4, headIndent: CGFloat(14 + item.depth * 14)
          ))
        }
      case let .orderedList(start, items):
        for (index, item) in items.enumerated() {
          let cleaned = MarkdownPresentation.droppingUnresolvedImages(item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if cleaned.isEmpty { continue }
          result.append(inlineBlock(
            cleaned, readingFont: readingFont, prefix: "\(start + index). ",
            spacingBefore: 0, spacingAfter: 4, headIndent: 14
          ))
        }
      case let .taskList(items):
        for item in items {
          // 导出成字符而不是画复选框：产物要能贴进邮件、文档、聊天窗口，
          // 那些地方没有我们的图形，字符到哪都还是同一个意思。
          let cleaned = MarkdownPresentation.droppingUnresolvedImages(item.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if cleaned.isEmpty { continue }
          result.append(inlineBlock(
            cleaned, readingFont: readingFont, prefix: (item.isDone ? "☑ " : "☐ "),
            spacingBefore: 0, spacingAfter: 4, headIndent: 14
          ))
        }
      case .divider:
        result.append(styledParagraph(
          String(repeating: "─", count: 24),
          font: font(readingFont, size: bodySize, weight: .regular),
          spacingBefore: 8, spacingAfter: 8
        ))
      case let .quote(_, text):
        result.append(inlineBlock(
          text, readingFont: readingFont, color: .secondaryLabelColor,
          spacingBefore: 6, spacingAfter: 6, headIndent: 18, firstLineIndent: 18
        ))
      case let .callout(kind, title, text, _):
        let label = title.isEmpty ? MarkdownPresentation.calloutLabel(kind) : title
        result.append(inlineBlock(
          text.isEmpty ? label : "\(label)  \(text)",
          readingFont: readingFont, color: .secondaryLabelColor,
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
          if let likes = item.likes { metadata += " · 赞 \(likes)" }
          if let published = item.published {
            metadata += " · \(CommentPublishedTime.localStamp(published))"
          }
          result.append(styledParagraph(
            metadata,
            font: font(readingFont, size: bodySize, weight: .semibold),
            color: .secondaryLabelColor,
            spacingBefore: 4, spacingAfter: 3, headIndent: indent, firstLineIndent: indent
          ))
          if !item.body.isEmpty {
            result.append(commentBodyAttributed(
              item.body, indent: indent, readingFont: readingFont, localImageURLs: localImageURLs
            ))
          }
        }
      case let .table(headers, rows, _):
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
    pullTailOntoLastPage(
      layoutManager: layoutManager, textStorage: textStorage,
      containers: containers, contentHeight: contentRect.height
    )

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
      annotateLinks(
        layoutManager: layoutManager, container: container, context: context,
        contentRect: contentRect, pageRect: pageRect
      )
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }

  /// AppKit 原生 OOXML 写出，再把被转换器丢掉的图片附件嵌回去。
  /// 任何一步失败都抛错，不返回一份悄悄缺图的文件。
  static func docxData(from attributed: NSAttributedString) throws -> Data {
    let (prepared, images) = try replacingImageAttachments(in: attributed)
    let raw = try prepared.data(
      from: NSRange(location: 0, length: prepared.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
    )
    guard !images.isEmpty else { return raw }
    return try embeddingImages(images, into: raw)
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

  /// 段内 Markdown（加粗/斜体/链接/行内代码）经系统解析保留 trait，再统一基底字体。
  private static func inlineStyled(_ text: String, readingFont: ResolvedReadingFont) -> NSAttributedString {
    inlineBlock(text, readingFont: readingFont, spacingBefore: 0, spacingAfter: 10, lineSpacing: 4)
  }

  private static func inlineBlock(
    _ markdown: String,
    readingFont: ResolvedReadingFont,
    prefix: String = "",
    baseSize: CGFloat = bodySize,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat = 10,
    headIndent: CGFloat = 0,
    firstLineIndent: CGFloat = 0,
    lineSpacing: CGFloat = 4
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    if !prefix.isEmpty {
      result.append(NSAttributedString(string: prefix, attributes: [
        .font: font(readingFont, size: baseSize, weight: weight),
        .foregroundColor: color,
      ]))
    }
    result.append(inlineRuns(markdown, readingFont: readingFont, baseSize: baseSize, weight: weight, color: color))
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacingBefore = spacingBefore
    paragraph.paragraphSpacing = spacingAfter
    paragraph.headIndent = headIndent
    paragraph.firstLineHeadIndent = firstLineIndent
    paragraph.lineSpacing = lineSpacing
    result.append(NSAttributedString(string: "\n"))
    if result.length > 0 {
      result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
    }
    return result
  }

  private static func inlineRuns(
    _ markdown: String,
    readingFont: ResolvedReadingFont,
    baseSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
  ) -> NSAttributedString {
    let source = MarkdownPresentation.droppingUnresolvedImages(markdown)
    let parsed = MarkdownPresentation.inlineAttributed(source)
    let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let full = NSRange(location: 0, length: mutable.length)
    guard full.length > 0 else { return mutable }
    mutable.enumerateAttribute(.font, in: full) { value, range, _ in
      let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      var descriptor = readingFont.nsFontDescriptor(size: baseSize)
      if traits.contains(.bold) || weight == .bold || weight == .semibold {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold])
      }
      if traits.contains(.italic) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .italic])
      }
      let resolved = traits.contains(.monoSpace)
        ? NSFont.monospacedSystemFont(ofSize: min(codeSize, baseSize), weight: .regular)
        : (NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize, weight: weight))
      mutable.addAttribute(.font, value: resolved, range: range)
    }
    mutable.addAttribute(.foregroundColor, value: color, range: full)
    mutable.enumerateAttribute(.link, in: full) { value, range, _ in
      guard value != nil else { return }
      mutable.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
      mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }
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

  // MARK: - export text cleanup

  struct PreparedExport: Equatable {
    let title: String
    let body: String
    /// 笔记的 `linkdigest-note:` 是本机行标识，不写进 frontmatter。
    let includesSource: Bool
  }

  /// 占位标题换成正文首个标题；和导出标题同一句的开头只留一次；
  /// 灯箱文件信息、时间码后的多余空格在这里收掉。
  static func preparedExport(storedTitle: String, canonicalURL: String, body: String) -> PreparedExport {
    let isNote = canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
    var title = storedTitle
    if isNote, let derived = UserNoteDocument.displayTitle(stored: storedTitle, body: body) {
      title = derived
    }
    var cleaned = MarkdownNoteFrontmatter.strippingViewCountUnderLeadingHeading(body)
    cleaned = CapturedSourceBodyPresentation.strippingFirstEchoedHeading(title: title, from: cleaned)
    cleaned = MarkdownPresentation.strippingLightboxFileInfo(cleaned)
    cleaned = normalizingLeadingTimecodes(cleaned)
    return PreparedExport(title: title, body: cleaned, includesSource: !isNote)
  }

  /// 行首时间码后面统一一个空格。`26:57  And` → `26:57 And`。代码块不动。
  static func normalizingLeadingTimecodes(_ markdown: String) -> String {
    var inFence = false
    return markdown.components(separatedBy: "\n").map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        return line
      }
      guard !inFence, let split = splitTimecode(line) else { return line }
      let indent = String(line.prefix { $0 == " " || $0 == "\t" })
      if split.rest.isEmpty { return indent + split.code }
      return indent + split.code + " " + split.rest
    }.joined(separator: "\n")
  }

  /// md / txt：评论头去掉「回复层级 N」，机器时间改成本地「yyyy-MM-dd HH:mm」。
  /// PDF 仍靠原文里的「回复层级」认出评论，所以这一步只走文本导出。
  static func cleaningExportCommentHeaders(
    _ markdown: String,
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String {
    var inFence = false
    return markdown.components(separatedBy: "\n").map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        return line
      }
      guard !inFence else { return line }
      return cleaningExportCommentHeaderLine(line, timeZone: timeZone, calendar: calendar)
    }.joined(separator: "\n")
  }

  private static func cleaningExportCommentHeaderLine(
    _ line: String,
    timeZone: TimeZone,
    calendar: Calendar
  ) -> String {
    guard line.contains("回复层级 ") || line.contains("[原评论](") || line.contains("score ") || line.contains("赞 ")
    else { return line }
    let indent = line.prefix { $0 == " " || $0 == "\t" }
    let trimmed = line.dropFirst(indent.count)
    guard trimmed.hasPrefix("- **") else { return line }
    let after = trimmed.dropFirst(4)
    guard let close = after.range(of: "**") else { return line }
    let author = after[..<close.lowerBound]
    var details = String(after[close.upperBound...]).trimmingCharacters(in: .whitespaces)
    if details.hasPrefix("·") {
      details = String(details.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    let kept = details.components(separatedBy: " · ").compactMap { part -> String? in
      let value = part.trimmingCharacters(in: .whitespaces)
      if value.isEmpty || value.hasPrefix("回复层级 ") { return nil }
      let stamped = CommentPublishedTime.localStamp(value, timeZone: timeZone, calendar: calendar)
      return stamped
    }
    var result = "\(indent)- **\(author)**"
    if !kept.isEmpty { result += " · " + kept.joined(separator: " · ") }
    return result
  }

  private static func timecodeParagraph(_ text: String, readingFont: ResolvedReadingFont) -> NSAttributedString? {
    guard !text.contains("\n"), let split = splitTimecode(text.trimmingCharacters(in: .whitespaces)) else {
      return nil
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    paragraph.paragraphSpacing = 6
    let result = NSMutableAttributedString()
    let codeFont = NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
    result.append(NSAttributedString(string: split.code, attributes: [
      .font: codeFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]))
    if !split.rest.isEmpty {
      result.append(NSAttributedString(string: " " + split.rest, attributes: [
        .font: font(readingFont, size: bodySize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
      ]))
    }
    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
    return result
  }

  /// 行首 `MM:SS` / `H:MM:SS`，后面至少一个空白。返回的 code 不含空白，rest 已去掉多余空白。
  private static func splitTimecode(_ line: String) -> (code: String, rest: String)? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }
    let body = line.dropFirst(indent.count)
    var index = body.startIndex
    var fields: [String] = []
    var digits = ""
    while index < body.endIndex {
      let character = body[index]
      if character.isNumber {
        digits.append(character)
        if digits.count > 2 { return nil }
        index = body.index(after: index)
        continue
      }
      if character == ":" {
        guard (1...2).contains(digits.count) else { return nil }
        fields.append(digits)
        digits = ""
        index = body.index(after: index)
        continue
      }
      break
    }
    guard digits.count == 2, (1...2).contains(fields.count) else { return nil }
    guard index < body.endIndex, body[index] == " " || body[index] == "\t" else { return nil }
    let code = (fields + [digits]).joined(separator: ":")
    let rest = body[index...].drop { $0 == " " || $0 == "\t" }
    return (code, String(rest))
  }

  private static func commentBodyAttributed(
    _ body: String,
    indent: CGFloat,
    readingFont: ResolvedReadingFont,
    localImageURLs: [URL]
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let segments = LocalMarkdownImageLayout.segments(
      markdown: body,
      localImageURLs: localImageURLs,
      appendsUnusedLocalImages: false
    )
    for segment in segments {
      switch segment {
      case let .text(text):
        let blocks = MarkdownPresentation.blocks(from: MarkdownPresentation.droppingUnresolvedImages(text))
        for block in blocks {
          result.append(commentBlock(block, indent: indent, readingFont: readingFont))
        }
      case let .image(url):
        if let attachment = imageAttachment(url: url) {
          result.append(attachment)
          result.append(NSAttributedString(string: "\n"))
        }
      case let .gallery(urls):
        for url in urls {
          if let attachment = imageAttachment(url: url) {
            result.append(attachment)
            result.append(NSAttributedString(string: "\n"))
          }
        }
      case let .video(video):
        let label = video.title?.isEmpty == false ? video.title! : video.platformLabel
        result.append(inlineBlock(label, readingFont: readingFont, spacingBefore: 2, spacingAfter: 4, headIndent: indent, firstLineIndent: indent))
      case let .quotedTweet(quote):
        if !quote.text.isEmpty {
          result.append(inlineBlock(quote.text, readingFont: readingFont, color: .secondaryLabelColor, spacingBefore: 2, spacingAfter: 4, headIndent: indent, firstLineIndent: indent))
        }
      }
    }
    return result
  }

  private static func commentBlock(
    _ block: MarkdownPresentation.Block,
    indent: CGFloat,
    readingFont: ResolvedReadingFont
  ) -> NSAttributedString {
    switch block {
    case let .heading(_, text):
      return inlineBlock(
        text, readingFont: readingFont, baseSize: bodySize, weight: .semibold,
        spacingBefore: 4, spacingAfter: 3, headIndent: indent, firstLineIndent: indent, lineSpacing: 2
      )
    case let .paragraph(text):
      let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty else { return NSAttributedString() }
      return inlineBlock(
        cleaned, readingFont: readingFont,
        spacingBefore: 0, spacingAfter: 6, headIndent: indent, firstLineIndent: indent, lineSpacing: 3
      )
    case let .list(items):
      let result = NSMutableAttributedString()
      for item in items {
        let cleaned = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { continue }
        let marker = String(repeating: "    ", count: item.depth) + (item.depth == 0 ? "• " : "◦ ")
        result.append(inlineBlock(
          cleaned, readingFont: readingFont, prefix: marker,
          spacingBefore: 0, spacingAfter: 3, headIndent: indent + 14, firstLineIndent: indent, lineSpacing: 2
        ))
      }
      return result
    case let .orderedList(start, items):
      let result = NSMutableAttributedString()
      for (index, item) in items.enumerated() {
        result.append(inlineBlock(
          item, readingFont: readingFont, prefix: "\(start + index). ",
          spacingBefore: 0, spacingAfter: 3, headIndent: indent + 14, firstLineIndent: indent, lineSpacing: 2
        ))
      }
      return result
    case let .quote(_, text):
      return inlineBlock(
        text, readingFont: readingFont, color: .secondaryLabelColor,
        spacingBefore: 2, spacingAfter: 4, headIndent: indent + 12, firstLineIndent: indent + 12, lineSpacing: 2
      )
    case let .code(_, content):
      return styledParagraph(
        content,
        font: .monospacedSystemFont(ofSize: codeSize, weight: .regular),
        spacingBefore: 4, spacingAfter: 4, headIndent: indent + 12, firstLineIndent: indent + 12, lineSpacing: 2
      )
    case .divider, .comments:
      return NSAttributedString()
    case let .taskList(items):
      let result = NSMutableAttributedString()
      for item in items {
        result.append(inlineBlock(
          item.text, readingFont: readingFont, prefix: (item.isDone ? "☑ " : "☐ "),
          spacingBefore: 0, spacingAfter: 3, headIndent: indent + 14, firstLineIndent: indent
        ))
      }
      return result
    case let .callout(_, title, text, _):
      let label = title.isEmpty ? text : (text.isEmpty ? title : "\(title)  \(text)")
      return inlineBlock(label, readingFont: readingFont, color: .secondaryLabelColor, spacingBefore: 2, spacingAfter: 4, headIndent: indent, firstLineIndent: indent)
    case let .table(headers, rows, _):
      let result = NSMutableAttributedString()
      result.append(styledParagraph(headers.joined(separator: " · "), font: font(readingFont, size: bodySize, weight: .semibold), spacingBefore: 4, spacingAfter: 2, headIndent: indent, firstLineIndent: indent))
      for row in rows {
        result.append(styledParagraph(row.joined(separator: " · "), font: font(readingFont, size: bodySize, weight: .regular), spacingBefore: 0, spacingAfter: 2, headIndent: indent + 8, firstLineIndent: indent + 8))
      }
      return result
    }
  }

  private static func annotateLinks(
    layoutManager: NSLayoutManager,
    container: NSTextContainer,
    context: CGContext,
    contentRect: CGRect,
    pageRect: CGRect
  ) {
    guard let storage = layoutManager.textStorage else { return }
    let glyphRange = layoutManager.glyphRange(for: container)
    guard glyphRange.length > 0 else { return }
    let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    storage.enumerateAttribute(.link, in: charRange) { value, range, _ in
      let url = Self.linkURL(value)
      guard let url else { return }
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let clipped = NSIntersectionRange(glyphs, glyphRange)
      guard clipped.length > 0 else { return }
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: clipped,
        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: container
      ) { rect, _ in
        let pdfRect = CGRect(
          x: contentRect.minX + rect.minX,
          y: pageRect.height - contentRect.minY - rect.maxY,
          width: rect.width,
          height: rect.height
        )
        context.setURL(url as CFURL, for: pdfRect)
      }
    }
  }

  // MARK: - docx images

  private struct EmbeddedDocxImage {
    let png: Data
    let widthPt: CGFloat
    let heightPt: CGFloat
  }

  private static func replacingImageAttachments(
    in source: NSAttributedString
  ) throws -> (NSAttributedString, [EmbeddedDocxImage]) {
    let raw = source.string as NSString
    var images: [EmbeddedDocxImage] = []
    let result = NSMutableAttributedString()
    var cursor = 0
    while cursor < raw.length {
      let character = raw.character(at: cursor)
      if character == 0xFFFC {
        guard let attachment = source.attribute(.attachment, at: cursor, effectiveRange: nil) as? NSTextAttachment
        else { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
        let png = try pngData(from: attachment)
        let (width, height) = displaySize(of: attachment)
        let token = "[[JZIMG:\(images.count)]]"
        images.append(EmbeddedDocxImage(png: png, widthPt: width, heightPt: height))
        var attributes = source.attributes(at: cursor, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        result.append(NSAttributedString(string: token, attributes: attributes))
        cursor += 1
        continue
      }
      var next = cursor + 1
      while next < raw.length, raw.character(at: next) != 0xFFFC { next += 1 }
      result.append(source.attributedSubstring(from: NSRange(location: cursor, length: next - cursor)))
      cursor = next
    }
    return (result, images)
  }

  private static func displaySize(of attachment: NSTextAttachment) -> (CGFloat, CGFloat) {
    var width = attachment.bounds.width
    var height = attachment.bounds.height
    if width < 1 || height < 1, let image = attachment.image, image.size.width > 0, image.size.height > 0 {
      width = image.size.width
      height = image.size.height
    }
    let maxWidth: CGFloat = 460
    guard width > 0, height > 0 else { return (maxWidth, maxWidth * 0.6) }
    if width > maxWidth {
      let scale = maxWidth / width
      width *= scale
      height *= scale
    }
    return (width, height)
  }

  private static func pngData(from attachment: NSTextAttachment) throws -> Data {
    if let image = attachment.image, let png = pngData(from: image) { return png }
    if let data = attachment.contents, let image = NSImage(data: data), let png = pngData(from: image) { return png }
    if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data), let png = pngData(from: image) {
      return png
    }
    throw ReadingDocumentExportError.docxImageEmbeddingFailed
  }

  private static func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return png
  }

  private static func embeddingImages(_ images: [EmbeddedDocxImage], into docx: Data) throws -> Data {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jizuo-docx-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appendingPathComponent("in.docx")
    let unpackURL = root.appendingPathComponent("unpacked", isDirectory: true)
    let outURL = root.appendingPathComponent("out.docx")
    try docx.write(to: zipURL)
    try runTool("/usr/bin/unzip", ["-q", "-o", zipURL.path, "-d", unpackURL.path])

    let documentURL = unpackURL.appendingPathComponent("word/document.xml")
    guard var document = try? String(contentsOf: documentURL, encoding: .utf8) else {
      throw ReadingDocumentExportError.docxImageEmbeddingFailed
    }
    document = try replacingImagePlaceholders(in: document, images: images)
    try document.write(to: documentURL, atomically: true, encoding: .utf8)

    let mediaURL = unpackURL.appendingPathComponent("word/media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    for (index, image) in images.enumerated() {
      try image.png.write(to: mediaURL.appendingPathComponent("image\(index + 1).png"))
    }

    let typesURL = unpackURL.appendingPathComponent("[Content_Types].xml")
    guard var types = try? String(contentsOf: typesURL, encoding: .utf8) else {
      throw ReadingDocumentExportError.docxImageEmbeddingFailed
    }
    if !types.contains("Extension=\"png\"") {
      guard let range = types.range(of: "</Types>") else { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
      types.replaceSubrange(range, with: "<Default Extension=\"png\" ContentType=\"image/png\"/></Types>")
      try types.write(to: typesURL, atomically: true, encoding: .utf8)
    }

    let relsURL = unpackURL.appendingPathComponent("word/_rels/document.xml.rels")
    guard var rels = try? String(contentsOf: relsURL, encoding: .utf8),
          let relsEnd = rels.range(of: "</Relationships>")
    else { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
    let relationships = images.indices.map { (index: Int) -> String in
      let n = index + 1
      return "<Relationship Id=\"rIdJZIMG\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(n).png\"/>"
    }.joined()
    rels.replaceSubrange(relsEnd, with: relationships + "</Relationships>")
    try rels.write(to: relsURL, atomically: true, encoding: .utf8)

    try runTool("/usr/bin/zip", ["-qr", "-X", outURL.path, "."], directory: unpackURL)
    guard let packed = try? Data(contentsOf: outURL), packed.starts(with: [0x50, 0x4B]) else {
      throw ReadingDocumentExportError.docxImageEmbeddingFailed
    }
    return packed
  }

  private static func replacingImagePlaceholders(in xml: String, images: [EmbeddedDocxImage]) throws -> String {
    var xml = xml
    if !xml.contains("xmlns:wp=") {
      xml = xml.replacingOccurrences(
        of: "<w:document",
        with: "<w:document xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
      )
    }
    for index in images.indices {
      let token = "[[JZIMG:\(index)]]"
      guard let tokenRange = xml.range(of: token) else { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
      let drawing = drawingRun(index: index, image: images[index])
      if let run = enclosingRunRange(containing: tokenRange, in: xml),
         runContainsOnlyToken(run, token: token, in: xml) {
        xml.replaceSubrange(run, with: drawing)
      } else {
        xml.replaceSubrange(tokenRange, with: "</w:t></w:r>\(drawing)<w:r><w:t xml:space=\"preserve\">")
      }
    }
    if xml.contains("[[JZIMG:") { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
    return xml
  }

  private static func enclosingRunRange(containing token: Range<String.Index>, in xml: String) -> Range<String.Index>? {
    var searchEnd = token.lowerBound
    while searchEnd > xml.startIndex,
          let found = xml[..<searchEnd].range(of: "<w:r", options: .backwards) {
      let next = found.upperBound
      if next < xml.endIndex {
        let character = xml[next]
        // `<w:rPr` 也以 `<w:r` 开头，不能当成 run。
        if character == ">" || character.isWhitespace {
          guard let runEnd = xml.range(of: "</w:r>", range: token.upperBound..<xml.endIndex) else { return nil }
          return found.lowerBound..<runEnd.upperBound
        }
      }
      searchEnd = found.lowerBound
    }
    return nil
  }

  private static func runContainsOnlyToken(_ run: Range<String.Index>, token: String, in xml: String) -> Bool {
    let slice = String(xml[run])
    let text = slice.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines) == token
  }

  private static func drawingRun(index: Int, image: EmbeddedDocxImage) -> String {
    let n = index + 1
    let cx = emu(image.widthPt)
    let cy = emu(image.heightPt)
    return """
    <w:r><w:drawing xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(n)" name="Picture \(n)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).png"/><pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdJZIMG\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
    """
  }

  private static func linkURL(_ value: Any?) -> URL? {
    if let url = value as? URL { return url }
    if let url = value as? NSURL { return url as URL }
    if let string = value as? String { return URL(string: string) }
    return nil
  }

  private static func emu(_ points: CGFloat) -> Int {
    max(1, Int((points * 12_700).rounded()))
  }

  private static func runTool(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ReadingDocumentExportError.docxImageEmbeddingFailed }
  }
}
