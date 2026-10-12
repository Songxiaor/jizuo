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
      let body = layer == .summary ? demotingHeadings(piece.body) : piece.body
      return sectionBody(body, heading: piece.heading, labeled: labeled)
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
      if !translatedComments.isEmpty { return translatedComments }
      return sourceComments.isEmpty ? nil : sourceComments
    }
    guard !sourceComments.isEmpty else {
      return translatedComments.isEmpty ? nil : translatedComments
    }
    guard wantsTranslation, !translatedComments.isEmpty else { return sourceComments }
    return sourceComments + "\n\n" + translatedCommentSection(translatedComments)
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
    for line in markdown.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("# ") else { continue }
      return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return ""
  }

  /// 「评论（译文）」和译文自带的评论计数标题合成一条，不再上下叠两个标题。
  private func translatedCommentSection(_ markdown: String) -> String {
    var lines = markdown.components(separatedBy: "\n")
    let heading = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 评论") }
    lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 评论") }
    let count = heading?.replacingOccurrences(of: "## 评论", with: "").trimmingCharacters(in: .whitespaces) ?? ""
    let title = count.isEmpty ? "### 评论（译文）" : "### 评论（译文，\(count.dropFirst().dropLast())）"
    return title + "\n\n" + demotingHeadings(lines.joined(separator: "\n"), levels: 1)
  }

  /// 总结和译文里的标题降一级，让各层标题保持同级。
  private func demotingHeadings(_ markdown: String, levels: Int = 1) -> String {
    markdown.components(separatedBy: "\n").map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#"), !trimmed.hasPrefix("####") else { return line }
      let indent = String(line.prefix { $0 == " " || $0 == "\t" })
      return indent + String(repeating: "#", count: levels) + trimmed
    }.joined(separator: "\n")
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


