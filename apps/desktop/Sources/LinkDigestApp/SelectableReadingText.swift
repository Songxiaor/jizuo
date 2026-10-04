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
  /// 段后间距：约半行（2026-09-28 正文排版样稿）。行距 7，行和行的缝明显小于段和段的缝。
  static let paragraphSpacing: CGFloat = 15
  /// 连续短句段（每段不到一行，公众号一句一段的写法）之间的缝：读成一组，不再句句空一行。
  static let shortRunSpacing: CGFloat = 3

  /// - Parameter emphasizesLede: 这一段文字是全文开头时为 true：第一段大一号当导语。
  static func attributed(
    blocks: [MarkdownPresentation.Block],
    readingFont: ResolvedReadingFont,
    palette: Palette,
    emphasizesLede: Bool = false
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    // 短帖（三百字以内）不设导语：一共两三句话，第一句放大只会显得突兀。
    let ledeAllowed = emphasizesLede && blocks.count >= 3 && blocks.reduce(0) { total, block in
      if case let .paragraph(text) = block { return total + text.count }
      return total
    } > 300
    for (index, block) in blocks.enumerated() {
      let next = index + 1 < blocks.count ? blocks[index + 1] : nil
      // 下一块是这一条的括号说明时，条目和说明之间几乎不留缝，让两者读成一组。
      let lastItemSpacing: CGFloat = next.map(isItemNote) == true ? 3 : 10
      switch block {
      case let .heading(level, text):
        // 标题随正文字号等比缩放；上方留出明显的空白，一眼看出「换了一节」（2026-09-28 样稿）。
        let size = readingFont.scaledSize([1: 23, 2: 19.5, 3: 17][level] ?? 16)
        result.append(paragraph(
          inline(stripMarkers(text), readingFont: readingFont, baseSize: size, bold: true, color: palette.primary),
          spacingBefore: level <= 2 ? 30 : 22, spacingAfter: 8, lineSpacing: 6
        ))
      case let .paragraph(text):
        if let indent = index > 0 ? itemNoteIndent(after: blocks[index - 1]) : nil, isItemNote(block) {
          // 「1. 要点」空一行再跟「（解释）」是 X 长帖的常见写法。当成普通段落时，
          // 说明和它的条目隔得跟两段话一样远，读者得自己猜哪句跟哪句是一组。
          // 这里缩进到条目文字对齐处、用次要色，挂在条目下面。
          result.append(paragraph(
            inline(text, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary),
            spacingAfter: Self.paragraphSpacing, lineSpacing: 7, headIndent: indent, firstLineIndent: indent
          ))
        } else if let label = leadingLabel(of: text) {
          // 「**核心结论**：……」：标签单独一行，靛青小字；正文另起（2026-09-28 样稿）。
          // 总结、笔记里最常见的结构，原来混在句子里，扫读时找不到。
          result.append(paragraph(
            labelLine(label.label, readingFont: readingFont, color: palette.accent),
            spacingBefore: index == 0 ? 0 : 10, spacingAfter: 4, lineSpacing: 2
          ))
          if !label.rest.isEmpty {
            result.append(paragraph(
              inline(label.rest, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.primary),
              spacingAfter: Self.paragraphSpacing, lineSpacing: MarkdownPresentation.bodyLineSpacing
            ))
          }
        } else {
          let isLede = ledeAllowed && index == 0 && isLedeCandidate(text)
          // 连着的短句段收成一组：这一段和下一段都不满一行时，只留一道细缝。
          let tightensToNext = isShortLine(text) && next.map(isShortLineParagraph) == true
          result.append(paragraph(
            inline(
              text, readingFont: readingFont,
              baseSize: isLede ? readingFont.bodySize + 1 : readingFont.bodySize,
              color: palette.primary
            ),
            spacingAfter: tightensToNext ? Self.shortRunSpacing : Self.paragraphSpacing,
            lineSpacing: MarkdownPresentation.bodyLineSpacing
          ))
        }
      case let .list(items):
        for (itemIndex, item) in items.enumerated() {
          // 深层用不同的记号，并跟着加缩进——选中复制出去时层级也不该丢。
          // 记号用靛青、Tab 对齐到悬挂缩进处：折行后的第二行和第一行文字齐（2026-09-28 样稿）。
          let indent = CGFloat(22 + item.depth * 18)
          let marker = (item.depth == 0 ? "•" : "◦") + "\t"
          result.append(paragraph(
            bulletLine(marker, item.text, readingFont: readingFont, color: palette.primary, markerColor: palette.accent),
            spacingAfter: itemIndex == items.count - 1 ? lastItemSpacing : 6,
            lineSpacing: MarkdownPresentation.bodyLineSpacing, headIndent: indent,
            firstLineIndent: indent - 14, tabStop: indent
          ))
        }
      case let .orderedList(start, items):
        for (itemIndex, item) in items.enumerated() {
          result.append(paragraph(
            bulletLine("\(start + itemIndex).\t", item, readingFont: readingFont, color: palette.primary, markerColor: palette.accent),
            spacingAfter: itemIndex == items.count - 1 ? lastItemSpacing : 6,
            lineSpacing: MarkdownPresentation.bodyLineSpacing, headIndent: 26, tabStop: 26
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
        // 分节号「·  ·  ·」居中（2026-10-03 走查）：原来是 24 个「─」拼的一串字，长度固定，
        // 正文宽的时候只画到六成，看着像没画完。书里的分节本来就用居中的几个点。
        result.append(paragraph(
          inline(
            MarkdownPresentation.sectionBreakGlyphs,
            readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary
          ),
          spacingBefore: 6, spacingAfter: 20, lineSpacing: 4, alignment: .center
        ))
      case let .quote(_, text):
        result.append(paragraph(
          inline(text, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary),
          spacingAfter: Self.paragraphSpacing, lineSpacing: 8, headIndent: 18, firstLineIndent: 18
        ))
      case let .callout(kind, title, text, _):
        let label = title.isEmpty ? MarkdownPresentation.calloutLabel(kind) : title
        let body = text.isEmpty ? label : "**\(label)**  \(text)"
        result.append(paragraph(
          inline(body, readingFont: readingFont, baseSize: readingFont.bodySize, color: palette.secondary),
          spacingAfter: Self.paragraphSpacing, lineSpacing: 8, headIndent: 18, firstLineIndent: 18
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

  /// 整段包在括号里的短说明，比如「（对我来说，交付物就是一门课程）」。
  static func isItemNote(_ block: MarkdownPresentation.Block) -> Bool {
    guard case let .paragraph(text) = block else { return false }
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = trimmed.last, "。.；;".contains(last) { trimmed.removeLast() }
    guard !trimmed.contains("\n") else { return false }
    return (trimmed.hasPrefix("（") && trimmed.hasSuffix("）"))
      || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
  }

  /// 段首「**标签**：正文」。标签限 14 字以内，太长的粗体更像强调句，不拆。
  static func leadingLabel(of text: String) -> (label: String, rest: String)? {
    let pattern = #"^(\*\*|__)([^*_\n]{1,14}?)\1\s*[：:]\s*"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let labelRange = Range(match.range(at: 2), in: text),
          let whole = Range(match.range, in: text) else { return nil }
    let label = text[labelRange].trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return (label, String(text[whole.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 不满一行的短段：中文按一字一格、西文按半格估算，约 36 字一行的版心里 ≤ 28 格。
  static func isShortLine(_ text: String) -> Bool {
    guard !text.contains("\n") else { return false }
    let width = text.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1) }
    return width > 0 && width <= 28
  }

  static func isShortLineParagraph(_ block: MarkdownPresentation.Block) -> Bool {
    guard case let .paragraph(text) = block else { return false }
    return leadingLabel(of: text) == nil && !isItemNote(block) && isShortLine(text)
  }

  /// 导语：一段完整的话（不是图片、标签或一个短标题似的句子）。
  static func isLedeCandidate(_ text: String) -> Bool {
    guard leadingLabel(of: text) == nil, !text.hasPrefix("!["), !text.contains("\n") else { return false }
    return (12...220).contains(text.count)
  }

  private static func labelLine(_ label: String, readingFont: ResolvedReadingFont, color: NSColor) -> NSAttributedString {
    let size = (readingFont.bodySize * 0.8).rounded()
    return NSAttributedString(string: label, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: .medium),
      .foregroundColor: color,
      .kern: 2,
    ])
  }

  /// 前一块是清单时，说明要对齐到的缩进；不是清单返回 nil。
  static func itemNoteIndent(after block: MarkdownPresentation.Block) -> CGFloat? {
    switch block {
    case .orderedList: 26
    case let .list(items): CGFloat(22 + (items.last?.depth ?? 0) * 18)
    default: nil
    }
  }

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
    let parsed = NSMutableAttributedString(attributedString: NSAttributedString(MarkdownPresentation.inlineAttributed(text, marksMath: true)))
    let full = NSRange(location: 0, length: parsed.length)
    guard full.length > 0 else { return parsed }
    parsed.enumerateAttributes(in: full) { attributes, range, _ in
      let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      // 行内代码：解析器只打「这是代码」的标记，等宽字是系统画字时自己换的，
      // 字体属性里看不出来——按标记认。
      let intent = (attributes[.inlinePresentationIntent] as? NSNumber)?.uintValue ?? 0
      let isInlineCode = intent & InlinePresentationIntent.code.rawValue != 0
      if traits.contains(.monoSpace) || isInlineCode {
        // 等宽字的字面比中文小，只小 1.5 号，放进句子里看起来和正文一样大。
        parsed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize - 1.5, weight: .regular), range: range)
        // 行内代码垫一个贴字的圆角浅底（对齐 Tolaria）：等宽字直接夹在中文句子里很突兀，
        // 有底才读得出是「一个词」。用系统的背景色属性会铺满整行高度，所以由
        // `ReadingLayoutManager` 按字高自己画。
        parsed.addAttribute(.readingInlineCodeChip, value: true, range: range)
        return
      }
      // 上下标（`H~2~O`、`<sup>`）：解析层只给了基线偏移，字号在这里按正文缩小。
      let isScript = ((attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0) != 0
      let size = isScript ? (baseSize * MarkdownPresentation.ScriptMarker.scale).rounded() : baseSize
      var descriptor = readingFont.nsFontDescriptor(size: size)
      if bold || traits.contains(.bold) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold])
      }
      if traits.contains(.italic) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .italic])
      }
      parsed.addAttribute(.font, value: NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size), range: range)
    }
    parsed.addAttribute(.foregroundColor, value: color, range: full)
    replaceInlineMath(in: parsed, baseSize: baseSize, color: color)
    addCJKLatinSpacing(to: parsed, baseSize: baseSize)
    narrowLatinQuotes(in: parsed)
    return parsed
  }

  /// 英文里的弯引号、撇号改用字体自带的比例宽字形。
  ///
  /// 思源宋体这类中文字体里 ‘ ’ “ ” 默认是全角，英文句子里的「we’ll」「“no command.”」
  /// 被撑成「we’ ll」「“ no」，像中间多了空格（2026-10-04 走查 GitHub README）。
  /// 同一个字体打开「比例宽度」特性就是窄字形（实测 ’ 16 → 4.3pt），字形风格不变。
  /// 只改两边都不是中日韩字符的引号：「他说：“你好”」里的照旧全角。
  static func narrowLatinQuotes(in text: NSMutableAttributedString) {
    let string = text.string as NSString
    guard string.length > 0 else { return }
    let quotes: Set<unichar> = [0x2018, 0x2019, 0x201C, 0x201D]
    func isWide(_ unit: unichar) -> Bool {
      switch unit {
      case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
           0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0xD800...0xDBFF:
        return true
      default:
        return false
      }
    }
    for index in 0..<string.length where quotes.contains(string.character(at: index)) {
      let before = index > 0 ? string.character(at: index - 1) : 0x20
      let after = index + 1 < string.length ? string.character(at: index + 1) : 0x20
      // 引号挨着引号（‘“…”’）时看再外面一层太绕，按「不是中日韩」处理即可。
      guard !isWide(before), !isWide(after) else { continue }
      guard let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { continue }
      let descriptor = font.fontDescriptor.addingAttributes([
        .featureSettings: [[
          NSFontDescriptor.FeatureKey.typeIdentifier: kTextSpacingType,
          NSFontDescriptor.FeatureKey.selectorIdentifier: kProportionalTextSelector,
        ]],
      ])
      if let narrow = NSFont(descriptor: descriptor, size: font.pointSize) {
        text.addAttribute(.font, value: narrow, range: NSRange(location: index, length: 1))
      }
    }
  }

  /// 行内公式记号换成公式图片（文本附件）；还没排好或排不出来时，先显示 TeX 原文。
  private static func replaceInlineMath(in text: NSMutableAttributedString, baseSize: CGFloat, color: NSColor) {
    guard text.string.contains(InlineMath.open) else { return }
    // 组装总在主线程（阅读渲染缓存是 @MainActor）；这里只是把这一点告诉编译器。
    nonisolated(unsafe) let text = text
    MainActor.assumeIsolated {
      while let openRange = text.string.range(of: String(InlineMath.open)),
            let closeRange = text.string.range(of: String(InlineMath.close), range: openRange.upperBound..<text.string.endIndex) {
        let tex = InlineMath.decode(text.string[openRange.upperBound..<closeRange.lowerBound])
        let whole = NSRange(openRange.lowerBound..<closeRange.upperBound, in: text.string)
        let attributes = text.attributes(at: whole.location, effectiveRange: nil)
        let request = ReadingWebRenderer.Request(
          kind: .inlineMath, source: tex, color: color.readingHex, fontSize: baseSize, isDark: false, width: 0
        )
        switch ReadingWebRenderer.shared.outcome(for: request) {
        case let .rendered(result):
          let attachment = NSTextAttachment()
          attachment.image = result.image
          attachment.bounds = CGRect(x: 0, y: -result.descent, width: result.size.width, height: result.size.height)
          let replacement = NSMutableAttributedString(attachment: attachment)
          replacement.addAttributes(attributes.filter { $0.key != .attachment }, range: NSRange(location: 0, length: replacement.length))
          text.replaceCharacters(in: whole, with: replacement)
        case .failed, .none:
          var fallback = attributes
          fallback[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 2.5, weight: .regular)
          text.replaceCharacters(in: whole, with: NSAttributedString(string: "$\(tex)$", attributes: fallback))
        }
      }
    }
  }

  /// 中文紧挨英文或数字时（「Karpathy风格的LLM维基」），在交界处补一点空隙。
  ///
  /// 用字距而不是插入空格：文字本身一个字符都不变，复制、搜索、摘录定位
  /// （`revealText` 按原文找位置）全都不受影响。原文已经有空格的地方不是交界，不会叠加。
  ///
  /// 宽度取八分之一个字宽，和 CSS `text-autospace` 的标准一致（2026-09-25）。原来是四分之一：
  /// 汉字自带左右留白，再叠四分之一字宽，看上去像两个空格（「谈  tokenization」）。
  ///
  /// 系统自己会加时就不再叠一层（2026-09-25 实测 macOS 27）：TextKit 已在汉字和字母之间留
  /// 约 1/8 字宽；我们再加的字距会被全角标点挤压「接走」——「机器人，谈tokenization」里
  /// 逗号被压窄，省下的宽度全堆到「谈」后面，看上去像空了两格。
  static func addCJKLatinSpacing(to text: NSMutableAttributedString, baseSize: CGFloat) {
    guard !systemAddsCJKLatinSpacing else { return }
    let string = text.string
    let gap = baseSize * 0.125
    var previous: (index: String.Index, isCJK: Bool, isLatin: Bool)?
    for index in string.indices {
      let character = string[index]
      let isCJK = isCJKIdeograph(character)
      let isLatin = character.isASCII && (character.isLetter || character.isNumber)
      if let previous, (previous.isCJK && isLatin) || (previous.isLatin && isCJK) {
        let range = NSRange(previous.index..<index, in: string)
        text.addAttribute(.kern, value: gap, range: range)
      }
      previous = (index, isCJK, isLatin)
    }
  }

  /// 量一次：「中A」在排版后的宽度比两字各自宽度之和多出来，就是系统自带了中英间距。
  static let systemAddsCJKLatinSpacing: Bool = {
    let font = NSFont.systemFont(ofSize: 20)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let storage = NSTextStorage(string: "中A", attributes: attributes)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 1000, height: 100))
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    let letterX = layout.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: container).minX
    let hanWidth = ("中" as NSString).size(withAttributes: attributes).width
    return letterX - hanWidth > 1
  }()

  private static func isCJKIdeograph(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // 汉字
         0x3040...0x30FF, // 假名
         0xAC00...0xD7AF: // 韩文
      return true
    default:
      return false
    }
  }

  private static func bulletLine(
    _ prefix: String,
    _ text: String,
    readingFont: ResolvedReadingFont,
    color: NSColor,
    markerColor: NSColor? = nil
  ) -> NSAttributedString {
    // 圆点用系统字体：宋体里的「•」又小又细，靛青也显不出来。
    let markerFont = markerColor != nil && (prefix.hasPrefix("•") || prefix.hasPrefix("◦"))
      ? NSFont.systemFont(ofSize: readingFont.bodySize, weight: .bold)
      : font(readingFont, size: readingFont.bodySize)
    let line = NSMutableAttributedString(string: prefix, attributes: [
      .font: markerFont,
      .foregroundColor: markerColor ?? color,
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
    firstLineIndent: CGFloat = 0,
    tabStop: CGFloat? = nil,
    alignment: NSTextAlignment = .natural
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: content)
    // A Markdown hard break stays inside the same paragraph. Cocoa treats LF
    // as a paragraph boundary and would apply the 20pt paragraph gap each time.
    mutable.mutableString.replaceOccurrences(
      of: "\n", with: "\u{2028}", range: NSRange(location: 0, length: mutable.length)
    )
    mutable.append(NSAttributedString(string: "\n"))
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = spacingBefore
    style.paragraphSpacing = spacingAfter
    style.lineSpacing = lineSpacing
    style.headIndent = headIndent
    style.firstLineHeadIndent = firstLineIndent
    style.alignment = alignment
    if let tabStop {
      style.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]
      style.defaultTabInterval = tabStop
    }
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
    view.textContainer?.replaceLayoutManager(ReadingLayoutManager())
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
    let initial = styledDocument(text)
    view.textStorage?.setAttributedString(initial.text)
    context.coordinator.openLineStart = initial.openLineStart
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
      if !suffix.isEmpty, let storage = view.textStorage {
        let restyleFrom = context.coordinator.openLineStart
        storage.beginEditing()
        storage.append(attributed(suffix))
        context.coordinator.openLineStart = finishCompletedLines(in: storage, from: restyleFrom)
        storage.endEditing()
        let length = storage.length
        let from = min(restyleFrom, length)
        view.layoutManager?.ensureLayout(
          forCharacterRange: NSRange(location: from, length: length - from)
        )
      }
    } else {
      let selection = view.selectedRange()
      let document = styledDocument(text)
      view.textStorage?.setAttributedString(document.text)
      context.coordinator.openLineStart = document.openLineStart
      let length = document.text.length
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
      let end = NSRange(location: max((view.string as NSString).length - 1, 0), length: 0)
      view.scrollRangeToVisible(end)
    }
  }

  final class Coordinator {
    var lastText = ""
    var lastStyle: StyleKey?
    /// 还没写完的那一行在文本里从哪开始；它之前的行都已经收成排版样式。
    var openLineStart = 0
  }

  // MARK: 流式阶段的轻量排版
  //
  // 原来流式时整段是纯文本，`## 小标题`、`**重点**`、`- 列表` 的符号原样露着，生成一结束
  // 换成正式排版，符号消失、标题变大，整页往上一跳（2026-10-02 走查）。每写完一行就把这一行
  // 收成接近最终的样子；还在长的那一行保持原样，不在半个 `**` 上猜。

  func styledDocument(_ value: String) -> (text: NSAttributedString, openLineStart: Int) {
    let result = NSMutableAttributedString(attributedString: attributed(value))
    let openLineStart = finishCompletedLines(in: result, from: 0)
    return (result, openLineStart)
  }

  private func finishCompletedLines(in storage: NSMutableAttributedString, from start: Int) -> Int {
    var lineStart = min(start, storage.length)
    while true {
      let string = storage.string as NSString
      let newline = string.range(of: "\n", options: [], range: NSRange(location: lineStart, length: string.length - lineStart))
      guard newline.location != NSNotFound else { return lineStart }
      let lineRange = NSRange(location: lineStart, length: newline.location - lineStart)
      let styled = styledLine(string.substring(with: lineRange))
      storage.replaceCharacters(in: lineRange, with: styled)
      lineStart += styled.length + 1
    }
  }

  private func styledLine(_ raw: String) -> NSAttributedString {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 3, Set(trimmed).isSubset(of: ["-", "*", "_"]) {
      return NSAttributedString(string: "")
    }
    var line = raw
    var lineFont = font
    var lineColor = color
    if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
      let level = line[match].filter { $0 == "#" }.count
      line.removeSubrange(match)
      let grow: CGFloat = level == 1 ? 6 : (level == 2 ? 3 : 1)
      lineFont = NSFontManager.shared.convert(
        NSFont(descriptor: font.fontDescriptor, size: font.pointSize + grow) ?? font,
        toHaveTrait: .boldFontMask
      )
    } else if let match = line.range(of: "^>\\s?", options: .regularExpression) {
      line.removeSubrange(match)
      lineColor = color.withAlphaComponent(0.7)
    } else if let match = line.range(of: "^(\\s*)[-*+]\\s+", options: .regularExpression) {
      let indent = String(line[match].prefix { $0 == " " || $0 == "\t" })
      line.replaceSubrange(match, with: indent + "•  ")
    }
    line = line.replacingOccurrences(of: "`", with: "")
    let base = attributed(line)
    let result = NSMutableAttributedString(attributedString: base)
    result.addAttributes([.font: lineFont, .foregroundColor: lineColor], range: NSRange(location: 0, length: result.length))
    // **粗体**：去掉星号，中间加粗。
    let bold = NSFontManager.shared.convert(lineFont, toHaveTrait: .boldFontMask)
    while let open = result.string.range(of: "**"),
          let close = result.string.range(of: "**", range: open.upperBound..<result.string.endIndex) {
      let openRange = NSRange(open, in: result.string)
      let closeRange = NSRange(close, in: result.string)
      let inner = NSRange(location: openRange.upperBound, length: closeRange.location - openRange.upperBound)
      result.addAttribute(.font, value: bold, range: inner)
      result.deleteCharacters(in: closeRange)
      result.deleteCharacters(in: openRange)
    }
    return result
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
  /// 用接近阅读列的高度，避免译文挤在一小块里自己滚。
  static let minHeight: CGFloat = 520
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

extension NSAttributedString.Key {
  /// 行内代码的底色标记（由 `ReadingLayoutManager` 画）。
  static let readingInlineCodeChip = NSAttributedString.Key("jizuo.readingInlineCodeChip")
}

/// 阅读区的排版器：给行内代码画贴字的圆角浅底。
///
/// 系统的背景色属性按整行高度铺（含行距），15pt 正文上是一块 28pt 高的灰条，
/// 很笨重。这里按字体的上下沿、上下各留 2pt 画，每行各画一段。
final class ReadingLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let textStorage, let container = textContainers.first else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    textStorage.enumerateAttribute(.readingInlineCodeChip, in: characters) { value, range, _ in
      guard value != nil else { return }
      let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        ?? NSFont.systemFont(ofSize: 14)
      let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      NSColor.labelColor.withAlphaComponent(0.07).setFill()
      enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
        let piece = NSIntersectionRange(glyphs, lineGlyphs)
        guard piece.length > 0 else { return }
        var bounds = self.boundingRect(forGlyphRange: piece, in: container)
        let baseline = lineRect.minY + self.location(forGlyphAt: piece.location).y
        bounds.origin.y = baseline - font.ascender - 2
        bounds.size.height = font.ascender - font.descender + 4
        bounds = bounds.insetBy(dx: -3, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      }
    }
  }
}
