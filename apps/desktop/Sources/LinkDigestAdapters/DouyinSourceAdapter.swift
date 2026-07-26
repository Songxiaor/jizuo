import Foundation
import LinkDigestCore

/// Douyin (抖音) public-page adapter for the manual-link entry.
///
/// - Takes ownership of douyin / iesdouyin / v.douyin short hosts.
/// - Fetches the public HTML (redirects allowed via the existing fetcher).
/// - Parses SSR JSON / `<video>` sources for a playable HTTPS URL.
/// - Does **not** reverse signatures, read browser cookies, or retry risk-control walls.
/// - On captcha / empty SSR, surfaces a fixed guide to use the browser extension.
public final class DouyinSourceAdapter: SourceAdapting, @unchecked Sendable {
  private let fetcher: any WebPageFetcher
  private let sessionFetcher: SessionAwareHTMLFetcher?
  private let now: @Sendable () -> Date

  public init(fetcher: any WebPageFetcher, now: @escaping @Sendable () -> Date = Date.init) {
    self.fetcher = fetcher
    self.sessionFetcher = nil
    self.now = now
  }

  /// 带 App 自有会话的构造：用户在设置里登录过抖音时，抓取会带上那份 Cookie，
  /// 于是能拿到未登录看不到的正文。没登录时 `SessionAwareHTMLFetcher` 原样退回
  /// 无 Cookie 路径，行为与旧构造完全一致。
  public init(
    fetcher: any WebPageFetcher,
    resources: any SafeResourceFetching,
    cookieHeader: @escaping @Sendable () async -> String?,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.fetcher = fetcher
    self.sessionFetcher = SessionAwareHTMLFetcher(
      plain: fetcher,
      resources: resources,
      cookieHeader: cookieHeader,
      // Cookie 绝不能跟着跳到站外，所以带会话的请求把跳转收窄到抖音自己的域。
      allowsRedirectTarget: { DouyinURL.matchesSessionHost($0) },
      referer: "https://www.douyin.com/"
    )
    self.now = now
  }

  public func takesOwnership(of url: URL) -> Bool {
    DouyinURL.matches(url)
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    guard DouyinURL.matches(url) else { throw ManualLinkError.invalidURL }
    let page: WebPageFetchResult
    do {
      // `??` 的右侧是 autoclosure，装不下 async 调用，只能显式分支。
      if let sessionFetcher {
        page = try await sessionFetcher.fetch(url: url)
      } else {
        page = try await fetcher.fetch(url: url)
      }
    } catch let error as ManualLinkError {
      throw error
    } catch is CancellationError {
      throw ManualLinkError.cancelled
    } catch {
      throw ManualLinkError.network
    }

    if DouyinPageParser.looksLikeRiskControl(html: page.html, url: page.url) {
      throw ManualLinkError.extensionCaptureRequired
    }

    guard let parsed = DouyinPageParser.parse(html: page.html, pageURL: page.url) else {
      throw ManualLinkError.extensionCaptureRequired
    }

    let timestamp = ISO8601DateFormatter().string(from: now())
    let text = DouyinPageParser.documentText(title: parsed.title, author: parsed.author, description: parsed.description)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ManualLinkError.extensionCaptureRequired
    }

    let storedURL = DouyinURL.canonicalVideoURL(from: page.url)?.absoluteString
      ?? parsed.canonicalURL?.absoluteString
      ?? page.url.absoluteString
    return CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: storedURL,
      title: parsed.title,
      platform: "douyin",
      method: "douyin_public_html",
      text: text,
      completeness: "best_effort",
      capturedAt: timestamp,
      sourceLabel: "手动链接（抖音公开视频）",
      media: CaptureMedia(
        platform: "douyin",
        videoURL: parsed.videoURL.absoluteString,
        coverURL: parsed.coverURL?.absoluteString,
        durationSeconds: parsed.durationSeconds,
        author: parsed.author
      )
    )
  }
}

public enum DouyinURL {
  public static func matches(_ url: URL) -> Bool {
    guard let host = PublicWebURLPolicy.normalizedHost(url.host ?? ""),
          ["http", "https"].contains(url.scheme?.lowercased())
    else { return false }
    if host == "v.douyin.com" || host.hasPrefix("v.") && host.hasSuffix("douyin.com") { return true }
    if host == "douyin.com" || host.hasSuffix(".douyin.com") { return true }
    if host == "iesdouyin.com" || host.hasSuffix(".iesdouyin.com") { return true }
    return false
  }

  /// 带会话的请求允许跳到哪些 host。
  ///
  /// 比 `matches` 严：`matches` 决定「这条链接归抖音适配器管」，可以宽松；
  /// 这个决定「Cookie 能跟着跳到哪」，宽一格就等于把用户的登录态送去别的域。
  /// 短链 `v.douyin.com` 会 302 到主站，所以两者都要在内。
  public static func matchesSessionHost(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = PublicWebURLPolicy.normalizedHost(url.host ?? "")
    else { return false }
    let allowed = ["douyin.com", "iesdouyin.com"]
    return allowed.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  /// Concrete video id from path `/video/{id}` or query `modal_id` / `aweme_id`
  /// (Feed overlay). Empty when the URL is only a bare host/feed shell.
  public static func awemeID(from url: URL) -> String? {
    let path = url.path
    if let match = path.range(of: #"/(?:video|note|share/video)/(\d{8,25})(?:/|$)"#, options: .regularExpression) {
      let slice = path[match]
      if let digits = slice.range(of: #"\d{8,25}"#, options: .regularExpression) {
        return String(slice[digits])
      }
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    for key in ["modal_id", "aweme_id", "item_id", "video_id", "group_id"] {
      if let value = components.queryItems?.first(where: { $0.name == key })?.value,
         value.range(of: #"^\d{8,25}$"#, options: .regularExpression) != nil {
        return value
      }
    }
    return nil
  }

  public static func canonicalVideoURL(from url: URL) -> URL? {
    guard let id = awemeID(from: url) else { return nil }
    return URL(string: "https://www.douyin.com/video/\(id)")
  }
}

public struct DouyinParsedPage: Sendable, Equatable {
  public let videoURL: URL
  public let coverURL: URL?
  public let title: String?
  public let author: String?
  public let description: String?
  public let durationSeconds: Double?
  public let canonicalURL: URL?
}

public enum DouyinPageParser {
  public static let riskControlMarkers = [
    "验证码",
    "请完成安全验证",
    "滑动验证",
    "异常访问",
    "网络繁忙",
    "login",
    "passport",
    "byted_acrawler",
    "__ac_signature",
    "__ac_nonce",
  ]

  public static func looksLikeRiskControl(html: String, url: URL) -> Bool {
    let path = url.path.lowercased()
    if path.contains("captcha") || path.contains("verify") || path.contains("passport") {
      return true
    }
    let lower = html.lowercased()
    // ByteDance anti-bot shell: empty body + acrawler cookie/sign reload.
    if lower.contains("byted_acrawler") || lower.contains("__ac_signature") || lower.contains("__ac_nonce") {
      return true
    }
    // Extremely short shells with challenge wording — not a video document.
    if html.unicodeScalars.count < 800 {
      return riskControlMarkers.contains { lower.contains($0.lowercased()) }
    }
    if lower.contains("请完成安全验证") || lower.contains("滑动验证") {
      return true
    }
    // Empty body with only obfuscated scripts is not a public video document.
    if !lower.contains("<video") && !lower.contains("play_addr") && !lower.contains("playaddr")
      && !lower.contains("render_data") && !lower.contains("_router_data") {
      if lower.contains("window.location.reload") && lower.contains("document.cookie") {
        return true
      }
    }
    return false
  }

  public static func parse(html: String, pageURL: URL) -> DouyinParsedPage? {
    if let fromSSR = parseSSR(html: html, pageURL: pageURL) { return fromSSR }
    if let fromVideo = parseVideoTag(html: html, pageURL: pageURL) { return fromVideo }
    return nil
  }

  public static func documentText(title: String?, author: String?, description: String?) -> String {
    var lines: [String] = ["---"]
    if let author, !author.isEmpty { lines.append("author: \(jsonString(author))") }
    if lines.count > 1 {
      lines.append("---")
      lines.append("")
    } else {
      lines = []
    }
    if let title, !title.isEmpty { lines.append("# \(title)") }
    if let description, !description.isEmpty {
      if !lines.isEmpty { lines.append("") }
      lines.append(description)
    }
    // 全空时返回空串，不再兜底成「抖音公开视频」。
    //
    // 那个兜底会让调用方的 `guard !text.isEmpty` 永远拦不住：什么都没抓到时照样
    // 入库一条只有占位文字的记录。2026-07-27 真机实测就是这样——锚定挡住了假
    // 元数据之后，仍然存下一条无标题无正文的空壳。抓不到就该走「请用扩展」，
    // 让人知道下一步做什么。
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Internals

  private static func parseVideoTag(html: String, pageURL: URL) -> DouyinParsedPage? {
    guard let src = firstMatch(
      "<video\\b[^>]*\\b(?:src|data-src)\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      in: html
    ) ?? firstMatch(
      "<source\\b[^>]*\\bsrc\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      in: html
    ) else { return nil }
    guard let videoURL = absoluteHTTPS(src, base: pageURL) else { return nil }
    let cover = metaContent(property: "og:image", in: html).flatMap { absoluteHTTPS($0, base: pageURL) }
    let title = metaContent(property: "og:title", in: html)
      ?? firstMatch("<title\\b[^>]*>([\\s\\S]*?)</title>", in: html).map(stripTags)
    let author = metaContent(name: "author", in: html)
    let description = metaContent(property: "og:description", in: html)
      ?? metaContent(name: "description", in: html)
    return DouyinParsedPage(
      videoURL: videoURL,
      coverURL: cover,
      title: title?.trimmedNonEmpty,
      author: author?.trimmedNonEmpty,
      description: description?.trimmedNonEmpty,
      durationSeconds: nil,
      canonicalURL: pageURL
    )
  }

  private static func parseSSR(html: String, pageURL: URL) -> DouyinParsedPage? {
    var blobs: [String] = []
    if let render = firstMatch(
      "id\\s*=\\s*[\\\"']RENDER_DATA[\\\"'][^>]*>([\\s\\S]*?)</script>",
      in: html
    ) {
      blobs.append(decodeURIComponent(render.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    if let router = firstMatch(
      "window\\._ROUTER_DATA\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*;?\\s*</script>",
      in: html
    ) {
      blobs.append(router)
    }
    if let ssr = firstMatch(
      "window\\._SSR_HYDRATED_DATA\\s*=\\s*(\\{[\\s\\S]*?\\})\\s*;?\\s*</script>",
      in: html
    ) {
      blobs.append(ssr)
    }
    // Also scan large inline script JSON islands for play addresses.
    if blobs.isEmpty {
      let matches = allMatches("\"play_addr\"\\s*:\\s*\\{[^\\}]{0,4000}\\}", in: html)
      blobs.append(contentsOf: matches)
      blobs.append(contentsOf: allMatches("\"playAddr\"\\s*:\\s*\\{[^\\}]{0,4000}\\}", in: html))
    }

    for blob in blobs {
      if let parsed = extractFromJSONBlob(blob, pageURL: pageURL) { return parsed }
    }

    // Fallback: any https URL that looks like a Douyin CDN video object.
    if let raw = firstMatch(
      "https://[^\\\"'\\s]+\\.(?:mp4|m3u8)[^\\\"'\\s]*",
      in: html
    ), let videoURL = URL(string: raw.replacingOccurrences(of: "\\u002F", with: "/")),
       videoURL.scheme?.lowercased() == "https",
       !raw.contains(".m3u8") {
      let cover = metaContent(property: "og:image", in: html).flatMap { absoluteHTTPS($0, base: pageURL) }
      let title = metaContent(property: "og:title", in: html)
      return DouyinParsedPage(
        videoURL: videoURL,
        coverURL: cover,
        title: title?.trimmedNonEmpty,
        author: nil,
        description: metaContent(property: "og:description", in: html)?.trimmedNonEmpty,
        durationSeconds: nil,
        canonicalURL: pageURL
      )
    }
    return nil
  }

  private static func extractFromJSONBlob(_ blob: String, pageURL: URL) -> DouyinParsedPage? {
    let normalized = blob
      .replacingOccurrences(of: "\\u002F", with: "/")
      .replacingOccurrences(of: "\\/", with: "/")
    // Prefer url_list / urlList entries that end with mp4 or contain mime_type video.
    let listPatterns = [
      "\"url_list\"\\s*:\\s*\\[\\s*\"(https:[^\"]+)\"",
      "\"urlList\"\\s*:\\s*\\[\\s*\"(https:[^\"]+)\"",
      "\"src\"\\s*:\\s*\"(https:[^\"]+\\.mp4[^\"]*)\"",
      "\"playApi\"\\s*:\\s*\"(https:[^\"]+)\"",
      "\"play_addr\"\\s*:\\s*\"(https:[^\"]+)\"",
    ]
    var videoURL: URL?
    for pattern in listPatterns {
      guard let raw = firstMatch(pattern, in: normalized),
            let url = URL(string: raw),
            url.scheme?.lowercased() == "https",
            !raw.contains(".m3u8")
      else { continue }
      videoURL = url
      break
    }
    guard let videoURL else { return nil }

    let coverRaw = firstMatch("\"cover\"\\s*:\\s*\\{[^\\}]*\"url_list\"\\s*:\\s*\\[\\s*\"(https:[^\"]+)\"", in: normalized)
      ?? firstMatch("\"origin_cover\"\\s*:\\s*\\{[^\\}]*\"url_list\"\\s*:\\s*\\[\\s*\"(https:[^\"]+)\"", in: normalized)
      ?? firstMatch("\"coverUrl\"\\s*:\\s*\"(https:[^\"]+)\"", in: normalized)
    let coverURL = coverRaw.flatMap { URL(string: $0) }
    // 锚定到这条视频的 id 附近再取。
    //
    // 页面外壳里到处都是 `"desc"` / `"nickname"`：推荐流的作者、按钮文案、当前
    // 登录用户的资料。不锚定就会抓到它们——2026-07-27 真机实测抓到过标题
    // 「PC Tab」（一个按钮的文案）和推荐位博主的昵称。两个都长得像真数据，
    // 存进库谁也看不出错，这比抓不到严重得多。
    //
    // 先在 id 周围的窗口里找；找不到就返回 nil，让调用方回落到「请用扩展」。
    // 宁可诚实失败，也不产出一条看不出错的假记录。
    let scoped = DouyinURL.awemeID(from: pageURL).flatMap { windowAround(id: $0, in: normalized) }
    let title = scoped.flatMap {
      firstNonEmptyMatch("\"desc\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: $0).map(unescapeJSON)
    }
    let author = scoped.flatMap {
      firstNonEmptyMatch("\"nickname\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: $0).map(unescapeJSON)
    }
    let duration: Double?
    if let ms = firstMatch("\"duration\"\\s*:\\s*(\\d+)", in: normalized), let value = Double(ms) {
      // Douyin duration is often milliseconds when > 1000.
      duration = value > 1000 ? value / 1000.0 : value
    } else {
      duration = nil
    }
    return DouyinParsedPage(
      videoURL: videoURL,
      coverURL: coverURL,
      title: title?.trimmedNonEmpty,
      author: author?.trimmedNonEmpty,
      description: title?.trimmedNonEmpty,
      durationSeconds: duration,
      canonicalURL: pageURL
    )
  }

  private static func absoluteHTTPS(_ raw: String, base: URL) -> URL? {
    let cleaned = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\u002F", with: "/")
      .replacingOccurrences(of: "\\/", with: "/")
    if cleaned.hasPrefix("//"), let url = URL(string: "https:\(cleaned)") { return url }
    if let url = URL(string: cleaned), url.scheme?.lowercased() == "https" { return url }
    if let url = URL(string: cleaned, relativeTo: base)?.absoluteURL, url.scheme?.lowercased() == "https" {
      return url
    }
    return nil
  }

  private static func metaContent(property: String, in html: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: property)
    return firstMatch(
      "<meta\\b[^>]*property\\s*=\\s*[\\\"']\(escaped)[\\\"'][^>]*content\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      in: html
    ) ?? firstMatch(
      "<meta\\b[^>]*content\\s*=\\s*[\\\"']([^\\\"']+)[\\\"'][^>]*property\\s*=\\s*[\\\"']\(escaped)[\\\"']",
      in: html
    )
  }

  private static func metaContent(name: String, in html: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    return firstMatch(
      "<meta\\b[^>]*name\\s*=\\s*[\\\"']\(escaped)[\\\"'][^>]*content\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      in: html
    )
  }

  private static func firstMatch(_ pattern: String, in value: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(value.startIndex..., in: value)
    guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1,
          let capture = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[capture])
  }

  /// 首个**非空**捕获。
  ///
  /// SSR JSON 是个几百 KB 的大 blob，`"desc"` / `"nickname"` 这种通用键会在很多
  /// 不相关的对象里出现。`firstMatch` 取到的第一个常常是 `"desc":""`——于是标题
  /// 变成空串，入库一条「无标题」记录，而抓取本身报成功。2026-07-27 真机实测就是
  /// 这个现象：作者拿到了（`nickname` 恰好第一个就有值），标题没拿到。
  /// 视频 id 周围的一段文本。
  ///
  /// SSR blob 里同名键遍地都是，只有挨着这条视频 id 的那批才属于它。窗口取
  /// ±6000 字符：抖音的 aweme 对象实测在几千字量级，太窄会漏掉同一对象里的
  /// 字段，太宽就退化成全文搜索、又抓到邻居的数据。id 出现多次时取第一次——
  /// 第一次通常是详情对象，后面的是「相关推荐」里的回指。
  private static func windowAround(id: String, in value: String, radius: Int = 6_000) -> String? {
    guard let hit = value.range(of: id) else { return nil }
    let lower = value.index(hit.lowerBound, offsetBy: -radius, limitedBy: value.startIndex) ?? value.startIndex
    let upper = value.index(hit.upperBound, offsetBy: radius, limitedBy: value.endIndex) ?? value.endIndex
    return String(value[lower..<upper])
  }

  /// 注意不能借用 `allMatches`：那个函数返回的是**整段匹配**（含键名和引号），
  /// 是它既有调用方依赖的语义。这里要的是捕获组 1。
  private static func firstNonEmptyMatch(_ pattern: String, in value: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(value.startIndex..., in: value)
    for match in expression.matches(in: value, range: range) {
      guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: value) else { continue }
      let text = String(value[capture])
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
    }
    return nil
  }

  private static func allMatches(_ pattern: String, in value: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let full = Range(match.range, in: value) else { return nil }
      return String(value[full])
    }
  }

  private static func decodeURIComponent(_ value: String) -> String {
    var result = value
    // Percent-decoding may need multiple passes for nested encoding.
    for _ in 0..<2 {
      if let decoded = result.removingPercentEncoding, decoded != result {
        result = decoded
      } else {
        break
      }
    }
    return result
  }

  private static func unescapeJSON(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\r", with: "\r")
      .replacingOccurrences(of: "\\t", with: "\t")
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }

  private static func stripTags(_ value: String) -> String {
    value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
