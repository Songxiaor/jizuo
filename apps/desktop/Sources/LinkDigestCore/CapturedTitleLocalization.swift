import Foundation

/// 外文抓取标题 → 阅读语言标题。原文标题写入 frontmatter `original_title`，
/// 列表/详情主标题改走 snapshot title，不把这次调用记成「已总结」。
public enum CapturedTitleLocalization {
  public static func isWeakTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
    if lower.hasPrefix("t.co/") { return true }
    return false
  }

  public static func shouldLocalize(title: String?, outputLanguage: String) -> Bool {
    guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
      return false
    }
    guard let target = CapturedContentLanguage.outputLanguage(outputLanguage) else { return false }
    guard let detected = CapturedContentLanguage.detect(in: title) else { return false }
    return detected != target
  }

  /// 新捕获判定：标题本身可读时用标题；标题只是链接时回退到正文抽样。
  public static func shouldLocalizeIncoming(
    title: String?,
    body: String?,
    outputLanguage: String
  ) -> Bool {
    let titleText = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !titleText.isEmpty else { return false }
    if !isWeakTitle(titleText),
       shouldLocalize(title: titleText, outputLanguage: outputLanguage) {
      return true
    }
    guard isWeakTitle(titleText) else { return false }
    guard let target = CapturedContentLanguage.outputLanguage(outputLanguage) else { return false }
    let bodySample = MarkdownNoteFrontmatter.parse(body ?? "").body
    let sample = [bodySample, titleText]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    guard let detected = CapturedContentLanguage.detect(in: sample) else { return false }
    return detected != target
  }

  public static func needsLocalization(
    title: String?,
    bodyText: String?,
    outputLanguage: String
  ) -> Bool {
    let parsed = MarkdownNoteFrontmatter.parse(bodyText ?? "")
    if parsed.originalTitle != nil { return false }
    return shouldLocalizeIncoming(title: title, body: parsed.body.isEmpty ? bodyText : parsed.body, outputLanguage: outputLanguage)
  }

  public static func modelInput(title: String, body: String?) -> String {
    let trimmedBody = MarkdownNoteFrontmatter.parse(body ?? "").body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if isWeakTitle(title), !trimmedBody.isEmpty {
      return """
      Page title (may be unhelpful): \(title)

      Content excerpt:
      <<<
      \(String(trimmedBody.prefix(800)))
      >>>
      """
    }
    return title
  }

  public static func sanitizedModelTitle(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix("#") {
      text = text.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let wrappers = CharacterSet(charactersIn: "\"'「」“”‘’")
    text = text.trimmingCharacters(in: wrappers)
    if let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first {
      text = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return UserNoteDocument.sanitizedTitle(text.trimmingCharacters(in: wrappers))
  }

  public static func bodyWithPreservedOriginal(bodyText: String, originalTitle: String) -> String {
    var note = MarkdownNoteFrontmatter.parse(bodyText)
    if note.originalTitle == nil {
      note.originalTitle = originalTitle
    }
    return note.render()
  }
}
