import XCTest
@testable import LinkDigestApp

@MainActor
final class BilibiliSiteSessionControllerTests: XCTestCase {
  func testAllowedHostsCoverPassportAndSiteButRejectForeign() {
    XCTAssertTrue(BilibiliSiteSessionController.isAllowedHost("www.bilibili.com"))
    XCTAssertTrue(BilibiliSiteSessionController.isAllowedHost("passport.bilibili.com"))
    XCTAssertTrue(BilibiliSiteSessionController.isAllowedHost("api.bilibili.com"))
    XCTAssertTrue(BilibiliSiteSessionController.isAllowedHost("m.bilibili.com"))
    XCTAssertTrue(BilibiliSiteSessionController.isAllowedHost("i0.hdslb.com"))
    XCTAssertFalse(BilibiliSiteSessionController.isAllowedHost("evil.example.test"))
    XCTAssertFalse(BilibiliSiteSessionController.isAllowedHost(nil))
  }

  func testLooksLoggedInRequiresSessionCookies() {
    let sessdata = HTTPCookie(properties: [
      .domain: ".bilibili.com",
      .path: "/",
      .name: "SESSDATA",
      .value: "abc",
    ])!
    let dede = HTTPCookie(properties: [
      .domain: ".bilibili.com",
      .path: "/",
      .name: "DedeUserID",
      .value: "123",
    ])!
    let jct = HTTPCookie(properties: [
      .domain: ".bilibili.com",
      .path: "/",
      .name: "bili_jct",
      .value: "tok",
    ])!
    XCTAssertTrue(BilibiliSiteSessionController.looksLoggedIn([sessdata]))
    XCTAssertTrue(BilibiliSiteSessionController.looksLoggedIn([dede, jct]))
    XCTAssertFalse(BilibiliSiteSessionController.looksLoggedIn([dede]))
    XCTAssertFalse(BilibiliSiteSessionController.looksLoggedIn([]))
  }
}
