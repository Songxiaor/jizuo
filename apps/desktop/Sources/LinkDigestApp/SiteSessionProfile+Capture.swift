import Foundation
import LinkDigestCore

/// 抖音与小红书的会话。
///
/// 它们和 B 站的用途不同：B 站的会话服务于「会过期的高清播放地址」，这两个服务于
/// 「未登录就看不到正文」。同一套隔离 WebKit 分区机制，两种消费端。
///
/// 都不提供 `verifier`：这两个站没有稳定的公开登录态接口，硬找就要去 replay 私有
/// 签名接口，那是项目明确回避的。没有 verifier 时控制器只依赖本机 Cookie 判定，
/// 会话失效的表现是抓取回落到「请用浏览器扩展」——有明确出口，不会静默出坏结果。
extension SiteSessionProfile {
  static let douyin = SiteSessionProfile(
    platform: .douyin,
    // 登录会在 douyin.com 与 www.douyin.com 之间跳，静态资源在 byteimg/pstatp，
    // 少了它们登录页会缺图缺脚本、扫码框出不来。
    allowedHostSuffixes: [
      "douyin.com",
      "iesdouyin.com",
      "bytedance.com",
      "byteimg.com",
      "pstatp.com",
      "snssdk.com",
    ],
    // 比导航白名单窄：CDN（byteimg/pstatp）下发的不是会话凭据。
    cookieDomainSuffixes: ["douyin.com", "iesdouyin.com", "snssdk.com"],
    // sessionid 是主会话 cookie；sessionid_ss 是它的 SameSite 变体，
    // 某些登录路径只下发后者，少写一个会让「已登录」永远显示不出来。
    loginCookieGroups: [["sessionid"], ["sessionid_ss"], ["sid_tt"]],
    loginURL: URL(string: "https://www.douyin.com/")!,
    accountIDCookieName: nil,
    accountIDLabel: nil,
    verifier: nil
  )

  static let xiaohongshu = SiteSessionProfile(
    platform: .xiaohongshu,
    allowedHostSuffixes: [
      "xiaohongshu.com",
      "xhslink.com",
      "xhscdn.com",
      "fegine.com",
    ],
    cookieDomainSuffixes: ["xiaohongshu.com", "xhslink.com"],
    // web_session 是登录后的主会话 cookie。a1/webId 未登录也会下发，
    // 拿它们判定会让未登录状态被误显示成「已登录」。
    loginCookieGroups: [["web_session"]],
    loginURL: URL(string: "https://www.xiaohongshu.com/explore")!,
    accountIDCookieName: nil,
    accountIDLabel: nil,
    verifier: nil
  )
}
