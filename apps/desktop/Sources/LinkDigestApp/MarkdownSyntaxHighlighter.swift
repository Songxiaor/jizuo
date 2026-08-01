import AppKit
import Foundation

/// 编辑 Markdown 时的语法着色。
///
/// 为什么不引第三方编辑器：现成的 macOS Markdown 编辑器（MarkEdit、MarkupEditor）
/// 都基于 WebView + CodeMirror。塞进来要付三笔账——字体与 `ReadingFontSelection`
/// 那套对不上、深浅色主题得再做一套、依赖从「只有 GRDB」变成带一个浏览器引擎。
/// 而真正缺的只是「编辑时能看见结构」，原生 NSTextView 上色就能拿到八成效果，
/// 且和阅读区天然是同一套排版。
///
/// 刻意**不做实时预览**：预览要么占掉一半宽度，要么在输入时跳动。写作时看见结构
/// 就够了，要看成品可以切到「原文」面板——那里本来就是同一份渲染器。
enum MarkdownSyntaxHighlighter {
  /// 一条着色规则：匹配什么、怎么画。
  private struct Rule {
    let pattern: String
    let options: NSRegularExpression.Options
    /// 作用于整个匹配的样式。
    let style: (_ base: NSFont, _ palette: Palette) -> [NSAttributedString.Key: Any]
  }

  struct Palette {
    let primary: NSColor
    let secondary: NSColor
    let accent: NSColor
    let code: NSColor

    init(primary: NSColor, secondary: NSColor, accent: NSColor, code: NSColor) {
      self.primary = primary
      self.secondary = secondary
      self.accent = accent
      self.code = code
    }
  }

  /// 规则按「先粗后细」排：标题整行的字号要先定下来，行内强调再叠加。
  ///
  /// 用计算属性而非 static let：规则里带闭包，不是 Sendable，作为全局常量会被
  /// 并发检查拦下。着色只在主线程发生，每次重建这几条规则的开销可以忽略。
  private static var rules: [Rule] {[
    // 标题：整行放大加粗，`#` 本身淡出——它是结构标记，不是内容。
    Rule(pattern: #"^(#{1,6})\s+(.+)$"#, options: [.anchorsMatchLines]) { base, palette in
      [.font: NSFont.boldSystemFont(ofSize: base.pointSize * 1.25), .foregroundColor: palette.primary]
    },
    // 引用整行淡化：它在视觉上本就该退后一层。
    Rule(pattern: #"^>\s+.*$"#, options: [.anchorsMatchLines]) { _, palette in
      [.foregroundColor: palette.secondary]
    },
    // 列表符号着色，但不动文字本身。
    Rule(pattern: #"^\s*([-*+]|\d+\.)\s"#, options: [.anchorsMatchLines]) { _, palette in
      [.foregroundColor: palette.accent]
    },
    // 围栏代码块与行内代码用等宽字体，一眼能和正文分开。
    Rule(pattern: #"```[\s\S]*?```"#, options: []) { base, palette in
      [
        .font: NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular),
        .foregroundColor: palette.code,
      ]
    },
    Rule(pattern: #"`[^`\n]+`"#, options: []) { base, palette in
      [
        .font: NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular),
        .foregroundColor: palette.code,
      ]
    },
    // 粗体、斜体：保留标记符号，只改字形——写作时标记本身也是信息。
    Rule(pattern: #"\*\*[^*\n]+\*\*"#, options: []) { base, palette in
      [.font: NSFont.boldSystemFont(ofSize: base.pointSize), .foregroundColor: palette.primary]
    },
    Rule(pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)"#, options: []) { base, palette in
      let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
      return [.font: italic, .foregroundColor: palette.primary]
    },
    // 链接：整体上色，让「这里有个地址」在一片文字里跳出来。
    Rule(pattern: #"\[[^\]\n]*\]\([^)\s]+\)"#, options: []) { _, palette in
      [.foregroundColor: palette.accent]
    },
  ]}

  /// 就地重新着色。只改属性、不动文字，因此不会打断输入法组字。
  static func apply(
    to storage: NSTextStorage,
    baseFont: NSFont,
    palette: Palette,
    lineSpacing: CGFloat
  ) {
    let full = NSRange(location: 0, length: storage.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing

    storage.beginEditing()
    storage.setAttributes(
      [.font: baseFont, .foregroundColor: palette.primary, .paragraphStyle: paragraph],
      range: full
    )
    let text = storage.string
    for rule in rules {
      guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
      for match in regex.matches(in: text, range: full) {
        storage.addAttributes(rule.style(baseFont, palette), range: match.range)
      }
    }
    storage.endEditing()
  }
}
