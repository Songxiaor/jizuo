import Foundation
import LinkDigestCore

enum CapturedSourceBodyPresentation {
  /// Social captions use author-entered line breaks, not prose line wrapping.
  /// Mark those lines as Markdown hard breaks; fenced code remains byte-for-byte intact.
  static func preservingCaptionParagraphs(_ markdown: String, platform: String) -> String {
    guard ["xiaohongshu", "douyin", "bilibili"].contains(platform) else { return markdown }
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
      result.append(trimmed.isEmpty ? line : line + "  ")
    }
    return result.joined(separator: "\n")
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
