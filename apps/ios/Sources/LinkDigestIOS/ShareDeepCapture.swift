import Foundation

/// 合并 Safari Share / 系统分享附件里的 URL、标题、正文（含 JS 预处理结果）。
public enum ShareDeepCapture {
  public static let renderedDOMSource = "safari_rendered_dom"
  public static let minimumUsefulBodyCharacters = 40

  public struct Fragments: Sendable, Equatable {
    public var url: String?
    public var title: String?
    public var text: String?
    public var source: String?

    public init(url: String? = nil, title: String? = nil, text: String? = nil, source: String? = nil) {
      self.url = ShareDeepCapture.normalize(url)
      self.title = ShareDeepCapture.normalize(title)
      self.text = ShareDeepCapture.normalize(text)
      self.source = ShareDeepCapture.normalize(source)
    }

    public var isEmpty: Bool {
      (url?.isEmpty ?? true) && (text?.isEmpty ?? true)
    }
  }

  /// 从 Safari `NSExtensionJavaScriptPreprocessingFile` 回传的字典合并字段。
  public static func fragments(fromPropertyList dict: [String: Any]) -> Fragments {
    let url = stringValue(dict["url"] ?? dict["URL"])
    let title = stringValue(dict["title"] ?? dict["Title"])
    let text = stringValue(dict["text"] ?? dict["body"] ?? dict["content"])
    let source = stringValue(dict["source"]) ?? renderedDOMSource
    return Fragments(url: url, title: title, text: text, source: source)
  }

  /// 后写入的非空字段覆盖先前；正文若更长则优先更长的。
  public static func merging(_ base: Fragments, with next: Fragments) -> Fragments {
    var out = base
    if let url = next.url, !url.isEmpty { out.url = url }
    if let title = next.title, !title.isEmpty { out.title = title }
    if let source = next.source, !source.isEmpty { out.source = source }
    if let text = next.text, !text.isEmpty {
      let currentCount = out.text?.unicodeScalars.count ?? 0
      if text.unicodeScalars.count >= currentCount {
        out.text = text
      }
    }
    return out
  }

  /// 纯 URL 文本不应再当正文；深抓正文加「来自当前页」前缀。
  public static func normalizedForInbox(_ fragments: Fragments) -> ShareInbox.Item {
    var url = fragments.url
    var text = fragments.text
    let title = fragments.title

    if url == nil, let candidate = text, ShareInbox.looksLikeHTTPURL(candidate) {
      url = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      text = nil
    }
    if let candidate = text, ShareInbox.looksLikeHTTPURL(candidate), candidate == url {
      text = nil
    }

    if fragments.source == renderedDOMSource,
       let body = text,
       body.unicodeScalars.count >= minimumUsefulBodyCharacters,
       !body.hasPrefix("【来自当前页】")
    {
      text = "【来自当前页】\n\n\(body)"
    }

    return ShareInbox.Item(url: url, text: text, title: title)
  }

  public static func isDeepCapturedBody(_ text: String?) -> Bool {
    guard let text else { return false }
    return text.hasPrefix("【来自当前页】")
  }

  private static func stringValue(_ raw: Any?) -> String? {
    if let value = raw as? String {
      return normalize(value)
    }
    if let value = raw as? NSNumber {
      return normalize(value.stringValue)
    }
    return nil
  }

  fileprivate static func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
