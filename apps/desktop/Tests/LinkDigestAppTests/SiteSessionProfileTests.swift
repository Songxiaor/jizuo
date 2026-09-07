import XCTest
@testable import LinkDigestApp

/// 会话 profile 写错不会崩、不会报错，只会表现成「登录了但没生效」或者「升级后
/// 又要重登」——都是最难查的一类。所以判据全部钉在这里。
final class SiteSessionProfileTests: XCTestCase {
  private let bilibili = SiteSessionProfile.bilibili

  func testExternalLoginRoutesOnlyKnownHTTPSProviders() {
    XCTAssertTrue(XExternalLoginPolicy.isProviderURL(URL(string: "https://accounts.google.com/o/oauth2/auth")))
    XCTAssertTrue(XExternalLoginPolicy.isProviderURL(URL(string: "https://appleid.apple.com/auth/authorize")))
    for value in ["http://accounts.google.com", "https://accounts.google.com.evil.test",
                  "https://evil.test/accounts.google.com", "https://user@accounts.google.com",
                  "https://accounts.google.com:8443", "javascript:alert(1)"] {
      XCTAssertFalse(XExternalLoginPolicy.isProviderURL(URL(string: value)), value)
    }
    XCTAssertEqual(XExternalLoginPolicy.loginURL.absoluteString, "https://x.com/i/flow/login")
    XCTAssertFalse(SiteSessionProfile.x.isAllowedHost("accounts.google.com"))
  }


  func testAllowedHostsCoverPassportAndCDNButRejectForeign() {
    // 登录会连跳 passport → 主站 → CDN，少一个后缀就卡在白屏。
    XCTAssertTrue(bilibili.isAllowedHost("www.bilibili.com"))
    XCTAssertTrue(bilibili.isAllowedHost("passport.bilibili.com"))
    XCTAssertTrue(bilibili.isAllowedHost("api.bilibili.com"))
    XCTAssertTrue(bilibili.isAllowedHost("m.bilibili.com"))
    XCTAssertTrue(bilibili.isAllowedHost("i0.hdslb.com"))
    // 这是这个 WebView 唯一的边界，放宽了它就是个自由浏览器。
    XCTAssertFalse(bilibili.isAllowedHost("evil.example.test"))
    XCTAssertFalse(bilibili.isAllowedHost(nil))
    XCTAssertFalse(bilibili.isAllowedHost(""))
    // 后缀匹配不能被 `bilibili.com.evil.test` 这种域名骗过去。
    XCTAssertFalse(bilibili.isAllowedHost("bilibili.com.evil.test"))
  }

  func testLooksLoggedInRequiresAFullCookieGroup() {
    XCTAssertTrue(bilibili.looksLoggedIn(["SESSDATA"]))
    XCTAssertTrue(bilibili.looksLoggedIn(["DedeUserID", "bili_jct"]))
    // DedeUserID 只是伴生项，单独出现不算登录。
    XCTAssertFalse(bilibili.looksLoggedIn(["DedeUserID"]))
    XCTAssertFalse(bilibili.looksLoggedIn(["bili_jct"]))
    XCTAssertFalse(bilibili.looksLoggedIn([]))
  }

  func testCookieFilterDropsExpiredAndKeepsSessionCookiesWithoutReadingValues() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertTrue(SiteSessionCookieFilter.isUnexpired(expiresDate: nil, now: now))
    XCTAssertTrue(SiteSessionCookieFilter.isUnexpired(expiresDate: now.addingTimeInterval(60), now: now))
    XCTAssertFalse(SiteSessionCookieFilter.isUnexpired(expiresDate: now, now: now))
    XCTAssertFalse(SiteSessionCookieFilter.isUnexpired(expiresDate: now.addingTimeInterval(-1), now: now))
    let session = cookie(name: "SESSDATA", expires: nil)
    let kept = SiteSessionCookieFilter.excludingExpired([session], now: now)
    XCTAssertEqual(kept.map(\.name), ["SESSDATA"])
    XCTAssertTrue(bilibili.looksLoggedIn(Set(kept.map(\.name))))
  }

  func testCookieDomainOwnershipStaysNarrowerThanNavigation() {
    XCTAssertTrue(bilibili.ownsCookieDomain(".bilibili.com"))
    XCTAssertTrue(bilibili.ownsCookieDomain("bilibili.com"))
    XCTAssertTrue(bilibili.ownsCookieDomain("passport.bilibili.com"))
    XCTAssertFalse(bilibili.ownsCookieDomain("evil.test"))
    XCTAssertFalse(bilibili.ownsCookieDomain(""))
    // bilivideo 是纯 CDN：要能导航过去加载页面，但它下发的 cookie 不是会话凭据，
    // 混进来会让 looksLoggedIn 读到不属于会话的名字。
    XCTAssertTrue(bilibili.isAllowedHost("upos-sz-mirror.bilivideo.com"))
    XCTAssertFalse(bilibili.ownsCookieDomain("upos-sz-mirror.bilivideo.com"))
  }

  func testDataStoreKeyMatchesThePreGeneralizationLiteral() {
    // 泛化前这个键是写死的字符串。换掉它等于换掉 WebKit 数据分区，用户已经登录的
    // 会话会变成孤儿——表现是「明明登录过，升级后又要重登」，且没有任何报错。
    XCTAssertEqual(bilibili.dataStoreIDKey, "linkdigest.site-session.bilibili.data-store-id")
    XCTAssertEqual(SiteSessionProfile.douyin.dataStoreIDKey, "linkdigest.site-session.douyin.data-store-id")
    XCTAssertEqual(SiteSessionProfile.xiaohongshu.dataStoreIDKey, "linkdigest.site-session.xiaohongshu.data-store-id")
    XCTAssertEqual(SiteSessionProfile.x.dataStoreIDKey, "linkdigest.site-session.x.data-store-id")
  }

  func testXiaohongshuNavigationAllowsBothShortLinkDomainsWithoutTreatingThemAsVerified() {
    XCTAssertTrue(SiteSessionProfile.xiaohongshu.isAllowedHost("xhslink.com"))
    XCTAssertTrue(SiteSessionProfile.xiaohongshu.isAllowedHost("xhslink.cn"))
    XCTAssertFalse(SiteSessionProfile.xiaohongshu.isAllowedHost("xhslink.com.evil.test"))
    XCTAssertNil(SiteSessionProfile.xiaohongshu.verifier)
    XCTAssertNil(SiteSessionProfile.x.verifier)
    XCTAssertNil(SiteSessionProfile.douyin.verifier)
  }

  func testBilibiliShipsAVerifierBecauseCookiePresenceIsNotValidity() {
    // 本机有 Cookie ≠ 服务端认它。少了 verifier，清晰度上不去时就只能靠猜。
    XCTAssertNotNil(bilibili.verifier)
    XCTAssertEqual(bilibili.accountIDCookieName, "DedeUserID")
    XCTAssertEqual(bilibili.platform, .bilibili)
  }

  private func cookie(name: String, expires: Date?) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: "redacted",
      .domain: ".bilibili.com",
      .path: "/",
    ]
    if let expires {
      properties[.expires] = expires
    }
    return HTTPCookie(properties: properties)!
  }
}
