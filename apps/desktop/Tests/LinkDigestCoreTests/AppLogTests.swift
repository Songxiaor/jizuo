import XCTest
@testable import LinkDigestCore

final class AppLogTests: XCTestCase {
  func testHostKeepsOnlyTheHostAndDropsPathQueryAndUserinfo() {
    XCTAssertEqual(AppLog.host("https://x.com/user/status/1?token=abc"), "x.com")
    XCTAssertEqual(AppLog.host(URL(string: "https://www.douyin.com/video/1")), "www.douyin.com")
    XCTAssertEqual(AppLog.host("not a url"), "unparseable")
    XCTAssertEqual(AppLog.host(nil as String?), "none")
  }

  func testRedactStripsBearerKeysURLsAndLongOpaqueTokens() {
    let redacted = AppLog.redact(
      "GET https://api.example.com/v1/chat?api_key=sk-live-9f3a77c1d2e4abcd Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"
    )
    XCTAssertFalse(redacted.contains("sk-live-9f3a77c1d2e4abcd"))
    XCTAssertFalse(redacted.contains("abcdefghijklmnopqrstuvwxyz012345"))
    XCTAssertFalse(redacted.contains("/v1/chat"))
    XCTAssertTrue(redacted.contains("[redacted]") || redacted.contains("Bearer [redacted]"))
    XCTAssertTrue(redacted.contains("https://api.example.com") || redacted.contains("[redacted-url]"))
  }

  func testMessageOrdersKeysAndRedactsFieldValues() {
    let line = AppLog.message("capture_ok", ["host": "x.com", "token": "sk-live-9f3a77c1d2e4abcd"])
    XCTAssertTrue(line.hasPrefix("capture_ok "))
    XCTAssertTrue(line.contains("host=x.com"))
    XCTAssertFalse(line.contains("sk-live-9f3a77c1d2e4abcd"))
  }
}
