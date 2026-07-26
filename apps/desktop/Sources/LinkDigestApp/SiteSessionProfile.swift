import Foundation
import LinkDigestCore

/// 一个站点的登录会话差异，全部收敛成这份数据。
///
/// 拆出来的动机：原先 `BilibiliSiteSessionController` 把域名、登录页、cookie 名、
/// 校验端点全写死在方法体里，加第二个站点只能整份复制。复制出来的副本会各自漂移，
/// 而这类漂移（少一个导航白名单后缀、cookie 判定写错一个名字）不会报错也不会崩，
/// 只会表现成「登录了但没生效」，最难查。
struct SiteSessionProfile: Sendable {
  let platform: SiteSessionPlatform

  /// 登录 WebView 允许导航到的 host 后缀。
  ///
  /// 登录流程会连跳好几个域（passport → 主站 → 静态资源 → 验证码），少一个就卡在
  /// 白屏；但这也是这个 WebView 唯一的边界，多一个就等于把它变成自由浏览器。
  let allowedHostSuffixes: [String]

  /// 归属本站会话的 cookie domain 后缀。
  ///
  /// 必须比 `allowedHostSuffixes` 窄：CDN 和静态资源域要放进导航白名单才能加载页面，
  /// 但它们下发的 cookie 不是会话凭据，混进来会让 `looksLoggedIn` 误判。
  let cookieDomainSuffixes: [String]

  /// 任一组齐全即视为已登录。
  ///
  /// 用「组」而不是单个名字，是因为站点的登录态判据本身就是这个形状：B 站
  /// `SESSDATA` 单独成立，而 `DedeUserID` 必须配上 `bili_jct` 才算数。
  let loginCookieGroups: [Set<String>]

  let loginURL: URL

  /// 状态行里显示的账号标识取自哪个 cookie。为 nil 时只显示「已登录」。
  let accountIDCookieName: String?

  /// 账号标识在状态行里的措辞，例如 B 站的 `UID`。
  let accountIDLabel: String?

  /// 用与业务请求完全相同的网络层打一次登录态接口，确认服务端是否认可这个会话。
  ///
  /// 可选：不是每个站点都有稳定的公开登录态接口，没有就只依赖本机 cookie 判定。
  /// 入参是 Cookie 头，返回值是直接显示给人看的一行字。实现方**不得**把 Cookie
  /// 写进返回值或日志。
  let verifier: (@Sendable (String) async -> String)?

  /// WebView 与业务请求共用的 UA。
  ///
  /// 站点会按 UA 拦「版本过低」页，WKWebView 默认 Safari UA 常被当成过时浏览器；
  /// 而且登录时和用会话时 UA 不一致，有些站会直接判定会话无效。
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  /// WebKit 数据分区的稳定 id，换了它等于把用户已有的登录态孤立掉。
  var dataStoreIDKey: String { "linkdigest.site-session.\(platform.rawValue).data-store-id" }

  func isAllowedHost(_ host: String?) -> Bool {
    guard var host = host?.lowercased(), !host.isEmpty else { return false }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if host.hasPrefix("m.") { host = String(host.dropFirst(2)) }
    return allowedHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  func ownsCookieDomain(_ rawDomain: String) -> Bool {
    let domain = rawDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !domain.isEmpty else { return false }
    return cookieDomainSuffixes.contains { domain == $0 || domain.hasSuffix(".\($0)") }
  }

  func looksLoggedIn(_ cookieNames: Set<String>) -> Bool {
    loginCookieGroups.contains { !$0.isEmpty && $0.isSubset(of: cookieNames) }
  }
}
