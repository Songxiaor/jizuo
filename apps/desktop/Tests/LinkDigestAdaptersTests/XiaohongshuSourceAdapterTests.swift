import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 这条路径上三类错误都不报错、只产出坏结果：认领范围写窄了链接掉回通用路径，
/// 抓回登录墙外壳当正文静默入库；会话跳转白名单写宽了，用户的 Cookie 会跟着
/// 302 送到站外；登录墙外壳解析成功则会存下一条「标题像模像样、正文是站点样板文」
/// 的记录。三类都在这里钉住。
final class XiaohongshuSourceAdapterTests: XCTestCase {
  private let adapter = XiaohongshuSourceAdapter()

  func testClaimsNoteAndShortLinkHosts() {
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.xiaohongshu.com/explore/648c70cf")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.xiaohongshu.com/discovery/item/648c70cf")!))
    // 短链 302 到主站，同样要登录才有正文。
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://xhslink.com/a/AbCdEf")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://xhslink.cn/o/5SGH7HyxwIk")!))
  }

  func testDoesNotClaimLookalikeOrForeignHosts() {
    // 后缀匹配必须带点，否则这个域名会被认成自己人。
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://xiaohongshu.com.evil.test/explore/1")!))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://www.bilibili.com/video/BV1")!))
  }

  func testWithoutSessionItRefusesInsteadOfFetchingTheLoginWall() async {
    do {
      _ = try await adapter.capture(url: URL(string: "https://www.xiaohongshu.com/explore/648c70cf")!)
      XCTFail("未登录时不应该去抓")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .loginRequired)
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }

  func testSessionRedirectAllowListKeepsCookiesOnSite() {
    // 这个判定决定「Cookie 能跟着 302 跳到哪」。宽一格就是把用户登录态送去别的域，
    // 而且不会有任何报错。
    XCTAssertTrue(XiaohongshuURL.matchesSessionHost(URL(string: "https://www.xiaohongshu.com/explore/1")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://xhslink.com/a/x")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://xhslink.cn/o/5SGH7HyxwIk")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://xiaohongshu.com.evil.test/")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://evil.test/")!))
    // 明文 http 不带 Cookie。
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "http://www.xiaohongshu.com/explore/1")!))
  }

  func testParserRejectsLoginWallShellButAcceptsARealNote() {
    // 登录墙外壳没有笔记内容：og:description 缺失。解析成功就会静默入库一条假正文。
    let wall = """
      <html><head><meta property="og:title" content="小红书 - 你的生活指南">
      </head><body></body></html>
      """
    XCTAssertNil(XiaohongshuPageParser.parse(html: wall))

    let note = """
      <html><head>
      <meta property="og:title" content="三天两夜厦门citywalk路线 - 小红书">
      <meta property="og:description" content="第一天先去鼓浪屿，建议早上八点前上岛。">
      <meta name="og:xhs:note_user_nickname" content="旅行的小张">
      </head></html>
      """
    let parsed = XiaohongshuPageParser.parse(html: note)
    XCTAssertEqual(parsed?.title, "三天两夜厦门citywalk路线")
    XCTAssertEqual(parsed?.author, "旅行的小张")
    XCTAssertTrue(parsed?.description.contains("鼓浪屿") == true)
  }

  func testShortLinkResolvesWithoutSendingCookiesToXhslink() async throws {
    let shortURL = URL(string: "https://xhslink.cn/o/5SGH7HyxwIk")!
    let noteURL = URL(string: "https://www.xiaohongshu.com/discovery/item/6a4a0c570000000007023508?xsec_token=redacted")!
    let noteHTML = """
      <html><head>
      <meta property="og:title" content="纯钛Apple Watch表带的质感真的很特别 - 小红书">
      <meta property="og:description" content="夏天手腕最怕闷热，这条表带确实凉快。">
      <meta property="og:image" content="https://sns-webpic-qc.xhscdn.com/note/redacted.jpg">
      </head></html>
      """
    let plain = XiaohongshuShortLinkFetcher(resolved: noteURL)
    let resources = XiaohongshuSessionResourceFetcher(html: noteHTML)
    let adapter = XiaohongshuSourceAdapter(
      fetcher: plain,
      resources: resources,
      cookieHeader: { "session=1" }
    )

    let document = try await adapter.capture(url: shortURL)

    XCTAssertEqual(plain.fetched, [shortURL])
    XCTAssertEqual(resources.requestedHosts, ["www.xiaohongshu.com"])
    XCTAssertTrue(document.text.contains("夏天手腕最怕闷热"))
    XCTAssertTrue(document.text.contains("sns-webpic-qc.xhscdn.com"))
    XCTAssertEqual(document.platform, "xiaohongshu")
  }
}

private final class XiaohongshuShortLinkFetcher: WebPageFetcher, @unchecked Sendable {
  let resolved: URL
  private let lock = NSLock()
  private var seen: [URL] = []

  init(resolved: URL) { self.resolved = resolved }

  var fetched: [URL] { lock.withLock { seen } }

  func fetch(url: URL) async throws -> WebPageFetchResult {
    lock.withLock { seen.append(url) }
    return .init(url: resolved, html: "<html></html>", contentType: "text/html")
  }
}

private final class XiaohongshuSessionResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  let html: String
  private let lock = NSLock()
  private var seen: [URL] = []

  init(html: String) { self.html = html }

  var requestedHosts: [String] {
    lock.withLock { seen.compactMap(\.host) }
  }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { seen.append(request.url) }
    return .init(
      url: request.url,
      statusCode: 200,
      contentType: "text/html; charset=utf-8",
      body: Data(html.utf8)
    )
  }
}


/// 会话 Cookie 的去向边界。
final class SessionCookieBoundaryTests: XCTestCase {
  func testDouyinHostMatchRequiresADotBoundary() {
    // `hasSuffix("douyin.com")` 少一个点，`v.evil-douyin.com` 就成了自己人。
    // 认领本身只是路由，但登录抖音后这条路径会带着会话 Cookie 去抓——
    // 等于把登录态发给攻击者控制的主机。
    XCTAssertFalse(DouyinURL.matches(URL(string: "https://v.evil-douyin.com/x")!))
    XCTAssertFalse(DouyinURL.matches(URL(string: "https://evil-douyin.com/x")!))
    XCTAssertFalse(DouyinURL.matches(URL(string: "https://douyin.com.evil.test/x")!))
    // 真实的抖音域名仍然认领。
    XCTAssertTrue(DouyinURL.matches(URL(string: "https://www.douyin.com/video/7000000000000000002")!))
    XCTAssertTrue(DouyinURL.matches(URL(string: "https://v.douyin.com/AbCdEf/")!))
    XCTAssertTrue(DouyinURL.matches(URL(string: "https://www.iesdouyin.com/share/video/1")!))
  }

  func testSessionRedirectAllowListIsStricterThanOwnership() {
    // 认领可以宽松（短链、历史域名），但「Cookie 发给谁」必须严格。
    XCTAssertTrue(DouyinURL.matchesSessionHost(URL(string: "https://www.douyin.com/video/1")!))
    XCTAssertFalse(DouyinURL.matchesSessionHost(URL(string: "https://v.evil-douyin.com/x")!))
    XCTAssertFalse(DouyinURL.matchesSessionHost(URL(string: "https://douyin.com.evil.test/")!))
    // 明文 http 不带 Cookie。
    XCTAssertFalse(DouyinURL.matchesSessionHost(URL(string: "http://www.douyin.com/video/1")!))
  }
}

/// 小红书登录墙外壳的识别。
final class XiaohongshuLoginWallTests: XCTestCase {
  func testSiteBoilerplateIsRejectedEvenWhenDescriptionIsNonEmpty() {
    // 会话过期时服务端返回 200 + 外壳 + 站点宣传语。只挡「描述为空」挡不住它，
    // 会入库一条标题「小红书」、正文是宣传语的记录，看着还挺像回事。
    let expired = """
      <html><head>
      <meta property="og:title" content="小红书 - 你的生活指南">
      <meta property="og:description" content="小红书是年轻人的生活方式平台，标记我的生活。">
      </head></html>
      """
    XCTAssertNil(XiaohongshuPageParser.parse(html: expired))

    // 标题恰好是裸站名（去尾正则要求前置分隔符，清不掉）也要挡住。
    let bareTitle = """
      <html><head>
      <meta property="og:title" content="小红书">
      <meta property="og:description" content="这段描述本身没有宣传语特征但标题是站名">
      </head></html>
      """
    XCTAssertNil(XiaohongshuPageParser.parse(html: bareTitle))
  }

  func testRealNoteStillParses() {
    let note = """
      <html><head>
      <meta property="og:title" content="三天两夜厦门citywalk路线 - 小红书">
      <meta property="og:description" content="第一天先去鼓浪屿，建议早上八点前上岛。">
      </head></html>
      """
    XCTAssertEqual(XiaohongshuPageParser.parse(html: note)?.title, "三天两夜厦门citywalk路线")
  }
}
