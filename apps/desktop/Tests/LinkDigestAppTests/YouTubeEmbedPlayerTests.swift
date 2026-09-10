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
