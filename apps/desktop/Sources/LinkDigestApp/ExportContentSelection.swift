import AppKit
import Foundation
import LinkDigestCore

/// 保存框里能勾的一层。名字和阅读页签一致。
///
/// 顺序就是导出顺序：总结在最前，评论在最后。当前页签那一层会在拼正文时
/// 提到总结之后，不改变这里的顺序。
enum ExportContentLayer: String, CaseIterable, Hashable, Sendable {
  case summary
  case source
  case caption
  case transcript
  case proofread
  case machineTranscript
  case translation
  case comments

  /// 页签上的叫法。翻译页签叫「翻译」，导出的这一层叫「译文」。
  var title: String {
    switch self {
    case .summary: "总结"
    case .source: "原文"
    case .caption: "配文"
    case .transcript: "转写"
    case .proofread: "校对稿"
    case .machineTranscript: "原稿"
    case .translation: "译文"
    case .comments: "评论"
    }
  }
}

/// 一次导出勾了哪些层，以及打开保存框时正在看哪一层。
struct ExportContentSelection: Equatable, Sendable {
  var layers: Set<ExportContentLayer>
  /// 打开保存框时正在看的那一层。它排在总结之后、其余层之前。
  var current: ExportContentLayer?

  /// 只勾了一层时，文件名加上这一层的名字。多层不加。
  var filenameSuffix: String? {
    guard layers.count == 1, let only = layers.first else { return nil }
    return only.title
  }

  /// 没传选择时用：这条实际有的层全带上。
  static func everything(in detail: HistoryDetailProjection) -> ExportContentSelection {
    ExportContentSelection(layers: Set(ExportContentDocument(detail: detail).available), current: nil)
  }

  /// 打开保存框时的默认勾选。
  ///
  /// 停在「翻译」只勾译文。停在原文、配文、转写、校对稿、原稿，只勾那一层。
  /// 停在「总结」勾总结和原文那一层（普通文章是原文，转写类是当前那一层）。
  /// 评论用上次记住的选择，第一次默认勾上。
  static func initial(
    available: [ExportContentLayer],
    current: ExportContentLayer,
    includeComments: Bool
  ) -> ExportContentSelection {
    var layers: Set<ExportContentLayer> = []
    switch current {
    case .summary:
      layers.insert(.summary)
      if let body = available.first(where: { $0.isSourceBody }) { layers.insert(body) }
    case .comments:
      break
    default:
      if available.contains(current) { layers.insert(current) }
    }
    if includeComments, available.contains(.comments) { layers.insert(.comments) }
    return ExportContentSelection(layers: layers, current: current)
  }
}

private extension ExportContentLayer {
  var isSourceBody: Bool {
    switch self {
    case .source, .caption, .transcript, .proofread, .machineTranscript: true
    case .summary, .translation, .comments: false
    }
  }
}

/// 一条记录里实际有哪些可导出的层，以及勾选之后拼出来的正文。
struct ExportContentDocument: Sendable {
  let available: [ExportContentLayer]
  private let pieces: [ExportContentLayer: Piece]
  private let sourceComments: String
  private let translatedComments: String

  init(detail: HistoryDetailProjection) {
    let built = Self.build(detail)
    available = built.available
    pieces = built.pieces
    sourceComments = built.sourceComments
    translatedComments = built.translatedComments
  }

  private struct Piece {
    var heading: String
    var body: String
    /// 旁边没有任何别的层时，这一层不加标题。普通文章只有原文时就是这样。
    var unlabeledWhenAlone: Bool
  }

  /// 当前页签对应哪一层。转写类按页签名字对应；普通文章的「原文」页对应 `.source`。
  func layer(forReadingTitle title: String) -> ExportContentLayer? {
    switch title {
    case "总结": .summary
    case "翻译": .translation
    case "原文": available.contains(.source) ? .source : nil
    case "配文": .caption
    case "转写", "转写稿": available.contains(.proofread) ? .proofread : .transcript
    case "校对稿": .proofread
    case "原稿": .machineTranscript
    default: nil
    }
  }

  func body(selecting selection: ExportContentSelection) -> String {
    body(selecting: selection.layers, current: selection.current)
  }

  func body(selecting layers: Set<ExportContentLayer>, current: ExportContentLayer? = nil) -> String {
    var chosen = available.filter { layers.contains($0) && $0 != .comments }
    // 总结永远在最前。当前页签那一层紧跟其后，其余层保持原顺序，评论最后。
    if let current, current != .summary, let index = chosen.firstIndex(of: current), index > 0 {
      let layer = chosen.remove(at: index)
      let insertAt = chosen.first == .summary ? 1 : 0
      chosen.insert(layer, at: insertAt)
    }
    let alone = chosen.count == 1
    var sections = chosen.compactMap { layer -> String? in
      guard let piece = pieces[layer], !piece.body.isEmpty else { return nil }
      let labeled = !(alone && piece.unlabeledWhenAlone)
      // 降标题统一在 sectionBody 里做一次。总结在这里再降一次会把 `## 要点` 变成 `####`。
      return sectionBody(piece.body, heading: piece.heading, labeled: labeled)
    }
    if layers.contains(.comments), let comments = comments(selecting: layers) {
      sections.append(comments)
    }
    return sections.joined(separator: "\n\n")
  }

  /// 只勾译文时用评论译文，没有就用原评论。原文和译文都勾时，原评论在前，
  /// 评论译文跟在每条下面。
  private func comments(selecting layers: Set<ExportContentLayer>) -> String? {
    let wantsSource = layers.contains { $0.isSourceBody }
    let wantsTranslation = layers.contains(.translation)
    if wantsTranslation, !wantsSource {
      if !translatedComments.isEmpty {
        return translatedCommentSection(translatedComments, levels: 0)
      }
      return sourceComments.isEmpty ? nil : sourceComments
    }
    guard !sourceComments.isEmpty else {
      return translatedComments.isEmpty ? nil : translatedComments
    }
    guard wantsTranslation, !translatedComments.isEmpty else { return sourceComments }
    if let merged = Self.interleavingComments(sourceComments, translated: translatedComments) {
      return merged
    }
    // 对不上哪条译文属于哪条评论时，整段评论译文放在后面，一条都不丢。
    return sourceComments + "\n\n" + translatedCommentSection(translatedComments, levels: 1)
  }

  /// 评论里的一条：头一行（作者、赞、链接）和下面的正文行。
  private struct CommentEntry {
    var header: String
    var body: [String]
    /// 头一行前面的空白。正文比它多缩进两格。
    var indent: String
    var permalink: String?
  }

  /// 把评论段拆成「标题等前导行」和一条条评论。认不出评论头就返回 nil。
  private static func commentEntries(_ markdown: String) -> (lead: [String], entries: [CommentEntry])? {
    let lines = markdown.components(separatedBy: "\n")
    let isReplies = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 评论与回复（") }
    var lead: [String] = []
    var entries: [CommentEntry] = []
    for line in lines {
      if let header = commentHeader(line, isReplies: isReplies) {
        entries.append(CommentEntry(header: line, body: [], indent: header.indent, permalink: header.permalink))
      } else if entries.isEmpty {
        lead.append(line)
      } else {
        entries[entries.count - 1].body.append(line)
      }
    }
    return entries.isEmpty ? nil : (lead, entries)
  }

  /// 和阅读区认评论头的规则一致：`- **作者** · …`，带分数、链接或回复层级；
  /// 「评论与回复」只认顶格的。正文里的 `- **重点**` 不算。
  private static func commentHeader(_ line: String, isReplies: Bool) -> (indent: String, permalink: String?)? {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let trimmed = line.dropFirst(indent.count)
    guard trimmed.hasPrefix("- **") else { return nil }
    let afterMarker = trimmed.dropFirst(4)
    guard let closing = afterMarker.range(of: "**"),
          !afterMarker[..<closing.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    let author = afterMarker[..<closing.lowerBound]
    let details = String(afterMarker[closing.upperBound...])
    if isReplies {
      guard indent.isEmpty else { return nil }
    } else {
      guard author.hasPrefix("u/") || details.contains("score ") || details.contains("[原评论](")
        || details.contains("回复层级 ") else { return nil }
    }
    let permalink = details.components(separatedBy: " · ").lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("[原评论](") && $0.hasSuffix(")") }
    return (indent, permalink)
  }

  /// 原文和译文都勾时，每条评论头下面先放译文，原评论紧跟在下面，用引用写，
  /// PDF 和 Word 里引用是浅色字，读起来译文为主、原文作对照。
  /// 先按「原评论」链接对；没有链接的，两边条数相同时按位置对。
  /// 有一条译文找不到对应的评论就返回 nil，交给整段放后面的做法。
  private static func interleavingComments(_ source: String, translated: String) -> String? {
    guard let original = commentEntries(source), let translation = commentEntries(translated) else { return nil }
    let entries = original.entries
    let others = translation.entries
    var matched: [Int?] = Array(repeating: nil, count: entries.count)
    var used = Set<Int>()
    for (index, entry) in entries.enumerated() {
      guard let link = entry.permalink else { continue }
      if let found = others.indices.first(where: { !used.contains($0) && others[$0].permalink == link }) {
        matched[index] = found
        used.insert(found)
      }
    }
    if entries.count == others.count {
      for index in entries.indices where matched[index] == nil && !used.contains(index) {
        // 有链接却和对面链接不同，不硬按位置对。
        if let link = entries[index].permalink, let other = others[index].permalink, link != other { continue }
        matched[index] = index
        used.insert(index)
      }
    }
    guard used.count == others.count else { return nil }

    var lines = original.lead
    for (index, entry) in entries.enumerated() {
      var body = entry.body
      while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
      lines.append(entry.header)
      let originalBody = Self.commentBodyText(body, removingIndent: entry.indent.count + 2)
      let translatedBody = matched[index].map {
        Self.commentBodyText(others[$0].body, removingIndent: others[$0].indent.count + 2)
      } ?? []
      // 没有译文，或译文和原文一样（本来就是中文），原评论照常显示一遍。
      guard !translatedBody.isEmpty, translatedBody != originalBody else {
        lines.append(contentsOf: body)
        continue
      }
      // 译文、原文之间不空行：`>` 行本身就会另起一块，Markdown 和 PDF 都认。
      let bodyIndent = entry.indent + "  "
      lines.append(contentsOf: translatedBody.map { $0.isEmpty ? "" : bodyIndent + $0 })
      lines.append(contentsOf: originalBody.map { $0.isEmpty ? bodyIndent + ">" : bodyIndent + "> " + $0 })
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 评论正文去掉评论自带的缩进，首尾空行去掉，用来比较和重新缩进。
  private static func commentBodyText(_ lines: [String], removingIndent count: Int) -> [String] {
    var result = lines.map { line -> String in
      var rest = Substring(line)
      var removed = 0
      while removed < count, let first = rest.first, first == " " || first == "\t" {
        rest = rest.dropFirst()
        removed += 1
      }
      return String(rest).trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(rest)
    }
    while result.first?.isEmpty == true { result.removeFirst() }
    while result.last?.isEmpty == true { result.removeLast() }
    return result
  }

  private struct Built {
    var available: [ExportContentLayer] = []
    var pieces: [ExportContentLayer: Piece] = [:]
    var sourceComments = ""
    var translatedComments = ""
  }

  private static func build(_ detail: HistoryDetailProjection) -> Built {
    var built = Built()
    let source = splittingComments(from: LayeredSourceDocument.modelInput(from: detail.snapshots))
    let summary = latest(detail, .summarize)
    let translation = latest(detail, .translate).map(splittingComments(from:))

    if let summary {
      built.available.append(.summary)
      built.pieces[.summary] = Piece(heading: "总结", body: summary, unlabeledWhenAlone: false)
    }

    let layered = sourceLayers(in: detail)
    if layered.count > 1 {
      for layer in layered where !layer.body.isEmpty {
        built.available.append(layer.kind)
        built.pieces[layer.kind] = Piece(heading: layer.kind.title, body: layer.body, unlabeledWhenAlone: false)
      }
    } else if !source.article.isEmpty {
      built.available.append(.source)
      built.pieces[.source] = Piece(heading: "原文", body: source.article, unlabeledWhenAlone: true)
    }

    if let article = translation?.article, !article.isEmpty {
      built.available.append(.translation)
      built.pieces[.translation] = Piece(heading: "译文", body: article, unlabeledWhenAlone: false)
    }

    built.sourceComments = source.comments
    built.translatedComments = translation?.comments ?? ""
    if !built.sourceComments.isEmpty || !built.translatedComments.isEmpty {
      built.available.append(.comments)
    }
    return built
  }

  private struct SourceLayerText {
    var kind: ExportContentLayer
    var body: String
  }

  /// 配文、转写、校对稿、原稿。只有转写、没有配文时仍叫「转写」，不叫「原文」。
  private static func sourceLayers(in detail: HistoryDetailProjection) -> [SourceLayerText] {
    let snapshots = detail.snapshots
    let caption = LayeredSourceDocument.captionSnapshot(in: snapshots)
      .flatMap { LayeredSourceDocument.isSupersededPlaceholder($0, in: snapshots) ? nil : $0 }
    let transcript = LayeredSourceDocument.transcriptSnapshot(in: snapshots)
    let machine = snapshots.last {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
        && $0.captureMethod != ProcessStepRecord.tidyCaptureMethod
    }
    let hasProof = transcript?.captureMethod == ProcessStepRecord.tidyCaptureMethod && machine != nil
    var layers: [SourceLayerText] = []
    if let caption, let body = nonEmpty(LayeredSourceDocument.body(of: caption)) {
      let split = splittingComments(from: body)
      if !split.article.isEmpty {
        layers.append(SourceLayerText(
          kind: transcript == nil ? .source : .caption,
          body: split.article
        ))
      }
    }
    if let transcript {
      let body = splittingComments(from: LayeredSourceDocument.body(of: transcript)).article
      if !body.isEmpty {
        layers.append(SourceLayerText(kind: hasProof ? .proofread : .transcript, body: body))
      }
    }
    if hasProof, let machine {
      let body = splittingComments(from: LayeredSourceDocument.body(of: machine)).article
      if !body.isEmpty {
        layers.append(SourceLayerText(kind: .machineTranscript, body: body))
      }
    }
    return layers
  }

  private static func latest(_ detail: HistoryDetailProjection, _ kind: RunKind) -> String? {
    guard let body = detail.runs.reversed().first(where: {
      $0.run.kind == kind && !($0.artifact?.bodyText.isEmpty ?? true)
    })?.artifact?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
    return body
  }

  /// 开头与文档标题相同的那行去掉，其余标题降一级。单独导出原文时不加「## 原文」。
  private func sectionBody(_ markdown: String, heading: String, labeled: Bool) -> String {
    let title = markdownTitle(markdown)
    var body = CapturedSourceBodyPresentation.strippingFirstEchoedHeading(title: title, from: markdown)
    body = demotingHeadings(body)
    guard labeled else { return body }
    return "## \(heading)\n\n\(body)"
  }

  private func markdownTitle(_ markdown: String) -> String {
    for (line, inCode) in Self.linesMarkingCode(markdown) where !inCode {
      guard let heading = Self.atxHeading(line), heading.level == 1, !heading.text.isEmpty else { continue }
      return heading.text
    }
    return ""
  }

  /// 「评论（译文）」和译文自带的评论计数标题合成一条，不再上下叠两个标题。
  private func translatedCommentSection(_ markdown: String, levels: Int) -> String {
    var lines = markdown.components(separatedBy: "\n")
    let heading = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 评论") }
    lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 评论") }
    let count = heading?.replacingOccurrences(of: "## 评论", with: "").trimmingCharacters(in: .whitespaces) ?? ""
    let title = count.isEmpty ? "### 评论（译文）" : "### 评论（译文，\(count.dropFirst().dropLast())）"
    let body = levels > 0 ? demotingHeadings(lines.joined(separator: "\n"), levels: levels) : lines.joined(separator: "\n")
    return title + "\n\n" + body
  }

  /// 总结和译文里的标题降一级，让各层标题保持同级。
  /// 只动真正的标题：代码块里的 `# 注释`、小红书的 `#话题` 都不是标题，原样留着。
  /// 四级及以下不再降。
  private func demotingHeadings(_ markdown: String, levels: Int = 1) -> String {
    Self.linesMarkingCode(markdown).map { line, inCode in
      guard !inCode, let heading = Self.atxHeading(line), heading.level < 4 else { return line }
      let indent = String(line.prefix { $0 == " " })
      return indent + String(repeating: "#", count: levels) + line.dropFirst(indent.count)
    }.joined(separator: "\n")
  }

  /// 按 CommonMark 认 ATX 标题：最多缩进三个空格，1 到 6 个 `#`，后面是空格、制表符或行尾。
  private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
    let indent = line.prefix { $0 == " " }
    guard indent.count <= 3 else { return nil }
    let rest = line.dropFirst(indent.count)
    let hashes = rest.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count) else { return nil }
    let after = rest.dropFirst(hashes.count)
    guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
    return (hashes.count, after.trimmingCharacters(in: .whitespaces))
  }

  /// 逐行标出是否在围栏代码块里（围栏行本身也算）。
  /// ``` 和 ~~~ 都认；只有同一种符号、长度不短于开头的那行才算收尾。
  /// 列表里的代码块常常缩进更多，所以缩进不设上限。
  private static func linesMarkingCode(_ markdown: String) -> [(line: String, inCode: Bool)] {
    var open: (mark: Character, length: Int)?
    return markdown.components(separatedBy: "\n").map { line in
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      if let fence = open {
        let run = trimmed.prefix { $0 == fence.mark }
        if run.count >= fence.length, trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
          open = nil
        }
        return (line, true)
      }
      if let mark = trimmed.first, mark == "`" || mark == "~" {
        let run = trimmed.prefix { $0 == mark }
        // 反引号围栏后面的语言名里不能再有反引号，否则是行内代码。
        if run.count >= 3, mark == "~" || !trimmed.dropFirst(run.count).contains("`") {
          open = (mark, run.count)
          return (line, true)
        }
      }
      return (line, false)
    }
  }

  /// 原文或译文里的「## 评论」整段拆出来。认不出评论结构就整篇当正文。
  private static func splittingComments(from markdown: String) -> (article: String, comments: String) {
    guard let range = MarkdownPresentation.structuredCommentRange(in: markdown) else {
      return (markdown.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
    return (
      markdown[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
      markdown[range].trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private static func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// 保存框下方那一排「内容」。勾选变了就改文件名；一项都不勾时「导出」不可点。
/// 评论勾不勾记住，下一次导出沿用。
@MainActor
final class ExportContentChooser: NSObject {
  static let commentsKey = "history.export.include-comments"
  var selection: ExportContentSelection
  var onChange: (ExportContentSelection) -> Void = { _ in }
  private(set) var view = NSView()
  private var boxes: [(layer: ExportContentLayer, button: NSButton)] = []

  static var remembersComments: Bool {
    get {
      guard UserDefaults.standard.object(forKey: commentsKey) != nil else { return true }
      return UserDefaults.standard.bool(forKey: commentsKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: commentsKey) }
  }

  init(available: [ExportContentLayer], selection: ExportContentSelection) {
    self.selection = selection
    super.init()
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    let label = NSTextField(labelWithString: "内容")
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    row.addArrangedSubview(label)
    boxes = available.map { layer in
      let box = NSButton(checkboxWithTitle: layer.title, target: nil, action: nil)
      box.state = selection.layers.contains(layer) ? .on : .off
      box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      box.setAccessibilityIdentifier("export-content-\(layer.rawValue)")
      return (layer, box)
    }
    boxes.forEach { row.addArrangedSubview($0.button) }
    row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    let width = row.fittingSize.width
    row.frame = NSRect(x: 0, y: 0, width: max(width, 420), height: 36)
    view = row
    boxes.forEach {
      $0.button.target = self
      $0.button.action = #selector(toggle(_:))
    }
  }

  /// 保存框出现后挂上。一项都不勾时，点「导出」不关掉保存框。
  func attach(to panel: NSSavePanel) {
    panel.delegate = self
  }

  @objc private func toggle(_ sender: NSButton) {
    guard let layer = boxes.first(where: { $0.button === sender })?.layer else { return }
    if sender.state == .on {
      selection.layers.insert(layer)
    } else {
      selection.layers.remove(layer)
    }
    if layer == .comments { Self.remembersComments = sender.state == .on }
    onChange(selection)
  }
}

extension ExportContentChooser: NSOpenSavePanelDelegate {
  func panel(_ sender: Any, validate url: URL) throws {
    if selection.layers.isEmpty {
      throw CocoaError(.userCancelled)
    }
  }
}


