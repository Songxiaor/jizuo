import XCTest
@testable import LinkDigestCore

final class ManualLinkCaptureTests: XCTestCase {
  func testURLPolicyRejectsPrivateRangesAndOnlyTestPolicyAllowsLoopback() throws {
    let resolver: PublicWebURLPolicy.Resolver = { host in
      ["private.test": "10.0.0.1", "reserved.test": "192.0.2.1", "public.test": "8.8.8.8"][host].map { [$0] } ?? []
    }
    let policy = PublicWebURLPolicy(resolver: resolver)
    XCTAssertNoThrow(try policy.validate(URL(string: "https://public.test/article")!))
    for raw in [
      "http://localhost/a", "https://user:pass@public.test/a", "https://public.test:444/a",
      "http://public.test:443/a", "https://public.test:80/a", "https://private.test/a",
      "https://reserved.test/a", "https://127.0.0.1/a", "https://[::1]/a",
      "https://[::ffff:127.0.0.1]/a", "https://[::ffff:169.254.169.254]/a",
      "https://[fe80::1]/a", "https://[fc00::1]/a", "https://[ff02::1]/a",
      "https://[2001::1]/a", "https://[2001:2::1]/a", "https://[2001:10::1]/a",
      "https://[2001:db8::1]/a", "https://[2002::1]/a", "https://[3fff::1]/a"
    ] {
      XCTAssertThrowsError(try policy.validate(URL(string: raw)!))
    }
    let testPolicy = PublicWebURLPolicy(resolver: resolver, allowLoopbackForTesting: true)
    XCTAssertNoThrow(try testPolicy.validate(URL(string: "http://127.0.0.1/test")!))
  }

  func testURLPolicyAllowsGloballyRoutedIPv6OutsideSpecialUseRanges() throws {
    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    for raw in ["https://[2606:4700::1111]/a", "https://[2a00:1450::200e]/a"] {
      XCTAssertNoThrow(try policy.validate(URL(string: raw)!))
    }
  }

  func testPeerPolicyRejectsDNSRebindTargetsAfterInitialPublicResolution() throws {
    let policy = PublicWebURLPolicy(resolver: { _ in ["8.8.8.8"] })
    XCTAssertNoThrow(try policy.validate(URL(string: "https://rebind.test/article")!))
    for peer in ["127.0.0.1", "169.254.169.254", "::ffff:127.0.0.1"] {
      XCTAssertThrowsError(try policy.validatePeerAddress(peer))
    }
  }

  func testFakeIPIsASeparateProxyDecisionAndNeverBecomesAValidDirectPeer() throws {
    let fakePolicy = PublicWebURLPolicy(resolver: { _ in ["198.18.1.229"] })
    let url = URL(string: "https://public.example/article")!
    XCTAssertEqual(try fakePolicy.routingDecision(for: url), .systemProxyForFakeIP)
    XCTAssertThrowsError(try fakePolicy.validate(url))
    XCTAssertThrowsError(try fakePolicy.validatePeerAddress("198.18.1.229"))

    let mixed = PublicWebURLPolicy(resolver: { _ in ["198.18.1.2", "10.0.0.1"] })
    XCTAssertThrowsError(try mixed.routingDecision(for: url))
    XCTAssertThrowsError(
      try fakePolicy.routingDecision(for: URL(string: "https://198.18.1.229/article")!)
    )
  }

  func testFakeIPPeersAreAdmittedOnlyByTheOptInTransportAndNeverWidenPrivateAccess() throws {
    let url = URL(string: "https://public.example/article")!
    // TUN/透明代理模式：系统层没有 HTTP 代理，直连 fake-IP 交给虚拟网卡是
    // 唯一走得通的路径，所以这条传输显式开口。
    let tunnelled = PublicWebURLPolicy(resolver: { _ in ["198.18.1.229"] }, allowsFakeIPPeers: true)
    XCTAssertEqual(try tunnelled.routingDecision(for: url), .systemProxyForFakeIP)
    XCTAssertNoThrow(try tunnelled.validate(url))
    XCTAssertNoThrow(try tunnelled.validatePeerAddress("198.18.1.229"))

    // 开口只覆盖 fake-IP 段。私有、回环、链路本地一律照拒。
    for address in ["10.0.0.8", "192.168.1.4", "172.16.0.9", "127.0.0.1", "169.254.1.1"] {
      XCTAssertThrowsError(try tunnelled.validatePeerAddress(address), address)
    }
    let privatePolicy = PublicWebURLPolicy(resolver: { _ in ["10.0.0.8"] }, allowsFakeIPPeers: true)
    XCTAssertThrowsError(try privatePolicy.routingDecision(for: url))
    // 混合答案里只要有一个非 fake-IP，仍旧整体拒绝。
    let mixed = PublicWebURLPolicy(resolver: { _ in ["198.18.1.2", "10.0.0.1"] }, allowsFakeIPPeers: true)
    XCTAssertThrowsError(try mixed.routingDecision(for: url))
    // 默认（未开口）的传输行为不变。
    let strict = PublicWebURLPolicy(resolver: { _ in ["198.18.1.229"] })
    XCTAssertThrowsError(try strict.validate(url))
    XCTAssertThrowsError(try strict.validatePeerAddress("198.18.1.229"))
  }

  func testExtractorPrefersArticleRemovesScriptsAndDecodesUnicode() throws {
    let page = try MinimalHTMLExtractor().extract(html: "<html><title>  A &amp; B </title><body>ignore <main>main words</main><article><script>secret()</script><p>Hello &#x4F60;&#22909; &amp; welcome to the article text.</p></article></body></html>")
    XCTAssertEqual(page.title, "A & B")
    XCTAssertEqual(page.text, "Hello 你好 & welcome to the article text.")
  }

  func testExtractorSkipsRoleMainTitleShellAndKeepsSubstackArticle() throws {
    let html = """
    <html><head><meta property="og:title" content="How an obscure decision on a preliminary matter could make a huge difference" /></head>
    <body>
    <div aria-label="Post" role="main" class="single-post-container"><div class="container">
    <article class="typography newsletter-post">
      <h1>How an obscure decision on a preliminary matter could make a huge difference</h1>
      <div class="available-content"><div class="body markup">
        <p>TL:DR Last week’s Upper Tribunal decision contains bombshells for social media companies.</p>
        <p>The second paragraph is here so a title-only capture cannot pass as the article body.</p>
      </div></div>
    </article>
    </div></div>
    </body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertEqual(page.title, "How an obscure decision on a preliminary matter could make a huge difference")
    XCTAssertTrue(page.text.contains("TL:DR Last week"), page.text)
    XCTAssertTrue(page.text.contains("title-only capture cannot pass"), page.text)
  }

  func testExtractorFallsBackMainThenBodyAndRejectsLoginShell() throws {
    XCTAssertEqual(try MinimalHTMLExtractor().extract(html: "<main>Enough words are placed in this main area for extraction.</main>").text, "Enough words are placed in this main area for extraction.")
    XCTAssertEqual(try MinimalHTMLExtractor().extract(html: "<body>Enough words are placed in this body area for extraction.</body>").text, "Enough words are placed in this body area for extraction.")
    XCTAssertThrowsError(try MinimalHTMLExtractor().extract(html: "<body>Please enable JavaScript to continue this page content.</body>")) { XCTAssertEqual($0 as? ManualLinkError, .loginRequired) }
  }

  func testExtractorKeepsProseContainerWithSeveralInlineLinks() throws {
    let html = """
    <html><head><title>Documentation article</title></head><body>
      <div class="document">
        <h1>Documentation article</h1>
        <p>This opening paragraph contains the real article body and enough explanatory prose to outweigh a few ordinary inline links.</p>
        <p>Readers can consult the <a href="/guide">guide</a>, <a href="/api">API reference</a>, and <a href="/faq">FAQ</a> without turning this whole container into navigation.</p>
        <p>The final paragraph must remain available when the page is captured.</p>
      </div>
    </body></html>
    """

    let page = try MinimalHTMLExtractor().extract(html: html)

    XCTAssertTrue(page.text.contains("real article body"), page.text)
    XCTAssertTrue(page.text.contains("final paragraph"), page.text)
  }

  func testExtractorEmitsMarkdownParagraphsHeadingsListsAndKeepsChinesePunctuation() throws {
    let html = """
    <html><head><meta property="og:title" content="中文标题：方法论文章" /></head>
    <body><article>
      <h1>一、先纠正一个认知</h1>
      <p>FDE 的门槛从来不是工程师本人是不是行业专家，而是三件更硬的事。</p>
      <p>结论很明确：谁能先在一个垂直行业里把专家知识资本化成内核——先亏钱做前几个客户。</p>
      <h2>二、把专家知识撬成 SOP</h2>
      <ul>
        <li>抽象是工程师的活，不是专家的活。</li>
        <li>不要让专家写文档！</li>
      </ul>
      <blockquote><p>没有平台内核就没有杠杆。</p></blockquote>
    </article></body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertEqual(page.title, "中文标题：方法论文章")
    // Headings and paragraphs become Markdown structure.
    XCTAssertTrue(page.text.contains("# 一、先纠正一个认知"), page.text)
    XCTAssertTrue(page.text.contains("## 二、把专家知识撬成 SOP"), page.text)
    // Chinese punctuation preserved (。！？：—).
    XCTAssertTrue(page.text.contains("三件更硬的事。"), page.text)
    XCTAssertTrue(page.text.contains("资本化成内核——先亏钱"), page.text)
    XCTAssertTrue(page.text.contains("不要让专家写文档！"), page.text)
    XCTAssertTrue(page.text.contains("中文标题：方法论文章") == false || page.title == "中文标题：方法论文章")
    // Lists and blockquote markers.
    XCTAssertTrue(page.text.contains("- 抽象是工程师的活"), page.text)
    XCTAssertTrue(page.text.contains("> 没有平台内核就没有杠杆。"), page.text)
    // Paragraph break between the two body paragraphs.
    XCTAssertTrue(page.text.contains("事。\n\n结论很明确"), page.text)
  }

  func testExtractorPreservesPreBlocksAsFencedCodeAndDropsLineNumberRail() throws {
    // 微信 code-snippet：行号 <ul> + 每行一个 <code> 的 <pre>。
    let html = """
    <html><body><article>
      <p>我把 Prompt 放在这里，有需要的朋友直接复制：</p>
      <section class="code-snippet__fix code-snippet__js">
        <ul class="code-snippet__line-index code-snippet__js"><li>1</li><li>2</li><li>3</li></ul>
        <pre class="code-snippet__js"><code># 横纵分析法 Deep Research Prompt</code><code>研究对象 = 「此处替换为你的研究对象名」</code><code>    indented  line</code></pre>
      </section>
      <p>以上就是完整内容。</p>
      <pre>plain
      newline&amp;entity</pre>
    </article></body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    // One fenced block, one source line per <code>, indentation intact.
    XCTAssertTrue(
      page.text.contains("```\n# 横纵分析法 Deep Research Prompt\n研究对象 = 「此处替换为你的研究对象名」\n    indented  line\n```"),
      page.text
    )
    // The line-number rail must not leak as list items.
    XCTAssertFalse(page.text.contains("- 1"), page.text)
    // Plain <pre> keeps its own newlines and decodes entities.
    XCTAssertTrue(page.text.contains("plain\n"), page.text)
    XCTAssertTrue(page.text.contains("newline&entity"), page.text)
    XCTAssertTrue(page.text.contains("以上就是完整内容。"), page.text)
  }

  func testManualServiceDoesNotCreateBrowserWireDocument() async throws {
    let service = ManualLinkCaptureService(fetcher: FixtureFetcher())
    let document = try await service.capture(urlString: "https://example.test/article")
    XCTAssertEqual(document.origin, .manualLink)
    XCTAssertEqual(document.method, "public_html")
    XCTAssertFalse(document.text.isEmpty)
  }

  func testWeChatVerificationInterstitialIsRejectedBeforePersistenceAndNormalVerificationWordsAreAccepted() async throws {
    let verification = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://mp.weixin.qq.com/verify/captcha")!,
      html: "<article>当前环境异常，请完成验证后即可继续访问。这里仍然有足够多的页面文字供提取器处理。</article>"
    ))
    do {
      _ = try await verification.capture(urlString: "https://mp.weixin.qq.com/verify/captcha")
      XCTFail("verification interstitial must not create a document")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .verificationRequired)
      XCTAssertEqual(error.userMessage, "该页面需要登录或人机验证，请使用浏览器扩展捕获。")
    }

    // Real WeChat mobile captcha uses a compound path segment, not bare /captcha.
    let compound = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?appmsg_token=x&ret=0")!,
      html: "<body>环境异常 视频 小程序 赞 在看 完成验证后即可继续访问 这里仍有足够多文字避免 empty。</body>"
    ))
    do {
      _ = try await compound.capture(
        urlString: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?appmsg_token=x&ret=0"
      )
      XCTFail("compound captcha path must not create a document")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .verificationRequired)
    }

    // Path alone is enough for WeChat captcha/wappoc shells even with sparse body.
    let sparse = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha")!,
      html: "<body>视频 小程序 赞 在看 以及其它壳层按钮文字凑满提取长度要求。</body>"
    ))
    do {
      _ = try await sparse.capture(urlString: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha")
      XCTFail("WeChat wappoc path must not create a document")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .verificationRequired)
    }

    let normalArticle = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://mp.weixin.qq.com/s/article")!,
      html: "<article>这篇正常文章讨论验证方法、实验设计和读者反馈，内容足够长且不属于任何验证拦截页面。</article>"
    ))
    let accepted = try await normalArticle.capture(urlString: "https://mp.weixin.qq.com/s/article")
    XCTAssertFalse(accepted.text.isEmpty)
  }

  func testXTrailingCounterNoiseIsRemovedWithoutHarmingOrdinaryNumbers() async throws {
    let x = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://x.com/example/status/1")!,
      html: "<article>正文保留 2026 年的 42 个有效数字。 6 0 6 5 0 5 3 0 3</article>"
    ))
    let xDocument = try await x.capture(urlString: "https://x.com/example/status/1")
    XCTAssertEqual(xDocument.text, "正文保留 2026 年的 42 个有效数字。")

    let ordinary = ManualLinkCaptureService(fetcher: StaticFetcher(
      url: URL(string: "https://example.test/article")!,
      html: "<article>非 X 文章也许有一个数字序列。 6 0 6 5 0 5 3 0 3</article>"
    ))
    let ordinaryDocument = try await ordinary.capture(urlString: "https://example.test/article")
    XCTAssertTrue(ordinaryDocument.text.hasSuffix("6 0 6 5 0 5 3 0 3"))
  }

  func testEmptyTitleFallsBackToUntitledAtDocumentBoundary() throws {
    let document = CapturedDocument(createdAt: "2026-07-18T00:00:00Z", origin: .browserCapture, url: "https://example.com/long/path?ignored=true", title: "  ", platform: "fixture", method: "dom", text: "body", completeness: "complete", capturedAt: "2026-07-18T00:00:00Z", sourceLabel: "fixture")
    XCTAssertEqual(document.title, CapturedDocumentTitle.missing)
    XCTAssertEqual(CapturedDocumentTitle.display(document.title, for: document.url), "无标题")
    XCTAssertEqual(
      CapturedDocumentTitle.display(
        "Introduction to AI Fluency · AI Fluency: Framework & Foundations · Claude Academy",
        for: "https://academy.claude.com/courses/ai-fluency-framework-foundations/introduction-to-ai-fluency"
      ),
      "Introduction to AI Fluency"
    )
    XCTAssertEqual(
      CapturedDocumentTitle.courseTitle(
        "Introduction to AI Fluency · AI Fluency: Framework & Foundations · Claude Academy",
        url: "https://academy.claude.com/courses/ai-fluency-framework-foundations/introduction-to-ai-fluency"
      ),
      "AI Fluency: Framework & Foundations"
    )
    // Legacy rows that stored host · /path should display as 无标题, not as a link.
    XCTAssertEqual(
      CapturedDocumentTitle.display("example.com · /long/path", for: "https://example.com/long/path"),
      "无标题"
    )
  }

  func testExtractorPrefersOpenGraphTitleAndStripsBoilerplateChrome() throws {
    let html = """
    <html><head>
      <title>Site chrome | Brand</title>
      <meta property="og:title" content="真正的文章标题" />
    </head><body>
      <article>
        <p>这是正文第一段，包含足够多的文字以便通过最短正文长度校验。</p>
        <p>这是正文第二段，继续说明产品与方法。</p>
        <div><a href="/1">相关阅读</a><a href="/2">热门文章</a><a href="/3">猜你喜欢</a><a href="/4">更多</a></div>
      </article>
    </body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertEqual(page.title, "真正的文章标题")
    XCTAssertTrue(page.text.contains("正文第一段"))
    XCTAssertTrue(page.text.contains("第一段，包含足够多"))
    XCTAssertTrue(page.text.contains("第一段，包含") || page.text.contains("校验。"))
    XCTAssertFalse(page.text.contains("猜你喜欢"))
    // Structured paragraphs separated by a blank line.
    XCTAssertTrue(page.text.contains("校验。\n\n这是正文第二段"), page.text)
  }

  func testSourceAdapterTakesOnlyItsClaimedURLAndFeedsDocumentIntoManualCapture() async throws {
    let adapter = FixtureSourceAdapter()
    let service = ManualLinkCaptureService(fetcher: FixtureFetcher(), sourceAdapters: [adapter])
    let document = try await service.capture(urlString: "https://github.com/octo/repo")
    XCTAssertEqual(document.title, "octo/repo")
    XCTAssertEqual(document.text, "# README fixture")
    XCTAssertEqual(document.method, "github_readme_api")
    XCTAssertEqual(adapter.captureCalls, 1)
    _ = try await service.capture(urlString: "https://github.com/octo/repo/issues/1")
    XCTAssertEqual(adapter.captureCalls, 1, "non-repository GitHub paths remain on the generic route")
  }

  func testHTMLResponsePolicyCoversStatusTypeAndSize() {
    XCTAssertNoThrow(try PublicHTMLResponsePolicy.validate(statusCode: 200, contentType: "application/xhtml+xml; charset=utf-8", expectedLength: 10, byteLimit: 100))
    XCTAssertThrowsError(try PublicHTMLResponsePolicy.validate(statusCode: 302, contentType: "text/html", expectedLength: 1, byteLimit: 100)) { XCTAssertEqual($0 as? ManualLinkError, .responseStatus) }
    XCTAssertThrowsError(try PublicHTMLResponsePolicy.validate(statusCode: 200, contentType: "application/json", expectedLength: 1, byteLimit: 100)) { XCTAssertEqual($0 as? ManualLinkError, .unsupportedContentType) }
    XCTAssertThrowsError(try PublicHTMLResponsePolicy.validate(statusCode: 200, contentType: "text/htmlish", expectedLength: 1, byteLimit: 100)) { XCTAssertEqual($0 as? ManualLinkError, .unsupportedContentType) }
    XCTAssertThrowsError(try PublicHTMLResponsePolicy.validate(statusCode: 200, contentType: "text/html", expectedLength: 101, byteLimit: 100)) { XCTAssertEqual($0 as? ManualLinkError, .responseTooLarge) }
  }

  func testDocumentRequiresBothTimestamps() {
    let valid = CapturedDocument(createdAt: "2026-07-15T04:00:00Z", origin: .manualLink, url: "https://example.test", title: nil, platform: "manual", method: "public_html", text: "valid enough body", completeness: "best_effort", capturedAt: "not-a-timestamp", sourceLabel: "fixture")
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(valid)) { XCTAssertEqual($0 as? CapturedDocumentValidationError, .invalidTimestamp) }
  }

  func testExtractorDropsEnglishChromeKeepsInstructionBudgetAndTables() throws {
    let html = """
    <html><head>
      <meta property="og:title" content="A Complete Guide To AGENTS.md" />
      <script type="application/ld+json">{"author":{"@type":"Person","name":"Matt Pocock"}}</script>
    </head><body>
    <article>
      <span>8 min read</span>
      <p>Loading</p>
      <h1>A Complete Guide To AGENTS.md</h1>
      <span>Matt Pocock</span>
      <details><summary>On this page</summary><nav aria-label="On this page"><a href="#a">What</a></nav></details>
      <article>
        <p>Have you ever felt concerned about the size of your AGENTS.md file?</p>
        <p>Kyle mentions the concept of an "instruction budget" for agents.</p>
        <table><thead><tr><th>Scenario</th><th>Impact</th></tr></thead>
        <tbody><tr><td>Small, focused AGENTS.md</td><td>More tokens available</td></tr></tbody></table>
        <aside id="course-cta">Subscribe to the Skills newsletter</aside>
      </article>
      <section id="related-reading" aria-label="Related reading"><h2>Related reading</h2><p>Other post</p></section>
    </article>
    </body></html>
    """
    let page = try MinimalHTMLExtractor().extract(html: html)
    XCTAssertEqual(page.title, "A Complete Guide To AGENTS.md")
    XCTAssertEqual(page.author, "Matt Pocock")
    XCTAssertTrue(page.text.contains("Have you ever felt concerned"), page.text)
    XCTAssertTrue(page.text.contains("instruction budget"), page.text)
    XCTAssertTrue(page.text.contains("| Scenario | Impact |"), page.text)
    XCTAssertFalse(page.text.contains("8 min read"), page.text)
    XCTAssertFalse(page.text.split(separator: "\n").contains("Loading"), page.text)
    XCTAssertFalse(page.text.contains("On this page"), page.text)
    XCTAssertFalse(page.text.contains("Related reading"), page.text)
    XCTAssertFalse(page.text.hasPrefix("# A Complete Guide"), page.text)
    XCTAssertFalse(page.text.contains("Matt Pocock"), page.text)
  }

  func testManualServicePrefersSiblingMarkdownCopy() async throws {
    let pageURL = URL(string: "https://www.aihero.dev/a-complete-guide-to-agents-md")!
    let markdown = """
    ---
    title: "A Complete Guide To AGENTS.md"
    slug: "a-complete-guide-to-agents-md"
    ---

    Have you ever felt concerned about the size of your AGENTS.md file?

    Kyle mentions the concept of an instruction budget.
    """
    let html = """
    <html><head><meta property="og:title" content="A Complete Guide To AGENTS.md" /></head>
    <body><article><span>8 min read</span><h1>A Complete Guide To AGENTS.md</h1>
    <details><summary>On this page</summary><p>TOC</p></details>
    <p>Have you ever felt concerned about the size of your AGENTS.md file?</p>
    <p>Kyle mentions the concept of an instruction budget.</p></article></body></html>
    """
    let resources = MapResourceFetcher(pages: [
      pageURL.appendingPathExtension("md").absoluteString: (200, "text/markdown", markdown)
    ])
    let service = ManualLinkCaptureService(
      fetcher: StaticFetcher(url: pageURL, html: html),
      resources: resources
    )
    let document = try await service.capture(urlString: pageURL.absoluteString)
    XCTAssertEqual(document.method, "public_markdown")
    XCTAssertEqual(document.title, "A Complete Guide To AGENTS.md")
    XCTAssertTrue(document.text.contains("Have you ever felt concerned"), document.text)
    XCTAssertTrue(document.text.contains("instruction budget"), document.text)
    XCTAssertFalse(document.text.contains("8 min read"), document.text)
    XCTAssertFalse(document.text.contains("On this page"), document.text)
    XCTAssertEqual(SiblingMarkdownURL.make(from: pageURL)?.absoluteString, "https://www.aihero.dev/a-complete-guide-to-agents-md.md")
  }
}

private struct FixtureFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: url, html: "<title>Fixture</title><article>Fixture article body contains enough words for a real test.</article>", contentType: "text/html")
  }
}

private struct StaticFetcher: WebPageFetcher {
  let url: URL
  let html: String
  func fetch(url _: URL) async throws -> WebPageFetchResult { .init(url: url, html: html, contentType: "text/html") }
}

private struct MapResourceFetcher: SafeResourceFetching {
  let pages: [String: (Int, String, String)]
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    guard let page = pages[request.url.absoluteString] else {
      return .init(url: request.url, statusCode: 404, contentType: "text/plain", body: Data())
    }
    return .init(url: request.url, statusCode: page.0, contentType: page.1, body: Data(page.2.utf8))
  }
}

private final class FixtureSourceAdapter: SourceAdapting, @unchecked Sendable {
  private let lock = NSLock(); private var calls = 0
  func takesOwnership(of url: URL) -> Bool { url.host == "github.com" && url.path == "/octo/repo" }
  func capture(url: URL) async throws -> CapturedDocument {
    lock.withLock { calls += 1 }
    return .init(createdAt: "2026-07-18T00:00:00Z", origin: .manualLink, url: url.absoluteString, title: "octo/repo", platform: "github", method: "github_readme_api", text: "# README fixture", completeness: "complete", capturedAt: "2026-07-18T00:00:00Z", sourceLabel: "fixture")
  }
  var captureCalls: Int { lock.withLock { calls } }
}
