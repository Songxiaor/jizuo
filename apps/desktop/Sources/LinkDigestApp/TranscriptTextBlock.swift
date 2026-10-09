import AppKit
import LinkDigestCore
import SwiftUI

/// 转写稿正文的原生文字块（2026-10-06 滑动性能改造）。
///
/// 原来三种转写稿（逐字稿、分说话人、校对稿）每一段都是一个 SwiftUI 视图，4 小时的稿子
/// 上千个。阅读区的 ScrollView 每当窗口重算拖拽区、鼠标悬停变化或任何小状态变化时，都要
/// 把整份正文从头量一遍，滑动时每帧量好几次——第一次滑过新内容最慢的 10% 要 22ms 一帧，
/// 120Hz 屏幕上一顿一顿的。
///
/// 这里把整份正文排成一段富文本，交给 TextKit 2 的 NSTextView：它只排看得见的那一屏，
/// 其余部分只估高度。SwiftUI 量整页时只量这一块。原型实测 120 万字：打开到第一帧约
/// 0.1–0.2s，快滑、猛甩都是 120 帧/秒不丢帧。
///
/// 时间码仍挂在左页边（制表位 + 悬挂缩进，尺寸见 `TranscriptGutter`），是可以点的链接。
struct TranscriptTextLine: Equatable {
  enum Kind: Equatable { case body, speaker, heading }
  var kind: Kind
  /// 页边显示的时间码；nil 时页边留空。
  var stamp: String?
  /// 点时间码跳到第几秒；nil 时时间码只显示、不能点。
  var seekSeconds: Double?
  var stampHelp: String?
  var text: String
  /// 这一行和上一行之间的额外留白（不含行距）。
  var spacingBefore: CGFloat = TranscriptGutter.paragraphSpacing
}

struct TranscriptTextStyle: Equatable {
  let readingFont: ResolvedReadingFont
  let primaryText: NSColor
  let secondaryText: NSColor
  let showsTimecodes: Bool
}

enum TranscriptTextDocument {
  static let seekScheme = "jizuo-seek"

  static func seekURL(_ seconds: Double) -> URL? {
    URL(string: "\(seekScheme):\(seconds)")
  }

  static func seconds(from url: URL) -> Double? {
    guard url.scheme == seekScheme else { return nil }
    return Double(url.absoluteString.dropFirst(seekScheme.count + 1))
  }

  static func make(_ lines: [TranscriptTextLine], style: TranscriptTextStyle) -> NSAttributedString {
    let readingFont = style.readingFont
    let body = readingFont.nsFont()
    let heading: NSFont = {
      let size = readingFont.scaledSize(19)
      let descriptor = readingFont.nsFontDescriptor(size: size)
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
      return NSFont(descriptor: descriptor, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }()
    let speaker = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium)
    let stampFont: NSFont = {
      let base = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      guard let descriptor = base.fontDescriptor.withDesign(.monospaced) else { return base }
      return NSFont(descriptor: descriptor, size: 11) ?? base
    }()
    let inset = style.showsTimecodes ? TranscriptGutter.textInset : 0

    let result = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = MarkdownPresentation.bodyLineSpacing
      paragraph.paragraphSpacingBefore = index == 0 ? 0 : line.spacingBefore
      paragraph.headIndent = inset
      paragraph.firstLineHeadIndent = 0
      if inset > 0 {
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: inset)]
        paragraph.defaultTabInterval = inset
      }
      let font: NSFont
      let color: NSColor
      switch line.kind {
      case .body: font = body; color = style.primaryText
      case .heading: font = heading; color = style.primaryText
      case .speaker: font = speaker; color = style.secondaryText
      }
      let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
      ]
      if inset > 0 {
        if let stamp = line.stamp, line.kind != .heading {
          var stampAttributes: [NSAttributedString.Key: Any] = [
            .font: stampFont, .foregroundColor: style.secondaryText, .paragraphStyle: paragraph,
          ]
          if let seconds = line.seekSeconds, let url = seekURL(seconds) {
            stampAttributes[.link] = url
            stampAttributes[.toolTip] = line.stampHelp ?? "跳到 \(stamp)"
          }
          result.append(NSAttributedString(string: stamp, attributes: stampAttributes))
        }
        result.append(NSAttributedString(string: "\t", attributes: textAttributes))
      }
      let text = index == lines.count - 1 ? line.text : line.text + "\n"
      result.append(NSAttributedString(string: text, attributes: textAttributes))
    }
    return result
  }
}

/// 嵌在阅读区 ScrollView 里的正文块：自己不滚，高度跟着 TextKit 2 的排版结果上报。
struct TranscriptTextBlock: NSViewRepresentable {
  let lines: [TranscriptTextLine]
  let style: TranscriptTextStyle
  var onSeek: ((Double) -> Void)?
  /// 单击正文（没选中文字、也没点在时间码上）：校对稿用它进入编辑。
  var onTapText: (() -> Void)?
  var identifier: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> TranscriptTextBlockView {
    let view = TranscriptTextBlockView()
    view.setAccessibilityIdentifier(identifier)
    update(view, context: context)
    return view
  }

  func updateNSView(_ view: TranscriptTextBlockView, context: Context) {
    update(view, context: context)
  }

  private func update(_ view: TranscriptTextBlockView, context: Context) {
    view.onSeek = onSeek
    view.onTapText = onTapText
    // 正文没变就不重排：SwiftUI 的每次刷新都会调到这里。
    let key = Coordinator.Key(lines: lines, style: style)
    guard context.coordinator.key != key else { return }
    context.coordinator.key = key
    view.setDocument(TranscriptTextDocument.make(lines, style: style), linkColor: style.secondaryText)
  }

  final class Coordinator {
    struct Key: Equatable {
      let lines: [TranscriptTextLine]
      let style: TranscriptTextStyle
    }
    var key: Key?
  }
}

final class TranscriptTextBlockView: NSView, NSTextViewDelegate {
  private let textView: TranscriptNSTextView
  private var reportedHeight: CGFloat = 0
  var onSeek: ((Double) -> Void)?
  var onTapText: (() -> Void)? {
    didSet { textView.onTapText = onTapText }
  }

  override init(frame: NSRect) {
    // TextKit 2：只排看得见的那一屏。注意别去碰 `layoutManager`，一碰就退回 TextKit 1。
    textView = TranscriptNSTextView(usingTextLayoutManager: true)
    super.init(frame: frame)
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.isRichText = true
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.isAutomaticLinkDetectionEnabled = false
    textView.delegate = self
    addSubview(textView)
    textView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(textFrameChanged), name: NSView.frameDidChangeNotification, object: textView
    )
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var isFlipped: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: max(1, ceil(textView.frame.height)))
  }

  override func layout() {
    super.layout()
    if abs(textView.frame.width - bounds.width) > 0.5 {
      textView.setFrameSize(NSSize(width: bounds.width, height: textView.frame.height))
    }
  }

  func setDocument(_ document: NSAttributedString, linkColor: NSColor) {
    textView.linkTextAttributes = [
      .foregroundColor: linkColor,
      .cursor: NSCursor.pointingHand,
    ]
    guard let storage = textView.textStorage else { return }
    // 展开 / 收起只在末尾增减段落：前面相同的部分原样留着，只换后面那截（2026-10-07）。
    // 整份换掉时 TextKit 2 把视口以上全部重新估高，展开后滚动位置会漂一两百点。
    let shared = Self.sharedPrefixLength(storage, document)
    if shared == 0 {
      storage.setAttributedString(document)
    } else if shared < storage.length || shared < document.length {
      storage.replaceCharacters(
        in: NSRange(location: shared, length: storage.length - shared),
        with: document.attributedSubstring(from: NSRange(location: shared, length: document.length - shared))
      )
    }
    textView.setSelectedRange(NSRange(location: 0, length: 0))
  }

  /// 两份文字开头逐字相同、且样式也相同的长度。样式不同（换了字号、主题）返回 0，整份重排。
  static func sharedPrefixLength(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
    let a = old.string as NSString
    let b = new.string as NSString
    let limit = min(a.length, b.length)
    var index = 0
    while index < limit, a.character(at: index) == b.character(at: index) { index += 1 }
    guard index > 0 else { return 0 }
    let range = NSRange(location: 0, length: index)
    return old.attributedSubstring(from: range).isEqual(to: new.attributedSubstring(from: range)) ? index : 0
  }

  var documentForTesting: NSAttributedString { textView.attributedString() }

  /// 估算高度随排版修正：变了才通知 SwiftUI，一次修正只引起一次轻量重排（整页只有这一块大）。
  @objc private func textFrameChanged() {
    let height = ceil(textView.frame.height)
    guard abs(height - reportedHeight) > 0.5 else { return }
    reportedHeight = height
    invalidateIntrinsicContentSize()
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
    guard let url, let seconds = TranscriptTextDocument.seconds(from: url) else { return false }
    self.textView.didFollowLink = true
    onSeek?(seconds)
    return true
  }
}

/// 单击正文（没拖选、没点链接）回调出去；其余照常交给 NSTextView。
final class TranscriptNSTextView: NSTextView {
  var onTapText: (() -> Void)?
  var didFollowLink = false

  override func mouseDown(with event: NSEvent) {
    didFollowLink = false
    super.mouseDown(with: event)
    // super 跑完整个拖选跟踪才返回，此时已经是松开之后。
    guard event.clickCount == 1, !didFollowLink, selectedRange().length == 0, let onTapText else { return }
    onTapText()
  }
}
