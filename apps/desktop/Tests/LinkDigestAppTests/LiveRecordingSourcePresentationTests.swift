import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 直播录制在界面上的「是谁」：图标复用所属平台的成套素材，悬停说明不套「改成「外部」的…」模板。
///
/// 背景（2026-11-11 走查）：侧栏和列表把 `douyinlive` / `xiaohongshulive` 当成未知来源，
/// 退成首字母「D」「X」，小红书的「X」和推特撞脸；侧栏悬停还按「本机文件」那套模板
/// 写成「改成「外部」的抖音直播（1 条）」。
final class LiveRecordingSourcePresentationTests: XCTestCase {
  func testLiveRecordingSourcesReuseTheirPlatformIconAssets() {
    XCTAssertEqual(HistoryPlatformRegistry.bundledAssetName(forHost: "douyinlive"), "douyin")
    XCTAssertEqual(HistoryPlatformRegistry.bundledAssetName(forHost: "xiaohongshulive"), "xiaohongshu")
    // 侧栏的单色剪影走同一份映射，否则会掉回线框/字母兜底。
    XCTAssertEqual(PlatformIconCatalog.sidebarGlyphs["douyinlive"], "glyph-douyin")
    XCTAssertEqual(PlatformIconCatalog.sidebarGlyphs["xiaohongshulive"], "glyph-xiaohongshu")
    // 选中时的品牌色跟平台一致：小红书红；抖音本来就无品牌色（用正文色）。
    XCTAssertNil(PlatformIconCatalog.sidebarBrandColor(for: "douyinlive"))
    XCTAssertNotNil(PlatformIconCatalog.sidebarBrandColor(for: "xiaohongshulive"))
  }

  func testLiveRecordingHostsAreRecognisedAsLiveAndStayOutOfTheFileWording() {
    for host in ["douyinlive", "xiaohongshulive"] {
      XCTAssertTrue(HistoryPlatformRegistry.isLiveRecordingHost(host))
      XCTAssertTrue(OwnershipSourceNavigation.isLiveRecordingHost(host))
      XCTAssertTrue(OwnershipSourceNavigation.localHosts.contains(host))
    }
    // 同平台的普通内容、本地文件、笔记都不算直播录制。
    XCTAssertFalse(HistoryPlatformRegistry.isLiveRecordingHost("douyin.com"))
    XCTAssertFalse(OwnershipSourceNavigation.isLiveRecordingHost(LocalImportSource.files.rawValue))
    XCTAssertFalse(OwnershipSourceNavigation.isLiveRecordingHost(HistoryPlatformDisplay.noteHost))
  }
}
