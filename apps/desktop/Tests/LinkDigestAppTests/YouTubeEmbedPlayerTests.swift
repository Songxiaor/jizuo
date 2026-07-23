import XCTest
@testable import LinkDigestApp

final class YouTubeEmbedPlayerTests: XCTestCase {
  func testWatchLinkParsingMatchesAdapterRules() {
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube.com/watch?v=8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://youtu.be/8_JZehVSRAI?t=10"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://m.youtube.com/watch?v=8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube.com/shorts/AbCdEf12345"), "AbCdEf12345")
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://www.youtube.com/"))
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://example.com/watch?v=8_JZehVSRAI"))
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://www.douyin.com/video/123"))
  }

  func testEmbedWebViewLocksNavigationAndDataStore() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/YouTubeEmbedPlayer.swift"),
      encoding: .utf8
    )
    // 官方 embed、无 Cookie 持久化、主框架导航仅允许 embed 自身、window.open 拒绝。
    XCTAssertTrue(source.contains("youtube-nocookie.com/embed/"))
    XCTAssertTrue(source.contains(".nonPersistent()"))
    XCTAssertTrue(source.contains("url.path.hasPrefix(\"/embed/\")"))
    XCTAssertTrue(source.contains("decisionHandler(.cancel)"))
    XCTAssertTrue(source.contains("createWebViewWith"))
    XCTAssertTrue(source.contains("mediaTypesRequiringUserActionForPlayback = .all"))
  }
}
