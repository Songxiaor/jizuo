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
  private let now: @Sendable () -> Date

  public init(fetcher: any WebPageFetcher, now: @escaping @Sendable () -> Date = Date.init) {
    self.fetcher = fetcher
    self.now = now
  }

  public func takesOwnership(of url: URL) -> Bool {
    DouyinURL.matches(url)
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    guard DouyinURL.matches(url) else { throw ManualLinkError.invalidURL }
    let page: WebPageFetchResult
    do {
      page = try await fetcher.fetch(url: url)
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
    let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if joined.isEmpty {
      return "抖音公开视频"
    }
    return joined
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
    let title = firstMatch("\"desc\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: normalized).map(unescapeJSON)
      ?? firstMatch("\"title\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: normalized).map(unescapeJSON)
    let author = firstMatch("\"nickname\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: normalized).map(unescapeJSON)
      ?? firstMatch("\"author\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"", in: normalized).map(unescapeJSON)
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
