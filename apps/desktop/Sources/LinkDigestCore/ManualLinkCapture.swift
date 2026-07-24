import Foundation

public enum ManualLinkError: Error, Sendable, Equatable {
  case invalidURL, unsafeURL, webHostNotAllowed, invalidPageResult, proxyHTTPSRequired, proxyAuthenticationRequired, fakeIPProxyUnavailable, proxyTLSValidation, responseStatus, unsupportedContentType, responseTooLarge, timedOut, emptyContent, loginRequired, verificationRequired, extensionCaptureRequired, githubRepositoryUnavailable, githubRateLimited, cancelled, network

  public var userMessage: String {
    switch self {
    case .invalidURL: "请输入完整的 http 或 https 网页链接。"
    case .unsafeURL: "为保护本机网络，LinkDigest 不能访问这个地址。"
    case .webHostNotAllowed: "内置网页抓取仅允许 https://mp.weixin.qq.com，已停止跳转。"
    case .invalidPageResult: "网页返回的正文格式无效，未保存任何内容。"
    case .proxyHTTPSRequired: "系统代理路径仅支持 HTTPS 网页。请使用浏览器扩展捕获此 HTTP 页面。"
    case .proxyAuthenticationRequired: "当前系统代理需要认证。LinkDigest 不会读取或转交代理凭据，请先在系统代理中完成认证后重试。"
    case .fakeIPProxyUnavailable: "当前代理 DNS 返回了 fake-ip，但系统代理通道未能完成连接。请确认代理/VPN 正在运行，并允许 LinkDigest 使用系统网络后重试。"
    case .proxyTLSValidation: "代理通道已建立，但目标网站的 HTTPS 身份校验未通过。请检查代理证书设置，或改用浏览器扩展。"
    case .responseStatus: "网页暂时无法打开，请检查链接后重试。"
    case .unsupportedContentType: "这个链接返回的不是网页内容。"
    case .responseTooLarge: "网页内容过大，暂不适合直接导入。"
    case .timedOut: "读取网页超时，请稍后重试或使用浏览器扩展。"
    case .emptyContent: "没有提取到可总结的正文，请尝试浏览器扩展。"
    case .loginRequired: "该页面需要已登录的浏览器内容，请使用浏览器扩展。"
    case .verificationRequired: "该页面需要登录或人机验证，请使用浏览器扩展捕获。"
    case .extensionCaptureRequired: "请在浏览器打开后用扩展发送。"
    case .githubRepositoryUnavailable: "仓库不存在或不是公开仓库。"
    case .githubRateLimited: "GitHub 接口暂时限流，请稍后重试。"
    case .cancelled: "已取消读取网页。"
    case .network: "无法读取网页，请检查网络后重试。"
    }
  }
}

/// Signature table for rendered anti-bot / login interstitials. Evaluated only
/// after extraction: neither response bodies nor provider details are retained
/// or exposed when it matches.
///
/// Real WeChat blocks often use compound path segments such as
/// `wappoc_appmsgcaptcha` rather than a bare `/captcha` component, so matching
/// is substring-based on the path plus host-aware rules for mp.weixin.qq.com.
public enum VerificationPagePolicy {
  public static let pathSegments = ["captcha", "verify"]
  public static let pathTokens = ["captcha", "verify", "wappoc"]
  public static let requiredBodyPhrases = ["环境异常", "完成验证后即可继续访问"]
  public static let bodySignals = [
    "环境异常",
    "完成验证后即可继续访问",
    "完成验证",
    "请完成验证",
    "安全验证",
    "去验证",
  ]

  public static func matches(url: URL, extractedText: String) -> Bool {
    let path = url.path.lowercased()
    let host = url.host?.lowercased() ?? ""
    let text = extractedText
    let pathLooksLikeInterstitial = pathContainsInterstitialToken(path)
      || url.pathComponents.contains(where: { component in
        let value = component.lowercased()
        return pathSegments.contains(value) || pathTokens.contains(where: { value.contains($0) })
      })

    if isWeChatHost(host) {
      // Compound captcha/wappoc paths are never article bodies.
      if pathLooksLikeInterstitial { return true }
      // Non-article WeChat shells that already show 环境异常 must not enter History.
      if !isWeChatArticlePath(path), text.contains("环境异常") { return true }
    }

    if pathLooksLikeInterstitial {
      if requiredBodyPhrases.allSatisfy({ text.contains($0) }) { return true }
      // One strong body signal is enough once the URL already looks like a gate.
      if bodySignals.contains(where: { text.contains($0) }) { return true }
    }

    // Legacy exact contract: bare captcha/verify segment + both classic phrases.
    let segments = url.pathComponents.map { $0.lowercased() }
    if segments.contains(where: { pathSegments.contains($0) }),
       requiredBodyPhrases.allSatisfy({ text.contains($0) }) {
      return true
    }
    return false
  }

  private static func pathContainsInterstitialToken(_ path: String) -> Bool {
    pathTokens.contains(where: { path.contains($0) })
  }

  private static func isWeChatHost(_ host: String) -> Bool {
    host == "mp.weixin.qq.com" || host.hasSuffix(".mp.weixin.qq.com")
  }

  /// Public article URLs are typically `/s/<id>` (optional trailing slash/query).
  private static func isWeChatArticlePath(_ path: String) -> Bool {
    path == "/s" || path.hasPrefix("/s/") || path.hasPrefix("/s?")
  }
}

/// X may append a visually animated counter as separate one-digit text nodes.
/// Remove it only from the tail of an X/Twitter document, after DOM extraction,
/// so ordinary numbers in an article and every non-X source remain untouched.
public enum XTrailingCounterNoiseFilter {
  public static let minimumDigitNodes = 6

  public static func removingTrailingCounter(from text: String, sourceURL: URL) -> String {
    guard isX(sourceURL) else { return text }
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    var boundary = tokens.count
    while boundary > 0, tokens[boundary - 1].count == 1,
          tokens[boundary - 1].unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
      boundary -= 1
    }
    guard tokens.count - boundary >= minimumDigitNodes else { return text }
    return tokens[..<boundary].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isX(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com")
  }
}

public struct WebPageFetchResult: Sendable, Equatable {
  public let url: URL
  public let html: String
  public let contentType: String
  public init(url: URL, html: String, contentType: String) { self.url = url; self.html = html; self.contentType = contentType }
}

public protocol WebPageFetcher: Sendable {
  func fetch(url: URL) async throws -> WebPageFetchResult
}

/// A deliberately narrow binary-resource request for source adapters. It is
/// not a general URLSession escape hatch: conformers must retain the same URL
/// admission, peer/TLS and redirect checks as their HTML fetch path.
public struct SafeResourceRequest: Sendable {
  public let url: URL
  public let headers: [String: String]
  public let byteLimit: Int
  /// 默认 GET。少数只读 API（如 X 的 guest token 激活）要求 POST；body 为空即可，
  /// 这类端点不接受请求体，只是把「激活」表达为 POST。
  public let method: String
  public let body: Data?
  public let allowsRedirectTarget: @Sendable (URL) -> Bool

  public init(
    url: URL,
    headers: [String: String] = [:],
    byteLimit: Int,
    method: String = "GET",
    body: Data? = nil,
    allowsRedirectTarget: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) {
    self.url = url
    self.headers = headers
    self.byteLimit = byteLimit
    self.method = method
    self.body = body
    self.allowsRedirectTarget = allowsRedirectTarget
  }
}

public struct SafeResourceResponse: Sendable, Equatable {
  public let url: URL
  public let statusCode: Int
  public let contentType: String?
  public let body: Data

  public init(url: URL, statusCode: Int, contentType: String?, body: Data) {
    self.url = url
    self.statusCode = statusCode
    self.contentType = contentType
    self.body = body
  }
}

public protocol SafeResourceFetching: Sendable {
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse
}

public enum PublicHTMLResponsePolicy {
  public static func validate(statusCode: Int, contentType: String?, expectedLength: Int64?, byteLimit: Int) throws {
    guard (200...299).contains(statusCode) else { throw ManualLinkError.responseStatus }
    let type = contentType?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard type == "text/html" || type == "application/xhtml+xml" else { throw ManualLinkError.unsupportedContentType }
    guard expectedLength ?? 0 <= Int64(byteLimit) else { throw ManualLinkError.responseTooLarge }
  }
}

public protocol HTMLContentExtracting: Sendable {
  func extract(html: String) throws -> ExtractedWebPage
}

public struct ExtractedWebPage: Sendable, Equatable {
  public let title: String?
  public let text: String
  public init(title: String?, text: String) { self.title = title; self.text = text }
}

public struct ManualLinkCaptureService: Sendable {
  private let fetcher: any WebPageFetcher
  private let extractor: any HTMLContentExtracting
  private let sourceAdapters: [any SourceAdapting]
  private let now: @Sendable () -> Date

  public init(fetcher: any WebPageFetcher, extractor: any HTMLContentExtracting = MinimalHTMLExtractor(), sourceAdapters: [any SourceAdapting] = [], now: @escaping @Sendable () -> Date = Date.init) {
    self.fetcher = fetcher; self.extractor = extractor; self.sourceAdapters = sourceAdapters; self.now = now
  }

  public func capture(urlString: String) async throws -> CapturedDocument {
    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased()) else { throw ManualLinkError.invalidURL }
    do {
      if let adapter = sourceAdapters.first(where: { $0.takesOwnership(of: url) }) {
        return try await adapter.capture(url: url)
      }
      let page = try await fetcher.fetch(url: url)
      let extracted = try extractor.extract(html: page.html)
      if VerificationPagePolicy.matches(url: page.url, extractedText: extracted.text) {
        throw ManualLinkError.verificationRequired
      }
      let cleanedText = XTrailingCounterNoiseFilter.removingTrailingCounter(from: extracted.text, sourceURL: page.url)
      let timestamp = ISO8601DateFormatter().string(from: now())
      return .init(
        createdAt: timestamp, idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
        origin: .manualLink, url: page.url.absoluteString, title: extracted.title,
        platform: "manual", method: "public_html", text: cleanedText,
        completeness: "best_effort", capturedAt: timestamp, sourceLabel: "手动链接（公开网页）"
      )
    } catch let error as ManualLinkError { throw error
    } catch is CancellationError { throw ManualLinkError.cancelled }
    catch { throw ManualLinkError.network }
  }
}

public struct MinimalHTMLExtractor: HTMLContentExtracting {
  /// Line-level noise often left after coarse article/main selection.
  public static let boilerplateLineMarkers = [
    "相关阅读", "相关推荐", "推荐阅读", "热门文章", "猜你喜欢", "更多精彩",
    "点击关注", "扫码关注", "分享到", "版权声明", "免责声明", "广告",
    "阅读原文", "在看", "写留言", "精选留言", "打开微信", "关注公众号",
  ]

  public init() {}

  public func extract(html: String) throws -> ExtractedWebPage {
    let title = extractTitle(from: html)
    let selected = firstMatch("id\\s*=\\s*[\"']js_content[\"'][^>]*>([\\s\\S]*?)</div>", in: html)
      ?? firstMatch("id\\s*=\\s*[\"']js_article[\"'][^>]*>([\\s\\S]*?)</div>", in: html)
      ?? firstMatch("itemprop\\s*=\\s*[\"']articleBody[\"'][^>]*>([\\s\\S]*?)</[^>]+>", in: html)
      ?? firstMatch("role\\s*=\\s*[\"']main[\"'][^>]*>([\\s\\S]*?)</[^>]+>", in: html)
      ?? firstMatch("<article\\b[^>]*>([\\s\\S]*?)</article>", in: html)
      ?? firstMatch("<main\\b[^>]*>([\\s\\S]*?)</main>", in: html)
      ?? firstMatch("<body\\b[^>]*>([\\s\\S]*?)</body>", in: html)
      ?? html
    var cleaned = selected
    for tag in ["script", "style", "noscript", "template", "nav", "footer", "header", "aside", "form", "iframe", "svg", "button"] {
      cleaned = replacing("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: cleaned, with: " ")
      cleaned = replacing("<\(tag)\\b[^>]*/?>", in: cleaned, with: " ")
    }
    cleaned = dropHighLinkDensityBlocks(in: cleaned)
    // Structured Markdown: headings, paragraphs, lists — keep CJK punctuation intact.
    var result = markdown(from: cleaned)
    result = stripBoilerplateLines(from: result)
    guard result.unicodeScalars.count >= 20 else { throw ManualLinkError.emptyContent }
    guard result.unicodeScalars.count <= CaptureValidator.maxTextScalars else { throw ManualLinkError.responseTooLarge }
    let lower = result.lowercased()
    if lower.contains("enable javascript") || lower.contains("sign in to continue") || lower.contains("登录后") || lower.contains("请登录") {
      throw ManualLinkError.loginRequired
    }
    return .init(title: title, text: result)
  }

  /// Prefer Open Graph / Twitter title, then `<title>`, then first `h1`.
  public func extractTitle(from html: String) -> String? {
    let candidates: [String?] = [
      metaContent(property: "og:title", in: html),
      metaContent(name: "twitter:title", in: html),
      plainInline(from: firstMatch("<title\\b[^>]*>([\\s\\S]*?)</title>", in: html) ?? "").trimmedNonEmpty,
      plainInline(from: firstMatch("<h1\\b[^>]*>([\\s\\S]*?)</h1>", in: html) ?? "").trimmedNonEmpty,
    ]
    for candidate in candidates {
      guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
      if value.count < 2 { continue }
      return value
    }
    return nil
  }

  // MARK: - HTML → Markdown

  /// Converts a cleaned content fragment into readable Markdown.
  /// Preserves Chinese punctuation (。！？，、；：…—) and paragraph breaks.
  public func markdown(from html: String) -> String {
    var value = html

    // 微信 code-snippet 的行号栏是 chrome，不是内容；必须在列表转换前丢弃。
    value = replacing("<ul\\b[^>]*code-snippet__line-index[^>]*>[\\s\\S]*?</ul>", in: value, with: "")

    // 代码块必须先整体摘出并用占位符保护：后续的标签重写、实体解码与
    // 空白归一化都会破坏代码的换行与缩进。
    var codeBlocks: [String] = []
    value = extractFencedCodeBlocks(from: value, into: &codeBlocks)

    // Blockquotes first (may nest paragraphs).
    value = replacing("<blockquote\\b[^>]*>([\\s\\S]*?)</blockquote>", in: value, with: "\n\n«BLOCKQUOTE»$1«/BLOCKQUOTE»\n\n")

    // Headings → ATX Markdown.
    for level in 1...6 {
      let marks = String(repeating: "#", count: level)
      value = replacing("<h\(level)\\b[^>]*>([\\s\\S]*?)</h\(level)>", in: value, with: "\n\n\(marks) «H»$1«/H»\n\n")
    }

    // Lists: mark items, then wrap.
    value = replacing("<li\\b[^>]*>([\\s\\S]*?)</li>", in: value, with: "\n- «LI»$1«/LI»")
    value = replacing("</?(ul|ol)\\b[^>]*>", in: value, with: "\n\n")

    // Paragraphs and breaks.
    value = replacing("<br\\s*/?>", in: value, with: "\n")
    value = replacing("<p\\b[^>]*>([\\s\\S]*?)</p>", in: value, with: "\n\n«P»$1«/P»\n\n")
    value = replacing("</?(div|section|article|figure|figcaption|tr|td|th|table|tbody|thead)\\b[^>]*>", in: value, with: "\n")

    // Inline emphasis (after blocks so markers stay inside paragraphs).
    value = replacing("<(strong|b)\\b[^>]*>([\\s\\S]*?)</\\1>", in: value, with: "**$2**")
    value = replacing("<(em|i)\\b[^>]*>([\\s\\S]*?)</\\1>", in: value, with: "*$2*")
    value = replacing("<code\\b[^>]*>([\\s\\S]*?)</code>", in: value, with: "`$1`")

    // Links: keep visible text only (URL stays on the detail header / 打开).
    value = replacing("<a\\b[^>]*>([\\s\\S]*?)</a>", in: value, with: "$1")
    // Images: keep alt text if present.
    value = replacing("<img\\b[^>]*\\balt\\s*=\\s*[\"']([^\"']*)[\"'][^>]*/?>", in: value, with: "$1")
    value = replacing("<img\\b[^>]*/?>", in: value, with: "")

    // Drop remaining tags without touching text or punctuation.
    value = replacing("<[^>]+>", in: value, with: "")
    value = decodeEntities(value)

    // Resolve structural placeholders after entity decode.
    value = value
      .replacingOccurrences(of: "«H»", with: "")
      .replacingOccurrences(of: "«/H»", with: "")
      .replacingOccurrences(of: "«P»", with: "")
      .replacingOccurrences(of: "«/P»", with: "")
      .replacingOccurrences(of: "«LI»", with: "")
      .replacingOccurrences(of: "«/LI»", with: "")

    // Blockquotes: expand marker pairs so every non-empty inner line is prefixed with "> ".
    value = expandBlockquotes(in: value)

    var result = normalizeMarkdownWhitespace(value)
    // 归一化完成后再还原代码块，换行与缩进因此原样保留。
    for (index, block) in codeBlocks.enumerated() {
      result = result.replacingOccurrences(of: codeBlockPlaceholder(index), with: block)
    }
    return result
  }

  private func codeBlockPlaceholder(_ index: Int) -> String { "«CODEBLOCK\(index)»" }

  /// 把每个 `<pre>` 转成 fenced code 并以占位符顶替。微信 code-snippet 每行
  /// 一个 `<code>`，按行拼接还原换行；普通 `<pre>` 直接保留自身文本换行。
  private func extractFencedCodeBlocks(from html: String, into codeBlocks: inout [String]) -> String {
    guard let preExpression = try? NSRegularExpression(pattern: "<pre\\b[^>]*>([\\s\\S]*?)</pre>", options: []),
          let codeExpression = try? NSRegularExpression(pattern: "<code\\b[^>]*>([\\s\\S]*?)</code>", options: [])
    else { return html }

    var result = html
    let matches = preExpression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
    for match in matches {
      guard match.numberOfRanges > 1,
            let full = Range(match.range, in: result),
            let innerRange = Range(match.range(at: 1), in: result)
      else { continue }
      let inner = String(result[innerRange])

      let codeMatches = codeExpression.matches(in: inner, range: NSRange(inner.startIndex..., in: inner))
      let rawText: String
      if codeMatches.count > 1 {
        rawText = codeMatches.compactMap { codeMatch -> String? in
          guard codeMatch.numberOfRanges > 1, let lineRange = Range(codeMatch.range(at: 1), in: inner) else { return nil }
          return codeText(String(inner[lineRange])).replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
      } else {
        rawText = codeText(inner)
      }
      let trimmed = rawText
        .replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
      guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        result.replaceSubrange(full, with: "\n")
        continue
      }
      let longestBacktickRun = trimmed
        .components(separatedBy: "\n")
        .flatMap { line in line.matches(of: /`+/).map { line[$0.range].count } }
        .max() ?? 0
      let fence = String(repeating: "`", count: max(3, longestBacktickRun + 1))
      codeBlocks.append("\(fence)\n\(trimmed)\n\(fence)")
      result.replaceSubrange(full, with: "\n\n\(codeBlockPlaceholder(codeBlocks.count - 1))\n\n")
    }
    return result
  }

  /// `<pre>` 内文本：`<br>` 还原为换行，去掉其余标签后解码实体；
  /// 不做任何空白折叠，代码的缩进由调用方整体保护。
  private func codeText(_ fragment: String) -> String {
    var value = fragment
    value = replacing("<br\\s*/?>", in: value, with: "\n")
    value = replacing("<[^>]+>", in: value, with: "")
    return decodeEntities(value)
  }

  private func expandBlockquotes(in value: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: "«BLOCKQUOTE»([\\s\\S]*?)«/BLOCKQUOTE»",
      options: []
    ) else { return value }
    let ns = value as NSString
    var result = value
    let matches = expression.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed()
    for match in matches {
      guard match.numberOfRanges > 1,
            let full = Range(match.range, in: result),
            let innerRange = Range(match.range(at: 1), in: result)
      else { continue }
      let inner = String(result[innerRange])
      let quoted = inner
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { line -> String in
          if line.hasPrefix("> ") { return line }
          return "> " + line
        }
        .joined(separator: "\n")
      result.replaceSubrange(full, with: "\n\n" + quoted + "\n\n")
    }
    return result
  }

  /// Plain inline text for titles — no Markdown markers, keep punctuation.
  public func plainInline(from html: String) -> String {
    var value = html
    value = replacing("<br\\s*/?>", in: value, with: " ")
    value = replacing("<[^>]+>", in: value, with: "")
    value = decodeEntities(value)
    return value
      .replacingOccurrences(of: "[\\t\\u00A0]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeMarkdownWhitespace(_ value: String) -> String {
    // Fenced code lines keep their leading indentation and internal spacing;
    // trimming them destroys captured code.
    var inFence = false
    var lines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { line -> String in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          inFence.toggle()
          return line.trimmingCharacters(in: .whitespaces)
        }
        if inFence {
          return line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        }
        // Collapse horizontal whitespace only; never strip CJK punctuation.
        var result = line.replacingOccurrences(of: "[\\t\\u00A0]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        // Soft-trim edges of each line, but keep leading "> " / "- " / "# ".
        if result.hasPrefix("> ") || result.hasPrefix("- ") || result.hasPrefix("#") {
          return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t").union(.controlCharacters).subtracting(CharacterSet(charactersIn: "\n")))
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
      }

    // Drop empty lines at ends; collapse 3+ blank lines to one paragraph gap.
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }

    var compacted: [String] = []
    var blankRun = 0
    for line in lines {
      if line.isEmpty {
        blankRun += 1
        if blankRun <= 1 { compacted.append("") }
      } else {
        blankRun = 0
        compacted.append(line)
      }
    }

    // Ensure a blank line between consecutive non-list body paragraphs when missing
    // (e.g. "…。下一句" still stays one line — only structural blanks from HTML).
    return compacted.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func metaContent(property: String, in html: String) -> String? {
    let pattern = "<meta\\b[^>]*property\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>|<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*property\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*>"
    return metaCapture(pattern, in: html)
  }

  private func metaContent(name: String, in html: String) -> String? {
    let pattern = "<meta\\b[^>]*name\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>|<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*name\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]*>"
    return metaCapture(pattern, in: html)
  }

  private func metaCapture(_ pattern: String, in html: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    guard let match = expression.firstMatch(in: html, range: range) else { return nil }
    for index in 1..<match.numberOfRanges {
      guard let capture = Range(match.range(at: index), in: html) else { continue }
      let value = plainInline(from: String(html[capture])).trimmedNonEmpty
      if let value { return value }
    }
    return nil
  }

  private func dropHighLinkDensityBlocks(in html: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: "<(ul|ol|div|section)\\b[^>]*>([\\s\\S]*?)</\\1>",
      options: [.caseInsensitive]
    ) else { return html }
    let ns = html as NSString
    var result = html
    let matches = expression.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed()
    for match in matches {
      guard match.numberOfRanges > 2 else { continue }
      let inner = ns.substring(with: match.range(at: 2))
      let plain = plainInline(from: inner)
      guard plain.unicodeScalars.count >= 40 else { continue }
      let linkCount = (try? NSRegularExpression(pattern: "<a\\b", options: [.caseInsensitive]))
        .map { $0.numberOfMatches(in: inner, range: NSRange(inner.startIndex..., in: inner)) } ?? 0
      guard linkCount >= 3 else { continue }
      let linkTextLength = plainInline(from: replacing("<a\\b[^>]*>([\\s\\S]*?)</a>", in: inner, with: "$1")).unicodeScalars.count
      if Double(linkTextLength) >= Double(plain.unicodeScalars.count) * 0.55 {
        if let full = Range(match.range, in: result) {
          result.replaceSubrange(full, with: "\n")
        }
      }
    }
    return result
  }

  private func stripBoilerplateLines(from text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    var inFence = false
    let kept = lines.filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      // Code lines are content verbatim — never boilerplate.
      if trimmed.hasPrefix("```") { inFence.toggle(); return true }
      if inFence { return true }
      if trimmed.isEmpty { return true }
      // Keep structural Markdown lines.
      if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("> ") { return true }
      if trimmed.unicodeScalars.count <= 24,
         Self.boilerplateLineMarkers.contains(where: { trimmed.contains($0) }) {
        return false
      }
      return true
    }
    return normalizeMarkdownWhitespace(kept.joined(separator: "\n"))
  }

  private func firstMatch(_ pattern: String, in value: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(value.startIndex..., in: value)
    guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1,
          let resultRange = Range(match.range(at: 1), in: value) else { return nil }
    return String(value[resultRange])
  }

  private func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
    return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
  }

  private func decodeEntities(_ value: String) -> String {
    // Named entities — include common Chinese-page entities; never drop 。！？ etc.
    let named = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
      "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
      "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’",
    ]
    var result = named.reduce(value) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    guard let expression = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") else { return result }
    let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
    for match in matches {
      guard let range = Range(match.range(at: 1), in: result) else { continue }
      let raw = String(result[range])
      let radix = raw.hasPrefix("x") || raw.hasPrefix("X") ? 16 : 10
      let digits = (raw.hasPrefix("x") || raw.hasPrefix("X")) ? String(raw.dropFirst()) : raw
      guard let scalarValue = UInt32(digits, radix: radix),
            let scalar = UnicodeScalar(scalarValue),
            let full = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(full, with: String(Character(scalar)))
    }
    return result
  }
}

private extension String { var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
