import Foundation
import LinkDigestCore

enum CapturedSourceBodyPresentation {
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
  /// 只剥「和标题同一句话」的开头，以及紧随其后、看起来像稿件信息行的短句。
  /// 正文里真正的第一节不要动。
  static func strippingEchoedOpening(title: String, from markdown: String) -> String {
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
    return lines.joined(separator: "\n")
  }

  private static func isEchoedByline(_ line: String) -> Bool {
    guard line.count <= 80, !line.hasPrefix("#") else { return false }
    let lower = line.lowercased()
    let looksLikeDate = line.contains("20") && (line.contains("-") || line.contains("年") || line.contains("月"))
    let looksLikeDuration = lower.contains("min") || line.contains("分钟") || line.contains("字")
    return looksLikeDate || looksLikeDuration
  }

  private static func canonicalText(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
  }
}
