import XCTest
@testable import LinkDigestAdapters

/// 子域拿不到图标时回退到注册域。
///
/// 起因：support.claude.com 的 /favicon.ico 返回 200 但**零字节**，
/// 而 claude.com/favicon.ico 有 15086 字节的正常图标——列表里那条帮助文档
/// 因此只剩首字母色块。帮助中心、文档站、博客常挂在 support./help./docs./blog.
/// 这类子域上，图标只在主域有，所以这是通用规则而不是给某个站开后门。
final class FaviconHostChainTests: XCTestCase {
  func testSubdomainFallsBackToRegistrableParent() {
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "support.claude.com"),
      ["support.claude.com", "claude.com"]
    )
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "docs.github.com"),
      ["docs.github.com", "github.com"]
    )
  }

  /// 已经是注册域就没有可退的地方，不能凭空多打一次请求。
  func testRegistrableDomainHasNoParentToTry() {
    XCTAssertEqual(WebsiteFaviconCache.faviconHostChain(from: "claude.com"), ["claude.com"])
    XCTAssertEqual(WebsiteFaviconCache.faviconHostChain(from: "example.org"), ["example.org"])
  }

  /// 这条是整个回退最容易出错的地方：再剥一层就越过注册边界，
  /// 抓到的是**别人的**域名的图标。
  func testNeverClimbsPastAPublicSuffix() {
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "shop.example.co.uk"),
      ["shop.example.co.uk", "example.co.uk"]
    )
    // example.co.uk 已是注册域，剥完只剩 co.uk，必须停。
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "example.co.uk"),
      ["example.co.uk"]
    )
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "example.com.cn"),
      ["example.com.cn"]
    )
  }

  /// 多层子域也只退一层：a.b.c.com 的图标该找 b.c.com，不该一路退到 c.com。
  func testStripsOnlyOneLabel() {
    XCTAssertEqual(
      WebsiteFaviconCache.faviconHostChain(from: "a.b.example.com"),
      ["a.b.example.com", "b.example.com"]
    )
  }

  func testFaviconURLIsAlwaysHTTPSRootIcon() {
    XCTAssertEqual(
      WebsiteFaviconCache.faviconURL(host: "claude.com")?.absoluteString,
      "https://claude.com/favicon.ico"
    )
  }
}
