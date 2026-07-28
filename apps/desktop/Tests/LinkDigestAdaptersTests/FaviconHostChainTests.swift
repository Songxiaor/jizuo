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

/// 读页面声明的图标。
///
/// 猜 `/favicon.ico` 在真实站点上有两种坏法，实测都撞到了：
/// - support.claude.com 返回 200 但零字节；
/// - www.residentialvps.com 返回 200 但 content-type 是 text/html（SPA 把未知
///   路径都回首页），退到注册域也是同一份 HTML。
///
/// 两种猜法都救不了，站点自己在 `<link rel="icon">` 里声明的才是权威来源。
extension FaviconHostChainTests {
  private var base: URL { URL(string: "https://www.residentialvps.com/plans")! }

  /// 真实站点上抓到的那一行，原样使用。
  func testReadsIconDeclaredByTheSite() {
    let html = #"""
    <head><link rel="icon" href="/Content/img/favicon.png" type="image/png" sizes="16x16" /></head>
    """#
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).map(\.absoluteString),
      ["https://www.residentialvps.com/Content/img/favicon.png"]
    )
  }

  /// 相对路径要按页面地址解析，不是按站点根。
  func testResolvesRelativeHrefAgainstThePageURL() {
    let html = #"<link rel="shortcut icon" href="../img/f.ico">"#
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).map(\.absoluteString),
      ["https://www.residentialvps.com/img/f.ico"]
    )
  }

  /// 声明的图标常挂在 CDN 上，跨域必须允许，否则这条路等于没开。
  func testAcceptsCrossHostCDNIcons() {
    let html = #"<link rel="icon" href="https://cdn.example.net/brand/icon.png">"#
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).map(\.absoluteString),
      ["https://cdn.example.net/brand/icon.png"]
    )
  }

  /// 有大的优先：16×16 在列表里也能用，但 180×180 更清楚。
  func testPrefersLargerDeclaredSizes() {
    let html = """
    <link rel="icon" href="/small.png" sizes="16x16">
    <link rel="apple-touch-icon" href="/big.png" sizes="180x180">
    """
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).first?.absoluteString,
      "https://www.residentialvps.com/big.png"
    )
  }

  /// 同一地址被 icon 与 apple-touch-icon 同时声明很常见，不该重复请求。
  func testDeduplicatesRepeatedDeclarations() {
    let html = """
    <link rel="icon" href="/f.png">
    <link rel="apple-touch-icon" href="/f.png">
    """
    XCTAssertEqual(WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).count, 1)
  }

  /// 非图标的 link 不能混进来——stylesheet 命中就会去下载一个 CSS 当图标。
  func testIgnoresNonIconLinks() {
    let html = """
    <link rel="stylesheet" href="/app.css">
    <link rel="canonical" href="https://example.com/x">
    <link rel="preconnect" href="https://cdn.example.net">
    """
    XCTAssertTrue(WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).isEmpty)
  }

  func testIgnoresUnsafeSchemesAndCredentials() {
    let html = """
    <link rel="icon" href="javascript:alert(1)">
    <link rel="icon" href="https://user:pass@example.net/i.png">
    <link rel="icon" href="data:image/png;base64,AAAA">
    """
    XCTAssertTrue(WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).isEmpty)
  }
}
