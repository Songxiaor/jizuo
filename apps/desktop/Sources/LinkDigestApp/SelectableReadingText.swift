import AppKit
import SwiftUI

/// 阅读区连续选择：SwiftUI `Text` 每块都是独立的选择孤岛，跨段拖选做不到；
/// 把相邻文本块合成一个非编辑 NSTextView，选择即可随光标连续伸展。
/// 代码块仍由 SwiftUI 卡片渲染（保留复制按钮），图片处自然分段。
enum ReadingTextComposer {
  struct Palette {
    let primary: NSColor
    let secondary: NSColor
    let accent: NSColor

    /// 渲染缓存键用的稳定指纹：三色解析成 sRGB 分量（语义色的外观差异
    /// 由缓存键里的外观名兜住，见 ReadingRenderCache）。
    var fingerprint: [CGFloat] {
      [primary, secondary, accent].flatMap(ReadingRenderCache.colorFingerprint)
    }
  }

  /// 与 MarkdownPresentation 的阅读排版同一套字号体系。
  static func attributed(
    blocks: [MarkdownPresentation.Block],
    readingFont: ResolvedReadingFont,
    palette: Palette
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for block in blocks {
      switch block {
      case let .heading(level, text):
        let size: CGFloat = [1: 23, 2: 19.5, 3: 17][level] ?? 16
        result.append(paragraph(
          inline(stripMarkers(text), readingFont: readingFont, baseSize: size, bold: true, color: palette.primary),
          spacingBefore: level == 1 ? 26 : 20, spacingAfter: 10, lineSpacing: 6
        ))
      case let .paragraph(text):
        result.append(paragraph(
          inline(text, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.primary),
          spacingAfter: 20, lineSpacing: MarkdownPresentation.bodyLineSpacing
        ))
      case let .list(items):
        for item in items {
          // 深层用不同的记号，并跟着加缩进——选中复制出去时层级也不该丢。
          let marker = item.depth == 0 ? "•  " : String(repeating: "    ", count: item.depth) + "◦  "
          result.append(paragraph(
            bulletLine(marker, item.text, readingFont: readingFont, color: palette.primary),
            spacingAfter: 8, lineSpacing: 6, headIndent: CGFloat(22 + item.depth * 18)
          ))
        }
      case let .orderedList(start, items):
        for (index, item) in items.enumerated() {
          result.append(paragraph(
            bulletLine("\(start + index).  ", item, readingFont: readingFont, color: palette.primary),
            spacingAfter: 8, lineSpacing: 6, headIndent: 26
          ))
        }
      case let .taskList(items):
        for item in items {
          // 已完成的用次要色：选中复制走的是文字，颜色只影响这里的阅读。
          result.append(paragraph(
            bulletLine(
              item.isDone ? "☑  " : "☐  ", item.text,
              readingFont: readingFont,
              color: item.isDone ? palette.secondary : palette.primary
            ),
            spacingAfter: 8, lineSpacing: 6, headIndent: 22
          ))
        }
      case .divider:
        result.append(paragraph(
          inline(
            String(repeating: "─", count: 24),
            readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary
          ),
          spacingBefore: 10, spacingAfter: 14, lineSpacing: 4
        ))
      case let .quote(_, text):
        result.append(paragraph(
          inline(text, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary),
          spacingAfter: 20, lineSpacing: 8, headIndent: 18, firstLineIndent: 18
        ))
      case let .callout(kind, text):
        let label = MarkdownPresentation.calloutLabel(kind)
        let body = text.isEmpty ? label : "\(label)  \(text)"
        result.append(paragraph(
          inline(body, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary),
          spacingAfter: 20, lineSpacing: 8, headIndent: 18, firstLineIndent: 18
        ))
      case .code, .table, .comments:
        // 代码卡、表格和评论树由 SwiftUI 独立渲染；不应进入本合成器。
        continue
      }
    }
    return result
  }

  static func plain(
    _ text: String,
    readingFont: ResolvedReadingFont,
    color: NSColor
  ) -> NSAttributedString {
    paragraph(
      NSAttributedString(string: text, attributes: [
        .font: font(readingFont, size: readingFont.bodySize),
        .foregroundColor: color,
      ]),
      spacingAfter: 0, lineSpacing: MarkdownPresentation.bodyLineSpacing
    )
  }

  // MARK: - helpers

  private static func stripMarkers(_ value: String) -> String {
    value
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "`", with: "")
  }

  private static func font(_ readingFont: ResolvedReadingFont, size: CGFloat, bold: Bool = false) -> NSFont {
    var descriptor = readingFont.nsFontDescriptor(size: size)
    if bold { descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold]) }
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
  }

  /// 行内 Markdown（加粗/斜体/行内代码/链接）→ 基底阅读字体；链接保留
  /// `.link` 属性交 NSTextView 处理，点击仍走安全校验。
  private static func inline(
    _ text: String,
    readingFont: ResolvedReadingFont,
    baseSize: CGFloat,
    bold: Bool = false,
    color: NSColor
  ) -> NSAttributedString {
    let parsed = NSMutableAttributedString(attributedString: NSAttributedString(MarkdownPresentation.inlineAttributed(text)))
    let full = NSRange(location: 0, length: parsed.length)
    guard full.length > 0 else { return parsed }
    parsed.enumerateAttribute(.font, in: full) { value, range, _ in
      let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      if traits.contains(.monoSpace) {
        parsed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize - 2.5, weight: .regular), range: range)
        return
      }
      var descriptor = readingFont.nsFontDescriptor(size: baseSize)
      if bold || traits.contains(.bold) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold])
      }
      if traits.contains(.italic) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .italic])
      }
      parsed.addAttribute(.font, value: NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize), range: range)
    }
    parsed.addAttribute(.foregroundColor, value: color, range: full)
    return parsed
  }

  private static func bulletLine(
    _ prefix: String,
    _ text: String,
    readingFont: ResolvedReadingFont,
    color: NSColor
  ) -> NSAttributedString {
    let line = NSMutableAttributedString(string: prefix, attributes: [
      .font: font(readingFont, size: readingFont.bodySize),
      .foregroundColor: color,
    ])
    line.append(inline(text, readingFont: readingFont, baseSize: readingFont.bodySize, color: color))
    return line
  }

  private static func paragraph(
    _ content: NSAttributedString,
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat,
    lineSpacing: CGFloat,
    headIndent: CGFloat = 0,
    firstLineIndent: CGFloat = 0
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: content)
    mutable.append(NSAttributedString(string: "\n"))
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = spacingBefore
    style.paragraphSpacing = spacingAfter
    style.lineSpacing = lineSpacing
    style.headIndent = headIndent
    style.firstLineHeadIndent = firstLineIndent
    mutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: mutable.length))
    return mutable
  }
}

/// 自适应高度的非编辑 NSTextView：宽度随 SwiftUI 提供，高度按排版实际
/// 占用回报；整块文本共享同一个选择上下文，实现跨段连续选择。
struct SelectableReadingTextView: NSViewRepresentable {
  let attributed: NSAttributedString
  let accent: NSColor
  let onOpenLink: (URL) -> Void
  var revealText: String? = nil
  /// 单击且没有拖出选区时进入编辑。总结、网页原文不传。
  var onRequestEdit: ((String?) -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

  func makeNSView(context: Context) -> SelfSizingTextView {
    let view = SelfSizingTextView(frame: .zero)
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isAutomaticLinkDetectionEnabled = false
    view.delegate = context.coordinator
    view.linkTextAttributes = [
      .foregroundColor: accent,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    view.textStorage?.setAttributedString(attributed)
    view.onRequestEdit = onRequestEdit
    context.coordinator.lastApplied = attributed
    return view
  }

  func updateNSView(_ view: SelfSizingTextView, context: Context) {
    context.coordinator.onOpenLink = onOpenLink
    view.onRequestEdit = onRequestEdit
    // 渲染缓存命中时传进来的是同一个实例，`===` 直接短路；实例不同再退回
    // 深比较（整篇逐属性比较，长文并不便宜），确实变了才重设存储——
    // setAttributedString 会引发整篇重排版，是这里最贵的一步。
    if context.coordinator.lastApplied !== attributed {
      if view.textStorage?.isEqual(to: attributed) != true {
        view.textStorage?.setAttributedString(attributed)
        view.invalidateIntrinsicContentSize()
      }
      context.coordinator.lastApplied = attributed
    }
    view.linkTextAttributes?[.foregroundColor] = accent
    if context.coordinator.lastRevealText != revealText,
       let revealText,
       !revealText.isEmpty {
      context.coordinator.lastRevealText = revealText
      let range = (view.string as NSString).range(of: revealText)
      if range.location != NSNotFound {
        view.setSelectedRange(range)
        DispatchQueue.main.async { view.scrollRangeToVisible(range) }
      }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var onOpenLink: (URL) -> Void
    var lastRevealText: String?
    /// 上次应用到 textStorage 的实例，用于 `===` 快速跳过（见 updateNSView）。
    var lastApplied: NSAttributedString?
    init(onOpenLink: @escaping (URL) -> Void) { self.onOpenLink = onOpenLink }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      // 链接不直接放行系统打开；交回 SwiftUI 层走 PublicWebURLPolicy 校验。
      if let view = textView as? SelfSizingTextView { view.didHandleLink = true }
      if let url = link as? URL { onOpenLink(url); return true }
      if let raw = link as? String, let url = URL(string: raw) { onOpenLink(url); return true }
      return false
    }
  }

  final class SelfSizingTextView: NSTextView {
    var onRequestEdit: ((String?) -> Void)?
    /// 这次 mouseUp 已经点过链接，不再当成「点文字开写」。
    var didHandleLink = false
    private var mouseDownPoint: NSPoint?

    /// 右键「添加到摘录」：把选中文字送进当前条目的学习批注。
    /// handler 由详情视图按当前任务设置；无选择或无 handler 时不加菜单项。
    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = super.menu(for: event)
      guard selectedRange().length > 0,
            ExcerptCaptureRouter.shared.handler != nil else { return menu }
      let item = NSMenuItem(
        title: "添加到摘录",
        action: #selector(captureSelectionAsExcerpt(_:)),
        keyEquivalent: ""
      )
      item.target = self
      menu?.insertItem(item, at: 0)
      let citationItem = NSMenuItem(
        title: "复制引用（含来源）",
        action: #selector(copySelectionAsCitation(_:)),
        keyEquivalent: ""
      )
      citationItem.target = self
      menu?.insertItem(citationItem, at: 1)
      menu?.insertItem(NSMenuItem.separator(), at: 2)
      return menu
    }

    @objc private func copySelectionAsCitation(_: Any?) {
      let range = selectedRange()
      guard range.length > 0,
            let selected = textStorage?.attributedSubstring(from: range).string else { return }
      let citation = ReadingSelectionRouter.shared.formatter?(selected) ?? selected
      CopyFeedbackController.shared.copy(citation)
    }

    @objc private func captureSelectionAsExcerpt(_: Any?) {
      let range = selectedRange()
      guard range.length > 0,
            let selected = textStorage?.attributedSubstring(from: range).string else { return }
      ExcerptCaptureRouter.shared.handler?(selected)
    }

    /// 点击落在链接上了吗。
    ///
    /// 判断要带上「点是否真的落在这个字形里」：只按最近字符索引取属性，点在
    /// 段末空白处也会命中前一个字符，于是明明点的是空白却触发了跳转。
    private func link(at point: NSPoint) -> URL? {
      guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
        return nil
      }
      var fraction: CGFloat = 0
      let glyphIndex = layoutManager.glyphIndex(
        for: point,
        in: textContainer,
        fractionOfDistanceThroughGlyph: &fraction
      )
      guard fraction > 0, fraction < 1 else { return nil }
      let index = layoutManager.characterIndexForGlyph(at: glyphIndex)
      guard index < textStorage.length else { return nil }
      switch textStorage.attribute(.link, at: index, effectiveRange: nil) {
      case let url as URL: return url
      case let raw as String: return URL(string: raw)
      default: return nil
      }
    }

    /// NSTextView 的 mouseDown 会自己把鼠标跟踪到松开，子类的 mouseUp 常常根本收不到。
    /// 可写正文必须在 mouseDown 里进编辑，并且不要再交给 super 去框选。
    ///
    /// **但链接要排在编辑前面**。可写正文原来一进 mouseDown 就直接进编辑并
    /// `return`，链接连交给 delegate 的机会都没有——转写稿和画面字幕都是可写的，
    /// 于是正文里的时间码全都点不动，点哪儿都是弹出编辑器。
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let isPlainClick = event.clickCount == 1
        && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      if isPlainClick, link(at: point) != nil {
        // 交给 super，由 `textView(_:clickedOnLink:at:)` 走既有的链接处理。
        mouseDownPoint = point
        super.mouseDown(with: event)
        return
      }
      if let onRequestEdit, isPlainClick {
        let index = characterIndexForInsertion(at: point)
        onRequestEdit(ReadingEditLocator.displayedSnippet(in: string, utf16Index: index))
        return
      }
      mouseDownPoint = point
      super.mouseDown(with: event)
    }

    /// 只读页：拖选出字后松手复制。可写正文的单击不会走到这里。
    override func mouseUp(with event: NSEvent) {
      super.mouseUp(with: event)
      if didHandleLink {
        didHandleLink = false
        mouseDownPoint = nil
        return
      }
      defer { mouseDownPoint = nil }
      guard onRequestEdit == nil else { return }
      let range = selectedRange()
      guard range.length > 0,
            let selected = textStorage?.attributedSubstring(from: range).string,
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      Task { @MainActor in
        let citation = ReadingSelectionRouter.shared.formatter?(selected) ?? selected
        CopyFeedbackController.shared.copy(citation)
      }
    }

    override var intrinsicContentSize: NSSize {
      guard let container = textContainer, let manager = layoutManager else {
        return super.intrinsicContentSize
      }
      manager.ensureLayout(for: container)
      let used = manager.usedRect(for: container)
      return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
      // 必须在 super 之前读旧宽度：super 之后 frame.width 已经是新值。
      let widthChanged = abs(newSize.width - frame.width) > 0.5
      super.setFrameSize(newSize)
      // 只有宽度变了才重排。高度变化是上次 invalidate 的结果，
      // 再 invalidate 会和 SwiftUI 布局形成自激循环。
      if widthChanged {
        invalidateIntrinsicContentSize()
      }
    }
  }
}

/// 生成中的正文自己滚动，不再撑高外层 SwiftUI ScrollView。
///
/// 只追加后缀还不够：每次 `invalidateIntrinsicContentSize()` 都会让详情页
/// 重测整块高度，用户正在滑的时候内容尺寸跟着变，120Hz 也会一顿一顿。
/// 外层高度锁定，增量排在 NSScrollView 里，滑动走 AppKit。
struct StreamingReadingTextView: NSViewRepresentable {
  let text: String
  let font: NSFont
  let color: NSColor
  let lineSpacing: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(frame: .zero)
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay

    let view = SelectableReadingTextView.SelfSizingTextView(frame: .zero)
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.heightTracksTextView = false
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.autoresizingMask = [.width]
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    view.isAutomaticLinkDetectionEnabled = false
    view.textStorage?.setAttributedString(attributed(text))
    scroll.documentView = view

    context.coordinator.lastText = text
    context.coordinator.lastStyle = styleKey
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? SelectableReadingTextView.SelfSizingTextView else {
      return
    }
    let styleChanged = context.coordinator.lastStyle != styleKey
    let followTail = StreamingViewport.shouldFollowTail(
      visibleMaxY: scroll.contentView.bounds.maxY,
      contentHeight: view.frame.height
    )
    if !styleChanged,
       let suffix = StreamingTextUpdate.appendedSuffix(
        previous: context.coordinator.lastText,
        next: text
       ) {
      if !suffix.isEmpty {
        let start = (view.string as NSString).length
        view.textStorage?.beginEditing()
        view.textStorage?.append(attributed(suffix))
        view.textStorage?.endEditing()
        let added = (suffix as NSString).length
        view.layoutManager?.ensureLayout(
          forCharacterRange: NSRange(location: start, length: added)
        )
      }
    } else {
      let selection = view.selectedRange()
      view.textStorage?.setAttributedString(attributed(text))
      let length = (text as NSString).length
      view.setSelectedRange(NSRange(
        location: min(selection.location, length),
        length: min(selection.length, max(0, length - min(selection.location, length)))
      ))
      if let container = view.textContainer {
        view.layoutManager?.ensureLayout(for: container)
      }
    }
    resizeDocument(view, in: scroll, followTail: followTail)
    context.coordinator.lastText = text
    context.coordinator.lastStyle = styleKey
  }

  private func resizeDocument(
    _ view: NSTextView,
    in scroll: NSScrollView,
    followTail: Bool
  ) {
    let width = max(scroll.contentSize.width, 1)
    if let container = view.textContainer, abs(container.containerSize.width - width) > 0.5 {
      container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
      view.layoutManager?.ensureLayout(for: container)
    }
    guard let container = view.textContainer else { return }
    let used = view.layoutManager?.usedRect(for: container).height ?? 0
    let height = max(ceil(used), scroll.contentSize.height)
    if abs(view.frame.width - width) > 0.5 || abs(view.frame.height - height) > 0.5 {
      view.setFrameSize(NSSize(width: width, height: height))
    }
    if followTail {
      view.scrollToEndOfDocument(nil)
    }
  }

  final class Coordinator {
    var lastText = ""
    var lastStyle: StyleKey?
  }

  struct StyleKey: Equatable {
    let fontName: String
    let pointSize: CGFloat
    let color: [CGFloat]
    let lineSpacing: CGFloat
  }

  private var styleKey: StyleKey {
    StyleKey(
      fontName: font.fontName,
      pointSize: font.pointSize,
      color: ReadingRenderCache.colorFingerprint(color),
      lineSpacing: lineSpacing
    )
  }

  private func attributed(_ value: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    return NSAttributedString(string: value, attributes: [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ])
  }
}

enum StreamingViewport {
  /// 生成中外层高度锁定，避免 SwiftUI 每拍重测整页。
  static let minHeight: CGFloat = 360
  /// 离底部这么近就跟着新字走；再往上滑则保持用户位置。
  static let tailSlop: CGFloat = 48

  static func shouldFollowTail(visibleMaxY: CGFloat, contentHeight: CGFloat) -> Bool {
    visibleMaxY >= contentHeight - tailSlop
  }
}

enum StreamingTextUpdate {
  /// nil 表示不是纯追加（例如重新运行、切换条目或内容被服务端修订），调用方
  /// 必须整篇替换；空字符串表示没有变化。
  static func appendedSuffix(previous: String, next: String) -> String? {
    let old = previous as NSString
    let new = next as NSString
    guard new.length >= old.length,
          new.substring(with: NSRange(location: 0, length: old.length)) == previous
    else { return nil }
    return new.substring(from: old.length)
  }
}

/// 阅读区点到的可见文字，对回 Markdown 源码里的光标位置。
enum ReadingEditLocator {
  /// 取点击处前后一小段，用来在源码里定位。太短会误命中。
  static func displayedSnippet(in text: String, utf16Index: Int, radius: Int = 12) -> String {
    let ns = text as NSString
    guard ns.length > 0 else { return "" }
    let index = min(max(0, utf16Index), ns.length)
    let start = max(0, index - radius)
    let end = min(ns.length, index + radius)
    return ns.substring(with: NSRange(location: start, length: end - start))
  }

  /// 对不上就落在开头：乱跳到无关段落比停在文首更糟。
  static func caretUTF16Offset(in source: String, displayedSnippet: String?) -> Int {
    let snippet = displayedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard snippet.count >= 2 else { return 0 }
    if let range = source.range(of: snippet) {
      return NSRange(range, in: source).location
    }
    let needle = String(snippet.prefix(16))
    if needle.count >= 4, let range = source.range(of: needle) {
      return NSRange(range, in: source).location
    }
    return 0
  }
}

/// 摘录路由：阅读区 NSTextView 与当前详情条目之间的最小接线。
/// 详情视图出现时设置 handler、消失时清空；同一时刻只有一个详情在读。
@MainActor final class ExcerptCaptureRouter {
  static let shared = ExcerptCaptureRouter()
  var handler: ((String) -> Void)?
}

/// 当前阅读条目的引用格式。只存在于进程内，不把标题或来源写进全局偏好。
@MainActor final class ReadingSelectionRouter {
  static let shared = ReadingSelectionRouter()
  var formatter: ((String) -> String)?
}
