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

/// 猜 `/favicon.ico` 时，重定向能跟到哪里。
///
/// 实测 `www.douyin.com/favicon.ico` 返回 302 跳到 `lf1-cdn-tos.bytegoofy.com`
/// 的一张标准 ICO。要求同域会把这一类站点全判死，而它们的页面 HTML 是 SPA 外壳
/// （抖音的 `</head>` 在第 36 个字节、零个 `<link rel="icon">`），退到读页面声明
/// 那条路也救不回来。
extension FaviconHostChainTests {
  /// 这条是修复的核心：跨域重定向必须能跟过去。
  func testFollowsIconRedirectToAnotherHost() {
    XCTAssertTrue(WebsiteFaviconCache.isSafeIconLocation(
      URL(string: "https://lf1-cdn-tos.bytegoofy.com/goofy/ies/douyin_web/public/favicon.ico")!
    ))
  }

  /// 放宽的只有「同域」一条，凭据照旧拒绝。
  func testRejectsCredentialsInIconLocation() {
    XCTAssertFalse(WebsiteFaviconCache.isSafeIconLocation(
      URL(string: "https://user:pass@cdn.example.net/icon.png")!
    ))
  }

  /// 非 http(s) 协议照旧拒绝。
  func testRejectsNonWebSchemesInIconLocation() {
    XCTAssertFalse(WebsiteFaviconCache.isSafeIconLocation(URL(string: "file:///etc/passwd")!))
    XCTAssertFalse(WebsiteFaviconCache.isSafeIconLocation(URL(string: "data:image/png;base64,AA")!))
  }

  /// 非标准端口照旧拒绝——图标不该把请求引到别的服务上。
  func testRejectsNonStandardPortsInIconLocation() {
    XCTAssertFalse(WebsiteFaviconCache.isSafeIconLocation(URL(string: "https://cdn.example.net:8443/icon.png")!))
    XCTAssertTrue(WebsiteFaviconCache.isSafeIconLocation(URL(string: "https://cdn.example.net:443/icon.png")!))
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

  /// 同档时先试位图，别拿一张不知道多大的 SVG 去撞字节上限。
  ///
  /// 取自 earendil.com 的真实声明顺序（SVG 写在最前）。那张 SVG 实测 4.6 MB，
  /// 远超 64 KiB 上限必然被拒；同目录的 apple-touch-icon 只有 49 KB，完全可用。
  /// 排序若把 SVG 放在前面，每次抓取都要先白费一个请求才轮到它。
  func testPrefersRasterOverVectorAmongLargeEnoughIcons() {
    let html = """
    <link rel="icon" type="image/svg+xml" href="/static/favicon/square.svg">
    <link rel="icon" type="image/x-icon" href="/static/favicon/favicon.ico">
    <link rel="icon" type="image/png" sizes="32x32" href="/static/favicon/favicon-32x32.png">
    <link rel="icon" type="image/png" sizes="16x16" href="/static/favicon/favicon-16x16.png">
    <link rel="apple-touch-icon" sizes="180x180" href="/static/favicon/apple-touch-icon.png">
    """
    let ordered = WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).map(\.absoluteString)
    XCTAssertEqual(ordered.first, "https://www.residentialvps.com/static/favicon/apple-touch-icon.png")
    // 矢量图仍要留在候选里：只提供 SVG 的站点靠它才不会回落到首字母方块。
    XCTAssertTrue(ordered.contains("https://www.residentialvps.com/static/favicon/square.svg"))
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

  /// 真实站点：`www.databricks.com` 的博客页。
  ///
  /// 它同时踩中两个坑——图标声明在第 53 万个字符（前面全是内联脚本），而且声明了
  /// 9 个尺寸，最大的 512×512 有 197 KB，远超 64 KiB 缓存上限。老实现固定只扫前
  /// 20 万字符、并按尺寸降序取前 3 个，两条都让它必然失败。
  func testFindsIconsDeclaredDeepInsideAVeryLargeHead() {
    let filler = String(repeating: "<script>var x=1;</script>", count: 30_000)
    let html = """
    <head>\(filler)
    <link rel="icon" href="/favicon-32x32.png" type="image/png"/>
    <link rel="apple-touch-icon" sizes="96x96" href="/icons/icon-96x96.png"/>
    <link rel="apple-touch-icon" sizes="512x512" href="/icons/icon-512x512.png"/>
    </head>
    """
    XCTAssertGreaterThan(html.count, 200_000, "这条测试的前提就是 head 超过老的扫描窗口")

    let urls = WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base)
    XCTAssertFalse(urls.isEmpty, "声明藏在 head 深处也必须能读到，否则只能回落到首字母方块")
    XCTAssertEqual(
      urls.first?.absoluteString,
      "https://www.residentialvps.com/icons/icon-96x96.png",
      "该挑够用的最小那张：512×512 实测 197 KB，超缓存上限，拿了也白拿"
    )
  }

  /// 正文里的 <link> 不算声明——扫描窗口放大后，这条边界必须仍然守住。
  func testStopsScanningAtHeadEnd() {
    let html = """
    <head><link rel="icon" href="/real.png" sizes="64x64"></head>
    <body><link rel="icon" href="/fake.png" sizes="128x128"></body>
    """
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).map(\.absoluteString),
      ["https://www.residentialvps.com/real.png"]
    )
  }

  /// 一张都不够大时取其中最大的：糊总比没有强。
  func testFallsBackToTheLargestWhenNoneReachesTheDisplaySize() {
    let html = """
    <link rel="icon" href="/tiny.png" sizes="16x16">
    <link rel="icon" href="/small.png" sizes="32x32">
    """
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).first?.absoluteString,
      "https://www.residentialvps.com/small.png"
    )
  }

  /// 只提供 SVG 的站点必须仍能拿到图标，否则它们永远回落到首字母方块。
  ///
  /// 这条原来叫「矢量图应当优先」，断言 SVG 排在 180×180 的 PNG 前面。理由是
  /// 「矢量任何尺寸都清晰」——那句话没错，但它只说明**清晰度**，完全没说明
  /// **字节数**，而候选是按 64 KiB 上限筛的。实测 earendil.com 的第一个声明是
  /// 一张 4.6 MB 的 SVG，同目录的 apple-touch-icon 只有 49 KB：旧规则每次都先
  /// 撞一次上限才轮到能用的那张。
  ///
  /// 所以「同档优先矢量」反转成「同档优先位图」，但矢量的**兜底**地位不变——
  /// 这条测试现在守的就是兜底：没有够大的位图时，SVG 仍然是首选。
  func testVectorRemainsTheFallbackWhenNoRasterIsLargeEnough() {
    let html = """
    <link rel="icon" href="/icon.svg" type="image/svg+xml">
    <link rel="apple-touch-icon" href="/icon-16.png" sizes="16x16">
    """
    XCTAssertEqual(
      WebsiteFaviconCache.declaredIconURLs(inHTML: html, baseURL: base).first?.absoluteString,
      "https://www.residentialvps.com/icon.svg"
    )
  }

  func testAcceptsSVGButRejectsHTMLMislabelledAsSVG() {
    XCTAssertTrue(WebsiteFaviconCache.isSupportedImage(
      contentType: "image/svg+xml",
      body: Data(#"<svg xmlns="http://www.w3.org/2000/svg"><circle r="8"/></svg>"#.utf8)
    ), "只提供 SVG 图标的站点不该永远回落到首字母方块")

    // SPA 把任意路径都回首页，是这条路上实测遇到过的坏法。
    XCTAssertFalse(WebsiteFaviconCache.isSupportedImage(
      contentType: "image/svg+xml",
      body: Data("<!doctype html><html><body>not an icon</body></html>".utf8)
    ))
  }

  /// 真实站点：`x.com/favicon.ico` 声明 `image/x-icon`，字节头却是 PNG。
  ///
  /// 按声明的类型去校验 magic bytes，就会拿 ICO 的头去比一张 PNG，必然不符——
  /// X 的图标因此一直取不到。以字节为准才对：服务器怎么标都不影响它是什么。
  func testAcceptsCorrectImageBytesEvenWhenContentTypeIsWrong() {
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + Array(repeating: 0, count: 32))
    XCTAssertTrue(WebsiteFaviconCache.isSupportedImage(contentType: "image/x-icon", body: png))
    // CDN 不发 Content-Type 或一律发 octet-stream 也很常见，同样不该判死。
    XCTAssertTrue(WebsiteFaviconCache.isSupportedImage(contentType: nil, body: png))
    XCTAssertTrue(WebsiteFaviconCache.isSupportedImage(contentType: "application/octet-stream", body: png))
  }

  func testStillRejectsMislabelledRasterImages() {
    XCTAssertFalse(WebsiteFaviconCache.isSupportedImage(
      contentType: "image/png",
      body: Data("<!doctype html>".utf8)
    ))
    XCTAssertTrue(WebsiteFaviconCache.isSupportedImage(
      contentType: "image/png",
      body: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    ))
  }
}
