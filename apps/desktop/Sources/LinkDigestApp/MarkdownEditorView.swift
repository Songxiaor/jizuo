import AppKit
import LinkDigestCore
import SwiftUI

/// 带 Markdown 着色的编辑器。
///
/// 替换裸 `TextEditor`：后者把标题、代码、引用一律画成同一片灰字，写超过几行就
/// 看不出结构。这里用 NSTextView + `MarkdownSyntaxHighlighter`，排版参数取自
/// 阅读区同一套偏好，所以「写」和「读」是同一个东西的两个状态，不是两种字体。
struct MarkdownEditorView: View {
  @Binding var text: String
  let font: NSFont
  let palette: MarkdownSyntaxHighlighter.Palette
  let lineSpacing: CGFloat
  /// 空白时的提示。传空串则不显示。
  var placeholder: String = ""
  /// 传入后，编辑器不再自己滚动，而是把内容高度回报出去，由外层页面统一滚动。
  ///
  /// 一页里套两层滚动条，写到底部时页面和编辑器会互相抢滚动，最后一行还常被
  /// 裁在框里看不见。写作页面应当只有一条滚动轴。
  var contentHeight: Binding<CGFloat>?
  /// 点了 `[[某条笔记]]` 时回调，参数是链接目标的标题。
  var onFollowWikiLink: ((String) -> Void)?
  /// 可以链接的笔记标题。为空则不启用 `[[` 补全。
  var linkableTitles: [String] = []

  var body: some View {
    MarkdownTextView(
      text: $text, font: font, palette: palette, lineSpacing: lineSpacing,
      contentHeight: contentHeight, onFollowWikiLink: onFollowWikiLink,
      linkableTitles: linkableTitles
    )
      // 提示画在编辑器之上而不是塞进 `text`：塞进去它就是一段真的内容，会被
      // 保存、被翻译、被搜到，用户还得先删掉它才能开始写。
      .overlay(alignment: .topLeading) {
        if text.isEmpty && !placeholder.isEmpty {
          Text(placeholder)
            .font(Font(font))
            .foregroundStyle(.tertiary)
            // 和 NSTextView 的 textContainerInset 对齐，否则提示和光标错开。
            .padding(.leading, MarkdownTextView.contentInset.width + 5)
            .padding(.top, MarkdownTextView.contentInset.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}

/// 把 ⌘B / ⌘I 变成插入 Markdown 记号。
///
/// 纯文本模式下这两个键位是没人接的：NSTextView 的默认实现走 `toggleBold:`，
/// 那是给富文本改字体属性用的，`isRichText = false` 时直接被丢掉。用户按了
/// 没反应，只能自己敲星号。
final class MarkdownNSTextView: NSTextView {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let key = event.charactersIgnoringModifiers?.lowercased() else {
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    case "b": return wrapSelection(with: "**")
    case "i": return wrapSelection(with: "*")
    default: return super.performKeyEquivalent(with: event)
    }
  }

  private func wrapSelection(with marker: String) -> Bool {
    let full = string
    let selected = selectedRange()
    guard let range = Range(selected, in: full) else { return false }

    let (result, newSelection) = MarkdownListEditing.toggleWrap(full, selection: range, marker: marker)
    let whole = NSRange(location: 0, length: (full as NSString).length)
    guard shouldChangeText(in: whole, replacementString: result) else { return true }
    textStorage?.replaceCharacters(in: whole, with: result)
    didChangeText()
    setSelectedRange(NSRange(newSelection, in: result))
    return true
  }
}

/// 承载 NSTextView 的那一层。
private struct MarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  let font: NSFont
  let palette: MarkdownSyntaxHighlighter.Palette
  let lineSpacing: CGFloat
  var contentHeight: Binding<CGFloat>?
  var onFollowWikiLink: ((String) -> Void)?
  var linkableTitles: [String] = []

  static let contentInset = NSSize(width: 18, height: 16)

  func makeNSView(context: Context) -> NSScrollView {
    // 自己搭而不用 `NSTextView.scrollableTextView()`：那个工厂给的是 NSTextView
    // 本身，换不成需要拦截 ⌘B/⌘I 的子类。
    let textView = MarkdownNSTextView()
    textView.autoresizingMask = [.width]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true

    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    // 写 Markdown 时智能标点会把 `"` 换成中文引号、`--` 换成破折号，
    // 让写出来的东西和存下去的不一致。
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.drawsBackground = false
    textView.textContainerInset = Self.contentInset
    textView.string = text
    scroll.drawsBackground = false
    // 自适应高度时不留自己的滚动条：外层页面负责滚动。
    scroll.hasVerticalScroller = contentHeight == nil

    context.coordinator.contentHeight = contentHeight
    context.coordinator.onFollowWikiLink = onFollowWikiLink
    context.coordinator.linkableTitles = linkableTitles
    context.coordinator.applyHighlight(to: textView, font: font, palette: palette, lineSpacing: lineSpacing)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    // 只有外部真的换了内容才覆盖，否则会打断正在输入的光标与输入法。
    if textView.string != text {
      let selected = textView.selectedRange()
      textView.string = text
      textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count), length: 0))
    }
    context.coordinator.contentHeight = contentHeight
    context.coordinator.onFollowWikiLink = onFollowWikiLink
    context.coordinator.linkableTitles = linkableTitles
    context.coordinator.applyHighlight(to: textView, font: font, palette: palette, lineSpacing: lineSpacing)
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    private let text: Binding<String>
    /// 防止把自己写回去的内容再当成用户输入处理。
    private var isApplyingHighlight = false
    var contentHeight: Binding<CGFloat>?
    var onFollowWikiLink: ((String) -> Void)?
    var linkableTitles: [String] = []

    init(text: Binding<String>) { self.text = text }

    // MARK: - `[[` 补全
    //
    // 借 NSTextView 自带的补全机制（`complete(_:)` + 下面两个 delegate），
    // 而不是自己画一个候选浮层：系统那套的键盘操作、滚动、失焦关闭都是现成的，
    // 自己实现一遍只会在边角上比它差。

    /// 正在补全的那段 `[[…` 在文本里的范围。
    ///
    /// 记下来是因为 `insertCompletion` 拿到的 `charRange` 是系统按「单词」
    /// 划出来的，中文标题里没有空格，它划出的范围和实际要替换的那段对不上。
    private var completionRange: NSRange?

    func textView(
      _ textView: NSTextView,
      completions words: [String],
      forPartialWordRange charRange: NSRange,
      indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
      guard !linkableTitles.isEmpty,
            let pending = pendingLink(in: textView) else { return [] }
      completionRange = pending.range
      return WikiLink.completions(for: pending.query, among: linkableTitles)
    }

    func textView(
      _ textView: NSTextView,
      insertCompletion word: String,
      forPartialWordRange charRange: NSRange,
      movement: Int,
      isFinal flag: Bool
    ) {
      guard flag, let range = completionRange else { return }
      completionRange = nil
      // 连 `[[` 一起替换成完整链接，并把已经在光标后面的 `]]` 吃掉，
      // 免得补出 `[[标题]]]]`。
      let storage = textView.string as NSString
      var replaced = range
      let tail = range.location + range.length
      if tail + 2 <= storage.length, storage.substring(with: NSRange(location: tail, length: 2)) == "]]" {
        replaced = NSRange(location: range.location, length: range.length + 2)
      }
      let markup = WikiLink.markup(for: word)
      guard textView.shouldChangeText(in: replaced, replacementString: markup) else { return }
      textView.textStorage?.replaceCharacters(in: replaced, with: markup)
      textView.didChangeText()
      textView.setSelectedRange(NSRange(location: replaced.location + (markup as NSString).length, length: 0))
    }

    /// 光标处那个还没写完的 `[[…`，换算成 NSRange。
    private func pendingLink(in textView: NSTextView) -> (range: NSRange, query: String)? {
      let full = textView.string
      let caretUTF16 = textView.selectedRange().location
      guard let caret = Range(NSRange(location: caretUTF16, length: 0), in: full)?.lowerBound,
            let pending = WikiLink.pendingLink(in: full, caret: caret) else { return nil }
      let range = NSRange(pending.openingIndex..<caret, in: full)
      return (range, pending.query)
    }

    /// 点了正文里的 `[[某条笔记]]`。
    ///
    /// 可编辑的 NSTextView 里点链接需要按住 ⌘，这正合适：写字时光标经常落在
    /// 链接上，单击就跳走会让人没法编辑自己刚写的那个链接。
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
            let title = WikiLinkURL.title(from: url) else { return false }
      onFollowWikiLink?(title)
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingHighlight, let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
      reportHeight(of: textView)
      // 刚打完 `[[` 就把候选弹出来。只在这一刻触发：弹出之后继续打字由系统
      // 自己筛，每次输入都调 `complete(_:)` 会让候选框不停地重开。
      if !linkableTitles.isEmpty, let pending = pendingLink(in: textView), pending.query.isEmpty {
        textView.complete(nil)
      }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        return continueList(in: textView)
      case #selector(NSResponder.insertTab(_:)):
        return shiftListItem(in: textView, by: Self.indentUnit)
      case #selector(NSResponder.insertBacktab(_:)):
        return shiftListItem(in: textView, by: nil)
      default:
        return false
      }
    }

    /// 一级缩进用两个空格：四个在中文正文里视觉上跳得太远。
    private static let indentUnit = "  "

    /// 当前光标所在行的范围，以及行尾（不含换行符）的位置。
    private func currentLine(in textView: NSTextView) -> (range: NSRange, end: Int, text: String) {
      let storage = textView.string as NSString
      let caret = textView.selectedRange()
      let lineRange = storage.lineRange(for: NSRange(location: caret.location, length: 0))
      var end = lineRange.location + lineRange.length
      // lineRange 含尾部换行，退回到真正的行尾。
      if end > lineRange.location, storage.character(at: end - 1) == 10 { end -= 1 }
      let line = storage.substring(with: NSRange(location: lineRange.location, length: end - lineRange.location))
      return (lineRange, end, line)
    }

    /// 在列表行末尾回车时自动续下一项。
    private func continueList(in textView: NSTextView) -> Bool {
      let caret = textView.selectedRange()
      guard caret.length == 0 else { return false }
      let line = currentLine(in: textView)
      // 只在行尾续。行中回车是拆行，用户想要的是原本的行为。
      guard caret.location == line.end,
            let continuation = MarkdownListEditing.continuation(forLine: line.text) else { return false }

      if continuation.deletingPrefixLength > 0 {
        let target = NSRange(location: line.range.location, length: continuation.deletingPrefixLength)
        return replace(in: textView, range: target, with: "")
      }
      return replace(in: textView, range: caret, with: continuation.insert)
    }

    /// Tab / Shift-Tab 在列表行上调整层级；其它地方交回默认行为。
    ///
    /// `by` 传 nil 表示反缩进。
    private func shiftListItem(in textView: NSTextView, by indent: String?) -> Bool {
      let line = currentLine(in: textView)
      guard MarkdownListEditing.marker(ofLine: line.text) != nil else { return false }

      guard let indent else {
        // 反缩进：只吃掉行首已有的一级缩进，没有就什么都不做。
        let prefix = String(line.text.prefix(Self.indentUnit.count))
        guard prefix == Self.indentUnit || prefix.first == "\t" else { return true }
        let width = prefix.first == "\t" ? 1 : Self.indentUnit.count
        return replace(in: textView, range: NSRange(location: line.range.location, length: width), with: "")
      }
      return replace(in: textView, range: NSRange(location: line.range.location, length: 0), with: indent)
    }

    /// 走 shouldChangeText/didChangeText，撤销栈与绑定才都跟得上。
    @discardableResult
    private func replace(in textView: NSTextView, range: NSRange, with string: String) -> Bool {
      guard textView.shouldChangeText(in: range, replacementString: string) else { return true }
      textView.textStorage?.replaceCharacters(in: range, with: string)
      textView.didChangeText()
      return true
    }

    /// 把排版后的实际高度回报给 SwiftUI。
    func reportHeight(of textView: NSTextView) {
      guard let contentHeight,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer else { return }
      layoutManager.ensureLayout(for: container)
      let height = layoutManager.usedRect(for: container).height
        + MarkdownTextView.contentInset.height * 2
      // 半点以内的抖动不回报：布局与高度互相触发时会来回震荡。
      guard abs(contentHeight.wrappedValue - height) > 0.5 else { return }
      // 异步跳出当前这轮 SwiftUI 更新，否则是「在视图更新中改状态」。
      DispatchQueue.main.async { contentHeight.wrappedValue = height }
    }

    func applyHighlight(
      to textView: NSTextView,
      font: NSFont,
      palette: MarkdownSyntaxHighlighter.Palette,
      lineSpacing: CGFloat
    ) {
      guard let storage = textView.textStorage else { return }
      isApplyingHighlight = true
      defer { isApplyingHighlight = false }
      // 着色只改属性不改文字，所以光标位置不受影响；但仍显式保存恢复，
      // 因为 setAttributes 在某些输入法状态下会重置选区。
      let selected = textView.selectedRange()
      MarkdownSyntaxHighlighter.apply(
        to: storage, baseFont: font, palette: palette, lineSpacing: lineSpacing
      )
      textView.setSelectedRange(selected)
      // 字号、行距、着色都会改变排版高度，重新量一次。
      reportHeight(of: textView)
    }
  }
}
