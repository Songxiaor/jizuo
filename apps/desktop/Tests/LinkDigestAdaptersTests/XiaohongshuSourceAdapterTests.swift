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

    XCTAssertEqual(plain.fetched, [shortURL, noteURL])
    XCTAssertEqual(resources.requestedHosts, ["www.xiaohongshu.com"])
    XCTAssertTrue(document.text.contains("夏天手腕最怕闷热"))
    XCTAssertTrue(document.text.contains("sns-webpic-qc.xhscdn.com"))
    XCTAssertEqual(document.platform, "xiaohongshu")
    XCTAssertEqual(document.method, "xiaohongshu_session_html")
    XCTAssertEqual(document.completeness, "best_effort")
  }

  func testInitialStateFixtureFillsFrontmatterAndFiltersImages() throws {
    let html = XiaohongshuFixtures.notePageHTML
    let detail = XiaohongshuPageParser.parseInitialState(
      html: html,
      noteID: XiaohongshuFixtures.noteID
    )
    XCTAssertEqual(detail?.title, "周末手冲咖啡入门")
    XCTAssertEqual(detail?.author, "夹具作者")
    XCTAssertEqual(detail?.publishedAt, "2026-08-27T19:01:29.000Z")
    XCTAssertEqual(detail?.likes, "1.2万")
    XCTAssertEqual(detail?.comments, "56")
    XCTAssertEqual(detail?.shares, "12")
    XCTAssertEqual(detail?.collects, "800")
    XCTAssertEqual(
      detail?.imageURLs.map(\.absoluteString),
      [
        "https://sns-webpic-qc.xhscdn.com/notes/fixture-a.jpg",
        "https://sns-avatar-qc.xhscdn.com/notes/fixture-b.jpg",
      ]
    )
    XCTAssertFalse(detail?.imageURLs.contains { $0.host?.contains("example.com") == true } == true)

    let text = XiaohongshuPageParser.documentText(from: try XCTUnwrap(detail))
    let note = MarkdownNoteFrontmatter.parse(text)
    XCTAssertEqual(note.author, "夹具作者")
    XCTAssertEqual(note.published, "2026-08-27T19:01:29.000Z")
    XCTAssertEqual(note.likes, "1.2万")
    XCTAssertEqual(note.comments, "56")
    XCTAssertEqual(note.shares, "12")
    XCTAssertEqual(note.collects, "800")
    XCTAssertTrue(note.body.contains("#手冲咖啡"))
    XCTAssertFalse(note.body.contains("[话题]#"))
    XCTAssertTrue(note.body.contains("#周末日常"))
    XCTAssertTrue(note.body.contains("![](https://sns-webpic-qc.xhscdn.com/notes/fixture-a.jpg)"))
    XCTAssertTrue(note.body.contains("![](https://sns-avatar-qc.xhscdn.com/notes/fixture-b.jpg)"))
    XCTAssertFalse(note.body.contains("example.com"))
    XCTAssertFalse(note.body.contains(XiaohongshuFixtures.noteTitle))
  }

  func testShareLinkWithoutSessionUsesPublicHTMLPath() async throws {
    let noteURL = XiaohongshuFixtures.shareURL
    let plain = XiaohongshuHTMLFetcher(resultURL: noteURL, html: XiaohongshuFixtures.notePageHTML)
    let resources = XiaohongshuUnusedResourceFetcher()
    let adapter = XiaohongshuSourceAdapter(
      fetcher: plain,
      resources: resources,
      cookieHeader: { nil }
    )

    let document = try await adapter.capture(url: noteURL)

    XCTAssertEqual(plain.fetched, [noteURL])
    XCTAssertEqual(resources.requestCount, 0)
    XCTAssertEqual(document.method, "xiaohongshu_public_html")
    XCTAssertEqual(document.completeness, "full_article")
    XCTAssertEqual(document.sourceLabel, "手动链接（小红书笔记）")
    XCTAssertEqual(document.title, XiaohongshuFixtures.noteTitle)
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(document.text).likes, "1.2万")
  }

  func testExpiredShareTokenWithoutSessionThrowsShareLinkExpired() async {
    let noteURL = XiaohongshuFixtures.shareURL
    let expiredURL = URL(string: "https://www.xiaohongshu.com/404?source=note&error_code=300031&error_msg=当前笔记暂时无法浏览")!
    let plain = XiaohongshuHTMLFetcher(resultURL: expiredURL, html: XiaohongshuFixtures.expiredPageHTML)
    let adapter = XiaohongshuSourceAdapter(
      fetcher: plain,
      resources: XiaohongshuUnusedResourceFetcher(),
      cookieHeader: { nil }
    )

    do {
      _ = try await adapter.capture(url: noteURL)
      XCTFail("失效分享链接应当抛 shareLinkExpired")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .shareLinkExpired)
      XCTAssertEqual(
        error.userMessage,
        "这条分享链接已失效（小红书的 xsec_token 有时效），请在小红书 App 里重新复制分享链接。"
      )
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }

  func testPublicShellFallsBackToSessionHTML() async throws {
    let noteURL = URL(string: "https://www.xiaohongshu.com/explore/\(XiaohongshuFixtures.noteID)")!
    let plain = XiaohongshuHTMLFetcher(resultURL: noteURL, html: XiaohongshuFixtures.shellHTML)
    let resources = XiaohongshuSessionResourceFetcher(html: XiaohongshuFixtures.notePageHTML)
    let adapter = XiaohongshuSourceAdapter(
      fetcher: plain,
      resources: resources,
      cookieHeader: { "session=1" }
    )

    let document = try await adapter.capture(url: noteURL)

    XCTAssertEqual(plain.fetched, [noteURL])
    XCTAssertEqual(resources.requestedHosts, ["www.xiaohongshu.com"])
    XCTAssertEqual(document.method, "xiaohongshu_session_html")
    XCTAssertEqual(document.completeness, "full_article")
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(document.text).author, "夹具作者")
  }

  func testShellWithoutTokenOrSessionStillRequiresLogin() async {
    let noteURL = URL(string: "https://www.xiaohongshu.com/explore/\(XiaohongshuFixtures.noteID)")!
    let plain = XiaohongshuHTMLFetcher(resultURL: noteURL, html: XiaohongshuFixtures.shellHTML)
    let adapter = XiaohongshuSourceAdapter(
      fetcher: plain,
      resources: XiaohongshuUnusedResourceFetcher(),
      cookieHeader: { nil }
    )

    do {
      _ = try await adapter.capture(url: noteURL)
      XCTFail("无 token 的外壳应当抛 loginRequired")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .loginRequired)
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }

  func testOGFallbackWritesAuthorFrontmatterNotBodyLine() async throws {
    let noteURL = URL(string: "https://www.xiaohongshu.com/explore/\(XiaohongshuFixtures.noteID)")!
    let ogHTML = """
      <html><head>
      <meta property="og:title" content="三天两夜厦门citywalk路线 - 小红书">
      <meta property="og:description" content="第一天先去鼓浪屿，建议早上八点前上岛。">
      <meta name="og:xhs:note_user_nickname" content="旅行的小张">
      <meta property="og:image" content="https://sns-webpic-qc.xhscdn.com/note/fixture-cover.jpg">
      </head></html>
      """
    let adapter = XiaohongshuSourceAdapter(
      fetcher: XiaohongshuHTMLFetcher(resultURL: noteURL, html: ogHTML),
      resources: XiaohongshuUnusedResourceFetcher(),
      cookieHeader: { nil }
    )

    let document = try await adapter.capture(url: noteURL)
    XCTAssertEqual(document.method, "xiaohongshu_public_html")
    XCTAssertEqual(document.completeness, "best_effort")
    XCTAssertEqual(document.title, "三天两夜厦门citywalk路线")
    let note = MarkdownNoteFrontmatter.parse(document.text)
    XCTAssertEqual(note.author, "旅行的小张")
    XCTAssertFalse(document.text.contains("作者："))
    XCTAssertTrue(note.body.contains("第一天先去鼓浪屿"))
    XCTAssertTrue(note.body.contains("![](https://sns-webpic-qc.xhscdn.com/note/fixture-cover.jpg)"))
  }
}

private enum XiaohongshuFixtures {
  static let noteID = "aabbccddeeff001122334455"
  static let noteTitle = "周末手冲咖啡入门"
  static let shareURL = URL(
    string: "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=TESTTOKEN&xsec_source=app_share"
  )!

  static let notePageHTML = """
    <html><head><title>\(noteTitle) - 小红书</title></head><body>
    <script>window.__INITIAL_STATE__={"note":{"firstNoteId":undefined,"currentNoteId":"\(noteID)","noteDetailMap":{"\(noteID)":{"note":{"title":"\(noteTitle)","desc":"水温控制在92度左右#手冲咖啡[话题]#","type":"normal","time":1787857289000,"ipLocation":"上海","user":{"nickname":"夹具作者","userId":"userfixture01"},"interactInfo":{"likedCount":"1.2万","collectedCount":"800","commentCount":"56","shareCount":"12"},"imageList":[{"urlDefault":"https://sns-webpic-qc.xhscdn.com/notes/fixture-a.jpg","infoList":[]},{"urlDefault":"https://ci.example.com/not-allowed.jpg","infoList":[]},{"urlDefault":"https://sns-avatar-qc.xhscdn.com/notes/fixture-b.jpg","infoList":[]}],"tagList":[{"name":"手冲咖啡","type":"topic"},{"name":"周末日常","type":"topic"}]}}}}}</script>
    </body></html>
    """

  static let expiredPageHTML = """
    <html><head><title>小红书 - 你访问的页面不见了</title></head><body>
    <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{}}}</script>
    </body></html>
    """

  static let shellHTML = """
    <html><head>
    <meta property="og:title" content="小红书 - 你的生活指南">
    <meta property="og:description" content="小红书是年轻人的生活方式平台，标记我的生活。">
    </head><body>更多有趣内容尽在小红书</body></html>
    """
}

private final class XiaohongshuHTMLFetcher: WebPageFetcher, @unchecked Sendable {
  let resultURL: URL
  let html: String
  private let lock = NSLock()
  private var seen: [URL] = []

  init(resultURL: URL, html: String) {
    self.resultURL = resultURL
    self.html = html
  }

  var fetched: [URL] { lock.withLock { seen } }

  func fetch(url: URL) async throws -> WebPageFetchResult {
    lock.withLock { seen.append(url) }
    return .init(url: resultURL, html: html, contentType: "text/html")
  }
}

private final class XiaohongshuUnusedResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var requestCount: Int { lock.withLock { count } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    _ = request
    lock.withLock { count += 1 }
    throw ManualLinkError.network
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
