import AppKit
import Foundation
import LinkDigestCore

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
    /// 预编译的正则。以前存 pattern 字符串、每次着色现编译——12 条规则
    /// 每敲一个字就重新编译 12 次，是编辑热路径上最贵的无用功。
    let regex: NSRegularExpression
    /// 作用于整个匹配的样式。
    let style: (_ base: NSFont, _ palette: Palette) -> [NSAttributedString.Key: Any]
    /// 只作用于第 1 个捕获组——那是结构标记本身（`#`、`>`、`-`）。
    ///
    /// 标记要留着（删掉就成了所见即所得，写的和存的对不上），但它不该和标题
    /// 一样黑、一样大。淡下去之后，一行的视觉重心才落在文字上。
    var markerStyle: ((_ base: NSFont, _ palette: Palette) -> [NSAttributedString.Key: Any])?

    init?(
      pattern: String,
      options: NSRegularExpression.Options,
      style: @escaping (_ base: NSFont, _ palette: Palette) -> [NSAttributedString.Key: Any],
      markerStyle: ((_ base: NSFont, _ palette: Palette) -> [NSAttributedString.Key: Any])? = nil
    ) {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
      self.regex = regex
      self.style = style
      self.markerStyle = markerStyle
    }
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

    /// 供「是否需要重新着色」判断用的稳定指纹：四个颜色解析成 sRGB 分量。
    /// 语义色（如 .primary）解析结果随外观变化，所以调用方还要连同
    /// 当前外观名一起比较，见 MarkdownTextView.Coordinator。
    var fingerprint: [CGFloat] {
      [primary, secondary, accent, code].flatMap { color -> [CGFloat] in
        guard let srgb = color.usingColorSpace(.sRGB) else { return [-1, -1, -1, -1] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
      }
    }
  }

  /// 规则按「先粗后细」排：标题整行的字号要先定下来，行内强调再叠加。
  ///
  /// `@MainActor static let`：规则里带闭包不是 Sendable，钉在主线程上既满足
  /// 并发检查，又让正则只编译一次（着色本来就只在主线程发生）。
  @MainActor private static let rules: [Rule] = compileRules()

  /// 「除换行以外的空白」。
  ///
  /// 原来这些行首规则写的是 `\s`，而 `\s` 把换行也算进去：`#` 单独一行时
  /// `^(#{1,6})\s+(.+)$` 会吃掉换行，把**下一行**画成标题；`> ` 后面跟空行时
  /// 引用色会一路蔓延到再下一段。既是显示上的错，也让「只重算改动那几行」
  /// 变得不可能——一条行内规则随时可能跨到看不见的地方去。
  private static let space = #"[^\S\r\n\u0085\u000B\u000C\u2028\u2029]"#

  /// 唯一允许跨行的结构：围栏代码块。增量着色对它单独处理。
  static let fenceMarker = "```"

  private static func compileRules() -> [Rule] {[
    // 标题：整行放大加粗，`#` 本身淡出——它是结构标记，不是内容。
    Rule(
      pattern: #"^(#{1,6})"# + space + #"+(.+)$"#,
      options: [.anchorsMatchLines],
      style: { base, palette in
        [.font: NSFont.boldSystemFont(ofSize: base.pointSize * 1.25), .foregroundColor: palette.primary]
      },
      markerStyle: { base, palette in
        [
          .font: NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.82, weight: .regular),
          .foregroundColor: palette.secondary.withAlphaComponent(0.35),
        ]
      }
    ),
    // 引用整行淡化：它在视觉上本就该退后一层。
    Rule(pattern: #"^>"# + space + #"+.*$"#, options: [.anchorsMatchLines]) { _, palette in
      [.foregroundColor: palette.secondary]
    },
    // 列表符号着色，但不动文字本身。
    Rule(
      pattern: #"^"# + space + #"*([-*+]|\d+\.)(?:"# + space + #"|$)"#,
      options: [.anchorsMatchLines]
    ) { _, palette in
      [.foregroundColor: palette.accent]
    },
    // 已完成的任务整行划掉并淡化：一屏待办里，做完的那些应该退到背景去。
    // 放在列表规则之后，好压过它给项目符号上的强调色。
    Rule(
      pattern: #"^"# + space + #"*[-*+]"# + space + #"+\[[xX]\].*$"#,
      options: [.anchorsMatchLines]
    ) { _, palette in
      [
        .foregroundColor: palette.secondary,
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .strikethroughColor: palette.secondary.withAlphaComponent(0.6),
      ]
    },
    // 复选框本身是控件不是文字，给它等宽字体，勾没勾一列对齐才看得出来。
    Rule(
      pattern: #"^"# + space + #"*[-*+]"# + space + #"+(\[[ xX]\])"#,
      options: [.anchorsMatchLines]
    ) { base, palette in
      [
        .font: NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .medium),
        .foregroundColor: palette.accent,
        // 未完成项的框不该被上一条规则的删除线扫到。
        .strikethroughStyle: 0,
      ]
    },
    // 删除线。
    Rule(pattern: #"~~[^~\n]+~~"#, options: []) { _, palette in
      [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        .foregroundColor: palette.secondary,
      ]
    },
    // 分隔线：整行画淡，它是结构不是内容。
    Rule(
      pattern: #"^"# + space + #"*(---+|\*\*\*+|___+)"# + space + #"*$"#,
      options: [.anchorsMatchLines]
    ) { _, palette in
      [.foregroundColor: palette.secondary.withAlphaComponent(0.5)]
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
  ].compactMap { $0 }}

  /// 双链单独一遍，不走 `rules`：它要按每处链接的目标写不同的 `.link` 值，
  /// 而 `rules` 的样式只认「整段匹配用同一份属性」。
  ///
  /// `offset` 是 `text` 这一段在整篇里的 UTF-16 起点，增量着色时不为 0。
  private static func highlightWikiLinks(
    in storage: NSTextStorage,
    text: String,
    offset: Int,
    palette: Palette
  ) {
    for reference in WikiLink.references(in: text) {
      let local = NSRange(reference.range, in: text)
      let range = NSRange(location: local.location + offset, length: local.length)
      storage.addAttributes(
        [
          .foregroundColor: palette.accent,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
          .underlineColor: palette.accent.withAlphaComponent(0.4),
          // 点击要知道跳去哪。用自定义 scheme，避免被当成网址交给浏览器。
          .link: WikiLinkURL.url(forTitle: reference.target),
        ],
        range: range
      )
    }
  }

  /// 就地重新着色整篇。只改属性、不动文字，因此不会打断输入法组字。
  @MainActor static func apply(
    to storage: NSTextStorage,
    baseFont: NSFont,
    palette: Palette,
    lineSpacing: CGFloat
  ) {
    apply(
      to: storage, baseFont: baseFont, palette: palette, lineSpacing: lineSpacing,
      in: NSRange(location: 0, length: storage.length)
    )
  }

  /// 只重算一段。
  ///
  /// `range` 必须来自 `scope(in:editedRange:previousFenceMarkerCount:)`：它保证
  /// 范围对齐到整行、并且完整包含它碰到的每个围栏块。除围栏块外所有规则都被
  /// 限制在一行之内（见 `space`），所以「重算这几行」和「重算整篇」在这段范围上
  /// 的结果逐字符相同。
  @MainActor static func apply(
    to storage: NSTextStorage,
    baseFont: NSFont,
    palette: Palette,
    lineSpacing: CGFloat,
    in range: NSRange
  ) {
    let text = storage.string
    let full = NSRange(location: 0, length: storage.length)
    let target = NSIntersectionRange(full, range)
    guard target.length > 0 || full.length == 0 else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing

    storage.beginEditing()
    storage.setAttributes(
      [.font: baseFont, .foregroundColor: palette.primary, .paragraphStyle: paragraph],
      range: target
    )
    for rule in rules {
      // 交给 `range:` 而不是先截子串：`^`/`$` 在整行边界上本来就该匹配，
      // 截串反而要为末尾那个换行符再补一层特判。
      for match in rule.regex.matches(in: text, range: target) {
        storage.addAttributes(rule.style(baseFont, palette), range: match.range)
        // 标记样式后叠：它要压过刚刚铺上去的整行样式。
        if let markerStyle = rule.markerStyle, match.numberOfRanges > 1 {
          let marker = match.range(at: 1)
          if marker.location != NSNotFound {
            storage.addAttributes(markerStyle(baseFont, palette), range: marker)
          }
        }
      }
    }
    // 双链最后上：它要压过前面任何规则给过的颜色。
    let isFullPass = target.location == 0 && target.length == full.length
    highlightWikiLinks(
      in: storage,
      text: isFullPass ? text : (text as NSString).substring(with: target),
      offset: isFullPass ? 0 : target.location,
      palette: palette
    )
    storage.endEditing()
  }

  // MARK: - 增量范围

  /// 一次编辑要重算的范围。
  struct HighlightScope: Equatable {
    /// nil 表示这次编辑动了整篇的结构，只能全文重算。
    let range: NSRange?
    /// 重算之后文本里 ``` 的条数，调用方存下来传给下一次。
    let fenceMarkerCount: Int
  }

  /// 文本里所有 ``` 的位置，按正则那样不重叠地扫。
  ///
  /// 围栏规则 ```` ```[\s\S]*?``` ```` 的匹配等价于「把这些位置按 1-2、3-4…
  /// 两两配对」，所以数一遍位置就能还原出所有代码块，不必真的跑一次正则。
  static func fenceMarkerLocations(in text: NSString) -> [Int] {
    var result: [Int] = []
    var cursor = 0
    let markerLength = (fenceMarker as NSString).length
    while cursor + markerLength <= text.length {
      let found = text.range(
        of: fenceMarker,
        options: [.literal],
        range: NSRange(location: cursor, length: text.length - cursor)
      )
      guard found.location != NSNotFound else { break }
      result.append(found.location)
      cursor = found.location + markerLength
    }
    return result
  }

  /// 算出这次编辑要重算哪一段。
  ///
  /// - Parameters:
  ///   - editedRange: 编辑**之后**新文本里被动过的范围。
  ///   - previousFenceMarkerCount: 上一次着色时的 ``` 条数。条数一变，整篇的
  ///     围栏配对都会跟着变（在前面插一行 ``` 会让后面每个代码块的起止对调），
  ///     这时只能全文重算。
  static func scope(
    in text: NSString,
    editedRange: NSRange,
    previousFenceMarkerCount: Int
  ) -> HighlightScope {
    let markers = fenceMarkerLocations(in: text)
    let fullScope = HighlightScope(range: nil, fenceMarkerCount: markers.count)
    guard markers.count == previousFenceMarkerCount else { return fullScope }
    guard editedRange.location >= 0, editedRange.length >= 0,
          NSMaxRange(editedRange) <= text.length else { return fullScope }

    var regions: [NSRange] = []
    var index = 0
    let markerLength = (fenceMarker as NSString).length
    while index + 1 < markers.count {
      regions.append(
        NSRange(location: markers[index], length: markers[index + 1] + markerLength - markers[index])
      )
      index += 2
    }
    // 落单的那个 ``` 不成块。编辑碰到它就说明配对随时会变，退回全文。
    let unpaired = markers.count % 2 == 1 ? markers.last : nil

    // 删掉末尾一个字时脏范围会落在 length 上，退一格取最后一行。
    var probe = editedRange
    if probe.length == 0, probe.location >= text.length, text.length > 0 {
      probe = NSRange(location: text.length - 1, length: 1)
    }
    var range = text.lineRange(for: probe)
    // 前后各多吃一行。敲一个回车会把原来一行劈成两半，而 lineRange 只给得出
    // 前半行；后半行上那些原本存在、现在断掉的结构（被劈开的 `[[双链]]`、
    // 被劈开的行内代码）留着旧属性不刷，就是编辑器里最常见的那种残色。
    if range.location > 0 {
      range = NSUnionRange(
        range, text.lineRange(for: NSRange(location: range.location - 1, length: 0))
      )
    }
    if NSMaxRange(range) < text.length {
      range = NSUnionRange(
        range, text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
      )
    }
    // 展开到「完整包含碰到的每个代码块」，块边界又可能跨出新的行，所以要迭代。
    var rounds = 0
    while true {
      rounds += 1
      guard rounds <= 8 else { return fullScope }
      var expanded = range
      for region in regions where NSIntersectionRange(region, expanded).length > 0 {
        expanded = NSUnionRange(expanded, region)
      }
      expanded = text.lineRange(for: expanded)
      if NSEqualRanges(expanded, range) { break }
      range = expanded
    }

    if let unpaired, unpaired >= range.location, unpaired < NSMaxRange(range) { return fullScope }
    // 范围里的每个 ``` 都必须属于一个被完整包进来的代码块，否则跑正则时会
    // 配出一对原本不存在的围栏。
    for marker in markers where marker >= range.location && marker < NSMaxRange(range) {
      let covered = regions.contains { region in
        region.location >= range.location && NSMaxRange(region) <= NSMaxRange(range)
          && marker >= region.location && marker < NSMaxRange(region)
      }
      guard covered else { return fullScope }
    }
    return HighlightScope(range: range, fenceMarkerCount: markers.count)
  }
}

/// 双链点击用的地址。
///
/// 自定义 scheme 而不是 https：NSTextView 的 `.link` 属性一旦是个真网址，
/// 点下去系统会直接交给浏览器打开。这里要的是「在 App 内跳到另一条笔记」。
enum WikiLinkURL {
  static let scheme = "linkdigest-wiki"

  static func url(forTitle title: String) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    // 标题放 path 而不是 host：host 会被规范化成小写并拒绝中文以外的一些字符。
    components.path = "/" + title
    return components.url ?? URL(string: "\(scheme):/")!
  }

  /// 从点击到的地址还原标题；不是双链地址则返回 nil。
  static func title(from url: URL) -> String? {
    guard url.scheme == scheme else { return nil }
    let title = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
    return title.isEmpty ? nil : title
  }
}
