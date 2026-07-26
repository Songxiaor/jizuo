import XCTest
@testable import LinkDigestApp

/// 嵌入播放器的导航白名单收得过紧和收得过松，症状完全不同，但都不报错：
/// 过紧 → 宿主页被 .cancel，WebKit 不发任何失败回调，表现是永远「加载中」的白框；
/// 过松 → 这个 WebView 变成一个能自由上网的浏览器。所以判定单独抽出来钉住。
final class YouTubeEmbedNavigationPolicyTests: XCTestCase {
  private func allows(_ urlString: String) -> Bool {
    YouTubeEmbedNavigationPolicy.allowsMainFrame(url: URL(string: urlString)!)
  }

  func testHostDocumentItselfIsAllowedBecauseItCarriesTheIframe() {
    // 这条是这次 bug 的根因：`loadHTMLString(_:baseURL:)` 的主框架 URL 就是
    // baseURL，path 为空。只放行 `/embed/` 会把宿主页自己拦掉。
    XCTAssertTrue(allows("https://www.youtube-nocookie.com"))
    XCTAssertTrue(allows("https://www.youtube-nocookie.com/"))
    XCTAssertTrue(allows("https://youtube-nocookie.com"))
  }

  func testEmbedPageStaysAllowed() {
    XCTAssertTrue(allows("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0"))
  }

  func testJumpingOutOfTheEmbedIsStillBlocked() {
    // 播放器里的标题、Logo、推荐位都指向站外；放行它们等于把这个 WebView
    // 变成自由浏览器，而它跑在一个没有地址栏的卡片里。
    XCTAssertFalse(allows("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    XCTAssertFalse(allows("https://www.youtube-nocookie.com/watch?v=dQw4w9WgXcQ"))
    XCTAssertFalse(allows("https://accounts.google.com/signin"))
    XCTAssertFalse(allows("https://evil.test/"))
    // 后缀匹配不能被这种域名骗过去。
    XCTAssertFalse(allows("https://www.youtube-nocookie.com.evil.test/embed/x"))
  }

  func testAboutBlankIsAllowedBecauseWebKitUsesItDuringSetup() {
    XCTAssertTrue(allows("about:blank"))
  }
}
