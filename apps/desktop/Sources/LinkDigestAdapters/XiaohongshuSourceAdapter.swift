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
  private let sessionFetcher: SessionAwareHTMLFetcher?
  private let hasSession: @Sendable () async -> Bool
  private let now: @Sendable () -> Date

  public init() {
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
    self.sessionFetcher = SessionAwareHTMLFetcher(
      plain: fetcher,
      resources: resources,
      cookieHeader: cookieHeader,
      // Cookie 绝不能跟着跳到站外。
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
    guard let sessionFetcher, await hasSession() else {
      throw ManualLinkError.loginRequired
    }
    let page: WebPageFetchResult
    do {
      page = try await sessionFetcher.fetch(url: url)
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
      title: parsed.title, author: parsed.author, description: parsed.description)
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
  /// 短链 `xhslink.com` 也算：它 302 到 `xiaohongshu.com`，同样需要登录才有正文，
  /// 放过去只会让通用路径多跳一次再撞同一堵墙。
  private static let hosts = ["xiaohongshu.com", "xhslink.com"]

  public static func matches(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased()),
          var host = url.host?.lowercased(), !host.isEmpty
    else { return false }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    // 后缀匹配必须带点，否则 `xiaohongshu.com.evil.test` 会被认成自己人。
    return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  /// 带会话的请求允许跳到哪些 host——决定 Cookie 能跟到哪，比 `matches` 严。
  public static func matchesSessionHost(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          var host = url.host?.lowercased(), !host.isEmpty
    else { return false }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
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
  }

  public static func parse(html: String) -> Parsed? {
    let ogTitle = metaContent(html: html, property: "og:title")
    let ogDescription = metaContent(html: html, property: "og:description")
    // 未登录时服务端返回登录墙外壳：og:title 是站点名，og:description 是站点简介，
    // 两者都不含笔记内容。用「描述为空」当判据——登录墙外壳的 og:description
    // 要么缺失，要么是固定的站点宣传语，都不该被当成正文入库。
    guard let ogDescription, !ogDescription.isEmpty else { return nil }
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
    return Parsed(
      title: title,
      author: metaContent(html: html, property: "og:xhs:note_user_nickname"),
      description: ogDescription
    )
  }

  public static func documentText(title: String, author: String?, description: String) -> String {
    var lines: [String] = []
    if let author, !author.isEmpty { lines.append("作者：\(author)") }
    if !lines.isEmpty { lines.append("") }
    lines.append(description)
    return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
