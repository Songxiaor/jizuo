import XCTest

@testable import LinkDigestApp

/// 播放与封面这两条链路上，来自抓取内容的地址不得再用裸 `URLSession.shared`。
///
/// 断源码而不是断行为：真正要守住的是「这条路径上不存在绕过门禁的写法」，
/// 一个行为测试只能覆盖当下这一处调用，新加一处仍然静悄悄通过。
final class HistoryMediaPlaybackSafeFetchTests: XCTestCase {
  private func appSource(_ name: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(name)"),
      encoding: .utf8
    )
  }

  func testDualTrackDownloadGoesThroughThePublicURLGate() throws {
    let source = try appSource("HistoryMediaPlayback.swift")
    XCTAssertTrue(
      source.contains("SafeMediaStreamDownloader()"),
      "双轨分片下载必须走安全下载器，门禁和其它抓取同一套"
    )
    XCTAssertTrue(source.contains("mediaDownloader.download(from:"))
    XCTAssertTrue(source.contains("mediaDownloader.contentLength(of:"))
    XCTAssertFalse(
      source.contains("URLSession.shared"),
      "播放卡片不得再直接用 URLSession.shared 下载抓取来的地址"
    )
  }

  func testYouTubePosterGoesThroughTheAdmittedThumbnailPath() throws {
    let source = try appSource("YouTubeEmbedPlayer.swift")
    XCTAssertTrue(source.contains("DouyinProfilePreviewResource.admittedURL"))
    XCTAssertTrue(source.contains("WorkThumbnailLoader.shared.image(url:"))
    XCTAssertFalse(
      source.contains("URLSession.shared"),
      "YouTube 封面要走已经做过门禁与缓存的取图线"
    )
  }

  /// 流式落盘是这条路径存在的理由：分片单条可达 180MB，不能整段进内存。
  func testStreamingDownloadStaysOffMemory() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestAdapters/SafeMediaStreamDownloader.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("session.download(for:"))
    XCTAssertTrue(source.contains("moveItem(at: tempURL, to: destination)"))
    XCTAssertTrue(
      source.contains("willPerformHTTPRedirection"),
      "重定向每一跳都要回到门禁，不能交给 URLSession 自己跟"
    )
    XCTAssertTrue(source.contains("allowsRedirect(from:"))
    XCTAssertTrue(source.contains("https") && source.contains("http"))
  }
}
