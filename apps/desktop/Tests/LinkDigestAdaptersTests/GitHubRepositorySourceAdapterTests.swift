import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestCore

private final class GitHubFixtureResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: SafeResourceResponse]
  private var seen: [SafeResourceRequest] = []
  init(_ values: [String: SafeResourceResponse]) { self.values = values }
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { seen.append(request) }
    return lock.withLock { values[request.url.absoluteString] } ?? .init(url: request.url, statusCode: 404, contentType: "application/json", body: Data())
  }
  var requests: [SafeResourceRequest] { lock.withLock { seen } }
}

final class GitHubRepositorySourceAdapterTests: XCTestCase {
  func testTakeoverOnlyMatchesExactRepositoryPaths() {
    let adapter = GitHubRepositorySourceAdapter(resources: GitHubFixtureResourceFetcher([:]))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://github.com/owner/repo/")!))
    for raw in [
      "https://github.com/owner/repo/issues/1", "https://github.com/owner/repo/blob/main/a.md",
      "https://github.com/owner/repo/tree/main", "https://example.com/owner/repo",
      "http://github.com/owner/repo", "https://user:pass@github.com/owner/repo"
    ] { XCTAssertFalse(adapter.takesOwnership(of: URL(string: raw)!)) }
  }

  func testReadmeSuccessUsesRawAcceptAndPreservesMarkdownDocument() async throws {
    let repoURL = URL(string: "https://github.com/octo/hello?tab=readme#top")!
    let api = URL(string: "https://api.github.com/repos/octo/hello/readme")!
    let fixture = GitHubFixtureResourceFetcher([
      api.absoluteString: .init(url: api, statusCode: 200, contentType: "text/plain; charset=utf-8", body: Data("# Hello\n\nREADME **markdown**".utf8))
    ])
    let document = try await GitHubRepositorySourceAdapter(resources: fixture).capture(url: repoURL)
    XCTAssertEqual(document.url, "https://github.com/octo/hello")
    XCTAssertEqual(document.title, "octo/hello")
    XCTAssertEqual(document.platform, "github")
    XCTAssertEqual(document.method, "github_readme_api")
    XCTAssertEqual(document.text, "# Hello\n\nREADME **markdown**")
    XCTAssertEqual(fixture.requests.first?.url, api)
    XCTAssertEqual(fixture.requests.first?.headers["Accept"], GitHubRepositorySourceAdapter.readmeAccept)
  }

  func testReadme404AndRateLimitUseFixedErrorsWithoutBody() async {
    let api = URL(string: "https://api.github.com/repos/octo/missing/readme")!
    for (status, expected) in [(404, ManualLinkError.githubRepositoryUnavailable), (403, ManualLinkError.githubRateLimited), (429, ManualLinkError.githubRateLimited)] {
      let fixture = GitHubFixtureResourceFetcher([api.absoluteString: .init(url: api, statusCode: status, contentType: "application/json", body: Data("sensitive provider body".utf8))])
      do {
        _ = try await GitHubRepositorySourceAdapter(resources: fixture).capture(url: URL(string: "https://github.com/octo/missing")!)
        XCTFail("expected fixed GitHub error")
      } catch { XCTAssertEqual(error as? ManualLinkError, expected) }
    }
  }

  func testImageCacheResolvesRelativeSkipsExternalAndDeletesWithTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-github-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = GitHubRepository(url: URL(string: "https://github.com/octo/hello")!)!
    let relative = URL(string: "docs/diagram.png", relativeTo: repository.rawBaseURL)!.absoluteURL
    let fixture = GitHubFixtureResourceFetcher([
      relative.absoluteString: .init(url: relative, statusCode: 200, contentType: "image/png", body: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]))
    ])
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    await cache.stage(markdown: "![diagram](docs/diagram.png) ![badge](https://example.com/badge.png)", repository: repository, captureID: "capture", resources: fixture)
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "capture", taskID: taskID, snapshotID: snapshotID)
    XCTAssertEqual(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).count, 1)
    XCTAssertEqual(fixture.requests.map(\.url), [relative])
    XCTAssertFalse(fixture.requests[0].allowsRedirectTarget(URL(string: "https://example.com/redirected.png")!), "an image request must reject external redirect hops before bytes are received")
    cache.delete(taskID: taskID)
    XCTAssertTrue(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).isEmpty)
  }

  func testImageCacheRejectsWrongTypeAndCapsAtTwenty() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-github-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = GitHubRepository(url: URL(string: "https://github.com/octo/hello")!)!
    var responses: [String: SafeResourceResponse] = [:]
    let markdown = (0..<21).map { index -> String in
      let url = URL(string: "image\(index).png", relativeTo: repository.rawBaseURL)!.absoluteURL
      responses[url.absoluteString] = .init(url: url, statusCode: 200, contentType: index == 0 ? "text/plain" : "image/png", body: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
      return "![i\(index)](image\(index).png)"
    }.joined(separator: "\n")
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    await cache.stage(markdown: markdown, repository: repository, captureID: "many", resources: GitHubFixtureResourceFetcher(responses))
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "many", taskID: taskID, snapshotID: snapshotID)
    // Cap is on successful stored images (not attempted URLs): 21 refs, index 0 wrong type, 20 kept.
    XCTAssertEqual(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).count, 20)
  }

  func testImageCacheRejectsAResponseOverFiveMiB() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-github-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = GitHubRepository(url: URL(string: "https://github.com/octo/hello")!)!
    let image = URL(string: "large.png", relativeTo: repository.rawBaseURL)!.absoluteURL
    let body = Data(repeating: 0, count: GitHubREADMEImageCache.perImageByteLimit + 1)
    let fixture = GitHubFixtureResourceFetcher([image.absoluteString: .init(url: image, statusCode: 200, contentType: "image/png", body: body)])
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    await cache.stage(markdown: "![large](large.png)", repository: repository, captureID: "large", resources: fixture)
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "large", taskID: taskID, snapshotID: snapshotID)
    XCTAssertTrue(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).isEmpty)
  }

  func testWeChatImageCacheUsesExactHostsRefererAndFailOpenSkips() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-wechat-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    let allowed = URL(string: "https://cdn.mmbiz.qpic.cn/body.png")!
    let cover = URL(string: "https://mmecoa.qpic.cn/cover.png")!
    let denied = "https://notmmbiz.qpic.cn/skip.png"
    let resources = GitHubFixtureResourceFetcher([
      allowed.absoluteString: .init(url: allowed, statusCode: 200, contentType: "image/png", body: png),
      cover.absoluteString: .init(url: cover, statusCode: 200, contentType: "image/png", body: png),
    ])
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    let article = URL(string: "https://mp.weixin.qq.com/s/article")!
    await cache.stageWeChatImages(bodyImageURLs: [allowed.absoluteString, denied], coverImageURL: cover.absoluteString, articleURL: article, captureID: "wechat", resources: resources)
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "wechat", taskID: taskID, snapshotID: snapshotID)
    XCTAssertEqual(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).count, 2)
    XCTAssertEqual(resources.requests.map(\.url), [allowed, cover])
    XCTAssertTrue(resources.requests.allSatisfy { $0.headers["Referer"] == article.absoluteString })
    XCTAssertTrue(resources.requests.allSatisfy { $0.allowsRedirectTarget(URL(string: "https://mmbiz.qpic.cn/next.png")!) })
    XCTAssertTrue(resources.requests.allSatisfy { !$0.allowsRedirectTarget(URL(string: "https://example.com/next.png")!) })
    XCTAssertFalse(WeChatImageReferences.isAllowedImageURL(URL(string: "https://mmbiz.qpic.cn.evil.example/x")!))
  }

  func testWeChatImageCacheCapsBodyCountAndBudgetWithoutBlockingStoredImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-wechat-limits.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    let bodyURLs = (0..<60).map { URL(string: "https://mmbiz.qpic.cn/\($0).png")! }
    let cover = URL(string: "https://mmbiz.qpic.cn/cover.png")!
    let responses = Dictionary(uniqueKeysWithValues: (bodyURLs + [cover]).map { ($0.absoluteString, SafeResourceResponse(url: $0, statusCode: 200, contentType: "image/png", body: png)) })
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    let countResources = GitHubFixtureResourceFetcher(responses)
    await cache.stageWeChatImages(bodyImageURLs: bodyURLs.map(\.absoluteString), coverImageURL: cover.absoluteString, articleURL: URL(string: "https://mp.weixin.qq.com/s/article")!, captureID: "count", resources: countResources)
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "count", taskID: taskID, snapshotID: snapshotID)
    XCTAssertEqual(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).count, 60, "the cover shares the total 60-image cache budget")
    XCTAssertEqual(countResources.requests.map(\.url), bodyURLs, "DOM-order inline images win; the trailing cover is truncated")

    let budgetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-wechat-budget.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: budgetRoot) }
    let large = URL(string: "https://mmbiz.qpic.cn/large.png")!
    let next = URL(string: "https://mmbiz.qpic.cn/next.png")!
    let afterBudget = URL(string: "https://mmbiz.qpic.cn/after-budget.png")!
    let budgetResources = GitHubFixtureResourceFetcher([
      large.absoluteString: .init(url: large, statusCode: 200, contentType: "image/png", body: png + Data([0x00, 0x00])),
      next.absoluteString: .init(url: next, statusCode: 200, contentType: "image/png", body: png),
      afterBudget.absoluteString: .init(url: afterBudget, statusCode: 200, contentType: "image/png", body: png),
    ])
    let budgetCache = GitHubREADMEImageCache(applicationSupportRoot: budgetRoot)
    await budgetCache.stageWeChatImages(bodyImageURLs: [large.absoluteString, next.absoluteString, afterBudget.absoluteString], coverImageURL: nil, articleURL: URL(string: "https://mp.weixin.qq.com/s/article")!, captureID: "budget", resources: budgetResources, perImageByteLimit: 10, totalByteBudget: 9)
    let budgetTask = TaskID(), budgetSnapshot = ContentSnapshotID()
    budgetCache.promote(captureID: "budget", taskID: budgetTask, snapshotID: budgetSnapshot)
    XCTAssertEqual(budgetCache.localImageURLs(taskID: budgetTask, snapshotID: budgetSnapshot).count, 1, "an oversized image skips while the article's next image remains eligible")
    XCTAssertEqual(budgetResources.requests.map(\.url), [large, next], "hitting the total budget stops later downloads")
  }

  func testImageCacheRejectsRiffAndMimeSignatureSpoofs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-github-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = GitHubRepository(url: URL(string: "https://github.com/octo/hello")!)!
    let riff = URL(string: "riff.webp", relativeTo: repository.rawBaseURL)!.absoluteURL
    let mismatch = URL(string: "mismatch.png", relativeTo: repository.rawBaseURL)!.absoluteURL
    let fixture = GitHubFixtureResourceFetcher([
      riff.absoluteString: .init(url: riff, statusCode: 200, contentType: "image/webp", body: Data("RIFF....WAVE".utf8)),
      mismatch.absoluteString: .init(url: mismatch, statusCode: 200, contentType: "image/png", body: Data([0xff, 0xd8, 0xff]))
    ])
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    await cache.stage(markdown: "![riff](riff.webp) ![mismatch](mismatch.png)", repository: repository, captureID: "spoof", resources: fixture)
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: "spoof", taskID: taskID, snapshotID: snapshotID)
    XCTAssertTrue(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).isEmpty)
  }

  func testRemoteMarkdownImagesUseBrowserHeadersAndSiteReferers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-cdn-headers.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rawURLs = [
      "https://mmbiz.qpic.cn/a.png",
      "https://wx.qlogo.cn/b.png",
      "https://cdn.qq.com/c.png",
      "https://v.douyinvod.com/d.png",
      "https://v.douyincdn.com/e.png",
      "https://www.douyin.com/f.png",
      "https://miro.medium.com/v2/resize:fit:1200/1*article.png",
      "https://images.example.test/g.png",
      "https://notqpic.cn/h.png",
    ]
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    let responses = Dictionary(uniqueKeysWithValues: rawURLs.map { raw in
      let url = URL(string: raw)!
      return (raw, SafeResourceResponse(url: url, statusCode: 200, contentType: "image/png", body: png))
    })
    let fixture = GitHubFixtureResourceFetcher(responses)
    let markdown = rawURLs.map { raw in "![](\(raw))" }.joined(separator: "\n")

    await GitHubREADMEImageCache(applicationSupportRoot: root).stageRemoteMarkdownImages(
      markdown: markdown,
      captureID: "headers",
      resources: fixture
    )

    let requests = Dictionary(uniqueKeysWithValues: fixture.requests.map { ($0.url.host!, $0.headers) })
    for headers in requests.values {
      XCTAssertEqual(headers["User-Agent"], GitHubREADMEImageCache.browserUserAgent)
    }
    for host in ["mmbiz.qpic.cn", "wx.qlogo.cn", "cdn.qq.com"] {
      XCTAssertEqual(requests[host]?["Referer"], "https://mp.weixin.qq.com/")
    }
    for host in ["v.douyinvod.com", "v.douyincdn.com", "www.douyin.com"] {
      XCTAssertEqual(requests[host]?["Referer"], "https://www.douyin.com/")
    }
    XCTAssertEqual(requests["miro.medium.com"]?["Referer"], "https://medium.com/")
    XCTAssertNil(requests["images.example.test"]?["Referer"])
    XCTAssertNil(requests["notqpic.cn"]?["Referer"])
  }

  func testOptInLiveMediumImageUsesTheAppTransport() async throws {
    guard let rawURL = ProcessInfo.processInfo.environment["LINKDIGEST_LIVE_MEDIUM_IMAGE_URL"],
          let url = URL(string: rawURL)
    else {
      throw XCTSkip("set LINKDIGEST_LIVE_MEDIUM_IMAGE_URL for an explicit live transport check")
    }
    let response = try await ProxyAwareWebPageFetcher().fetchResource(
      .init(
        url: url,
        headers: [
          "User-Agent": GitHubREADMEImageCache.browserUserAgent,
          "Referer": "https://medium.com/",
        ],
        byteLimit: GitHubREADMEImageCache.perImageByteLimit,
        allowsRedirectTarget: MarkdownRemoteImageReferences.isAllowedImageURL
      )
    )
    XCTAssertTrue((200...299).contains(response.statusCode))
    XCTAssertEqual(response.contentType?.split(separator: ";", maxSplits: 1).first, "image/png")
    XCTAssertTrue(response.body.starts(with: [0x89, 0x50, 0x4e, 0x47]))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "linkdigest-live-medium-cache.\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    let captureID = "live-medium-\(UUID().uuidString)"
    await cache.stageRemoteMarkdownImages(
      markdown: "![Medium article image](\(url.absoluteString))",
      captureID: captureID,
      resources: ProxyAwareWebPageFetcher()
    )
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    cache.promote(captureID: captureID, taskID: taskID, snapshotID: snapshotID)
    let cached = try XCTUnwrap(cache.localImageURLs(taskID: taskID, snapshotID: snapshotID).first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    XCTAssertTrue(try Data(contentsOf: cached).starts(with: [0x89, 0x50, 0x4e, 0x47]))
  }

  /// 图标托管在 CDN 上是主流做法，所以跨域重定向必须跟过去——实测
  /// `www.douyin.com/favicon.ico` 就是 302 跳到 `lf1-cdn-tos.bytegoofy.com`。
  /// 这里改成钉住真正的边界：凭据、非标准端口、非 http(s) 协议照旧拒绝。
  func testWebsiteFaviconCacheUsesHostLocalCacheAndFollowsCDNRedirect() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-favicon-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(string: "https://captured.example/article?tracking=1#section")!
    let favicon = try XCTUnwrap(WebsiteFaviconCache.faviconURL(for: source))
    XCTAssertEqual(favicon.absoluteString, "https://captured.example/favicon.ico")
    let fixture = GitHubFixtureResourceFetcher([
      favicon.absoluteString: .init(url: favicon, statusCode: 200, contentType: "image/x-icon", body: Data([0x00, 0x00, 0x01, 0x00, 0x01]))
    ])
    let cache = WebsiteFaviconCache(applicationSupportRoot: root)

    let first = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    XCTAssertNotNil(first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first?.path ?? ""))
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertEqual(fixture.requests[0].byteLimit, WebsiteFaviconCache.perHostByteLimit)
    XCTAssertTrue(fixture.requests[0].allowsRedirectTarget(URL(string: "https://captured.example/favicon-v2.ico")!))
    XCTAssertTrue(fixture.requests[0].allowsRedirectTarget(URL(string: "https://cdn.example/favicon.ico")!))
    XCTAssertFalse(fixture.requests[0].allowsRedirectTarget(URL(string: "https://user:pass@captured.example/favicon.ico")!))
    XCTAssertFalse(fixture.requests[0].allowsRedirectTarget(URL(string: "https://cdn.example:8443/favicon.ico")!))
    XCTAssertFalse(fixture.requests[0].allowsRedirectTarget(URL(string: "file:///etc/passwd")!))

    let second = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    XCTAssertEqual(second, first)
    XCTAssertEqual(fixture.requests.count, 1, "A host cache hit must not request a remote image again")
  }

  func testWebsiteFaviconCacheRejectsOversizeWrongMimeAndFailedResponses() async throws {
    let source = URL(string: "https://captured.example/article")!
    let favicon = try XCTUnwrap(WebsiteFaviconCache.faviconURL(for: source))
    let tooLarge = Data([0x00, 0x00, 0x01, 0x00]) + Data(repeating: 0, count: WebsiteFaviconCache.perHostByteLimit)
    // 判据是**字节**，不是 Content-Type：实测 x.com 的 /favicon.ico 声明
    // `image/x-icon` 却发一张标准 PNG，认头不认字节等于把这类站点全放弃。
    // 所以这里钉的是「字节确实不是图片就必须拒」——SPA 把未知路径回首页那种
    // 坏法（标成图标、实为 HTML）照样挡得住。
    for (label, response) in [
      ("large", SafeResourceResponse(url: favicon, statusCode: 200, contentType: "image/x-icon", body: tooLarge)),
      ("not-an-image", SafeResourceResponse(url: favicon, statusCode: 200, contentType: "image/x-icon", body: Data("<!doctype html><html><body>home</body></html>".utf8))),
      ("failure", SafeResourceResponse(url: favicon, statusCode: 503, contentType: "image/x-icon", body: Data([0x00, 0x00, 0x01, 0x00])))
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-favicon-cache-\(label).\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let cache = WebsiteFaviconCache(applicationSupportRoot: root)
      let fixture = GitHubFixtureResourceFetcher([favicon.absoluteString: response])
      let local = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
      XCTAssertNil(local, "\(label) must fall back to the stable host-initial mark")
      XCTAssertNil(cache.localImageURL(for: source))
    }
  }

  func testWebsiteFaviconCacheNegativeResultSuppressesRequestsUntilTTLExpires() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-favicon-negative-cache.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(string: "https://missing-icon.example/article")!
    let favicon = try XCTUnwrap(WebsiteFaviconCache.faviconURL(for: source))
    let fixture = GitHubFixtureResourceFetcher([
      favicon.absoluteString: .init(url: favicon, statusCode: 503, contentType: "image/x-icon", body: Data())
    ])
    let clock = FaviconCacheTestClock(Date(timeIntervalSince1970: 1_000))
    let cache = WebsiteFaviconCache(applicationSupportRoot: root, now: { clock.now })

    // 断言「抑制」这个不变量，而不是绝对请求数。
    //
    // 一次失败的尝试现在会打不止一个请求：本站 favicon.ico 之后还要回退到页面
    // 声明（`<link rel="icon">`）。写死数字会让每次给取回链路加一层兜底都连带
    // 改这条测试，而真正该守住的是「新鲜的 .miss 期间一个请求都不该再发」。
    let first = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    let afterFirstAttempt = fixture.requests.count
    let suppressed = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    XCTAssertNil(first)
    XCTAssertNil(suppressed)
    XCTAssertGreaterThan(afterFirstAttempt, 0, "第一次尝试总该真的发出请求")
    XCTAssertEqual(
      fixture.requests.count, afterFirstAttempt,
      "新鲜的 .miss 标记期间不该再发出任何请求"
    )

    clock.advance(by: WebsiteFaviconCache.negativeCacheTTL + 1)
    let retried = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    XCTAssertNil(retried)
    XCTAssertGreaterThan(
      fixture.requests.count, afterFirstAttempt,
      "负缓存过期后必须重新尝试"
    )
  }

  /// ScienceDirect 这类受保护页面在浏览器里声明了跨域图标，但 App 单独抓 HTML
  /// 只能拿到机器人外壳。浏览器观察到的精确地址必须能越过旧 `.miss`，同时仍然
  /// 走 SafeResourceFetching 与图片字节校验。
  func testBrowserDeclaredFaviconSupersedesNegativeCacheAndStaysKeyedBySourceHost() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-browser-favicon.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(string: "https://www.sciencedirect.com/science/article/pii/S0148296323008524")!
    let declared = URL(string: "https://sciencedirect.elseviercdn.cn/shared-assets/103/images/favSD.ico")!
    let fixture = GitHubFixtureResourceFetcher([
      declared.absoluteString: .init(
        url: declared,
        statusCode: 200,
        contentType: "image/vnd.microsoft.icon",
        body: Data([0x00, 0x00, 0x01, 0x00, 0x02, 0x00])
      )
    ])
    let cache = WebsiteFaviconCache(applicationSupportRoot: root)

    let initial = await cache.localImageURL(fetchingIfNeededFor: source, resources: fixture)
    XCTAssertNil(initial)
    let requestsAfterMiss = fixture.requests.count
    XCTAssertGreaterThan(requestsAfterMiss, 0)

    let local = await cache.localImageURL(
      fetchingBrowserDeclaredURL: declared,
      for: source,
      resources: fixture
    )
    XCTAssertNotNil(local)
    XCTAssertEqual(cache.localImageURL(for: source), local)
    XCTAssertEqual(fixture.requests.dropFirst(requestsAfterMiss).map(\.url), [declared])
    XCTAssertTrue(fixture.requests.last?.allowsRedirectTarget(
      URL(string: "https://another-safe-cdn.example/icon.ico")!
    ) ?? false)
  }
}

private final class FaviconCacheTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.withLock { value } }
  func advance(by interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}
