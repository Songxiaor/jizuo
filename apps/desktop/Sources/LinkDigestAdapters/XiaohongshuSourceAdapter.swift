import Foundation
import LinkDigestCore

/// 小红书手动链接。
///
/// 未登录时服务端返回的是登录墙外壳——里面有站点导航和推荐位，但没有笔记内容。
/// 走通用 HTML 路径的结果是**静默成功**：入库一条标题像模像样、正文是站点样板文
/// 的记录，用户要读完才发现不对，而且它已经占了一条历史。所以未登录一律不抓，
/// 直接给出引导。
///
/// 用户在设置里登录小红书后，抓取会带上那份 App 自有会话（隔离 WebKit 分区里的
/// Cookie，不是系统浏览器的），此时才真去取正文。
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
    // 没有会话就不抓。抓了也只会拿到登录墙，然后把它当正文入库。
    guard let sessionFetcher, let plainFetcher, await hasSession() else {
      throw ManualLinkError.loginRequired
    }
    let targetURL: URL
    if XiaohongshuURL.isShortLink(url) {
      let resolved: WebPageFetchResult
      do {
        resolved = try await plainFetcher.fetch(url: url)
      } catch let error as ManualLinkError {
        throw error
      } catch is CancellationError {
        throw ManualLinkError.cancelled
      } catch {
        throw ManualLinkError.network
      }
      guard XiaohongshuURL.matchesSessionHost(resolved.url) else {
        throw ManualLinkError.loginRequired
      }
      targetURL = resolved.url
    } else {
      targetURL = url
    }
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

    guard let parsed = XiaohongshuPageParser.parse(html: page.html) else {
      // 会话过期时服务端照样返回 200 加登录墙外壳，解析不出笔记就当会话失效处理，
      // 给出人能照做的下一步，而不是静默存一条空记录。
      throw ManualLinkError.loginRequired
    }
    let text = XiaohongshuPageParser.documentText(
      title: parsed.title,
      author: parsed.author,
      description: parsed.description,
      imageURL: parsed.imageURL
    )
    guard !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
      throw ManualLinkError.loginRequired
    }
    let timestamp = ISO8601DateFormatter().string(from: now())
    return CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: page.url.absoluteString,
      title: parsed.title,
      platform: "xiaohongshu",
      method: "xiaohongshu_session_html",
      text: text,
      completeness: "best_effort",
      capturedAt: timestamp,
      sourceLabel: "手动链接（小红书笔记）"
    )
  }
}

public enum XiaohongshuURL {
  /// 短链 `xhslink.com` / `xhslink.cn` 也算：手机分享现在常用 `.cn`。
  /// 它们 302 到 `xiaohongshu.com`，同样需要登录才有正文。
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

  private static func normalizedHost(_ raw: String?) -> String? {
    guard var host = raw?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    return host
  }
}

/// 笔记页解析。
///
/// 只读 og:meta，不碰页面里那套混淆过的 class 名——2026-07-26 真机校准时确认，
/// 笔记详情的 og:title / og:description 是完整的标题与正文，而 DOM class 名是
/// 构建时生成的，随时会变。少一个依赖就少一处会静默失效的地方。
public enum XiaohongshuPageParser {
  public struct Parsed: Sendable, Equatable {
    public let title: String
    public let author: String?
    public let description: String
    public let imageURL: URL?
  }

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

  public static func documentText(
    title: String,
    author: String?,
    description: String,
    imageURL: URL? = nil
  ) -> String {
    var lines: [String] = []
    if let author, !author.isEmpty { lines.append("作者：\(author)") }
    if !lines.isEmpty { lines.append("") }
    lines.append(description)
    if let imageURL {
      lines.append("")
      lines.append("![](\(imageURL.absoluteString))")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
  }

  /// 笔记封面。登录墙站点 logo 不在 xhscdn 上，parse 已经挡过外壳。
  static func noteImageURL(html: String) -> URL? {
    guard let raw = metaContent(html: html, property: "og:image"),
          let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")
    else { return nil }
    return url
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
}
