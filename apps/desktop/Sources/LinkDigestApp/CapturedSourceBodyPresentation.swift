import Foundation
import LinkDigestCore

enum CapturedSourceBodyPresentation {
  /// 字幕段读起来像一面墙：几千字连成几段、中文之间夹着拼接留下的空格
  /// （YouTube 字幕，2026-10-03 Syc 走查「一点阅读感都没有」）。只在显示时整理，
  /// 存下的原文不动，已存的旧条目也一起变好：
  /// - 「## 字幕」下面的长段落在句末拆开，一段一百来字；
  /// - 汉字、中文标点之间的空格去掉。
  /// 整段只是一个「返回列表」导航链接（arena.ai 正文开头的「Back to All Articles」）：
  /// 不是正文，显示时去掉（2026-10-03 走查）。已存的旧条目也一起干净。
  static func strippingBackNavigationLinks(_ markdown: String) -> String {
    let pattern = #"^\[(?:←\s*)?(?:[Bb]ack to\b[^\]]{0,40}|返回[^\]]{0,12})\]\([^)]*\)$"#
    let blocks = markdown.components(separatedBy: "\n\n").filter { block in
      let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.range(of: pattern, options: .regularExpression) == nil
    }
    return blocks.joined(separator: "\n\n")
  }

  static func readableTranscriptSections(_ markdown: String) -> String {
    var output: [String] = []
    var inTranscript = false
    for block in markdown.components(separatedBy: "\n\n") {
      let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("#") {
        let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        inTranscript = heading == "字幕" || heading.hasPrefix("字幕（")
        output.append(block)
        continue
      }
      guard inTranscript, !trimmed.isEmpty, !trimmed.hasPrefix("```"), !trimmed.hasPrefix("!["), !trimmed.hasPrefix("- ") else {
        output.append(block)
        continue
      }
      output.append(contentsOf: splitAtSentenceEnds(removingCJKSpaces(trimmed)))
    }
    return output.joined(separator: "\n\n")
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      (0x4E00...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
        || (0xFF00...0xFFEF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        || "“”‘’…—".unicodeScalars.contains(scalar)
    }
  }

  static func removingCJKSpaces(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    for index in characters.indices {
      let character = characters[index]
      if character == " " || character == "\u{3000}" {
        let previous = result.last
        let next = characters[(index + 1)...].first { $0 != " " && $0 != "\u{3000}" }
        if let previous, let next, isCJK(previous), isCJK(next) { continue }
        if let previous, previous == " " { continue }
      }
      result.append(character)
    }
    return result
  }

  /// 长段在句末拆开。中文按字数，西文按字符数放宽一倍，免得一句英文被拆得太碎。
  static func splitAtSentenceEnds(_ paragraph: String, target: Int = 110) -> [String] {
    let isMostlyCJK = paragraph.filter(isCJK).count * 2 > paragraph.count
    let limit = isMostlyCJK ? target : target * 3
    guard paragraph.count > Int(Double(limit) * 1.5) else { return [paragraph] }
    let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", "…"]
    var pieces: [String] = []
    var current = ""
    var characters = Array(paragraph)[...]
    while let character = characters.popFirst() {
      current.append(character)
      let atSentenceEnd = enders.contains(character) || (character == "." && characters.first == " ")
      guard atSentenceEnd, current.count >= limit else { continue }
      // 句末若紧跟右引号、右括号，一起留在这一段。
      while let next = characters.first, "”’」』）)".contains(next) { current.append(next); characters.removeFirst() }
      pieces.append(current.trimmingCharacters(in: .whitespaces))
      current = ""
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty {
      if rest.count < limit / 3, let last = pieces.popLast() { pieces.append(last + (isMostlyCJK ? "" : " ") + rest) }
      else { pieces.append(rest) }
    }
    return pieces
  }

  /// Social captions use author-entered line breaks, not prose line wrapping.
  /// Mark those lines as Markdown hard breaks; fenced code remains byte-for-byte intact.
  static func preservingCaptionParagraphs(_ markdown: String, platform: String) -> String {
    // 推文（2026-10-01 加入）：作者按行写的要点，Markdown 会把单换行并成一段。
    let keepsLineBreaks = ["xiaohongshu", "douyin", "bilibili", "x"].contains(platform)
    var fence: String?
    var result: [String] = []
    for line in markdown.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let active = fence {
        result.append(line)
        if trimmed.hasPrefix(active) { fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
        result.append(line)
        continue
      }
      // 「• 两阶段过滤」这类用符号写的要点不是 Markdown 列表，几行会被并成一段、
      // 符号夹在句子中间（2026-10-01 走查）。转成真正的列表项，每条一行。
      if let item = Self.symbolBulletItem(trimmed) {
        result.append("- " + item)
        continue
      }
      guard keepsLineBreaks, !trimmed.isEmpty else {
        result.append(line)
        continue
      }
      // 社交平台配文的排法（2026-10-03 Syc：「一整堵墙，没有任何阅读观感」）。
      //
      // 原来每一行都只是硬换行：十几行等距排下来，没有段落，序号挤在行首，
      // 「————」印成一串字。现在按作者分行的意图分三种：
      // - 序号行（「1.帮我…」「2、…」）转成真正的编号列表，折行挂在文字下面；
      // - 只有横线的行画成分隔线；
      // - 普通行：一句话说完了（句末标点或够长）就分段，留出段距；没说完的短行
      //   （「沉静之旅」「#话题」这类）仍然硬换行连在一起，不被拆得七零八落。
      let previousIsListItem = result.last.map(Self.isMarkdownListLine) ?? false
      if Self.isSeparatorLine(trimmed) {
        Self.closeParagraph(&result)
        result.append(contentsOf: ["---", ""])
        continue
      }
      if let item = Self.numberedCaptionItem(trimmed) {
        if !previousIsListItem { Self.closeParagraph(&result) }
        result.append(item)
        continue
      }
      if previousIsListItem { result.append("") }
      if Self.endsThought(trimmed) {
        result.append(contentsOf: [trimmed, ""])
      } else {
        result.append(trimmed + "  ")
      }
    }
    while result.last?.isEmpty == true { result.removeLast() }
    return result.joined(separator: "\n")
  }

  /// 正文第一行就是页面上方的标题时去掉这一行（连同后面的空行）。
  ///
  /// 推文的标题取自配文首句。有视频时标题必须留着（视频把正文挤到一屏外），
  /// 于是视频下面的配文又从同一句开始，一屏里出现两遍（2026-10-03 走查）。
  /// 只认「整行就是标题」，标题只是首行的前半句时不动。
  static func strippingLeadingLine(_ markdown: String, equalTo title: String) -> String {
    let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return markdown }
    var lines = markdown.components(separatedBy: "\n")
    guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
          lines[index].trimmingCharacters(in: .whitespaces) == target,
          // 后面还得有别的字，不然整段配文就只剩空白。
          lines[(index + 1)...].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return markdown }
    lines.removeSubrange(0...index)
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    return lines.joined(separator: "\n")
  }

  /// 上一行还开着（硬换行连着）就收掉尾巴上的两个空格，再空一行起新段。
  private static func closeParagraph(_ result: inout [String]) {
    guard let last = result.last, !last.isEmpty else { return }
    if last.hasSuffix("  ") { result[result.count - 1] = String(last.dropLast(2)) }
    result.append("")
  }

  private static func isMarkdownListLine(_ line: String) -> Bool {
    line.hasPrefix("- ") || line.range(of: #"^\d{1,2}\. "#, options: .regularExpression) != nil
  }

  /// 「————」「-----」「＝＝＝」这类只用来隔开上下文的行。
  static func isSeparatorLine(_ trimmed: String) -> Bool {
    trimmed.count >= 3 && trimmed.allSatisfy { "—–-─━_＿=＝~～*＊·".contains($0) }
  }

  /// 「1.帮我…」「2、梳理…」「3）配上…」→「1. 帮我…」。只认 1–2 位序号。
  static func numberedCaptionItem(_ trimmed: String) -> String? {
    guard let match = trimmed.wholeMatch(of: /^(\d{1,2})[.、)）．]\s*(.+)$/) else { return nil }
    let rest = String(match.2)
    // 「3.5 倍速」「2.0 版本」是小数，不是序号。
    if trimmed.dropFirst(match.1.count).first == ".", rest.first?.isNumber == true { return nil }
    return "\(match.1). \(rest)"
  }

  /// 这一行是不是一句完整的话：句末标点，或者长到会自己折行。
  static func endsThought(_ trimmed: String) -> Bool {
    if let last = trimmed.last, "。！？!?…；;」』”\"）)~～".contains(last) { return true }
    return trimmed.count >= 28
  }

  private static let bulletSymbols: [Character] = ["•", "·", "●", "▪", "◦", "‧", "・"]

  /// 以要点符号开头、后面跟着文字的行，返回去掉符号的文字。
  static func symbolBulletItem(_ trimmedLine: String) -> String? {
    guard let first = trimmedLine.first, bulletSymbols.contains(first) else { return nil }
    let rest = trimmedLine.dropFirst().trimmingCharacters(in: .whitespaces)
    // 「·」也用作间隔号（「张三 · 李四」），但那种不会出现在行首；行首只有一个符号、
    // 后面没字的（分隔线）不算。
    return rest.isEmpty ? nil : rest
  }

  /// 阅读卡如何处理「正文开头又把标题印一遍」。
  enum EchoedOpeningStyle: Equatable {
    /// 非抖音：剥掉与标题相同的首行（标题或普通段落）以及紧随的日期/时长行。
    case stripMatchingOpening
    /// 抖音：只去掉合成的 ATX 标题 `# 同名标题`。与标题相同的真实配文首段和 hashtags 必须留下。
    case stripSyntheticTitleHeadingOnly
  }

  static func isRedundantDouyinBody(
    platform: String?,
    title: String,
    markdown: String
  ) -> Bool {
    guard platform == "douyin" else { return false }
    let titleKey = canonicalText(title)
    var remainder = canonicalText(MarkdownNoteFrontmatter.parse(markdown).body)
    guard !titleKey.isEmpty, !remainder.isEmpty else { return false }
    while remainder.hasPrefix(titleKey) {
      remainder.removeFirst(titleKey.count)
    }
    return remainder.isEmpty
  }

  /// 详情顶上已经有标题时，正文里再印一遍同名标题（外加一行日期/时长）就是重复。
  ///
  /// `style` 必须由调用方按平台传入：非抖音保持原去重；抖音不得删真实配文。
  static func strippingEchoedOpening(
    title: String,
    from markdown: String,
    style: EchoedOpeningStyle = .stripMatchingOpening
  ) -> String {
    switch style {
    case .stripMatchingOpening:
      return strippingMatchingOpening(title: title, from: markdown)
    case .stripSyntheticTitleHeadingOnly:
      return strippingSyntheticTitleHeadingOnly(title: title, from: markdown)
    }
  }

  /// 只剥「和标题同一句话」的开头，以及紧随其后、看起来像稿件信息行的短句。
  /// 正文里真正的第一节不要动。
  private static func strippingMatchingOpening(title: String, from markdown: String) -> String {
    let titleKey = canonicalText(title)
    guard !titleKey.isEmpty else { return markdown }
    var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    guard let headingIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      return markdown
    }
    let headingLine = lines[headingIndex].trimmingCharacters(in: .whitespaces)
    let headingText = headingLine.hasPrefix("#")
      ? headingLine.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
      : headingLine
    guard canonicalText(headingText) == titleKey else { return markdown }
    lines.remove(at: headingIndex)
    if let bylineIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
       isEchoedByline(lines[bylineIndex].trimmingCharacters(in: .whitespaces)) {
      lines.remove(at: bylineIndex)
    }
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeFirst()
    }
    let stripped = lines.joined(separator: "\n")
    guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return markdown }
    return stripped
  }

  /// 只认 `# 标题` / `## 标题` 这种带空格的 ATX 行，避免把 `#话题` 当成标题删掉。
  private static func strippingSyntheticTitleHeadingOnly(title: String, from markdown: String) -> String {
    let titleKey = canonicalText(title)
    guard !titleKey.isEmpty else { return markdown }
    var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    guard let headingIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      return markdown
    }
    let headingLine = lines[headingIndex].trimmingCharacters(in: .whitespaces)
    guard let headingText = atxHeadingText(headingLine),
          canonicalText(headingText) == titleKey
    else { return markdown }
    lines.remove(at: headingIndex)
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeFirst()
    }
    let body = lines.joined(separator: "\n")
    return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? headingText : body
  }

  private static func atxHeadingText(_ line: String) -> String? {
    let hashes = line.prefix(while: { $0 == "#" })
    guard (1...6).contains(hashes.count) else { return nil }
    let rest = line.dropFirst(hashes.count)
    guard rest.first == " " || rest.first == "\t" else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  private static func isEchoedByline(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count <= 80, !trimmed.hasPrefix("#") else { return false }
    let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
    if trimmed.range(of: #"^20\d{2}-\d{1,2}-\d{1,2}(?:\s+\d+(?:\.\d+)?\s*(?:min|mins|minutes|分钟))?$"#, options: options) != nil {
      return true
    }
    if trimmed.range(of: #"^20\d{2}年\d{1,2}月(?:\d{1,2}日)?(?:\s+\d+(?:\.\d+)?\s*(?:分钟|min|mins|minutes))?$"#, options: options) != nil {
      return true
    }
    return trimmed.count <= 20
      && trimmed.range(of: #"^\d+(?:\.\d+)?\s*(?:min|mins|minutes|分钟)$"#, options: options) != nil
  }

  private static func canonicalText(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
  }
}
