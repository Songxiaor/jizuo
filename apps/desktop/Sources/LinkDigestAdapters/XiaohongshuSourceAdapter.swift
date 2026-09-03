import Foundation
import LinkDigestCore

/// 小红书手动链接。
///
/// 手机分享链接（`xhslink` 短链 → 主站 `/explore/{id}?xsec_token=...`）在未登录时
/// 也能拿到公开笔记页。先无 Cookie 抓一次；失败且用户在设置里登录过，再带
/// App 自有会话重试。两次都拿不到笔记时，带 `xsec_token` 的失效页走
/// `shareLinkExpired`，其余仍引导登录。
///
/// 无 fetcher 的 `init()` 保持旧行为：不发请求，直接 `loginRequired`。
public struct XiaohongshuSourceAdapter: SourceAdapting, Sendable {
  private let plainFetcher: (any WebPageFetcher)?
  private let sessionFetcher: SessionAwareHTMLFetcher?
  private let hasSession: @Sendable () async -> Bool
  private let now: @Sendable () -> Date

  public init() {
    self.plainFetcher = nil
    self.sessionFetcher = nil
    self.hasSession = { false }
    self.now = Date.init
  }

  public init(
    fetcher: any WebPageFetcher,
    resources: any SafeResourceFetching,
    cookieHeader: @escaping @Sendable () async -> String?,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.plainFetcher = fetcher
    self.sessionFetcher = SessionAwareHTMLFetcher(
      plain: fetcher,
      resources: resources,
      cookieHeader: cookieHeader,
      // Cookie 只发给笔记主站，绝不跟着短链域走。
      allowsRedirectTarget: { XiaohongshuURL.matchesSessionHost($0) },
      referer: "https://www.xiaohongshu.com/"
    )
    self.hasSession = { await cookieHeader()?.isEmpty == false }
    self.now = now
  }

  public func takesOwnership(of url: URL) -> Bool {
    XiaohongshuURL.matches(url)
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    guard XiaohongshuURL.matches(url) else { throw ManualLinkError.invalidURL }
    guard let sessionFetcher, let plainFetcher else {
      throw ManualLinkError.loginRequired
    }

    let targetURL = try await resolveTarget(url, using: plainFetcher)
    guard XiaohongshuURL.matchesSessionHost(targetURL) else {
      throw ManualLinkError.loginRequired
    }
    let noteID = XiaohongshuURL.noteID(from: targetURL)

    var lastPage: WebPageFetchResult?
    var publicFetchError: ManualLinkError?
    do {
      let page = try await fetchPage(plainFetcher, url: targetURL)
      lastPage = page
      if let document = makeDocument(
        page: page,
        noteID: noteID,
        method: "xiaohongshu_public_html"
      ) {
        return document
      }
    } catch let error as ManualLinkError {
      if error == .cancelled { throw error }
      publicFetchError = error
    }

    if await hasSession() {
      let page: WebPageFetchResult
      do {
        page = try await sessionFetcher.fetch(url: targetURL)
      } catch let error as ManualLinkError {
        throw error
      } catch is CancellationError {
        throw ManualLinkError.cancelled
      } catch {
        throw ManualLinkError.network
      }
      lastPage = page
      if let document = makeDocument(
        page: page,
        noteID: noteID,
        method: "xiaohongshu_session_html"
      ) {
        return document
      }
    }

    if XiaohongshuURL.hasXsecToken(targetURL),
       let page = lastPage,
       XiaohongshuPageParser.looksLikeExpiredShare(html: page.html, url: page.url) {
      throw ManualLinkError.shareLinkExpired
    }
    if lastPage == nil, let publicFetchError {
      throw publicFetchError
    }
    throw ManualLinkError.loginRequired
  }

  private func resolveTarget(_ url: URL, using fetcher: any WebPageFetcher) async throws -> URL {
    guard XiaohongshuURL.isShortLink(url) else { return url }
    let resolved = try await fetchPage(fetcher, url: url)
    guard XiaohongshuURL.matchesSessionHost(resolved.url) else {
      throw ManualLinkError.loginRequired
    }
    return resolved.url
  }

  private func fetchPage(_ fetcher: any WebPageFetcher, url: URL) async throws -> WebPageFetchResult {
    do {
      return try await fetcher.fetch(url: url)
    } catch let error as ManualLinkError {
      throw error
    } catch is CancellationError {
      throw ManualLinkError.cancelled
    } catch {
      throw ManualLinkError.network
    }
  }

  private func makeDocument(
    page: WebPageFetchResult,
    noteID: String?,
    method: String
  ) -> CapturedDocument? {
    let timestamp = ISO8601DateFormatter().string(from: now())
    // 分享链接的 xsec_token 是有时效的签名，不该跟着落库；有 noteID 时收成干净的笔记地址。
    let storedURL = noteID.map { "https://www.xiaohongshu.com/explore/\($0)" } ?? page.url.absoluteString
    if let detail = XiaohongshuPageParser.parseInitialState(html: page.html, noteID: noteID) {
      let text = XiaohongshuPageParser.documentText(from: detail)
      guard !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
              || !detail.title.isEmpty
      else { return nil }
      return CapturedDocument(
        createdAt: timestamp,
        idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
        origin: .manualLink,
        url: storedURL,
        title: detail.title,
        platform: "xiaohongshu",
        method: method,
        text: text,
        completeness: "full_article",
        capturedAt: timestamp,
        sourceLabel: "手动链接（小红书笔记）"
      )
    }
    if XiaohongshuPageParser.looksLikeExpiredShare(html: page.html, url: page.url) {
      return nil
    }
    guard let parsed = XiaohongshuPageParser.parse(html: page.html) else { return nil }
    let text = XiaohongshuPageParser.documentText(
      title: parsed.title,
      author: parsed.author,
      description: parsed.description,
      imageURL: parsed.imageURL
    )
    guard !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: storedURL,
      title: parsed.title,
      platform: "xiaohongshu",
      method: method,
      text: text,
      completeness: "best_effort",
      capturedAt: timestamp,
      sourceLabel: "手动链接（小红书笔记）"
    )
  }
}

public enum XiaohongshuURL {
  /// 短链 `xhslink.com` / `xhslink.cn` 也算：手机分享现在常用 `.cn`。
  /// 它们 302 到 `xiaohongshu.com`，分享链接常带 `xsec_token`。
  private static let claimHosts = ["xiaohongshu.com", "xhslink.com", "xhslink.cn"]
  private static let sessionHosts = ["xiaohongshu.com"]
  private static let shortLinkHosts = ["xhslink.com", "xhslink.cn"]

  public static func matches(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased()),
          let host = normalizedHost(url.host)
    else { return false }
    return claimHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  /// 带会话的请求允许跳到哪些 host——决定 Cookie 能跟到哪，比 `matches` 严。
  /// 短链域只用来展开，不接收登录态。
  public static func matchesSessionHost(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = normalizedHost(url.host)
    else { return false }
    return sessionHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  public static func isShortLink(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased()),
          let host = normalizedHost(url.host)
    else { return false }
    return shortLinkHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  public static func hasXsecToken(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .contains(where: { $0.name == "xsec_token" && !($0.value ?? "").isEmpty }) == true
  }

  /// `/explore/{id}` 或 `/discovery/item/{id}`，id 为 24 位十六进制。
  public static func noteID(from url: URL) -> String? {
    let parts = url.pathComponents.filter { $0 != "/" }
    let candidate: String?
    if parts.count >= 2, parts[0].lowercased() == "explore" {
      candidate = parts[1]
    } else if parts.count >= 3,
              parts[0].lowercased() == "discovery",
              parts[1].lowercased() == "item" {
      candidate = parts[2]
    } else {
      candidate = nil
    }
    guard let candidate, candidate.range(of: #"^[0-9a-fA-F]{24}$"#, options: .regularExpression) != nil else {
      return nil
    }
    return candidate.lowercased()
  }

  private static func normalizedHost(_ raw: String?) -> String? {
    guard var host = raw?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    return host
  }
}

/// 笔记页解析。
///
/// 优先读 `window.__INITIAL_STATE__` 里的 `note.noteDetailMap`（标题、正文、
/// 互动数、图片、话题、发布时间）。对象字面量里会出现字面 `undefined`，解析前
/// 换成 `null`。失败时再退回 og:meta——2026-07-26 真机校准过，og:title /
/// og:description 仍是完整标题与正文。
public enum XiaohongshuPageParser {
  public struct Parsed: Sendable, Equatable {
    public let title: String
    public let author: String?
    public let description: String
    public let imageURL: URL?
  }

  public struct NoteDetail: Sendable, Equatable {
    public let title: String
    public let desc: String
    public let author: String?
    public let publishedAt: String?
    public let likes: String?
    public let comments: String?
    public let shares: String?
    public let collects: String?
    public let imageURLs: [URL]
    public let tags: [String]
    public let isVideo: Bool
    public let noteID: String
  }

  private static let initialStateByteLimit = 4 * 1_024 * 1_024
  private static let maxImages = 35
  private static let countPattern = #"^\d+(\.\d+)?[万亿wWkK]?$"#

  public static func parse(html: String) -> Parsed? {
    let ogTitle = metaContent(html: html, property: "og:title")
    let ogDescription = metaContent(html: html, property: "og:description")
    // 未登录 / 会话过期时服务端返回登录墙外壳：og:title 是站点名，og:description
    // 是固定的站点简介，两者都不含笔记内容。
    guard let ogDescription, !ogDescription.isEmpty else { return nil }
    // 只挡「描述为空」不够：会话过期时服务端返回 200 + 外壳 + 站点宣传语，
    // 那种情况下 parse 会成功，入库一条标题「小红书」、正文是宣传语的记录。
    // 标题去尾正则要求前置分隔符，裸「小红书」清不掉，于是它看着还挺像回事。
    guard !isSiteBoilerplate(title: ogTitle, description: ogDescription) else { return nil }
    let rawTitle = ogTitle ?? ""
    // 去掉「 - 小红书」这类站点后缀。
    let title = rawTitle
      .replacingOccurrences(
        of: #"[_\-—|]\s*(小红书|xiaohongshu|RED)\s*$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    // 去掉站点后缀后如果只剩站名本身，说明这就是外壳，不是笔记。
    guard !siteNames.contains(title.lowercased()) else { return nil }
    return Parsed(
      title: title,
      author: metaContent(html: html, property: "og:xhs:note_user_nickname"),
      description: ogDescription,
      imageURL: noteImageURL(html: html)
    )
  }

  public static func parseInitialState(html: String, noteID: String?) -> NoteDetail? {
    guard let raw = extractInitialStateObject(from: html) else { return nil }
    guard raw.utf8.count <= initialStateByteLimit else { return nil }
    let sanitized = raw.replacingOccurrences(of: ":undefined", with: ":null")
    guard let data = sanitized.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data),
          let root = json as? [String: Any]
    else { return nil }

    let noteRoot = root["note"] as? [String: Any]
    let map = noteRoot?["noteDetailMap"] as? [String: Any] ?? [:]
    guard let resolvedID = resolveNoteID(requested: noteID, noteRoot: noteRoot, map: map),
          let entry = map[resolvedID] as? [String: Any]
    else { return nil }
    let note = (entry["note"] as? [String: Any]) ?? entry

    let title = jsonString(note["title"]) ?? ""
    let desc = jsonString(note["desc"]) ?? ""
    let user = note["user"] as? [String: Any]
    let author = jsonString(user?["nickname"])
    let interact = note["interactInfo"] as? [String: Any]
    let images = imageURLs(from: note["imageList"] as? [Any] ?? [])
    let tags = tagNames(from: note["tagList"] as? [Any] ?? [])
    let type = jsonString(note["type"])?.lowercased()
    let publishedAt = jsonInt64(note["time"]).map(iso8601UTCMilliseconds(fromMilliseconds:))

    guard !title.isEmpty || !desc.isEmpty || !images.isEmpty else { return nil }

    return NoteDetail(
      title: strippedSiteSuffix(title),
      desc: desc,
      author: author,
      publishedAt: publishedAt,
      likes: acceptedCount(jsonString(interact?["likedCount"])),
      comments: acceptedCount(jsonString(interact?["commentCount"])),
      shares: acceptedCount(jsonString(interact?["shareCount"])),
      collects: acceptedCount(jsonString(interact?["collectedCount"])),
      imageURLs: images,
      tags: tags,
      isVideo: type == "video",
      noteID: resolvedID
    )
  }

  /// 站点自称。标题去掉分隔符后缀后若正好是其中之一，说明拿到的是外壳。
  static let siteNames: Set<String> = [
    "小红书", "小红书 - 你的生活指南", "你的生活指南", "xiaohongshu", "red",
  ]

  /// 登录墙外壳的固定文案特征。
  ///
  /// 这些是小红书给未登录访客和搜索引擎看的站点简介，不随笔记变化。命中即说明
  /// 会话无效——服务端返回 200，但内容是外壳。
  private static let boilerplateMarkers = [
    "你的生活指南", "标记我的生活", "全世界的好东西", "3亿人的生活经验",
    "更多有趣内容尽在小红书", "下载小红书",
  ]

  static func isSiteBoilerplate(title: String?, description: String) -> Bool {
    let normalizedTitle = (title ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if siteNames.contains(normalizedTitle.lowercased()) { return true }
    return boilerplateMarkers.contains { description.contains($0) }
  }

  /// 服务端 200 但跳到 `/404?error_code=300031`，或标题写「页面不见了」。
  static func looksLikeExpiredShare(html: String, url: URL) -> Bool {
    let path = url.path
    if path == "/404" || path.hasPrefix("/404/") { return true }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if items.contains(where: { $0.name == "error_code" && $0.value == "300031" }) {
      return true
    }
    if html.contains("error_code=300031") { return true }
    if html.contains("小红书 - 你访问的页面不见了") { return true }
    return false
  }

  public static func documentText(from detail: NoteDetail) -> String {
    var frontmatter: [String] = []
    if let author = detail.author, !author.isEmpty {
      frontmatter.append("author: \(yamlQuoted(author))")
    }
    if let published = detail.publishedAt, !published.isEmpty {
      frontmatter.append("published: \(yamlQuoted(published))")
    }
    if let likes = detail.likes { frontmatter.append("likes: \(yamlQuoted(likes))") }
    if let comments = detail.comments { frontmatter.append("comments: \(yamlQuoted(comments))") }
    if let shares = detail.shares { frontmatter.append("shares: \(yamlQuoted(shares))") }
    if let collects = detail.collects { frontmatter.append("collects: \(yamlQuoted(collects))") }

    var body = normalizeTopicMarkers(in: detail.desc)
    let missingTags = detail.tags.filter { tag in !body.contains("#\(tag)") }
    if !missingTags.isEmpty {
      if !body.isEmpty { body.append("\n") }
      body.append(missingTags.map { "#\($0)" }.joined(separator: " "))
    }
    if !detail.imageURLs.isEmpty {
      if !body.isEmpty { body.append("\n") }
      body.append(detail.imageURLs.map { "![](\($0.absoluteString))" }.joined(separator: "\n"))
    }
    body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if frontmatter.isEmpty { return body }
    return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(body)"
  }

  public static func documentText(
    title: String,
    author: String?,
    description: String,
    imageURL: URL? = nil
  ) -> String {
    var frontmatter: [String] = []
    if let author, !author.isEmpty {
      frontmatter.append("author: \(yamlQuoted(author))")
    }
    var lines: [String] = []
    lines.append(description)
    if let imageURL {
      lines.append("")
      lines.append("![](\(imageURL.absoluteString))")
    }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if frontmatter.isEmpty { return body }
    return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(body)"
  }

  /// 笔记封面。登录墙站点 logo 不在 xhscdn 上，parse 已经挡过外壳。
  static func noteImageURL(html: String) -> URL? {
    guard let raw = metaContent(html: html, property: "og:image") else { return nil }
    return acceptedImageURL(raw)
  }

  /// property 和 name 两种写法都要认：小红书两种都下发过。
  static func metaContent(html: String, property: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: property)
    for attribute in ["property", "name"] {
      let pattern = "<meta[^>]+\(attribute)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"']"
      if let match = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
        let fragment = String(html[match])
        if let value = fragment.range(of: "content=[\"']([^\"']*)[\"']", options: .regularExpression) {
          let raw = String(fragment[value])
            .replacingOccurrences(of: #"^content=[\"']"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\"']$"#, with: "", options: .regularExpression)
          let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
          if !decoded.isEmpty { return decoded }
        }
      }
    }
    return nil
  }

  private static func extractInitialStateObject(from html: String) -> String? {
    guard let marker = html.range(of: "window.__INITIAL_STATE__") else { return nil }
    let afterMarker = html[marker.upperBound...]
    guard let equal = afterMarker.firstIndex(of: "=") else { return nil }
    let afterEqual = afterMarker[afterMarker.index(after: equal)...]
    guard let scriptEnd = afterEqual.range(of: "</script>", options: .caseInsensitive) else {
      return nil
    }
    var object = String(afterEqual[..<scriptEnd.lowerBound])
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if object.hasSuffix(";") { object.removeLast() }
    object = object.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    return object.isEmpty ? nil : object
  }

  private static func resolveNoteID(
    requested: String?,
    noteRoot: [String: Any]?,
    map: [String: Any]
  ) -> String? {
    if let requested {
      return map[requested] == nil ? nil : requested
    }
    if let current = jsonString(noteRoot?["currentNoteId"]), map[current] != nil {
      return current
    }
    if let first = jsonString(noteRoot?["firstNoteId"]), map[first] != nil {
      return first
    }
    return map.keys.first
  }

  private static func imageURLs(from list: [Any]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for item in list {
      guard result.count < maxImages else { break }
      guard let dict = item as? [String: Any] else { continue }
      var candidates: [String] = []
      if let urlDefault = dict["urlDefault"] as? String { candidates.append(urlDefault) }
      if let infoList = dict["infoList"] as? [Any] {
        for info in infoList {
          if let infoDict = info as? [String: Any], let url = infoDict["url"] as? String {
            candidates.append(url)
          }
        }
      }
      for raw in candidates {
        guard let url = acceptedImageURL(raw), seen.insert(url.absoluteString).inserted else {
          continue
        }
        result.append(url)
        break
      }
    }
    return result
  }

  private static func acceptedImageURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")
    else { return nil }
    return url
  }

  private static func tagNames(from list: [Any]) -> [String] {
    var names: [String] = []
    var seen = Set<String>()
    for item in list {
      guard let dict = item as? [String: Any],
            let name = jsonString(dict["name"]),
            seen.insert(name).inserted
      else { continue }
      names.append(name)
    }
    return names
  }

  private static func normalizeTopicMarkers(in desc: String) -> String {
    desc.replacingOccurrences(
      of: #"#([^#\[\]]+)\[话题\]#"#,
      with: "#$1",
      options: .regularExpression
    )
  }

  private static func strippedSiteSuffix(_ title: String) -> String {
    title
      .replacingOccurrences(
        of: #"[_\-—|]\s*(小红书|xiaohongshu|RED)\s*$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
  }

  private static func acceptedCount(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    guard trimmed.range(of: countPattern, options: .regularExpression) != nil else { return nil }
    return trimmed
  }

  private static func iso8601UTCMilliseconds(fromMilliseconds ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func yamlQuoted(_ value: String) -> String {
    "\"" + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ") + "\""
  }

  private static func jsonString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      return number.stringValue
    }
    return nil
  }

  private static func jsonInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      return number.int64Value
    }
    if let value = value as? String, let parsed = Int64(value) {
      return parsed
    }
    return nil
  }
}
