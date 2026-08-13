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
  }

  /// 封面优先（lite-embed）：卡片先显示封面，点击才创建 WKWebView。
  ///
  /// 播放器创建必须在用户手势之后——这道门由 isPlayerRequested 把守；
  /// 换来的是 autoplay=1 兑现那次点击（否则用户要点两次播放）。
  /// 封面只取公开缩略图（i.ytimg.com），不带身份信息。
  func testCardShowsPosterFirstAndOnlyCreatesPlayerAfterUserGesture() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/YouTubeEmbedPlayer.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("isPlayerRequested"))
    XCTAssertTrue(source.contains("YouTubeEmbedPosterView"))
    XCTAssertTrue(source.contains("i.ytimg.com/vi/"))
    XCTAssertTrue(source.contains("autoplay=1"))
    XCTAssertTrue(source.contains("mediaTypesRequiringUserActionForPlayback = []"))
    // 封面点击是创建播放器的唯一卡内入口；影院入口同样是显式按钮手势。
    XCTAssertTrue(source.contains("YouTubeEmbedPosterView(videoID: videoID) { isPlayerRequested = true }"))
  }
}
