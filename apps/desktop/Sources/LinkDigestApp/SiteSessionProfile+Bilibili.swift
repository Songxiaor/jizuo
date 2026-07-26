import Foundation
import LinkDigestAdapters
import LinkDigestCore

extension SiteSessionProfile {
  /// B 站会话。
  ///
  /// `dataStoreIDKey` 由 `platform.rawValue` 拼出，结果是
  /// `linkdigest.site-session.bilibili.data-store-id`——与泛化之前写死的那个键
  /// **逐字一致**。这条不能动：换了键等于换了 WebKit 数据分区，用户已经登录的
  /// 会话会变成孤儿，表现是「明明登录过，升级后又要重登」。
  static let bilibili = SiteSessionProfile(
    platform: .bilibili,
    // 登录会连跳 passport → 主站 → 静态资源；hdslb/bilivideo 是 CDN，
    // 不放进来登录页就加载不全。
    allowedHostSuffixes: [
      "bilibili.com",
      "bilibili.cn",
      "bilivideo.com",
      "hdslb.com",
      "biliapi.net",
      "biliapi.com",
    ],
    // 比导航白名单窄：CDN 域下发的 cookie 不是会话凭据。
    cookieDomainSuffixes: [
      "bilibili.com",
      "bilibili.cn",
      "hdslb.com",
      "biliapi.net",
      "biliapi.com",
    ],
    // SESSDATA 是主会话 cookie，单独成立；DedeUserID 只是稳定伴生项，
    // 必须配上 bili_jct 才算数。
    loginCookieGroups: [["SESSDATA"], ["DedeUserID", "bili_jct"]],
    loginURL: URL(string: "https://passport.bilibili.com/login")!,
    accountIDCookieName: "DedeUserID",
    accountIDLabel: "UID",
    verifier: { cookie in await verifyBilibiliSession(cookieHeader: cookie) }
  )
}

/// 只读取 `isLogin` 与会员等级，不把 Cookie 写进返回值或日志。
private func verifyBilibiliSession(cookieHeader: String) async -> String {
  guard let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
    return "校验端点不可用"
  }
  let fetcher = ProxyAwareWebPageFetcher()
  do {
    let response = try await fetcher.fetchResource(
      .init(
        url: endpoint,
        headers: [
          "Accept": "application/json",
          "User-Agent": SiteSessionProfile.browserUserAgent,
          "Referer": "https://www.bilibili.com/",
          "Cookie": cookieHeader,
        ],
        byteLimit: 256 * 1024,
        allowsRedirectTarget: { target in
          let host = target.host?.lowercased() ?? ""
          return host == "api.bilibili.com" || host.hasSuffix(".bilibili.com")
        }
      )
    )
    guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
      return "无法解析返回内容（HTTP \(response.statusCode)）"
    }
    let data = root["data"] as? [String: Any]
    guard (data?["isLogin"] as? Bool) ?? false else {
      // code=-101 是「账号未登录」。Cookie 存在但服务端不认：过期，或没送达。
      let code = root["code"] as? Int ?? -1
      return "服务端不认可这个会话（code \(code)）——高清档不会解锁"
    }
    let vipStatus = (data?["vipStatus"] as? Int) ?? 0
    let vipType = ((data?["vip"] as? [String: Any])?["type"] as? Int) ?? 0
    let vip = vipStatus == 1 ? (vipType >= 2 ? "年度大会员" : "大会员") : "非大会员"
    return "服务端已认可 · \(vip)"
  } catch {
    return "校验请求失败：\(error)"
  }
}
