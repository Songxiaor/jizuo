import XCTest
@testable import LinkDigestApp

/// 会话 profile 写错不会崩、不会报错，只会表现成「登录了但没生效」或者「升级后
/// 又要重登」——都是最难查的一类。所以判据全部钉在这里。
final class SiteSessionProfileTests: XCTestCase {
  private let bilibili = SiteSessionProfile.bilibili

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
  }

  func testBilibiliShipsAVerifierBecauseCookiePresenceIsNotValidity() {
    // 本机有 Cookie ≠ 服务端认它。少了 verifier，清晰度上不去时就只能靠猜。
    XCTAssertNotNil(bilibili.verifier)
    XCTAssertEqual(bilibili.accountIDCookieName, "DedeUserID")
    XCTAssertEqual(bilibili.platform, .bilibili)
  }
}
