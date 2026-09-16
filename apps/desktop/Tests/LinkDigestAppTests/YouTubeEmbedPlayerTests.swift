import XCTest
@testable import LinkDigestApp

final class YouTubeEmbedPlayerTests: XCTestCase {
  func testWatchLinkParsingMatchesAdapterRules() {
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube.com/watch?v=8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://youtu.be/8_JZehVSRAI?t=10"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://m.youtube.com/watch?v=8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube.com/shorts/AbCdEf12345"), "AbCdEf12345")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube.com/embed/8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertEqual(YouTubeWatchLink.videoID(from: "https://www.youtube-nocookie.com/embed/8_JZehVSRAI"), "8_JZehVSRAI")
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://www.youtube.com/"))
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://example.com/watch?v=8_JZehVSRAI"))
    XCTAssertNil(YouTubeWatchLink.videoID(from: "https://www.douyin.com/video/123"))
  }

  func testGalleryThumbnailURLIsDisplayOnlyAndStaysOnAdmittedYtimgHost() {
    let watch = "https://www.youtube.com/watch?v=Qk8rSlDR8z4"
    XCTAssertEqual(
      YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: watch)?.absoluteString,
      "https://i.ytimg.com/vi/Qk8rSlDR8z4/hqdefault.jpg"
    )
    XCTAssertEqual(
      YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://youtu.be/ZIaOBAjvc38?t=10")?.absoluteString,
      "https://i.ytimg.com/vi/ZIaOBAjvc38/hqdefault.jpg"
    )
    XCTAssertEqual(
      YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://www.youtube.com/shorts/JBKYwV4WsVA")?.absoluteString,
      "https://i.ytimg.com/vi/JBKYwV4WsVA/hqdefault.jpg"
    )
    XCTAssertNotNil(GalleryCoverAdmission.admittedURL("https://i.ytimg.com/vi/Qk8rSlDR8z4/hqdefault.jpg"))
    XCTAssertNil(YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://example.com/watch?v=Qk8rSlDR8z4"))
    XCTAssertNil(YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://www.youtube.com/watch?v=../evil"))
    XCTAssertNil(YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://www.youtube.com/watch?v="))
    XCTAssertNil(YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: "https://i.ytimg.com/vi/Qk8rSlDR8z4/hqdefault.jpg"))
  }

  func testSavedWorkCardUsesCanonicalYouTubeThumbnailWithoutRewritingMarkdown() throws {
    let card = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/CreatorDirectoryViews.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(card.contains("YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: row.canonicalURL)"))
    XCTAssertTrue(card.contains("displayCoverURL"))
    XCTAssertTrue(card.contains("if let cover = displayCoverURL"))
    XCTAssertTrue(card.contains("if row.hasMedia == true, let file = await localCover(nil)"))
    XCTAssertTrue(card.contains("prefersTextPreview = true"))
    XCTAssertTrue(card.contains("prefersTextPreview {"), "没有本机视频文件时退回文字摘录，不报「封面加载失败」")
    XCTAssertFalse(card.contains("guard let admitted else {\n          coverFailed = true"))
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
    // 官方 embed、专用数据存储、主框架导航仅允许 embed 自身、window.open 拒绝。
    //
    // 2026-09-15 起的有意取舍（Syc 批准）：零件落磁盘缓存换「第二次打开不再
    // 冷下载」，身份类数据每次启动整批清掉。所以这条断言从「不能是持久存储」
    // 翻成「必须是专用持久存储 + 必须清身份」——两侧都要钉住，少任何一边
    // 都是静默的隐私或速度回归。
    XCTAssertTrue(source.contains("youtube-nocookie.com/embed/"))
    XCTAssertTrue(source.contains("forIdentifier:"), "必须是专用存储，不能与登录会话共用")
    XCTAssertTrue(source.contains("wipeEmbedIdentityData"), "身份类数据每次启动要清掉")
    XCTAssertTrue(source.contains("WKWebsiteDataTypeCookies"))
    XCTAssertFalse(source.contains(".nonPersistent()"), "缓存要落磁盘，否则每次打开都是冷下载")
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
      role: .card, isCinemaPresented: false))
    XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
      role: .cinema, isCinemaPresented: false))
    // 影院已展开：影院层响应（双击 = 关闭），卡片层不响应。
    XCTAssertFalse(VideoCinemaDoubleClickDecision.shouldRespond(
      role: .card, isCinemaPresented: true))
    XCTAssertTrue(VideoCinemaDoubleClickDecision.shouldRespond(
      role: .cinema, isCinemaPresented: true))
    // 任意影院状态下，两层都「有且仅有一层」响应——一次双击只该打开/关闭一层。
    for presented in [false, true] {
      let card = VideoCinemaDoubleClickDecision.shouldRespond(
        role: .card, isCinemaPresented: presented)
      let cinema = VideoCinemaDoubleClickDecision.shouldRespond(
        role: .cinema, isCinemaPresented: presented)
      XCTAssertFalse(card && cinema, "presented=\(presented) 时两层不应同时响应")
      XCTAssertTrue(card || cinema, "presented=\(presented) 时应有且仅有一层响应")
    }
  }
}
