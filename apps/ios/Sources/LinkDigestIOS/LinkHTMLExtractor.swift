import Foundation

/// 从 HTML 抽出标题、描述与纯文本正文（iOS Companion 最小实现，不依赖桌面 Adapters）。
public struct LinkExtractedPage: Sendable, Equatable {
  public var title: String?
  public var description: String?
  public var body: String

  public init(title: String?, description: String? = nil, body: String) {
    self.title = title
    self.description = description
    self.body = body
  }
}

public enum LinkHTMLExtractor {
  public static let minimumBodyCharacters = 20

  /// 优先 og:title / twitter:title，再 `<title>`，再首个 h1。
  /// 正文优先 article → main → 去噪 body；过短时回退 meta description。
  /// `platformID` 来自 `IOSContentPlatform.id`，用于平台特化抽取。
  public static func extract(html: String, platformID: String? = nil) -> LinkExtractedPage {
    let title = extractTitle(from: html)
    let description = extractDescription(from: html)
    var body = extractBody(from: html, platformID: platformID)

    // 小红书 / 抖音 / 微博 / X / YouTube / B 站：公开页常几乎无 DOM 正文，og:description 才是可读内容。
    if let platformID,
       ["xiaohongshu", "douyin", "weibo", "x", "youtube", "bilibili"].contains(platformID),
       let description, !description.isEmpty
    {
      if body.unicodeScalars.count < minimumBodyCharacters || looksLikeLoginShell(title: title, body: body) {
        body = description
      } else if !body.contains(description) {
        body = description + "\n\n" + body
      }
    }

    // 知乎：优先 RichText / article；过短时拼上 description。
    if platformID == "zhihu",
       let description, !description.isEmpty,
       body.unicodeScalars.count < minimumBodyCharacters
    {
      body = description
    }

    if body.unicodeScalars.count < minimumBodyCharacters, let description, !description.isEmpty {
      if body.isEmpty {
        body = description
      } else if !body.contains(description) {
        body = description + "\n\n" + body
      }
    }
    return LinkExtractedPage(title: title, description: description, body: body)
  }

  public static func extractBody(from html: String, platformID: String? = nil) -> String {
    // 微信公众号：#js_content 是正文主容器。
    if platformID == "wechat",
       let jsContent = firstCapture(
         "<div\\b[^>]*id\\s*=\\s*[\"']js_content[\"'][^>]*>([\\s\\S]*?)</div>",
         in: html
       )
    {
      let text = plainText(from: jsContent)
      if text.unicodeScalars.count >= minimumBodyCharacters {
        return text
      }
    }

    // 知乎专栏 / 回答：常见 RichText / Post-RichText / article。
    if platformID == "zhihu" {
      let candidates = [
        firstCapture("<div\\b[^>]*class\\s*=\\s*[\"'][^\"']*RichText[^\"']*[\"'][^>]*>([\\s\\S]*?)</div>", in: html) ?? "",
        firstCapture("<article\\b[^>]*>([\\s\\S]*?)</article>", in: html) ?? "",
      ]
      for chunk in candidates where !chunk.isEmpty {
        let text = plainText(from: chunk)
        if text.unicodeScalars.count >= minimumBodyCharacters {
          return text
        }
      }
    }

    // B 站：优先视频简介区 / og 已在上层处理；这里再抽 desc 容器。
    if platformID == "bilibili",
       let desc = firstCapture(
         "<div\\b[^>]*id\\s*=\\s*[\"']v_desc[\"'][^>]*>([\\s\\S]*?)</div>",
         in: html
       )
    {
      let text = plainText(from: desc)
      if text.unicodeScalars.count >= 8 {
        return text
      }
    }

    // JSON-LD Article / SocialMediaPosting 正文（X / 通用）。
    if let jsonLD = extractJSONLDArticleBody(from: html),
       jsonLD.unicodeScalars.count >= minimumBodyCharacters
    {
      return jsonLD
    }

    return extractGenericBody(from: html)
  }

  /// 从 application/ld+json 抽 articleBody / text。
  public static func extractJSONLDArticleBody(from html: String) -> String? {
    guard let script = firstCapture(
      "<script\\b[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>([\\s\\S]*?)</script>",
      in: html
    ) else {
      return nil
    }
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
      return nil
    }
    return jsonLDText(from: json)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func jsonLDText(from json: Any) -> String? {
    if let dict = json as? [String: Any] {
      for key in ["articleBody", "text", "description"] {
        if let value = dict[key] as? String, value.unicodeScalars.count >= 8 {
          return value
        }
      }
      if let graph = dict["@graph"] {
        return jsonLDText(from: graph)
      }
    }
    if let array = json as? [Any] {
      for item in array {
        if let text = jsonLDText(from: item) { return text }
      }
    }
    return nil
  }

  private static func looksLikeLoginShell(title: String?, body: String) -> Bool {
    let haystack = ((title ?? "") + " " + body).lowercased()
    let markers = ["登录", "登入", "log in", "sign in", "打开小红书", "打开抖音", "微博", "sign up"]
    return markers.contains { haystack.contains($0) } && body.unicodeScalars.count < 120
  }

  public static func extractTitle(from html: String) -> String? {
    let candidates: [String?] = [
      metaContent(property: "og:title", in: html),
      metaContent(name: "twitter:title", in: html),
      decodeEntities(firstCapture("<title\\b[^>]*>([\\s\\S]*?)</title>", in: html) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty,
      decodeEntities(firstCapture("<h1\\b[^>]*>([\\s\\S]*?)</h1>", in: html) ?? "")
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty,
    ]
    for candidate in candidates {
      guard let value = candidate, value.count >= 2 else { continue }
      return collapseWhitespace(value)
    }
    return nil
  }

  public static func extractDescription(from html: String) -> String? {
    let candidates: [String?] = [
      metaContent(property: "og:description", in: html),
      metaContent(name: "twitter:description", in: html),
      metaContent(name: "description", in: html),
    ]
    for candidate in candidates {
      guard let value = candidate, value.count >= 8 else { continue }
      return collapseWhitespace(value)
    }
    return nil
  }

  public static func extractGenericBody(from html: String) -> String {
    var working = html
    for tag in ["script", "style", "noscript", "template", "svg", "iframe"] {
      working = replacing("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: working, with: " ")
      working = replacing("<\(tag)\\b[^>]*/?>", in: working, with: " ")
    }
    // 导航/页脚等常见 chrome，降低误抽概率。
    for tag in ["nav", "header", "footer", "aside"] {
      working = replacing("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: working, with: " ")
    }

    let semantic: [(label: String, html: String)] = [
      ("article", firstCapture("<article\\b[^>]*>([\\s\\S]*?)</article>", in: working) ?? ""),
      ("main", firstCapture("<main\\b[^>]*>([\\s\\S]*?)</main>", in: working) ?? ""),
      ("role-main", firstCapture(
        "<[^>]+role\\s*=\\s*[\"']main[\"'][^>]*>([\\s\\S]*?)</[a-zA-Z0-9]+>",
        in: working
      ) ?? ""),
    ]

    var bestText = ""
    var bestScore = -1
    for candidate in semantic where !candidate.html.isEmpty {
      let text = plainText(from: candidate.html)
      let score = bodyScore(text)
      if score > bestScore {
        bestScore = score
        bestText = text
      }
    }

    // 有够长的 article/main 时优先用它们，避免整页 body（含短卡片）因字数更多抢分。
    if bestText.unicodeScalars.count >= minimumBodyCharacters {
      return bestText
    }

    let bodyHTML = firstCapture("<body\\b[^>]*>([\\s\\S]*?)</body>", in: working) ?? working
    let bodyText = plainText(from: bodyHTML)
    if bodyText.unicodeScalars.count >= minimumBodyCharacters {
      return bodyText
    }
    if !bestText.isEmpty { return bestText }
    return plainText(from: working)
  }

  /// 从 HTML `<meta charset>` / http-equiv 推断编码名。
  public static func charsetHint(from html: String) -> String? {
    if let charset = firstCapture(
      "<meta\\b[^>]*charset\\s*=\\s*[\"']?\\s*([a-zA-Z0-9_\\-]+)",
      in: html
    ) {
      return charset.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let content = firstCaptureAlternates(
      "<meta\\b[^>]*http-equiv\\s*=\\s*[\"']content-type[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*/?>"
        + "|<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*http-equiv\\s*=\\s*[\"']content-type[\"'][^>]*/?>",
      in: html
    ) {
      return charsetFromContentType(content)
    }
    return nil
  }

  public static func charsetFromContentType(_ raw: String) -> String? {
    let parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let charsetPart = parts.first(where: { $0.lowercased().hasPrefix("charset=") }) else {
      return nil
    }
    return String(charsetPart.dropFirst("charset=".count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
      .nilIfEmpty
  }

  // MARK: - Helpers

  private static func bodyScore(_ text: String) -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return -1 }
    let length = trimmed.unicodeScalars.count
    let paragraphs = trimmed.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    return length + paragraphs * 40
  }

  private static func plainText(from html: String) -> String {
    var value = html
    value = replacing("<br\\s*/?>", in: value, with: "\n")
    value = replacing("</p>", in: value, with: "\n\n")
    value = replacing("</div>", in: value, with: "\n")
    value = replacing("</h[1-6]>", in: value, with: "\n\n")
    value = replacing("</li>", in: value, with: "\n")
    value = replacing("<[^>]+>", in: value, with: "")
    value = decodeEntities(value)
    return collapseWhitespacePreservingParagraphs(value)
  }

  private static func metaContent(property: String, in html: String) -> String? {
    let pattern =
      "<meta\\b[^>]*property\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*/?>"
      + "|<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*property\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*/?>"
    guard let match = firstCaptureAlternates(pattern, in: html) else { return nil }
    let decoded = decodeEntities(match).trimmingCharacters(in: .whitespacesAndNewlines)
    return decoded.nilIfEmpty.map(collapseWhitespace)
  }

  private static func metaContent(name: String, in html: String) -> String? {
    let pattern =
      "<meta\\b[^>]*name\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*/?>"
      + "|<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*name\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]*/?>"
    guard let match = firstCaptureAlternates(pattern, in: html) else { return nil }
    let decoded = decodeEntities(match).trimmingCharacters(in: .whitespacesAndNewlines)
    return decoded.nilIfEmpty.map(collapseWhitespace)
  }

  private static func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, options: [], range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  /// 两个互斥捕获组（属性顺序不同）取第一个非空。
  private static func firstCaptureAlternates(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, options: [], range: range) else { return nil }
    for index in 1..<match.numberOfRanges {
      guard let captureRange = Range(match.range(at: index), in: text) else { continue }
      let value = String(text[captureRange])
      if !value.isEmpty { return value }
    }
    return nil
  }

  private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }

  private static func decodeEntities(_ value: String) -> String {
    var result = value
    let named: [(String, String)] = [
      ("&nbsp;", " "),
      ("&amp;", "&"),
      ("&lt;", "<"),
      ("&gt;", ">"),
      ("&quot;", "\""),
      ("&#39;", "'"),
      ("&apos;", "'"),
    ]
    for (entity, replacement) in named {
      result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    if let decimal = try? NSRegularExpression(pattern: "&#(\\d+);") {
      let matches = decimal.matches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result)
      )
      for match in matches.reversed() {
        guard let full = Range(match.range, in: result),
              let numRange = Range(match.range(at: 1), in: result),
              let code = UInt32(result[numRange]),
              let scalar = UnicodeScalar(code)
        else { continue }
        result.replaceSubrange(full, with: String(Character(scalar)))
      }
    }
    if let hex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
      let matches = hex.matches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result)
      )
      for match in matches.reversed() {
        guard let full = Range(match.range, in: result),
              let numRange = Range(match.range(at: 1), in: result),
              let code = UInt32(result[numRange], radix: 16),
              let scalar = UnicodeScalar(code)
        else { continue }
        result.replaceSubrange(full, with: String(Character(scalar)))
      }
    }
    return result
  }

  private static func collapseWhitespace(_ value: String) -> String {
    value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func collapseWhitespacePreservingParagraphs(_ value: String) -> String {
    let paragraphs = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
      .map { collapseWhitespace($0) }
    var lines: [String] = []
    var blankPending = false
    for line in paragraphs {
      if line.isEmpty {
        blankPending = !lines.isEmpty
        continue
      }
      if blankPending {
        lines.append("")
        blankPending = false
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
