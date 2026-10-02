import XCTest
@testable import LinkDigestCore

/// 2026-10-02 抓取完整度测试里找到的问题：App 贴链接挑错正文、删掉图片、把验证页当正文。
final class CaptureCompletenessTests: XCTestCase {
  // MARK: - 直读 HTML（App 贴链接的备用路径）

  func testCardWallArticlesYieldToMainContent() throws {
    let card = "<article><h3>推荐卡片</h3><p>另一篇文章的简介，只有一句话。</p></article>"
    let body = String(repeating: "<p>这是正文里真正的一段内容，讲清楚这篇文章要说的事情。</p>", count: 20)
    let html = """
    <html><head><title>正文标题</title></head><body><main>
    <h1>正文标题</h1>\(body)
    <section>\(card)\(card)\(card)</section>
    </main></body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertTrue(page.text.contains("真正的一段内容"))
    XCTAssertGreaterThan(page.text.count, 400)
  }

  func testSingleArticleStillWins() throws {
    let html = """
    <html><body><nav>首页 关于 联系 订阅 登录 注册 更多栏目 更多栏目 更多栏目</nav>
    <article><p>一篇很短的文章正文，但它是页面上唯一的文章区块。</p></article>
    <footer>版权所有 备案号 友情链接 友情链接 友情链接 友情链接 友情链接</footer></body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertTrue(page.text.contains("唯一的文章区块"))
    XCTAssertFalse(page.text.contains("友情链接"))
  }

  func testContentImagesSurviveAndDecorationIsDropped() throws {
    let html = """
    <html><body><article>
    <p>第一段正文，下面是一张配图，用来说明这个结论。</p>
    <img class="avatar" src="https://cdn.example.com/u/1.png">
    <img src="https://cdn.example.com/spacer.gif" width="1" height="1">
    <img data-src="https://cdn.example.com/real.jpg" src="data:image/gif;base64,R0lGOD" alt="示意图">
    <img src="/images/chart.png" alt="图表">
    <img src="https://cdn.example.com/bel-7.gif" width="69" height="357" usemap="#nav">
    <p>第二段正文，接着上面的图继续往下讲。</p>
    </article></body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertTrue(page.text.contains("![示意图](https://cdn.example.com/real.jpg)"))
    XCTAssertTrue(page.text.contains("![图表](/images/chart.png)"))
    XCTAssertFalse(page.text.contains("u/1.png"))
    XCTAssertFalse(page.text.contains("spacer.gif"))
    XCTAssertFalse(page.text.contains("bel-7.gif"))
    let resolved = MarkdownImageURLResolver.resolvingRelativeImages(
      in: page.text, baseURL: URL(string: "https://blog.example.com/post/1")!
    )
    XCTAssertTrue(resolved.contains("![图表](https://blog.example.com/images/chart.png)"))
  }

  // MARK: - 隐藏网页（App 贴链接的主路径）

  private let pageURL = URL(string: "https://example.com/post")!

  private func json(_ fields: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
  }

  func testRenderedPageBecomesFullArticleDocument() throws {
    let text = String(repeating: "正文内容。", count: 30)
    let document = try RenderedPageExtraction.document(
      json: json(["title": "标题", "url": pageURL.absoluteString, "text": text]),
      requestedURL: pageURL
    )
    XCTAssertEqual(document.method, "rendered_dom")
    XCTAssertEqual(document.completeness, "full_article")
    XCTAssertEqual(document.text, text)
  }

  func testSoftIssueWithSubstantialTextIsKeptAsVisibleOnly() throws {
    let text = String(repeating: "登录后可见的正文。", count: 30)
    let document = try RenderedPageExtraction.document(
      json: json(["text": text, "captureIssue": "CAPTURE_LOGIN_WALL"]),
      requestedURL: pageURL
    )
    XCTAssertEqual(document.completeness, "visible_only")
  }

  func testHardIssuesAndShortSoftIssuesAreRejected() {
    XCTAssertThrowsError(try RenderedPageExtraction.document(
      json: json(["text": String(repeating: "验证", count: 200), "captureIssue": "CAPTURE_SECURITY_CHALLENGE"]),
      requestedURL: pageURL
    )) { XCTAssertEqual($0 as? ManualLinkError, .verificationRequired) }
    XCTAssertThrowsError(try RenderedPageExtraction.document(
      json: json(["text": "请登录", "captureIssue": "CAPTURE_LOGIN_WALL"]),
      requestedURL: pageURL
    )) { XCTAssertEqual($0 as? ManualLinkError, .loginRequired) }
  }

  func testZhihuVerificationRedirectIsNotSavedAsContent() {
    let unhuman = "https://www.zhihu.com/account/unhuman?type=U4E3Z1&need_login=true"
    XCTAssertThrowsError(try RenderedPageExtraction.document(
      json: json(["url": unhuman, "text": "请您登录后查看更多专业优质内容。想来知乎工作？请发送邮件到 jobs@zhihu.com"]),
      requestedURL: URL(string: "https://www.zhihu.com/question/1/answer/2")!
    )) { XCTAssertEqual($0 as? ManualLinkError, .verificationRequired) }
  }

  func testCloudflareBlockPageIsNotSavedAsContent() {
    let text = "Please enable cookies. Sorry, you have been blocked. You are unable to access medium.com. Cloudflare Ray ID: a44107d90b534e41"
    XCTAssertThrowsError(try RenderedPageExtraction.document(
      json: json(["url": "https://medium.com/p/abc", "text": text]),
      requestedURL: URL(string: "https://medium.com/p/abc")!
    )) { XCTAssertEqual($0 as? ManualLinkError, .verificationRequired) }
  }

  func testLoginRedirectIsNotSavedAsContent() {
    XCTAssertThrowsError(try RenderedPageExtraction.document(
      json: json(["url": "https://www.zhihu.com/signin?next=%2Fquestion%2F1", "text": String(repeating: "其他方式登录 ", count: 10)]),
      requestedURL: URL(string: "https://www.zhihu.com/question/1/answer/2")!
    )) { XCTAssertEqual($0 as? ManualLinkError, .loginRequired) }
    XCTAssertFalse(RenderedPageExtraction.isLoginRedirect(
      from: URL(string: "https://example.com/login-tips")!, to: URL(string: "https://example.com/login-tips")!
    ))
  }

  func testMediumMemberOnlyPreviewIsMarkedPartial() {
    let medium = URL(string: "https://medium.com/codetodeploy/a-post-fba295ade37d")!
    XCTAssertTrue(ManualLinkCaptureService.isMemberOnlyPreview(sourceURL: medium, body: "Member-only story\n\n# Title\n\nOpening."))
    XCTAssertFalse(ManualLinkCaptureService.isMemberOnlyPreview(sourceURL: medium, body: "# Title\n\nA free story."))
    XCTAssertFalse(ManualLinkCaptureService.isMemberOnlyPreview(
      sourceURL: URL(string: "https://example.com/p")!, body: "Member-only story"
    ))
  }

  // MARK: - 两种保存方式的区别（写给用户看）

  func testLoginRemindersOnlyForPlatformsThatNeedLogin() {
    XCTAssertEqual(CaptureRouteGuidance.loginPlatform(for: URL(string: "https://www.zhihu.com/question/1/answer/2")!), .zhihu)
    XCTAssertEqual(CaptureRouteGuidance.loginPlatform(for: URL(string: "https://xhslink.com/a/b")!), .xiaohongshu)
    XCTAssertEqual(CaptureRouteGuidance.loginPlatform(for: URL(string: "https://v.douyin.com/abc/")!), .douyin)
    // X 单条帖子走公开接口、B 站登录只影响清晰度：不提醒。
    XCTAssertNil(CaptureRouteGuidance.loginPlatform(for: URL(string: "https://x.com/a/status/1")!))
    XCTAssertNil(CaptureRouteGuidance.loginPlatform(for: URL(string: "https://www.bilibili.com/video/BV1")!))
  }

  func testLoginFailuresNameThePlatformAndBothWayOut() {
    let zhihu = URL(string: "https://www.zhihu.com/question/1/answer/2")!
    let message = CaptureRouteGuidance.failureMessage(for: .verificationRequired, url: zhihu)
    XCTAssertTrue(message.contains("知乎"))
    XCTAssertTrue(message.contains("站点登录"))
    XCTAssertTrue(message.contains("浏览器扩展"))
    XCTAssertEqual(
      CaptureRouteGuidance.failureMessage(for: .network, url: zhihu),
      ManualLinkError.network.userMessage
    )
    XCTAssertEqual(
      CaptureRouteGuidance.failureMessage(for: .verificationRequired, url: URL(string: "https://medium.com/p/1")!),
      ManualLinkError.verificationRequired.userMessage
    )
  }

  /// 小红书事后补读评论打不开原笔记（访问码会过期、不落库）：说清原因和出路，不让人以为要重新登录。
  func testXiaohongshuCommentRefetchExplainsTheMissingShareCode() {
    let note = URL(string: "https://www.xiaohongshu.com/explore/6a97752700000000120026e8")!
    let message = CaptureRouteGuidance.commentsUnavailableMessage(for: note)
    XCTAssertTrue(message?.contains("访问码") == true)
    XCTAssertTrue(message?.contains("浏览器扩展") == true)
    XCTAssertNil(CaptureRouteGuidance.commentsUnavailableMessage(for: URL(string: "https://www.zhihu.com/question/1/answer/2")!))
  }

  /// 评论区要登录才显示全部：提醒只存了未登录可见的部分；小红书点明「登录被挤掉」。
  func testCommentLoginWallNoticeNamesXiaohongshuOneLoginRule() {
    let xhs = CaptureRouteGuidance.commentsLoginWallNotice(for: URL(string: "https://www.xiaohongshu.com/explore/6a9e1c10000000001103a75f")!)
    XCTAssertTrue(xhs.contains("挤掉"))
    XCTAssertTrue(xhs.contains("站点登录"))
    let other = CaptureRouteGuidance.commentsLoginWallNotice(for: URL(string: "https://www.reddit.com/r/x/comments/abc/t/")!)
    XCTAssertFalse(other.contains("小红书"))
  }

  /// YouTube 没拿到字幕时分清两种情况：视频本来没有字幕（不重试、直说），有字幕却没取到（重试、教用户重来）。
  func testYouTubeCaptionStateDecidesRetryAndNotice() throws {
    XCTAssertEqual(RenderedPageExtraction.captionTrackCount(json: json(["text": "x", "captionTrackCount": 0])), 0)
    XCTAssertEqual(RenderedPageExtraction.captionTrackCount(json: json(["text": "x", "captionTrackCount": 3])), 3)
    XCTAssertNil(RenderedPageExtraction.captionTrackCount(json: json(["text": "x"])))

    let video = URL(string: "https://www.youtube.com/watch?v=aircAruvnKk")!
    let withTranscript = try RenderedPageExtraction.document(
      json: json(["text": "# 标题\n\n## 字幕\n\n" + String(repeating: "字幕内容。", count: 500)]), requestedURL: video
    )
    let without = try RenderedPageExtraction.document(
      json: json(["text": "# 标题\n\n## 简介\n\n" + String(repeating: "简介内容。", count: 500)]), requestedURL: video
    )
    XCTAssertTrue(RenderedPageExtraction.hasTranscript(withTranscript))
    XCTAssertFalse(RenderedPageExtraction.hasTranscript(without))
    XCTAssertTrue(RenderedPageExtraction.shouldRetry(without, url: video))

    XCTAssertTrue(RenderedPageExtraction.missingTranscriptNotice(captionTrackCount: 0).contains("本身没有字幕"))
    XCTAssertTrue(RenderedPageExtraction.missingTranscriptNotice(captionTrackCount: 2).contains("仍要重新抓取"))
    XCTAssertTrue(RenderedPageExtraction.missingTranscriptNotice(captionTrackCount: nil).contains("仍要重新抓取"))
  }

  func testYouTubeWatchPagesUseTheVideoScript() {
    XCTAssertTrue(RenderedPageExtraction.isYouTubeWatch(URL(string: "https://www.youtube.com/watch?v=aircAruvnKk")!))
    XCTAssertTrue(RenderedPageExtraction.isYouTubeWatch(URL(string: "https://youtu.be/aircAruvnKk")!))
    XCTAssertFalse(RenderedPageExtraction.isYouTubeWatch(URL(string: "https://www.youtube.com/@3blue1brown")!))
  }

  func testExtractorRunsWithoutEvalSoTrustedTypesPagesAccept() {
    let body = RenderedPageExtraction.functionBody(script: "var extractYoutube=(function(){return 1})();\nextractYoutube;")
    XCTAssertFalse(body.contains("eval"))
    XCTAssertTrue(body.hasSuffix("return JSON.stringify((await extractYoutube) ?? null);"))
  }

  func testBundledExtractorScriptsArePresent() {
    XCTAssertNotNil(RenderedPageExtraction.extractorScript(for: pageURL))
    XCTAssertNotNil(RenderedPageExtraction.extractorScript(for: URL(string: "https://www.youtube.com/watch?v=aircAruvnKk")!))
  }
}
