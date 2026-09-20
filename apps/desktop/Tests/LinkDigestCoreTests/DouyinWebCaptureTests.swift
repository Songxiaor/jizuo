import XCTest
@testable import LinkDigestCore

final class DouyinWebCaptureTests: XCTestCase {
  func testNavigationAllowsOnlyHTTPSDouyinMainFrames() {
    XCTAssertNoThrow(
      try DouyinWebCapturePolicy.validateNavigationURL(
        URL(string: "https://v.douyin.com/UX1kjPiekmQ/")!
      )
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.navigationDecision(
        url: URL(string: "https://www.douyin.com/video/7661288207509769506"),
        isMainFrame: true
      ),
      .allow
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.navigationDecision(
        url: URL(string: "https://evil.example/collect"),
        isMainFrame: false
      ),
      .blockSilently
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.navigationDecision(
        url: URL(string: "https://evil.example/collect"),
        isMainFrame: true
      ),
      .failCapture
    )
    XCTAssertThrowsError(
      try DouyinWebCapturePolicy.validateNavigationURL(
        URL(string: "https://v.evil-douyin.com/UX1kjPiekmQ/")!
      )
    )
  }

  func testValidatesBoundedRenderedItemResult() throws {
    let page = try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7661288207509769506",
      "canonicalURL": "https://www.douyin.com/video/7661288207509769506",
      "title": "食伤生财真相：盲派讲透",
      "description": "为什么你有这个格局却赚不到收益",
      "author": "青山言粉丝3.4万获赞11.8万已",
      "publishedAt": "发布时间：2026-07-11 23:11",
      "videoURL": "https://v3.douyinvod.com/example",
      "coverURL": "https://p3.douyinpic.com/example.jpeg",
      "durationSeconds": 510.0,
    ])

    XCTAssertEqual(page.awemeID, "7661288207509769506")
    XCTAssertEqual(page.author, "青山言")
    XCTAssertEqual(page.publishedAt, "2026-07-11 23:11")
    XCTAssertEqual(page.durationSeconds, 510)
    XCTAssertTrue(page.imageURLs.isEmpty)
  }

  func testValidatesNoteCanonicalAndGalleryImages() throws {
    let page = try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7673819714897187302",
      "canonicalURL": "https://www.douyin.com/note/7673819714897187302",
      "title": "一切皆插件：DSH 的设计哲学",
      "imageURLs": [
        "https://p3.douyinpic.com/aweme/tplv-dy-aweme-images/one.jpeg?biz_tag=aweme_images",
        "https://p3.douyinpic.com/aweme/tplv-dy-aweme-images/two.jpeg?biz_tag=aweme_images",
      ],
    ])

    XCTAssertEqual(page.canonicalURL.path, "/note/7673819714897187302")
    XCTAssertEqual(page.imageURLs.count, 2)
    XCTAssertNil(page.videoURL)
    XCTAssertEqual(
      DouyinWebCapturePolicy.completionDecision(for: page),
      .completeWithPlayableMedia
    )
  }

  func testAllowsByteDanceSessionHopsWithoutOpeningUserSubmittedHosts() {
    XCTAssertEqual(
      DouyinWebCapturePolicy.navigationDecision(
        url: URL(string: "https://passport.snssdk.com/sso/login"),
        isMainFrame: true
      ),
      .allow
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.navigationDecision(
        url: URL(string: "https://login.bytedance.com/sso"),
        isMainFrame: true
      ),
      .allow
    )
    XCTAssertTrue(
      DouyinWebCapturePolicy.isSessionNavigationURL(
        URL(string: "https://passport.snssdk.com/sso/login")!
      )
    )
    XCTAssertThrowsError(
      try DouyinWebCapturePolicy.validateNavigationURL(
        URL(string: "https://passport.snssdk.com/sso/login")!
      )
    )
  }

  func testAcceptsGalleryImageURLAndRejectsAvatars() {
    XCTAssertNotNil(
      DouyinWebCapturePolicy.galleryImageURL(
        from: "https://p3.douyinpic.com/aweme/tplv-dy-aweme-images/one.jpeg?biz_tag=aweme_images"
      )
    )
    XCTAssertNil(
      DouyinWebCapturePolicy.galleryImageURL(
        from: "https://p3.douyinpic.com/aweme/100x100/avatar.jpeg"
      )
    )
  }

  func testRejectsNonGalleryImagesOnNotePages() {
    XCTAssertThrowsError(try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7673819714897187302",
      "canonicalURL": "https://www.douyin.com/note/7673819714897187302",
      "title": "图文",
      "imageURLs": ["https://p3.douyinpic.com/aweme/100x100/avatar.jpeg"],
    ]))
  }

  func testRejectsMismatchedIdentityAndNonHTTPSMedia() {
    XCTAssertThrowsError(try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7661288207509769506",
      "canonicalURL": "https://www.douyin.com/video/7000000000000000000",
      "title": "错误身份",
    ]))
    XCTAssertThrowsError(try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7661288207509769506",
      "canonicalURL": "https://www.douyin.com/video/7661288207509769506",
      "title": "正确身份",
      "videoURL": "blob:https://www.douyin.com/session-only",
    ]))
  }

  func testRenderedCaptureWaitsUntilPlayableMediaAppears() {
    let pageWithoutMedia = DouyinRenderedPage(
      awemeID: "7667204319003834802",
      canonicalURL: URL(string: "https://www.douyin.com/video/7667204319003834802")!,
      title: "Kimi k3 私有化部署费用"
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.completionDecision(for: pageWithoutMedia),
      .waitForPlayableMedia
    )

    let pageWithMedia = DouyinRenderedPage(
      awemeID: pageWithoutMedia.awemeID,
      canonicalURL: pageWithoutMedia.canonicalURL,
      title: pageWithoutMedia.title,
      videoURL: URL(string: "https://v3.douyinvod.com/playback.mp4")
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.completionDecision(for: pageWithMedia),
      .completeWithPlayableMedia
    )

    let pageWithImages = DouyinRenderedPage(
      awemeID: pageWithoutMedia.awemeID,
      canonicalURL: URL(string: "https://www.douyin.com/note/7667204319003834802")!,
      title: pageWithoutMedia.title,
      imageURLs: [
        URL(string: "https://p3.douyinpic.com/aweme/tplv-dy-aweme-images/one.jpeg?biz_tag=aweme_images")!,
      ]
    )
    XCTAssertEqual(
      DouyinWebCapturePolicy.completionDecision(for: pageWithImages),
      .completeWithPlayableMedia
    )
  }

  func testAcceptsValidStatsAndDropsInvalidOnesWithoutFailing() throws {
    let accepted = try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7000000000000000003",
      "canonicalURL": "https://www.douyin.com/video/7000000000000000003",
      "title": "短标题",
      "stats": [
        "likes": "1.2 万",
        "comments": "88",
        "shares": "3",
        "collects": "1.0k",
      ],
    ])
    XCTAssertEqual(accepted.likes, "1.2万")
    XCTAssertEqual(accepted.comments, "88")
    XCTAssertEqual(accepted.shares, "3")
    XCTAssertEqual(accepted.collects, "1.0k")

    let mixed = try DouyinWebCapturePolicy.validateJavaScriptResult([
      "awemeID": "7000000000000000003",
      "canonicalURL": "https://www.douyin.com/video/7000000000000000003",
      "title": "短标题",
      "stats": [
        "likes": "1.2万",
        "comments": 88,
        "shares": "12ab",
        "collects": "12345678901234567",
      ],
    ])
    XCTAssertEqual(mixed.likes, "1.2万")
    XCTAssertNil(mixed.comments)
    XCTAssertNil(mixed.shares)
    XCTAssertNil(mixed.collects)

    XCTAssertNoThrow(
      try DouyinWebCapturePolicy.validateJavaScriptResult([
        "awemeID": "7000000000000000003",
        "canonicalURL": "https://www.douyin.com/video/7000000000000000003",
        "title": "短标题",
        "stats": ["1.2万"],
      ])
    )
  }

  func testRenderedMarkdownWritesEngagementAfterPublished() {
    let page = DouyinRenderedPage(
      awemeID: "7000000000000000003",
      canonicalURL: URL(string: "https://www.douyin.com/video/7000000000000000003")!,
      title: "短标题",
      author: "作者甲",
      publishedAt: "2026-01-01 12:00",
      likes: "100",
      comments: "20",
      shares: "3",
      collects: "5"
    )
    let markdown = DouyinWebCapturePolicy.renderedDocumentMarkdown(from: page)
    XCTAssertTrue(
      markdown.contains(
        "published: \"2026-01-01 12:00\"\nlikes: \"100\"\ncomments: \"20\"\nshares: \"3\"\ncollects: \"5\"\n---"
      ),
      "实际输出：\(markdown)"
    )
    XCTAssertTrue(markdown.contains("# 短标题"))
  }

  func testLongTitleDoesNotEmitHeadingLine() {
    let title = String(repeating: "字", count: 61)
    let page = DouyinRenderedPage(
      awemeID: "7000000000000000003",
      canonicalURL: URL(string: "https://www.douyin.com/video/7000000000000000003")!,
      title: title
    )
    let markdown = DouyinWebCapturePolicy.renderedDocumentMarkdown(from: page)
    XCTAssertFalse(markdown.contains("# \(title)"), "实际输出：\(markdown)")
    XCTAssertTrue(markdown.contains("---\n\n\(title)"), "实际输出：\(markdown)")
    let body = MarkdownNoteFrontmatter.parse(markdown).body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(body.hasPrefix("# "))
    XCTAssertEqual(body, title)
  }
}

/// 慢加载回归。原始缺陷只在「视频地址晚于标题出现」时暴露，而真机上是否暴露
/// 取决于当次网络和 CDN，靠人工点一条视频验证等于抽签。这里用可控时钟把慢样本
/// 固定下来：不真正睡眠，只累计虚拟时间。
@MainActor
final class DouyinCaptureWaitTests: XCTestCase {
  /// 记录被请求的睡眠总时长，用来断言「等了多久」而不是「等了几次」。
  private final class FakeClock {
    private(set) var elapsed: Duration = .zero
    private(set) var sleepCount = 0

    func sleep(_ interval: Duration) {
      elapsed += interval
      sleepCount += 1
    }
  }

  private static let pollInterval: Duration = .milliseconds(250)
  private static let deadline: Duration = .seconds(20)

  private static func page(videoURL: String?) -> DouyinRenderedPage {
    DouyinRenderedPage(
      awemeID: "7667204319003834802",
      canonicalURL: URL(string: "https://www.douyin.com/video/7667204319003834802")!,
      title: "Kimi k3 私有化部署费用",
      author: "青山言",
      videoURL: videoURL.flatMap(URL.init(string:))
    )
  }

  /// 核心回归：视频地址在旧的 8 × 250ms ≈ 2 秒窗口之后才出现，仍必须抓到。
  /// 旧实现会在 2 秒处放弃并把只有标题作者的结果当成功，这条会失败。
  func testCapturesVideoURLAppearingAfterTheOldTwoSecondWindow() async throws {
    let clock = FakeClock()
    let appearsAt: Duration = .seconds(9)
    var polls = 0

    let captured = try await DouyinCaptureWait.waitForPlayableMedia(
      pollInterval: Self.pollInterval,
      isCancelled: { clock.elapsed >= Self.deadline },
      sleep: { clock.sleep($0) },
      poll: {
        polls += 1
        return .ready(
          Self.page(
            videoURL: clock.elapsed >= appearsAt
              ? "https://v3.douyinvod.com/playback.mp4"
              : nil
          )
        )
      }
    )

    XCTAssertEqual(
      captured?.videoURL?.absoluteString,
      "https://v3.douyinvod.com/playback.mp4"
    )
    // 真的等过了 2 秒窗口，而不是碰巧第一轮就拿到。
    XCTAssertGreaterThanOrEqual(clock.elapsed, appearsAt)
    XCTAssertGreaterThan(clock.sleepCount, 8)
    XCTAssertEqual(polls, clock.sleepCount + 1)
  }

  /// 图文帖有正片图即可完成，不必再等视频地址。
  func testImageGalleryCompletesWithoutAVideoURL() async throws {
    let clock = FakeClock()
    let captured = try await DouyinCaptureWait.waitForPlayableMedia(
      pollInterval: Self.pollInterval,
      isCancelled: { clock.elapsed >= Self.deadline },
      sleep: { clock.sleep($0) },
      poll: {
        .ready(
          DouyinRenderedPage(
            awemeID: "7673819714897187302",
            canonicalURL: URL(string: "https://www.douyin.com/note/7673819714897187302")!,
            title: "一切皆插件",
            imageURLs: [
              URL(string: "https://p3.douyinpic.com/aweme/tplv-dy-aweme-images/one.jpeg?biz_tag=aweme_images")!,
            ]
          )
        )
      }
    )

    XCTAssertEqual(captured?.imageURLs.count, 1)
    XCTAssertNil(captured?.videoURL)
    XCTAssertEqual(clock.sleepCount, 0)
  }

  /// 元数据先到不算完成：一路只有标题作者时必须等满截止时间，
  /// 且不得把它当成一次成功的抓取返回。
  func testMetadataOnlyNeverCompletesAndWaitsOutTheDeadline() async throws {
    let clock = FakeClock()

    let captured = try await DouyinCaptureWait.waitForPlayableMedia(
      pollInterval: Self.pollInterval,
      isCancelled: { clock.elapsed >= Self.deadline },
      sleep: { clock.sleep($0) },
      poll: { .ready(Self.page(videoURL: nil)) }
    )

    XCTAssertNil(captured)
    XCTAssertGreaterThanOrEqual(clock.elapsed, Self.deadline)
  }

  /// 页面尚未就绪与「就绪但没有视频地址」走同一条等待路径，
  /// 不会因为状态不同提前结束。
  func testNotReadyPagesKeepWaitingWithoutCompleting() async throws {
    let clock = FakeClock()
    let readyAt: Duration = .seconds(5)

    let captured = try await DouyinCaptureWait.waitForPlayableMedia(
      pollInterval: Self.pollInterval,
      isCancelled: { clock.elapsed >= Self.deadline },
      sleep: { clock.sleep($0) },
      poll: {
        clock.elapsed >= readyAt
          ? .ready(Self.page(videoURL: "https://v3.douyinvod.com/playback.mp4"))
          : .notReady
      }
    )

    XCTAssertNotNil(captured?.videoURL)
    XCTAssertGreaterThanOrEqual(clock.elapsed, readyAt)
  }

  /// 抓取过程中的错误照常抛出，不被等待循环吞成「继续等」。
  func testPollErrorsPropagateInsteadOfSilentlyRetrying() async {
    let clock = FakeClock()

    do {
      _ = try await DouyinCaptureWait.waitForPlayableMedia(
        pollInterval: Self.pollInterval,
        isCancelled: { clock.elapsed >= Self.deadline },
        sleep: { clock.sleep($0) },
        poll: { throw ManualLinkError.verificationRequired }
      )
      XCTFail("验证拦截必须中断等待")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, .verificationRequired)
    }
  }
}
