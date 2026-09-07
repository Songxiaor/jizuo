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
    let text = DouyinPageParser.documentText(
      title: parsed.title,
      author: parsed.author,
      description: parsed.description,
      coverURL: parsed.coverURL?.absoluteString
    )
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ManualLinkError.extensionCaptureRequired
    }

    let storedURL = DouyinURL.canonicalItemURL(from: page.url)?.absoluteString
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
    // 后缀匹配必须带点。`hasSuffix("douyin.com")` 会把 `v.evil-douyin.com` 判成
    // 自己人——它同时满足 `hasPrefix("v.")`。认领本身只是路由，但登录抖音之后
    // 这条路径会带着会话 Cookie 去抓，等于把登录态发给攻击者控制的主机。
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
    if let match = path.range(of: #"/(?:video|note|share/video|share/note)/(\d{8,25})(?:/|$)"#, options: .regularExpression) {
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

  public static func isNotePath(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    return path.contains("/share/note/") || path.contains("/note/")
  }

  /// WebKit 抓取入口。有 aweme id 时落到桌面 `/note/{id}` 或 `/video/{id}`，
  /// 让设置里的抖音登录会话去水合正文；短链还没有 id，保持原地址跟着 302 走。
  ///
  /// 不要改写成 `iesdouyin.com/share/note`。那条移动分享页不带 App 登录态，
  /// 公开 HTML 里也没有正片图；再配手机 UA，已登录 Cookie 还会被站点判失效。
  public static func renderedCaptureURL(from url: URL) -> URL {
    canonicalItemURL(from: url) ?? url
  }

  /// 落地路径是图文就收成 `/note/{id}`，否则收成 `/video/{id}`。
  /// 识别靠路径，不靠分享文案里的「图文作品」——抽 URL 之后那段字就没了。
  public static func canonicalItemURL(from url: URL) -> URL? {
    guard let id = awemeID(from: url) else { return nil }
    if isNotePath(url) {
      return URL(string: "https://www.douyin.com/note/\(id)")
    }
    return URL(string: "https://www.douyin.com/video/\(id)")
  }

  public static func canonicalVideoURL(from url: URL) -> URL? {
    canonicalItemURL(from: url)
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

/// 抖音 JSON / DOM 里到处是 `url_list`：封面、头像、推荐位都用它。
/// 播放地址必须是可交给 AVPlayer 的 HTTPS 视频，不能把图片或条目页当成视频。
public enum DouyinPlayableURL {
  public static func isPlayable(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          !host.isEmpty
    else { return false }
    let absolute = url.absoluteString.lowercased()
    let path = url.path.lowercased()
    if absolute.contains(".m3u8") { return false }
    if isImageURL(url) { return false }
    if host == "douyinpic.com" || host.hasSuffix(".douyinpic.com") { return false }
    if absolute.contains("avatar") || absolute.contains("/aweme/100x100/") { return false }
    if path.range(of: #"/(?:video|note)/\d{8,25}(?:/|$)"#, options: .regularExpression) != nil {
      return false
    }
    return true
  }

  public static func isImageURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let absolute = url.absoluteString.lowercased()
    for ext in [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".heic"] {
      if path.hasSuffix(ext) || absolute.contains("\(ext)?") || absolute.contains("\(ext)&") {
        return true
      }
    }
    return false
  }

  /// `play_addr` 优先于页面 `<video src>`：后者经常是 blob、封面或条目页。
  public static func select(primary: URL?, secondary: URL?) -> URL? {
    if let primary, isPlayable(primary) { return primary }
    if let secondary, isPlayable(secondary) { return secondary }
    return nil
  }
}

public enum DouyinPageParser {
  static let maximumStateSnippetScalars = 240_000

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

  /// Parses a bounded window copied from the rendered page's own state when
  /// the visible `<video>` uses a blob/MSE URL. Field extraction remains
  /// anchored to the aweme id in `pageURL`.
  static func parseStateSnippet(_ snippet: String, pageURL: URL) -> DouyinParsedPage? {
    guard snippet.unicodeScalars.count <= maximumStateSnippetScalars else { return nil }
    return extractFromJSONBlob(snippet, pageURL: pageURL)
  }

  /// 本条 aweme 的播放地址：只认身份匹配对象上的明确播放字段。
  /// 与 `parseAnchoredCoverURL` 同一套完整 JSON / 不完整外壳扫描；
  /// 目标只有封面时不得借邻居 `play_addr`，字段在 ±6000 窗外仍属于本条。
  private static func ownedAwemeObject(in snippet: String, awemeID: String) -> [String: Any]? {
    func identity(_ object: [String: Any]) -> Bool {
      (object["aweme_id"] as? String ?? object["awemeId"] as? String) == awemeID
    }
    func search(_ value: Any, depth: Int = 0) -> [String: Any]? {
      guard depth < 64 else { return nil }
      if let object = value as? [String: Any] {
        if identity(object) { return object }
        for child in object.values {
          if let found = search(child, depth: depth + 1) { return found }
        }
      } else if let array = value as? [Any] {
        for child in array {
          if let found = search(child, depth: depth + 1) { return found }
        }
      }
      return nil
    }
    if let root = try? JSONSerialization.jsonObject(with: Data(snippet.utf8)) {
      return search(root)
    }
    let bytes = Array(snippet.utf8)
    var starts: [Int] = []
    var quoted = false
    var escaped = false
    for (index, byte) in bytes.enumerated() {
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
        continue
      }
      if byte == 34 { quoted = true; continue }
      if byte == 123 { starts.append(index) }
      if byte == 125, let start = starts.popLast() {
        let data = Data(bytes[start...index])
        guard let text = String(data: data, encoding: .utf8),
              text.contains(awemeID),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              identity(object)
        else { continue }
        return object
      }
    }
    return nil
  }

  /// 只读 `play_addr` / `playAddr` / `download_addr` / `playApi` / `.mp4` src。
  /// 不接受封面、头像上的通用 `url_list`。
  private static func playbackURL(in object: [String: Any]) -> URL? {
    if let video = object["video"] as? [String: Any],
       let url = playableURL(fromPlaybackFields: video) {
      return url
    }
    return playableURL(fromPlaybackFields: object)
  }

  private static func playableURL(fromPlaybackFields container: [String: Any]) -> URL? {
    for key in ["play_addr", "playAddr", "download_addr", "downloadAddr"] {
      if let url = firstPlayableURL(in: container[key]) { return url }
    }
    if let raw = container["playApi"] as? String,
       let url = URL(string: raw),
       DouyinPlayableURL.isPlayable(url) {
      return url
    }
    if let raw = container["src"] as? String,
       raw.lowercased().contains(".mp4"),
       let url = URL(string: raw),
       DouyinPlayableURL.isPlayable(url) {
      return url
    }
    return nil
  }

  private static func firstPlayableURL(in value: Any?) -> URL? {
    if let raw = value as? String, let url = URL(string: raw), DouyinPlayableURL.isPlayable(url) {
      return url
    }
    guard let field = value as? [String: Any] else { return nil }
    let lists = field["url_list"] ?? field["urlList"]
    guard let urls = lists as? [String] else { return nil }
    for raw in urls {
      if let url = URL(string: raw), DouyinPlayableURL.isPlayable(url) { return url }
    }
    return nil
  }

  private static func durationSeconds(in object: [String: Any]) -> Double? {
    func parse(_ raw: Any?) -> Double? {
      let value: Double?
      if let number = raw as? NSNumber { value = number.doubleValue }
      else if let text = raw as? String { value = Double(text) }
      else { return nil }
      guard let value, value.isFinite, value > 0 else { return nil }
      return value > 1000 ? value / 1000.0 : value
    }
    if let video = object["video"] as? [String: Any], let duration = parse(video["duration"]) {
      return duration
    }
    return parse(object["duration"])
  }

  private static func nickname(in object: [String: Any]) -> String? {
    if let author = object["author"] as? [String: Any],
       let name = (author["nickname"] as? String)?.trimmedNonEmpty {
      return name
    }
    return (object["nickname"] as? String)?.trimmedNonEmpty
  }

  /// Read only the video object owned by the exact requested aweme.
  /// A bounded response may omit the outer wrapper, so complete inner objects
  /// are also considered. Nearby recommendations never supply missing fields.
  static func parseAnchoredCoverURL(_ snippet: String, pageURL: URL) -> URL? {
    guard snippet.unicodeScalars.count <= maximumStateSnippetScalars,
          let awemeID = DouyinURL.awemeID(from: pageURL) else { return nil }

    func cover(in object: [String: Any]) -> URL? {
      guard (object["aweme_id"] as? String ?? object["awemeId"] as? String) == awemeID,
            let video = object["video"] as? [String: Any] else { return nil }
      for key in ["origin_cover", "originCover", "cover"] {
        guard let field = video[key] as? [String: Any],
              let urls = (field["url_list"] ?? field["urlList"]) as? [String] else { continue }
        for raw in urls {
          if let url = DouyinWebCapturePolicy.renderedCoverURL(URL(string: raw), canonicalURL: pageURL) {
            return url
          }
        }
      }
      return nil
    }
    func search(_ value: Any, depth: Int = 0) -> URL? {
      guard depth < 64 else { return nil }
      if let object = value as? [String: Any] {
        if let found = cover(in: object) { return found }
        for child in object.values {
          if let found = search(child, depth: depth + 1) { return found }
        }
      } else if let array = value as? [Any] {
        for child in array {
          if let found = search(child, depth: depth + 1) { return found }
        }
      }
      return nil
    }

    if let root = try? JSONSerialization.jsonObject(with: Data(snippet.utf8)) {
      return search(root)
    }
    // Scan balanced objects without treating braces inside JSON strings as
    // structure. Parsing validates the candidate before its identity is used.
    let bytes = Array(snippet.utf8)
    var starts: [Int] = []
    var quoted = false
    var escaped = false
    for (index, byte) in bytes.enumerated() {
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
        continue
      }
      if byte == 34 { quoted = true; continue }
      if byte == 123 { starts.append(index) }
      if byte == 125, let start = starts.popLast() {
        let data = Data(bytes[start...index])
        // Most completed objects are media variants and do not own an aweme.
        guard let text = String(data: data, encoding: .utf8),
              text.contains(awemeID),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let found = cover(in: object) else { continue }
        return found
      }
    }
    return nil
  }

  /// 从渲染态片段里取出这条 aweme 的互动计数。状态值是精确整数。
  ///
  /// 片段可能是正常 JSON，也可能是 `\"digg_count\":123` 这种转义形式。
  /// 只认挨着 `awemeID` 的那个 `statistics` 对象，避免吃到推荐流邻居。
  static func parseStatistics(
    _ snippet: String,
    awemeID: String
  ) -> (likes: String?, comments: String?, shares: String?, collects: String?)? {
    guard snippet.unicodeScalars.count <= maximumStateSnippetScalars else { return nil }
    guard awemeID.range(of: #"^\d{8,25}$"#, options: .regularExpression) != nil else { return nil }
    let flattened = snippet.replacingOccurrences(of: "\\\"", with: "\"")
    guard let statsExpression = try? NSRegularExpression(
      pattern: #""statistics"\s*:\s*\{([^}]{0,800})"#,
      options: []
    ),
    let idExpression = try? NSRegularExpression(
      pattern: #""(?:aweme_id|awemeId)"\s*:\s*"(\d{8,25})""#,
      options: []
    ) else { return nil }

    let fullRange = NSRange(flattened.startIndex..., in: flattened)
    let idHits: [(id: String, location: Int)] = idExpression.matches(
      in: flattened,
      range: fullRange
    ).compactMap { match in
      guard match.numberOfRanges > 1,
            let capture = Range(match.range(at: 1), in: flattened)
      else { return nil }
      return (String(flattened[capture]), match.range.location)
    }
    guard !idHits.isEmpty else { return nil }

    var best: (
      distance: Int,
      likes: String?,
      comments: String?,
      shares: String?,
      collects: String?
    )?
    for match in statsExpression.matches(in: flattened, range: fullRange) {
      let location = match.range.location
      guard let nearest = idHits.min(by: {
        abs($0.location - location) < abs($1.location - location)
      }), nearest.id == awemeID else { continue }
      let distance = abs(nearest.location - location)
      guard distance <= 6_000 else { continue }
      guard match.numberOfRanges > 1,
            let bodyRange = Range(match.range(at: 1), in: flattened)
      else { continue }
      let body = String(flattened[bodyRange])
      let counts = (
        distance,
        firstMatch(#""digg_count"\s*:\s*"?(\d+)"?"#, in: body),
        firstMatch(#""comment_count"\s*:\s*"?(\d+)"?"#, in: body),
        firstMatch(#""share_count"\s*:\s*"?(\d+)"?"#, in: body),
        firstMatch(#""collect_count"\s*:\s*"?(\d+)"?"#, in: body)
      )
      if best == nil || distance < best!.distance {
        best = counts
      }
    }
    guard let best else { return nil }
    return (best.likes, best.comments, best.shares, best.collects)
  }

  /// Collect note gallery URLs from the same bounded aweme window.
  /// Skips avatars and comment images; only `aweme_images` / `tplv-dy-aweme-images`.
  public static func parseGalleryImageURLs(_ snippet: String, pageURL: URL) -> [URL] {
    guard snippet.unicodeScalars.count <= maximumStateSnippetScalars else { return [] }
    let normalized = snippet
      .replacingOccurrences(of: "\\u002F", with: "/")
      .replacingOccurrences(of: "\\/", with: "/")
    let scoped = DouyinURL.awemeID(from: pageURL)
      .flatMap { windowAround(id: $0, in: normalized, radius: 20_000) }
      ?? normalized
    guard let expression = try? NSRegularExpression(
      pattern: #"https://[^"\\\s<>]+douyinpic\.com[^"\\\s<>]+"#,
      options: [.caseInsensitive]
    ) else { return [] }
    let range = NSRange(scoped.startIndex..., in: scoped)
    var urls: [URL] = []
    for match in expression.matches(in: scoped, range: range) {
      guard let capture = Range(match.range, in: scoped) else { continue }
      var raw = String(scoped[capture])
      while let last = raw.last, ["\\", "\"", ",", ")", "]"].contains(String(last)) {
        raw.removeLast()
      }
      if let url = DouyinWebCapturePolicy.galleryImageURL(from: raw), !urls.contains(url) {
        urls.append(url)
      }
      if urls.count >= DouyinWebCapturePolicy.maximumGalleryImages { break }
    }
    return urls
  }

  public static func documentText(
    title: String?,
    author: String?,
    description: String?,
    coverURL: String? = nil
  ) -> String {
    var lines: [String] = ["---"]
    if let author, !author.isEmpty { lines.append("author: \(jsonString(author))") }
    if let coverURL, !coverURL.isEmpty { lines.append("cover_image: \(jsonString(coverURL))") }
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
    guard let videoURL = absoluteHTTPS(src, base: pageURL),
          DouyinPlayableURL.isPlayable(videoURL) else { return nil }
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
       DouyinPlayableURL.isPlayable(videoURL) {
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
    guard let awemeID = DouyinURL.awemeID(from: pageURL) else { return nil }
    let normalized = blob
      .replacingOccurrences(of: "\\u002F", with: "/")
      .replacingOccurrences(of: "\\/", with: "/")
    // state / SSR 播放地址只来自本条 aweme 对象上的明确播放字段。
    // ±6000 窗口 + nearest url_list 会在目标只有封面时借到邻居正片，
    // 也会在 video 字段离 id 超过 6000 时漏掉本条。
    guard let object = ownedAwemeObject(in: normalized, awemeID: awemeID)
            ?? ownedAwemeObject(in: blob, awemeID: awemeID),
          let videoURL = playbackURL(in: object)
    else { return nil }

    let coverURL = parseAnchoredCoverURL(blob, pageURL: pageURL)
    let title = (object["desc"] as? String)?.trimmedNonEmpty
    let author = nickname(in: object)
    return DouyinParsedPage(
      videoURL: videoURL,
      coverURL: coverURL,
      title: title,
      author: author,
      description: title,
      durationSeconds: durationSeconds(in: object),
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
