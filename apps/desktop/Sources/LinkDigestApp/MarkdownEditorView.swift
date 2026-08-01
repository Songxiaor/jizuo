import AppKit
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

  var body: some View {
    MarkdownTextView(text: $text, font: font, palette: palette, lineSpacing: lineSpacing)
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

/// 承载 NSTextView 的那一层。
private struct MarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  let font: NSFont
  let palette: MarkdownSyntaxHighlighter.Palette
  let lineSpacing: CGFloat

  static let contentInset = NSSize(width: 18, height: 16)

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let textView = scroll.documentView as? NSTextView else { return scroll }

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
    scroll.hasVerticalScroller = true

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
    context.coordinator.applyHighlight(to: textView, font: font, palette: palette, lineSpacing: lineSpacing)
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    private let text: Binding<String>
    /// 防止把自己写回去的内容再当成用户输入处理。
    private var isApplyingHighlight = false

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingHighlight, let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
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
    }
  }
}
