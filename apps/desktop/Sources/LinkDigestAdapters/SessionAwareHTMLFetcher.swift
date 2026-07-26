import Foundation
import LinkDigestCore

/// 带 App 自有会话的网页抓取。
///
/// 「App 自有会话」指用户在设置里主动登录、存在隔离 WebKit 分区的那份 Cookie，
/// 与「偷读系统浏览器的 cookie 库」是两件事——后者是项目明确不做的，前者是 B 站
/// 早就在用的模式。这里把同一个模式推广给其它需要登录才能看到正文的站点。
///
/// 没有会话时**原样走旧路径**（`plain.fetch(url:)`），不多一个 header、不改一行行为。
/// 这条很重要：登录是可选功能，未登录用户的抓取结果不该因为这个改动有任何变化。
struct SessionAwareHTMLFetcher: Sendable {
  let plain: any WebPageFetcher
  let resources: any SafeResourceFetching
  /// 返回 nil 表示当前没有可用会话。实现方绝不能把这个字符串写进日志或记录。
  let cookieHeader: @Sendable () async -> String?
  /// 带会话请求时允许跳转到哪些地址。必须收窄到本站，否则 Cookie 会跟着跳到站外。
  let allowsRedirectTarget: @Sendable (URL) -> Bool
  /// 有些站点未带 Referer 会直接返回风控页。
  let referer: String

  /// 与登录 WebView 共用 UA。登录时和用会话时 UA 不一致，有些站会判定会话无效。
  private static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  private static let byteLimit = 4 * 1_024 * 1_024

  func fetch(url: URL) async throws -> WebPageFetchResult {
    guard let cookie = await cookieHeader(), !cookie.isEmpty else {
      return try await plain.fetch(url: url)
    }
    let response = try await resources.fetchResource(
      .init(
        url: url,
        headers: [
          "Accept": "text/html,application/xhtml+xml",
          "User-Agent": Self.browserUserAgent,
          "Referer": referer,
          "Cookie": cookie,
        ],
        byteLimit: Self.byteLimit,
        allowsRedirectTarget: allowsRedirectTarget
      )
    )
    try PublicHTMLResponsePolicy.validate(
      statusCode: response.statusCode,
      contentType: response.contentType,
      expectedLength: Int64(response.body.count),
      byteLimit: Self.byteLimit
    )
    // 这些站点都用 UTF-8；解不出来时不猜编码，交给调用方按「没抓到正文」处理，
    // 免得把乱码当正文入库。
    guard let html = String(data: response.body, encoding: .utf8), !html.isEmpty else {
      throw ManualLinkError.invalidPageResult
    }
    return WebPageFetchResult(
      url: response.url,
      html: html,
      contentType: response.contentType ?? "text/html"
    )
  }
}
