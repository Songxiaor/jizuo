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

    /// 双层双击互斥：影院打开后卡片层仍在视图树里，两层各自的本地监视器会收到同一次
    /// 双击——只有 role 与影院当前状态匹配的那一层才该响应，否则同一个双击会又开又关。
    func testCinemaDoubleClickLayersAreMutuallyExclusive() {
      // 影院未展开：卡片层响应（双击 = 放大），影院层不响应。
      XCTAssertTrue(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .card, clickCount: 2, isCinemaPresented: false))
      XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .cinema, clickCount: 2, isCinemaPresented: false))
      // 影院已展开：影院层响应（双击 = 关闭），卡片层不响应。
      XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .card, clickCount: 2, isCinemaPresented: true))
      XCTAssertTrue(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .cinema, clickCount: 2, isCinemaPresented: true))
      // 任意影院状态下，两层都「有且仅有一层」响应。
      for presented in [false, true] {
        let card = VideoCinemaDoubleClickDecision.shouldRespond(
          role: .card, clickCount: 2, isCinemaPresented: presented)
        let cinema = VideoCinemaDoubleClickDecision.shouldRespond(
          role: .cinema, clickCount: 2, isCinemaPresented: presented)
        XCTAssertFalse(card && cinema, "presented=\(presented) 时两层不应同时响应")
        XCTAssertTrue(card || cinema, "presented=\(presented) 时应有且仅有一层响应")
      }
      // 非双击（单击/三击）一律不响应。
      XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .card, clickCount: 1, isCinemaPresented: false))
      XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
        role: .cinema, clickCount: 1, isCinemaPresented: true))
    }
}
