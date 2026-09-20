import Foundation
import LinkDigestIOS
import LinkDigestShared
import XCTest

final class LinkHTMLExtractorTests: XCTestCase {
  func testExtractsOgTitleAndArticleBody() {
    let html = """
    <html>
      <head>
        <meta property="og:title" content="开放图谱标题 &amp; 测试" />
        <title>被忽略的 title</title>
      </head>
      <body>
        <nav>导航应被忽略</nav>
        <article>
          <p>第一段：Hello &#x4F60;&#22909; &amp; welcome。</p>
          <p>第二段提供足够长度，方便抽取器认定正文有效。</p>
        </article>
      </body>
    </html>
    """
    let page = LinkHTMLExtractor.extract(html: html)
    XCTAssertEqual(page.title, "开放图谱标题 & 测试")
    XCTAssertTrue(page.body.contains("Hello 你好 & welcome"))
    XCTAssertTrue(page.body.contains("第二段提供足够长度"))
    XCTAssertFalse(page.body.contains("<p>"))
    XCTAssertFalse(page.body.contains("script"))
  }

  func testFallsBackToTitleAndBodyWhenNoArticle() {
    let html = """
    <html><head><title>  简单标题  </title></head>
    <body>
      <script>var x = 1;</script>
      <style>.x{color:red}</style>
      <p>正文开头。这里写够二十个以上的字符，保证 body 通过最小长度检查。</p>
    </body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html)
    XCTAssertEqual(page.title, "简单标题")
    XCTAssertTrue(page.body.contains("正文开头"))
    XCTAssertFalse(page.body.contains("var x"))
    XCTAssertFalse(page.body.contains("color:red"))
  }

  func testTwitterTitlePreferredOverDocumentTitle() {
    let html = """
    <html><head>
      <meta name="twitter:title" content="推特标题">
      <title>文档标题</title>
    </head><body><main><p>Main content with enough characters for extraction path.</p></main></body></html>
    """
    XCTAssertEqual(LinkHTMLExtractor.extractTitle(from: html), "推特标题")
  }

  func testMetaDescriptionFallbackWhenBodyTooShort() {
    let html = """
    <html><head>
      <title>短页</title>
      <meta name="description" content="这是一段足够长的 meta 描述，用作正文回退内容。">
    </head><body><p>太短</p></body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html)
    XCTAssertEqual(page.title, "短页")
    XCTAssertEqual(page.description, "这是一段足够长的 meta 描述，用作正文回退内容。")
    XCTAssertTrue(page.body.contains("meta 描述"))
  }

  func testPrefersLongerMainOverShortArticle() {
    let html = """
    <html><body>
      <article><p>短文章块</p></article>
      <main>
        <p>主栏正文更长：这里写足够多的汉字与标点，保证评分高于短 article，从而被抽取器选中。</p>
        <p>第二段继续加长，避免误选导航或短卡片。</p>
      </main>
    </body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html)
    XCTAssertTrue(page.body.contains("主栏正文更长"))
    XCTAssertFalse(page.body.contains("短文章块"))
  }

  func testCharsetHintFromMeta() {
    let html = #"<html><head><meta charset="gb18030"><title>t</title></head><body></body></html>"#
    XCTAssertEqual(LinkHTMLExtractor.charsetHint(from: html)?.lowercased(), "gb18030")

    let httpEquiv = """
    <meta http-equiv="Content-Type" content="text/html; charset=GBK">
    """
    XCTAssertEqual(LinkHTMLExtractor.charsetHint(from: httpEquiv)?.lowercased(), "gbk")
  }

  func testStripsNavHeaderFooterFromBody() {
    let html = """
    <html><body>
      <nav>导航菜单请忽略这些字</nav>
      <header>站点顶栏请忽略</header>
      <article>
        <p>真正正文第一段，长度足够通过最小门槛字符检查一二三四五六七八。</p>
      </article>
      <footer>页脚版权请忽略</footer>
    </body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html)
    XCTAssertTrue(page.body.contains("真正正文第一段"))
    XCTAssertFalse(page.body.contains("导航菜单"))
    XCTAssertFalse(page.body.contains("页脚版权"))
  }

  func testXiaohongshuPrefersOgDescriptionWhenShellBody() {
    let html = """
    <html><head>
      <meta property="og:title" content="旅行手账">
      <meta property="og:description" content="周末去海边，风很大，但阳光很好，拍了好多照片分享给你。">
      <title>小红书</title>
    </head><body><p>登录后查看更多</p></body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html, platformID: "xiaohongshu")
    XCTAssertEqual(page.title, "旅行手账")
    XCTAssertTrue(page.body.contains("周末去海边"))
  }

  func testWechatPrefersJsContent() {
    let html = """
    <html><body>
      <div id="js_content"><p>公众号正文第一段，这里写足够多的字保证通过抽取门槛检查。</p></div>
      <div>侧栏推荐请忽略</div>
    </body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html, platformID: "wechat")
    XCTAssertTrue(page.body.contains("公众号正文第一段"))
    XCTAssertFalse(page.body.contains("侧栏推荐"))
  }

  func testDouyinAndWeiboPreferOgDescriptionWhenShell() {
    let douyin = """
    <html><head>
      <meta property="og:title" content="抖音短视频">
      <meta property="og:description" content="这条抖音公开页简介写得足够长，用来验证登录墙壳页时的回退抽取。">
    </head><body><p>打开抖音 App 查看更多</p></body></html>
    """
    let douyinPage = LinkHTMLExtractor.extract(html: douyin, platformID: "douyin")
    XCTAssertTrue(douyinPage.body.contains("抖音公开页简介"))

    let weibo = """
    <html><head>
      <meta property="og:description" content="微博公开页简介也需要足够长度，才能在 SPA 壳里当作可读正文备用。">
      <title>微博</title>
    </head><body><p>登录</p></body></html>
    """
    let weiboPage = LinkHTMLExtractor.extract(html: weibo, platformID: "weibo")
    XCTAssertTrue(weiboPage.body.contains("微博公开页简介"))
  }

  func testXPrefersOgDescriptionWhenShell() {
    let html = """
    <html><head>
      <meta property="og:title" content="@user on X">
      <meta property="og:description" content="今天聊一下 iOS Companion 的抓取边界，公开页往往只有这段简介可见。">
    </head><body><p>Something went wrong. Log in.</p></body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html, platformID: "x")
    XCTAssertTrue(page.body.contains("iOS Companion"))
  }

  func testYouTubeAndBilibiliPreferOgWhenThinBody() {
    let yt = """
    <html><head>
      <meta property="og:title" content="Demo Video">
      <meta property="og:description" content="这是 YouTube 公开页简介，播放器壳里几乎没有可读正文。">
    </head><body><div id="player"></div></body></html>
    """
    let ytPage = LinkHTMLExtractor.extract(html: yt, platformID: "youtube")
    XCTAssertTrue(ytPage.body.contains("YouTube 公开页简介"))

    let bili = """
    <html><head>
      <meta property="og:description" content="B 站简介也够短，但至少比空壳有用。">
    </head>
    <body><div id="v_desc"><p>B 站视频简介正文，写得足够长才能通过抽取门槛检查一二三四。</p></div></body></html>
    """
    let biliPage = LinkHTMLExtractor.extract(html: bili, platformID: "bilibili")
    XCTAssertTrue(biliPage.body.contains("B 站视频简介正文"))
  }

  func testZhihuPrefersRichText() {
    let html = """
    <html><body>
      <div class="RichText ztext">知乎回答正文，这里有足够多的字保证通过抽取门槛检查，不要被导航干扰。</div>
      <nav>热榜</nav>
    </body></html>
    """
    let page = LinkHTMLExtractor.extract(html: html, platformID: "zhihu")
    XCTAssertTrue(page.body.contains("知乎回答正文"))
    XCTAssertFalse(page.body.contains("热榜"))
  }

  func testJSONLDArticleBody() {
    let html = """
    <html><head>
      <script type="application/ld+json">
      {"@type":"SocialMediaPosting","articleBody":"JSON-LD 里的帖文正文，长度足够通过抽取门槛检查一二三四五六。"}
      </script>
    </head><body><p>壳</p></body></html>
    """
    let body = LinkHTMLExtractor.extractJSONLDArticleBody(from: html)
    XCTAssertTrue(body?.contains("JSON-LD 里的帖文正文") == true)
    let page = LinkHTMLExtractor.extract(html: html, platformID: "x")
    XCTAssertTrue(page.body.contains("JSON-LD 里的帖文正文"))
  }
}

final class IOSContentPlatformTests: XCTestCase {
  func testRecognizesPrimaryPlatforms() {
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://v.douyin.com/abc")?.id, "douyin")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://x.com/user/status/1")?.id, "x")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://www.youtube.com/watch?v=1")?.id, "youtube")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://youtu.be/1")?.id, "youtube")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://www.bilibili.com/video/BV1")?.id, "bilibili")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://www.xiaohongshu.com/explore/1")?.id, "xiaohongshu")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://mp.weixin.qq.com/s/x")?.id, "wechat")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://www.zhihu.com/question/1")?.id, "zhihu")
    XCTAssertEqual(IOSContentPlatform.recognize(urlString: "https://weibo.com/1")?.id, "weibo")
    XCTAssertNil(IOSContentPlatform.recognize(urlString: "https://example.com/a"))
  }

  func testLayeredFetchWarningIncludesPlatformHint() {
    let platform = IOSContentPlatform.recognize(urlString: "https://www.xiaohongshu.com/explore/1")
    let message = LinkPageFetcher.layeredFetchWarning(base: "正文过短", platform: platform)
    XCTAssertTrue(message.contains("【小红书】"))
    XCTAssertTrue(message.contains("正文过短"))
    XCTAssertTrue(message.contains("登录墙") || message.contains("og:"))
  }
}

final class LinkPageFetcherBehaviorTests: XCTestCase {
  func testNonHTMLContentTypeReturnsReadableWarning() async {
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/pdf"]
      )!
      return (response, Data("%PDF-1.4".utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let fetcher = LinkPageFetcher(session: URLSession(configuration: config), timeoutSeconds: 5)
    let result = await fetcher.fetch(urlString: "https://example.com/file.pdf")
    XCTAssertEqual(result.body, "（待抓取正文）")
    XCTAssertTrue(result.warningMessage?.contains("不是网页") == true)
  }

  func testHTTP404ReturnsReadableWarningAndPlaceholder() async {
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )!
      return (response, Data("<html>missing</html>".utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let fetcher = LinkPageFetcher(session: URLSession(configuration: config))
    let result = await fetcher.fetch(urlString: "https://example.com/missing")
    XCTAssertEqual(result.body, "（待抓取正文）")
    XCTAssertTrue(result.warningMessage?.contains("404") == true)
  }

  func testMetaCharsetUsedWhenHeaderMissing() async {
    // "测试" in GB18030；正文用 ASCII，避免整页混编码导致 GB 解码失败。
    let gbTitle = Data([0xb2, 0xe2, 0xca, 0xd4])
    var html = Data("<html><head><meta charset=\"gb18030\"><title>".utf8)
    html.append(gbTitle)
    html.append(
      contentsOf: """
      </title></head><body><article><p>ASCII body long enough to pass the minimum extraction threshold for link fetcher tests.</p></article></body></html>
      """.utf8
    )

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )!
      return (response, html)
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let fetcher = LinkPageFetcher(session: URLSession(configuration: config))
    let result = await fetcher.fetch(urlString: "https://example.com/gb")
    XCTAssertNil(result.warningMessage)
    XCTAssertEqual(result.title, "测试")
    XCTAssertTrue(result.body.contains("ASCII body long enough"))
  }
}

final class IOSProviderProfileTests: XCTestCase {
  func testDecodeMigratesLoneModelNameIntoAddedModels() throws {
    let json = Data(#"{"baseURL":"https://opencode.ai/zen/go/v1","modelName":"glm-5.3-flash"}"#.utf8)
    let profile = try JSONDecoder().decode(IOSProviderProfile.self, from: json)
    XCTAssertEqual(profile.modelName, "glm-5.3-flash")
    XCTAssertEqual(profile.addedModels, ["glm-5.3-flash"])
  }

  func testSaveRoundTripKeepsAddedModels() {
    let defaults = UserDefaults(suiteName: "test.ios.profile.models.\(UUID().uuidString)")!
    let store = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    store.save(
      IOSProviderProfile(
        baseURL: "https://opencode.ai/zen/go/v1",
        modelName: "kimi-k2.6",
        addedModels: ["glm-5.3-flash", "kimi-k2.6"],
        outputLanguage: "简体中文"
      )
    )
    let loaded = store.load()
    XCTAssertEqual(loaded.modelName, "kimi-k2.6")
    XCTAssertEqual(loaded.addedModels, ["glm-5.3-flash", "kimi-k2.6"])
  }
}

final class OpenAICompatibleModelCatalogTests: XCTestCase {
  func testModelsURLAppendsPath() throws {
    let url = try OpenAICompatibleModelCatalog.modelsURL(baseURL: "https://opencode.ai/zen/go/v1")
    XCTAssertEqual(url.absoluteString, "https://opencode.ai/zen/go/v1/models")
  }

  func testListModelsParsesIDs() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertTrue(request.url?.absoluteString.hasSuffix("/models") == true)
      let json = #"{"object":"list","data":[{"id":"glm-5.3-flash"},{"id":"kimi-k2.6"},{"id":"glm-5.3-flash"}]}"#
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(json.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let catalog = OpenAICompatibleModelCatalog(session: URLSession(configuration: config))
    let models = try await catalog.listModels(
      baseURL: "https://opencode.ai/zen/go/v1",
      apiKey: "fake"
    )
    XCTAssertEqual(models, ["glm-5.3-flash", "kimi-k2.6"])
  }

  func testListModelsSurfacesHTTP404() async {
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data("{}".utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let catalog = OpenAICompatibleModelCatalog(session: URLSession(configuration: config))
    do {
      _ = try await catalog.listModels(baseURL: "https://api.example.com/v1", apiKey: "k")
      XCTFail("expected error")
    } catch let error as ModelCatalogError {
      XCTAssertEqual(error, .httpStatus(404))
      XCTAssertFalse((error.errorDescription ?? "").contains("{"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }
}

final class OpenAICompatibleSummarizerTests: XCTestCase {
  func testChatCompletionsURLAppendsPath() throws {
    let url = try OpenAICompatibleSummarizer.chatCompletionsURL(baseURL: "https://example.com/v1/")
    XCTAssertEqual(url.absoluteString, "https://example.com/v1/chat/completions")
  }

  func testRejectsCompletedChatEndpoint() {
    XCTAssertThrowsError(
      try OpenAICompatibleSummarizer.chatCompletionsURL(
        baseURL: "https://example.com/v1/chat/completions"
      )
    )
  }

  func testSummarizeParsesChoicesWithInjectedSession() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-real")
      let responseJSON = """
      {"choices":[{"message":{"role":"assistant","content":"这是一条测试总结。"}}]}
      """
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let summarizer = OpenAICompatibleSummarizer(session: session)

    let summary = try await summarizer.summarize(
      title: "标题",
      body: "足够长的正文内容用于总结测试。",
      sourceURL: "https://example.com/a",
      baseURL: "https://api.example.com/v1",
      model: "gpt-test",
      apiKey: "test-key-not-real"
    )
    XCTAssertEqual(summary, "这是一条测试总结。")
  }

  func testSummarizeSurfacesHTTPError() async {
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data("{\"error\":{\"message\":\"bad key\"}}".utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let summarizer = OpenAICompatibleSummarizer(session: URLSession(configuration: config))

    do {
      _ = try await summarizer.summarize(
        title: "t",
        body: "body text for error path",
        sourceURL: nil,
        baseURL: "https://api.example.com/v1",
        model: "m",
        apiKey: "fake"
      )
      XCTFail("expected error")
    } catch let error as SummarizerError {
      XCTAssertEqual(error, .httpStatus(401))
      XCTAssertFalse((error.errorDescription ?? "").contains("bad key"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }
}

@MainActor
final class NotesViewModelDEFTests: XCTestCase {
  func testCreateLinkNoteFetchingUsesExtractorViaFetcher() async {
    MockURLProtocol.requestHandler = { request in
      let html = """
      <html><head><title>抓取标题</title></head>
      <body><article><p>自动抓取的正文，长度要超过抽取器的最小门槛字符数。</p></article></body></html>
      """
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html; charset=utf-8"]
      )!
      return (response, Data(html.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let fetcher = LinkPageFetcher(session: URLSession(configuration: config))
    let store = InMemoryNoteCardStore()
    let model = NotesViewModel(
      store: store,
      linkFetcher: fetcher,
      profileStore: UserDefaultsIOSProviderProfileStore(
        defaults: UserDefaults(suiteName: "test.notes.def.\(UUID().uuidString)")!
      ),
      apiKeyStore: InMemoryIOSAPIKeyStore()
    )

    let warning = await model.createLinkNoteFetching(
      url: "https://example.com/post",
      titleOverride: nil,
      bodyOverride: nil,
      summary: nil
    )
    XCTAssertNil(warning)
    XCTAssertEqual(model.notes.count, 1)
    XCTAssertEqual(model.notes.first?.kind, .link)
    XCTAssertEqual(model.notes.first?.title, "抓取标题")
    XCTAssertTrue(model.notes.first?.body.contains("自动抓取的正文") == true)
  }

  func testCreateLinkNoteFetchingStillSavesOnHTTPFailure() async {
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 403,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )!
      return (response, Data("forbidden".utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      linkFetcher: LinkPageFetcher(session: URLSession(configuration: config)),
      profileStore: UserDefaultsIOSProviderProfileStore(
        defaults: UserDefaults(suiteName: "test.notes.fetch.fail.\(UUID().uuidString)")!
      ),
      apiKeyStore: InMemoryIOSAPIKeyStore()
    )

    let warning = await model.createLinkNoteFetching(
      url: "https://www.xiaohongshu.com/explore/private",
      titleOverride: nil,
      bodyOverride: nil,
      summary: nil
    )
    XCTAssertNotNil(warning)
    XCTAssertTrue(warning?.contains("403") == true)
    XCTAssertEqual(model.notes.count, 1)
    XCTAssertEqual(model.notes.first?.sourceURL, "https://www.xiaohongshu.com/explore/private")
    let body = model.notes.first?.body ?? ""
    XCTAssertTrue(body.contains(NotesViewModel.fetchWarningPrefix))
    XCTAssertTrue(body.contains("（待抓取正文）"))
    XCTAssertTrue(body.contains("【小红书】") || warning?.contains("小红书") == true)
  }

  func testCancelGenerationClearsBusyFlagsWithoutError() async {
    MockURLProtocol.requestHandler = { _ in
      // 同步阻塞，模拟慢请求，便于测试中途取消。
      Thread.sleep(forTimeInterval: 1.5)
      let responseJSON = #"{"choices":[{"message":{"content":"慢回复"}}]}"#
      let response = HTTPURLResponse(
        url: URL(string: "https://api.example.com/v1/chat/completions")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let defaults = UserDefaults(suiteName: "test.notes.cancel.\(UUID().uuidString)")!
    let profileStore = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    profileStore.save(IOSProviderProfile(baseURL: "https://api.example.com/v1", modelName: "m1"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      summarizer: OpenAICompatibleSummarizer(session: URLSession(configuration: config)),
      profileStore: profileStore,
      apiKeyStore: InMemoryIOSAPIKeyStore(seed: "fake-key")
    )
    await model.createLinkNote(
      url: "https://example.com/a",
      title: "T",
      body: "足够长的正文用来触发总结请求。",
      summary: nil
    )
    guard let card = model.notes.first else { return XCTFail("missing note") }

    let summarizeTask = Task { await model.summarizeNote(card) }
    try? await Task.sleep(nanoseconds: 120_000_000)
    model.cancelGeneration()
    await summarizeTask.value
    XCTAssertFalse(model.isGenerating)
    XCTAssertNil(model.summarizeError)
    XCTAssertNil(model.notes.first?.summary)
  }

  func testSummarizeNoteWritesSummaryWithInjectedPorts() async {
    MockURLProtocol.requestHandler = { request in
      let responseJSON = #"{"choices":[{"message":{"content":"注入总结"}}]}"#
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let defaults = UserDefaults(suiteName: "test.notes.summary.\(UUID().uuidString)")!
    let profileStore = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    profileStore.save(IOSProviderProfile(baseURL: "https://api.example.com/v1", modelName: "m1"))
    let keyStore = InMemoryIOSAPIKeyStore(seed: "fake-key")

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let summarizer = OpenAICompatibleSummarizer(session: URLSession(configuration: config))
    let store = InMemoryNoteCardStore()
    let model = NotesViewModel(
      store: store,
      summarizer: summarizer,
      profileStore: profileStore,
      apiKeyStore: keyStore
    )
    await model.createLinkNote(
      url: "https://example.com/x",
      title: "链",
      body: "正文足够长用于总结。",
      summary: nil
    )
    guard let card = model.notes.first else {
      return XCTFail("missing note")
    }
    await model.summarizeNote(card)
    XCTAssertNil(model.summarizeError)
    XCTAssertEqual(model.notes.first?.summary, "注入总结")
  }

  func testTranslateNoteWritesTranslation() async {
    MockURLProtocol.requestHandler = { request in
      let responseJSON = #"{"choices":[{"message":{"content":"注入译文"}}]}"#
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let defaults = UserDefaults(suiteName: "test.notes.translate.\(UUID().uuidString)")!
    let profileStore = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    profileStore.save(
      IOSProviderProfile(
        baseURL: "https://api.example.com/v1",
        modelName: "m1",
        outputLanguage: "简体中文"
      )
    )
    let keyStore = InMemoryIOSAPIKeyStore(seed: "fake-key")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      summarizer: OpenAICompatibleSummarizer(session: URLSession(configuration: config)),
      profileStore: profileStore,
      apiKeyStore: keyStore
    )
    await model.createLinkNote(
      url: "https://example.com/en",
      title: "Hello",
      body: "Hello world, this is English source text.",
      summary: nil
    )
    guard let card = model.notes.first else { return XCTFail("missing note") }
    await model.translateNote(card)
    XCTAssertNil(model.summarizeError)
    XCTAssertEqual(model.notes.first?.translation, "注入译文")
  }

  func testTranscribeNoteUsesPageTranscriptPathForYouTube() async {
    MockURLProtocol.requestHandler = { request in
      XCTAssertTrue(request.url?.absoluteString.contains("chat/completions") == true)
      let responseJSON = #"{"choices":[{"message":{"content":"页面转写稿"}}]}"#
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let defaults = UserDefaults(suiteName: "test.notes.transcript.\(UUID().uuidString)")!
    let profileStore = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    profileStore.save(IOSProviderProfile(baseURL: "https://api.example.com/v1", modelName: "m1"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      summarizer: OpenAICompatibleSummarizer(session: URLSession(configuration: config)),
      profileStore: profileStore,
      apiKeyStore: InMemoryIOSAPIKeyStore(seed: "fake-key")
    )
    await model.createLinkNote(
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      title: "Demo",
      body: "这是一段公开页简介，足够整理成转写稿草稿。",
      summary: nil
    )
    guard let card = model.notes.first else { return XCTFail("missing note") }
    await model.transcribeNote(card)
    XCTAssertNil(model.summarizeError)
    let transcript = model.notes.first?.transcript ?? ""
    XCTAssertTrue(transcript.contains(NotesViewModel.pageTranscriptDraftPrefix))
    XCTAssertTrue(transcript.contains("页面转写稿"))
  }

  func testTranscribeNoteUsesAudioPathForDirectMedia() async {
    MockURLProtocol.requestHandler = { request in
      let url = request.url!.absoluteString
      if url.hasSuffix(".mp3") {
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "audio/mpeg"]
        )!
        return (response, Data("fake-mp3".utf8))
      }
      XCTAssertTrue(url.contains("audio/transcriptions"))
      let responseJSON = #"{"text":"直链音频内容"}"#
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(responseJSON.utf8))
    }
    defer { MockURLProtocol.requestHandler = nil }

    let defaults = UserDefaults(suiteName: "test.notes.audio.\(UUID().uuidString)")!
    let profileStore = UserDefaultsIOSProviderProfileStore(defaults: defaults)
    profileStore.save(IOSProviderProfile(baseURL: "https://api.example.com/v1", modelName: "whisper-1"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      summarizer: OpenAICompatibleSummarizer(session: session),
      audioTranscriber: OpenAICompatibleAudioTranscriber(session: session),
      profileStore: profileStore,
      apiKeyStore: InMemoryIOSAPIKeyStore(seed: "fake-key")
    )
    await model.createLinkNote(
      url: "https://cdn.example.com/clip.mp3",
      title: "Audio",
      body: "unused",
      summary: nil
    )
    guard let card = model.notes.first else { return XCTFail("missing note") }
    await model.transcribeNote(card)
    XCTAssertNil(model.summarizeError)
    let transcript = model.notes.first?.transcript ?? ""
    XCTAssertTrue(transcript.contains(NotesViewModel.audioTranscriptPrefix))
    XCTAssertTrue(transcript.contains("直链音频内容"))
  }

  func testFriendlySyncMessageRewritesDeveloperWording() {
    let msg = NotesViewModel.friendlySyncMessage("CloudKit 同步尚未启用（enabled 设为 true）")
    XCTAssertTrue(msg.contains("付费"))
    XCTAssertFalse(msg.contains("enabled"))
  }

  func testOpenCodeGoCatalogFiltersNonChatModels() {
    let base = "https://opencode.ai/zen/go/v1"
    XCTAssertEqual(
      IOSModelCatalogSupport.compatibility(modelID: "glm-5.3-flash", baseURL: base),
      .supported
    )
    XCTAssertEqual(
      IOSModelCatalogSupport.compatibility(modelID: "qwen3.8-flash", baseURL: base),
      .unsupportedTransport
    )
    let sorted = IOSModelCatalogSupport.sortedForDisplay(
      ["qwen3.8-flash", "glm-5.3-flash", "mystery-model"],
      baseURL: base
    )
    XCTAssertEqual(sorted.first, "glm-5.3-flash")
  }

  func testSyncStatusSummaryReflectsSuccessAndFailure() async {
    let remote = InMemoryNoteCardStore()
    let local = InMemoryNoteCardStore()
    let model = NotesViewModel(
      store: local,
      sync: LocalMergeNoteCardSync(remote: remote),
      profileStore: UserDefaultsIOSProviderProfileStore(
        defaults: UserDefaults(suiteName: "test.sync.\(UUID().uuidString)")!
      ),
      apiKeyStore: InMemoryIOSAPIKeyStore()
    )
    await model.synchronize()
    XCTAssertTrue(model.syncStatusSummary.hasPrefix("已同步"))
    XCTAssertEqual(model.syncStatus.phase, .idle)
    XCTAssertNotNil(model.syncStatus.lastSuccessAtMilliseconds)

    let failing = NotesViewModel(
      store: local,
      sync: FailingNoteCardSync(message: "模拟同步失败"),
      profileStore: UserDefaultsIOSProviderProfileStore(
        defaults: UserDefaults(suiteName: "test.sync.fail.\(UUID().uuidString)")!
      ),
      apiKeyStore: InMemoryIOSAPIKeyStore()
    )
    await failing.synchronize()
    XCTAssertEqual(failing.syncStatus.phase, .failed)
    XCTAssertEqual(failing.syncStatusSummary, "模拟同步失败")
  }
}

private struct FailingNoteCardSync: NoteCardSyncing {
  let message: String
  func synchronize(local: NoteCardStore) async throws -> NoteSyncStatus {
    NoteSyncStatus(phase: .failed, lastErrorMessage: message)
  }
}

private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = MockURLProtocol.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
