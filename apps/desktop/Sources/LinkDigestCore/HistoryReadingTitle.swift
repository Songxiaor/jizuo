import Foundation

/// 阅读展示用的标题：抓取标题仍是库里的事实；总结/翻译正文开头的一级标题
/// 只参与显示，不写回 task。
///
/// 列表第二行常常已经是 `# 中文总结标题…` 预览，详情头却仍钉着原文标题——
/// 这里把两者对齐：有产物标题时主标题用它，原文降为副行。
public enum HistoryReadingTitle {
  /// 从总结、翻译正文里取可用的展示标题。总结优先。
  public static func productTitle(summaryBody: String?, translationBody: String?) -> String? {
    if let title = derivedTitle(fromArtifactBody: summaryBody) { return title }
    return derivedTitle(fromArtifactBody: translationBody)
  }

  /// 列表行：有产物预览时优先用其中的一级标题做主标题。
  public static func primaryTitle(captured: String, artifactPreview: String?) -> String {
    guard let product = derivedTitle(fromArtifactBody: artifactPreview),
          product != captured
    else { return captured }
    return product
  }

  /// 详情头：主标题 + 可选的原文副标题（仅当两者不同）。
  /// `preservedOriginalTitle` 来自 frontmatter `original_title`，优先于抓取标题。
  public static func detailTitles(
    captured: String,
    product: String?,
    preservedOriginalTitle: String? = nil
  ) -> (primary: String, original: String?) {
    let preserved = preservedOriginalTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let product, !product.isEmpty, product != captured {
      let original = preserved?.isEmpty == false ? preserved : captured
      return (product, original == product ? nil : original)
    }
    if let preserved, !preserved.isEmpty, preserved != captured {
      return (captured, preserved)
    }
    return (captured, nil)
  }

  /// 列表预览：主标题已改用产物 `#` 时，去掉那一行，避免和主标题重复。
  public static func listPreview(
    artifactPreview: String?,
    primaryTitle: String,
    authorFallback: String?
  ) -> String? {
    if let preview = artifactPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
      if let stripped = strippingLeadingHeading(from: preview, matching: primaryTitle) {
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(240)) }
      } else {
        return String(preview.prefix(240))
      }
    }
    let author = authorFallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return author.isEmpty ? nil : author
  }

  private static func derivedTitle(fromArtifactBody body: String?) -> String? {
    guard let body else { return nil }
    let markdown = MarkdownNoteFrontmatter.parse(body).body
    let source = markdown.isEmpty ? body : markdown
    return UserNoteDocument.derivedTitle(fromBody: source)
  }

  private static func strippingLeadingHeading(from body: String, matching title: String) -> String? {
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var removed = false
    while let first = lines.first {
      let trimmed = first.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        lines.removeFirst()
        continue
      }
      guard trimmed.hasPrefix("# ") else { break }
      let heading = UserNoteDocument.sanitizedTitle(String(trimmed.dropFirst(2)))
      let matchesExact = heading == title
      let matchesTruncated = title.hasSuffix("…") && heading.hasPrefix(String(title.dropLast()))
      guard matchesExact || matchesTruncated else { break }
      lines.removeFirst()
      removed = true
      break
    }
    guard removed else { return nil }
    return lines.joined(separator: "\n")
  }
}
