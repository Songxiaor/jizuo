import Foundation
import WebKit
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
@testable import LinkDigestCore

@MainActor
final class DouyinProfileImportTests: XCTestCase {
  private let authorID = "MS4wLjABAAAA26unzRl4eTG2pAGnxD1pS3kMvjaUIcNxvLGr3VJOiKU"

  func testImportRequestGivesEachOpenANewIdentityAndKeepsBlankSeparateFromCapture() {
    let blank = DouyinProfileImportRequest.blank()
    let again = DouyinProfileImportRequest.blank()
    let capture = DouyinProfileImportRequest.capture(profileURL: "https://www.douyin.com/user/review-author-1")
    XCTAssertNotEqual(blank.id, again.id)
    XCTAssertNotEqual(blank.id, capture.id)
    XCTAssertEqual(blank.initialInput, "")
    XCTAssertFalse(blank.autoStart)
    XCTAssertEqual(capture.initialInput, "https://www.douyin.com/user/review-author-1")
    XCTAssertTrue(capture.autoStart)
  }

  func testProfileInputAcceptsShareTextShortLinkAndCanonicalProfile() {
    XCTAssertEqual(
      DouyinProfileInputRoute.parse("复制打开抖音 https://v.douyin.com/abc123/ 看主页"),
      .shortLink(platform: .douyin, sourceURL: URL(string: "https://v.douyin.com/abc123/")!)
    )
    XCTAssertEqual(
      DouyinProfileInputRoute.parse("https://www.douyin.com/user/\(authorID)?from_tab_name=main"),
      .profile(
        platform: .douyin,
        sourceURL: URL(string: "https://www.douyin.com/user/\(authorID)")!,
        authorID: authorID
      )
    )
    XCTAssertNil(DouyinProfileInputRoute.parse("https://www.douyin.com/video/7661288207509769506"))
    XCTAssertNil(DouyinProfileInputRoute.parse("https://www.xiaohongshu.com/user/profile/demo"))
  }

  func testMergeKeepsOnlySameAuthorCanonicalWorksAndDeduplicatesVirtualScroll() {
    let savedURL = "https://www.douyin.com/video/7661288207509769506"
    let model = makeModel(alreadySaved: { $0 == savedURL })
    start(model)

    let directive = model.merge(snapshot([
      item("https://www.douyin.com/video/7661288207509769506?previous_page=app", authorID: authorID),
      item("https://www.douyin.com/video/7661288207509769506", authorID: authorID),
      item("https://www.douyin.com/note/7673819714897187302", authorID: authorID),
      item("https://www.douyin.com/video/7999999999999999999", authorID: "another-author"),
      item("https://www.douyin.com/user/not-a-work", authorID: authorID),
    ]))

    XCTAssertEqual(directive, .keepLoading)
    XCTAssertEqual(model.candidates.map(\.canonicalURL), [
      savedURL,
      "https://www.douyin.com/note/7673819714897187302",
    ])
    XCTAssertTrue(model.candidates[0].wasAlreadySaved)
    XCTAssertFalse(model.candidates[1].wasAlreadySaved)
  }

  func testSelectionSurvivesAdditionalScreensAndSaveEnqueuesOnlySelectedWithoutVideoByDefault() {
    final class CaptureBox {
      var urls: [String] = []
      var downloadsVideo: Bool?
    }
    let captured = CaptureBox()
    let model = makeModel(enqueue: { urls, downloadsVideo in
      captured.urls = urls
      captured.downloadsVideo = downloadsVideo
      return .init(queued: urls.count, skipped: 0)
    })
    start(model)
    _ = model.merge(snapshot([
      item("https://www.douyin.com/video/7000000000000000001", authorID: authorID),
    ]))
    model.toggleSelection("7000000000000000001")
    _ = model.merge(snapshot([
      item("https://www.douyin.com/video/7000000000000000002", authorID: authorID),
    ]))

    XCTAssertEqual(model.selectedIDs, ["7000000000000000001"])
    model.saveSelected()
    XCTAssertEqual(captured.urls, ["https://www.douyin.com/video/7000000000000000001"])
    XCTAssertEqual(captured.downloadsVideo, false)
    XCTAssertTrue(model.selectedIDs.isEmpty)
  }

  func testInitialEmptyPageWaitsBeforeHedgedVisibleEnd() {
    let model = makeModel()
    start(model)

    for _ in 1..<DouyinProfileImportViewModel.initialEmptyScreenLimit {
      XCTAssertEqual(model.merge(snapshot([])), .keepLoading)
    }
    XCTAssertEqual(model.merge(snapshot([])), .stop(.visibleEnd))
    XCTAssertEqual(model.phase, .stopped(.visibleEnd))
    XCTAssertTrue(DouyinProfileImportStopReason.visibleEnd.message.contains("暂未发现"))
    XCTAssertTrue(DouyinProfileImportStopReason.visibleEnd.message.contains("可继续加载"))
  }

  func testManualStopIsNotUndoneByALateNavigationCallback() {
    let model = makeModel()
    start(model)
    model.stop()

    model.acceptNavigation(URL(string: "https://www.douyin.com/user/\(authorID)")!)

    XCTAssertEqual(model.phase, .stopped(.user))
  }

  func testStartingAProfileCreatesCreatorBeforeAnyWorkIsSaved() {
    final class Created {
      var values: [(String, String, String?)] = []
    }
    let created = Created()
    let model = makeModel(ensureCreator: { author, url, name in
      created.values.append((author, url, name))
      return CreatorID()
    })
    start(model)
    XCTAssertEqual(created.values.map(\.0), [authorID])
    XCTAssertNotNil(model.creatorID)
  }

  func testVerifiedAlreadySavedCandidatesAttachByCanonicalURL() {
    final class Attached {
      var values: [[String]] = []
    }
    let attached = Attached()
    let creatorID = CreatorID()
    let model = makeModel(
      alreadySaved: { $0.contains("7000000000000000001") },
      ensureCreator: { _, _, _ in creatorID },
      attachExisting: { _, urls in attached.values.append(urls) }
    )
    start(model)
    _ = model.merge(snapshot([
      item("https://www.douyin.com/video/7000000000000000001", authorID: authorID),
      item("https://www.douyin.com/video/7000000000000000002", authorID: authorID),
    ]))
    XCTAssertEqual(attached.values, [["https://www.douyin.com/video/7000000000000000001"]])
  }

  func testPublicProfileAvatarIsExtractedFromHeaderNotWorkCards() async throws {
    let avatar = "https://p3.douyinpic.com/aweme/100x100/fixture-avatar.jpeg"
    let html = """
      <div data-e2e="user-info">
        <div data-e2e="user-avatar"><img src="\(avatar)" width="100" height="100"></div>
        <h1 data-e2e="user-title">夹具博主</h1>
      </div>
      <div data-e2e="user-post-list" style="width:200px;height:200px">
        <a href="/video/7000000000000000001"><img src="https://p3.douyinpic.com/aweme/cover.jpeg" alt="作品封面"></a>
      </div>
      """
    let snapshot = try await extractFixture(html)
    XCTAssertEqual(snapshot.status, "ready")
    XCTAssertEqual(snapshot.profileName, "夹具博主")
    XCTAssertEqual(snapshot.profileAvatarURL, avatar)
    XCTAssertEqual(snapshot.candidates.first?.coverURL, "https://p3.douyinpic.com/aweme/cover.jpeg")
  }

  func testAccessLimitsAndWrongTabRemainDistinctStopReasons() {
    for (status, reason) in [
      ("login", DouyinProfileImportStopReason.loginRequired),
      ("verification", .verificationRequired),
      ("wrong_tab", .worksTabRequired),
    ] {
      let model = makeModel()
      start(model)
      XCTAssertEqual(
        model.merge(.init(
          status: status,
          profileAuthorID: authorID,
          profileName: nil,
          activeTab: nil,
          candidates: []
        )),
        .stop(reason)
      )
    }
  }

  func testLoginSnapshotStillSavesVisiblePublicHeaderAndIgnoresWorks() {
    final class Refresh {
      var calls: [(String?, String?)] = []
    }
    let refresh = Refresh()
    let creatorID = CreatorID()
    let model = makeModel(
      ensureCreator: { _, _, _ in creatorID },
      refreshCreatorName: { _, name, avatar in refresh.calls.append((name, avatar)) }
    )
    start(model)
    let avatar = "https://p3.douyinpic.com/aweme/100x100/fixture-avatar.jpeg"
    XCTAssertEqual(
      model.merge(.init(
        status: "login",
        profileAuthorID: authorID,
        profileName: "夹具博主",
        profileAvatarURL: avatar,
        activeTab: nil,
        candidates: [item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)]
      )),
      .stop(.loginRequired)
    )
    XCTAssertEqual(model.profileName, "夹具博主")
    XCTAssertEqual(refresh.calls.count, 1)
    XCTAssertEqual(refresh.calls.first?.0, "夹具博主")
    XCTAssertEqual(refresh.calls.first?.1, avatar)
    XCTAssertTrue(model.candidates.isEmpty)
  }

  func testVerificationDoesNotRefreshEmptyHeaderOverExisting() {
    final class Refresh {
      var calls: [(String?, String?)] = []
    }
    let refresh = Refresh()
    let creatorID = CreatorID()
    let model = makeModel(
      ensureCreator: { _, _, _ in creatorID },
      refreshCreatorName: { _, name, avatar in refresh.calls.append((name, avatar)) }
    )
    start(model)
    let avatar = "https://p3.douyinpic.com/aweme/100x100/fixture-avatar.jpeg"
    XCTAssertEqual(
      model.merge(.init(
        status: "ready",
        profileAuthorID: authorID,
        profileName: "夹具博主",
        profileAvatarURL: avatar,
        activeTab: "作品",
        candidates: [item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)]
      )),
      .keepLoading
    )
    XCTAssertEqual(refresh.calls.count, 1)
    XCTAssertEqual(
      model.merge(.init(
        status: "verification",
        profileAuthorID: authorID,
        profileName: nil,
        profileAvatarURL: nil,
        activeTab: nil,
        candidates: []
      )),
      .stop(.verificationRequired)
    )
    XCTAssertEqual(model.profileName, "夹具博主")
    XCTAssertEqual(refresh.calls.count, 1, "验证码页的空姓名/头像不得覆盖已保存资料")
  }

  func testPerRoundBudgetPausesButContinueKeepsExistingCandidates() {
    let model = makeModel()
    start(model)
    let items = (0..<144).map { index in
      item("https://www.douyin.com/video/\(8_000_000_000_000_000_000 + UInt64(index))", authorID: authorID)
    }

    XCTAssertEqual(
      model.merge(snapshot(items)),
      .stop(.perRoundBudget(DouyinProfileImportViewModel.perRoundBudget))
    )
    XCTAssertEqual(model.candidates.count, DouyinProfileImportViewModel.perRoundBudget)
    model.continueLoading()
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertEqual(model.candidates.count, DouyinProfileImportViewModel.perRoundBudget)
    XCTAssertEqual(model.merge(snapshot(items)), .keepLoading)
    XCTAssertEqual(model.candidates.count, 144, "Continue must recover the unconsumed cards in the same DOM")
    XCTAssertEqual(Set(model.candidates.map(\.id)).count, 144)
  }

  func testTargetAuthorIsLockedForFullProfileAndFirstResolvedShortLink() {
    for input in ["https://www.douyin.com/user/\(authorID)", "https://v.douyin.com/fixture/"] {
      let model = makeModel()
      model.input = input
      model.start()
      if input.contains("v.douyin") {
        model.acceptNavigation(URL(string: "https://www.douyin.com/user/\(authorID)")!)
        model.navigationStarted(navigationRequestID: model.navigationRequestID)
      }
      model.acceptNavigation(URL(string: "https://www.douyin.com/user/another-author")!)
      guard case .failed = model.phase else { return XCTFail("A different author must not replace the target") }
      XCTAssertTrue(model.candidates.isEmpty)
    }
  }

  func testBrowserPreviewUpsertsSameCreatorHeaderIncludingAvatar() {
    var created = 0
    var refreshed: [(String?, String?)] = []
    let creatorID = CreatorID()
    let model = makeModel(
      ensureCreator: { _, _, _ in created += 1; return creatorID },
      refreshCreatorName: { _, name, avatar in refreshed.append((name, avatar)) }
    )
    let avatar = "https://pbs.twimg.com/profile_images/1/owner.jpg"
    model.presentExternalCandidates(.init(
      requestId: "preview",
      profileURL: "https://x.com/sample_author",
      authorID: "sample_author",
      profileName: "夹具作者",
      profileAvatarURL: avatar,
      items: [.init(id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123")]
    ))
    XCTAssertEqual(created, 1)
    XCTAssertEqual(model.creatorID, creatorID)
    XCTAssertEqual(model.profileName, "夹具作者")
    XCTAssertEqual(refreshed.count, 1)
    XCTAssertEqual(refreshed.first?.0, "夹具作者")
    XCTAssertEqual(refreshed.first?.1, avatar)
    model.toggleSelection("1234567890123")
    model.saveSelected()
    XCTAssertEqual(created, 1, "保存作品必须复用同一 creator，不得再插一条")
    XCTAssertTrue(model.mergeExternalCandidates(.init(
      requestId: "preview-2",
      profileURL: "https://x.com/sample_author",
      authorID: "sample_author",
      profileName: "夹具作者",
      profileAvatarURL: avatar,
      items: [.init(id: "1234567890456", url: "https://x.com/sample_author/status/1234567890456")]
    )))
    XCTAssertEqual(created, 1)
    XCTAssertEqual(refreshed.count, 2)
  }

  func testBrowserSourcedCandidatesDoNotStartWebKitScanAndKeepSelectionOnMerge() {
    let model = makeModel()
    model.presentExternalCandidates(
      XProfileCandidatesRequest(
        requestId: "req-1",
        profileURL: "https://x.com/sample_author",
        authorID: "sample_author",
        items: [
          .init(id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "One"),
        ]
      )
    )
    XCTAssertEqual(model.discoverySource, .browserExtension)
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    XCTAssertEqual(model.candidates.map(\.workID), ["1234567890123"])
    model.toggleSelection("1234567890123")
    XCTAssertTrue(model.mergeExternalCandidates(
      XProfileCandidatesRequest(
        requestId: "req-2",
        profileURL: "https://x.com/sample_author",
        authorID: "sample_author",
        items: [
          .init(id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "One"),
          .init(id: "1234567890456", url: "https://x.com/sample_author/status/1234567890456", previewText: "Two"),
        ]
      )
    ))
    XCTAssertEqual(model.selectedIDs, ["1234567890123"])
    XCTAssertEqual(model.candidates.map(\.workID), ["1234567890123", "1234567890456"])
    model.continueLoading()
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    XCTAssertTrue((model.saveMessage ?? "").contains("浏览器"))
  }

  func testEmbeddedXImportAdoptsBrowserCandidatesWithoutClearingSelection() {
    let model = makeModel()
    model.input = "https://x.com/sample_author"
    model.start()
    model.acceptNavigation(URL(string: "https://x.com/sample_author")!)
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertEqual(model.discoverySource, .embeddedWebKit)
    let snapshot = DouyinProfileDOMSnapshot(
      status: "ready",
      profileAuthorID: "sample_author",
      profileName: "要查看键盘快捷键，按下问号查看键盘快捷键",
      activeTab: "Posts",
      candidates: [
        DouyinProfileDOMCandidate(
          url: "https://x.com/sample_author/status/1234567890123",
          authorID: "sample_author",
          previewText: "One",
          coverURL: nil,
          publishedText: "Now"
        )
      ]
    )
    XCTAssertEqual(model.merge(snapshot), .keepLoading)
    model.toggleSelection("1234567890123")
    XCTAssertTrue(model.mergeExternalCandidates(
      XProfileCandidatesRequest(
        requestId: "browser-1",
        profileURL: "https://x.com/sample_author",
        authorID: "sample_author",
        profileName: "DAN KOE",
        items: [
          .init(id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "One"),
          .init(id: "1234567890456", url: "https://x.com/sample_author/status/1234567890456", previewText: "Two"),
        ]
      )
    ))
    XCTAssertEqual(model.discoverySource, .browserExtension)
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    XCTAssertEqual(model.selectedIDs, ["1234567890123"])
    XCTAssertEqual(model.candidates.map(\.workID), ["1234567890123", "1234567890456"])
    XCTAssertEqual(model.profileName, "DAN KOE")
    XCTAssertFalse(model.isScanning)
  }

  func testDoesNotMergeXCandidatesIntoDouyinWithTheSameAuthorID() {
    let model = makeModel()
    model.input = "https://www.douyin.com/user/alice"
    model.start()
    model.acceptNavigation(URL(string: "https://www.douyin.com/user/alice")!)
    XCTAssertEqual(model.platform, .douyin)
    XCTAssertEqual(model.currentAuthorID, "alice")
    XCTAssertFalse(model.mergeExternalCandidates(
      XProfileCandidatesRequest(
        requestId: "x-alice",
        profileURL: "https://x.com/alice",
        authorID: "alice",
        items: [.init(id: "1234567890123", url: "https://x.com/alice/status/1234567890123", previewText: "A")]
      )
    ))
    XCTAssertEqual(model.platform, .douyin)
    XCTAssertEqual(model.discoverySource, .embeddedWebKit)
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertTrue(model.candidates.isEmpty)
  }

  func testBrowserHandoffIgnoresInFlightWebKitSnapshotAndNavigation() async throws {
    let model = makeModel()
    model.input = "https://x.com/sample_author"
    model.start()
    model.acceptNavigation(URL(string: "https://x.com/sample_author")!)
    let coordinator = DouyinProfileImportWebView.Coordinator(model: model)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let navigation = try XCTUnwrap(webView.loadHTMLString("<p>Open</p>", baseURL: nil))
    coordinator.trackNavigation(navigation, requestID: model.navigationRequestID)
    let pending = PendingProfileJavaScript()
    let invoked = expectation(description: "Extraction suspended")
    let task = coordinator.startScan { script in
      pending.scripts.append(script)
      return try await withCheckedThrowingContinuation { continuation in
        pending.continuation = continuation
        invoked.fulfill()
      }
    }
    await fulfillment(of: [invoked], timeout: 2)
    XCTAssertTrue(model.mergeExternalCandidates(
      XProfileCandidatesRequest(
        requestId: "browser-1",
        profileURL: "https://x.com/sample_author",
        authorID: "sample_author",
        profileName: "DAN KOE",
        items: [.init(id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "One")]
      )
    ))
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    let stale = DouyinProfileDOMSnapshot(
      status: "ready",
      profileAuthorID: "sample_author",
      profileName: "WK overwrite",
      activeTab: "Posts",
      candidates: [
        DouyinProfileDOMCandidate(
          url: "https://x.com/sample_author/status/9999999999999",
          authorID: "sample_author",
          previewText: "Stale",
          coverURL: nil,
          publishedText: "Then"
        )
      ]
    )
    pending.continuation?.resume(returning: String(decoding: try JSONEncoder().encode(stale), as: UTF8.self))
    await task.value
    coordinator.finishNavigation(navigation, url: URL(string: "https://x.com/other_author")!)
    coordinator.failNavigation(navigation, error: URLError(.notConnectedToInternet))
    model.scanFailed(scanRequestID: model.scanRequestID)
    XCTAssertEqual(model.merge(stale), .stop(.browserExtension))
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    XCTAssertEqual(model.profileName, "DAN KOE")
    XCTAssertEqual(model.candidates.map(\.workID), ["1234567890123"])
    XCTAssertEqual(model.discoverySource, .browserExtension)
  }

  func testPrepareForBrowserHandoffStopsEmbeddedScanAndKeepsAuthor() {
    let model = makeModel()
    model.input = "https://x.com/sample_author"
    model.start()
    model.acceptNavigation(URL(string: "https://x.com/sample_author")!)
    model.prepareForBrowserHandoff()
    XCTAssertEqual(model.discoverySource, .browserExtension)
    XCTAssertEqual(model.phase, .stopped(.browserExtension))
    XCTAssertEqual(model.currentAuthorID, "sample_author")
    XCTAssertEqual(model.platform, .x)
  }

  func testShortLinkToAWorkFailsClearlyButLoginNavigationCanStillResolve() {
    let model = makeModel()
    model.input = "https://v.douyin.com/fixture/"
    model.start()
    model.acceptNavigation(URL(string: "https://www.douyin.com/passport/login")!)
    XCTAssertEqual(model.phase, .loading)
    model.acceptNavigation(URL(string: "https://www.douyin.com/video/7000000000000000001")!)
    XCTAssertEqual(model.phase, .failed("这是单条作品链接，请改用单条保存入口，不能当作博主主页导入。"))
  }

  func testCancelledAndOldNavigationCallbacksCannotStopOrRebindCurrentRequest() throws {
    let model = makeModel()
    model.input = "https://www.douyin.com/user/\(authorID)"
    model.start()
    let coordinator = DouyinProfileImportWebView.Coordinator(model: model)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let oldNavigation = try XCTUnwrap(webView.loadHTMLString("<p>First</p>", baseURL: nil))
    coordinator.trackNavigation(oldNavigation, requestID: model.navigationRequestID)
    model.start()
    let currentNavigation = try XCTUnwrap(webView.loadHTMLString("<p>Second</p>", baseURL: nil))
    coordinator.trackNavigation(currentNavigation, requestID: model.navigationRequestID)
    coordinator.failNavigation(oldNavigation, error: URLError(.networkConnectionLost))
    coordinator.finishNavigation(oldNavigation, url: URL(string: "https://www.douyin.com/user/another-author")!)
    coordinator.failNavigation(currentNavigation, error: URLError(.cancelled))
    XCTAssertEqual(model.phase, .loading)
    coordinator.finishNavigation(currentNavigation, url: URL(string: "https://www.douyin.com/user/\(authorID)")!)
    XCTAssertEqual(model.phase, .scanning)
    coordinator.failNavigation(currentNavigation, error: URLError(.notConnectedToInternet))
    XCTAssertEqual(model.phase, .stopped(.navigationFailed))
  }

  func testStoppedOrPreviousScanCannotMergeOrReportFailureIntoNextRound() {
    let model = makeModel()
    start(model)
    let oldID = model.scanRequestID
    model.stop()
    model.continueLoading()
    XCTAssertEqual(model.merge(snapshot([item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)]), scanRequestID: oldID), .stop(.user))
    model.scanFailed(scanRequestID: oldID)
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertTrue(model.candidates.isEmpty)
  }

  func testSuspendedJavaScriptCannotMergeScrollOrFailAfterCancellationAndResume() async throws {
    for fails in [false, true] {
      let model = makeModel()
      start(model)
      let coordinator = DouyinProfileImportWebView.Coordinator(model: model)
      let pending = PendingProfileJavaScript()
      let invoked = expectation(description: "Extraction suspended")
      let task = coordinator.startScan { script in
        pending.scripts.append(script)
        return try await withCheckedThrowingContinuation { continuation in
          pending.continuation = continuation
          invoked.fulfill()
        }
      }
      await fulfillment(of: [invoked], timeout: 2)
      model.stop()
      coordinator.cancelScan()
      model.continueLoading()
      if fails {
        pending.continuation?.resume(throwing: URLError(.networkConnectionLost))
      } else {
        let data = try JSONEncoder().encode(snapshot([item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)]))
        pending.continuation?.resume(returning: String(decoding: data, as: UTF8.self))
      }
      await task.value
      XCTAssertEqual(pending.scripts.count, 1, "An obsolete extraction must not scroll the new round")
      XCTAssertTrue(model.candidates.isEmpty)
      XCTAssertEqual(model.phase, .scanning)
    }
  }

  func testNavigationRequiresTrustedHTTPSWithoutCredentialsOrCustomPorts() {
    XCTAssertTrue(DouyinProfileNavigationPolicy.allows(URL(string: "https://www.douyin.com/user/fixture")))
    XCTAssertTrue(DouyinProfileNavigationPolicy.allows(URL(string: "https://www.douyin.com:443/user/fixture")))
    for value in ["http://www.douyin.com/", "https://www.douyin.com:8443/", "https://user:pass@www.douyin.com/", "https://douyin.com.example.test/", "file:///tmp/a", "javascript:alert(1)"] {
      XCTAssertFalse(DouyinProfileNavigationPolicy.allows(URL(string: value)), value)
    }
  }

  func testUnsafePreviewURLsAreDroppedBeforeCandidatesReachTheView() {
    let model = makeModel()
    start(model)
    let unsafe = ["http://p3.douyinpic.com/image.jpg", "https://127.0.0.1/a", "https://192.168.1.1/a", "https://[::1]/a", "https://localhost/a", "https://p3.douyinpic.com:8443/a", "https://user:pass@p3.douyinpic.com/a", "data:image/png;base64,AA==", "https://tracker.example.test/a"]
    let cards = unsafe.enumerated().map { index, url in
      DouyinProfileDOMCandidate(url: "https://www.douyin.com/video/\(7_000_000_000_000_000_000 + index)", authorID: authorID, previewText: nil, coverURL: url, publishedText: nil)
    }
    _ = model.merge(snapshot(cards))
    XCTAssertEqual(model.candidates.count, unsafe.count)
    XCTAssertTrue(model.candidates.allSatisfy { $0.coverURL == nil })
    XCTAssertNotNil(DouyinProfilePreviewResource.admittedURL("https://p3-pc-sign.douyinpic.com/image.jpg"))
  }

  func testPreviewFetchUsesSafeResourceRequestAndRejectsUnsafeRedirectTargets() async throws {
    let url = URL(string: "https://p3.douyinpic.com/image.jpg")!
    let resources = ProfilePreviewResources(response: .init(url: url, statusCode: 200, contentType: "image/jpeg", body: Data([1, 2, 3])))
    let data = try await DouyinProfilePreviewResource.fetch(url, using: resources)
    XCTAssertEqual(data, Data([1, 2, 3]))
    let recordedRequest = await resources.lastRequest
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.byteLimit, DouyinProfilePreviewResource.byteLimit)
    XCTAssertEqual(request.headers["Accept"], "image/*")
    XCTAssertNil(request.headers["Cookie"])
    XCTAssertTrue(request.allowsRedirectTarget(URL(string: "https://p9.byteimg.com/image.jpg")!))
    for target in ["http://p3.douyinpic.com/a", "https://127.0.0.1/a", "https://evil.example/a", "https://p3.douyinpic.com:444/a"] {
      XCTAssertFalse(request.allowsRedirectTarget(URL(string: target)!))
    }
    let unsafeResponse = ProfilePreviewResources(response: .init(url: URL(string: "https://127.0.0.1/a")!, statusCode: 200, contentType: "image/jpeg", body: Data([1])))
    do {
      _ = try await DouyinProfilePreviewResource.fetch(url, using: unsafeResponse)
      XCTFail("A transport response outside the permitted image hosts must fail closed")
    } catch { XCTAssertEqual(error as? ManualLinkError, .unsafeURL) }
  }

  func testPreviewTransportRejectsPrivateDNSAndReboundConnectedPeer() async {
    for rebind in [false, true] {
      let resolver = ProfilePreviewResolver(rebind: rebind)
      let transport = PeerBoundNetworkWebPageFetcher(
        resolver: { _ in resolver.resolve() },
        allowLoopbackForTesting: false,
        limits: .init(timeout: 1), portForTesting: 1
      )
      do {
        _ = try await DouyinProfilePreviewResource.fetch(URL(string: "https://p3.douyinpic.com/image.jpg")!, using: transport)
        XCTFail("Private DNS or a rebound numeric peer must be rejected before a connection")
      } catch { XCTAssertEqual(error as? ManualLinkError, .unsafeURL) }
    }
  }

  func testMissingRootWaitsForSPAThenStopsAsPlatformChanged() {
    let model = makeModel()
    start(model)
    let missing = DouyinProfileDOMSnapshot(status: "missing_root", profileAuthorID: authorID, profileName: nil, activeTab: nil, candidates: [])
    for _ in 1..<DouyinProfileImportViewModel.missingRootLimit {
      XCTAssertEqual(model.merge(missing), .keepLoading)
    }
    XCTAssertEqual(model.merge(missing), .stop(.platformChanged))
    model.continueLoading()
    XCTAssertEqual(model.merge(missing), .keepLoading)
    XCTAssertEqual(model.merge(snapshot([item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)])), .keepLoading)
    XCTAssertEqual(model.candidates.count, 1)
  }

  func testDOMIgnoresHiddenCaptchaAndOutsideRecommendations() async throws {
    let result = try await extractFixture("""
      <iframe id="nocaptcha-container" style="display:none;width:0;height:0"></iframe>
      <div style="display:none"><div class="captcha" style="width:200px;height:100px">安全验证</div></div>
      <div role="tab" aria-selected="true">作品 427</div>
      <div data-e2e="user-post-list"><ul><li><a href="/video/7000000000000000001">我的作品</a></li></ul></div>
      <aside><a href="/video/7000000000000000002">推荐作品</a></aside>
      """)
    XCTAssertEqual(result.status, "ready")
    XCTAssertEqual(result.candidates.map(\.url), ["https://www.douyin.com/video/7000000000000000001"])
    XCTAssertEqual(result.candidates.first?.authorID, authorID)
  }

  func testDOMVisibleCaptchaStillStopsAndMissingRootIsExplicit() async throws {
    let verification = try await extractFixture("<iframe id='nocaptcha-container' style='display:none'></iframe><div class='captcha' style='width:200px;height:100px'></div>")
    XCTAssertEqual(verification.status, "verification", "All captcha nodes must be checked, including after a hidden first match")
    let missing = try await extractFixture("<h1>公开主页</h1><div>页面正在加载</div>")
    XCTAssertEqual(missing.status, "missing_root")
    let login = try await extractFixture("<div>登录后查看</div>")
    XCTAssertEqual(login.status, "login")
  }

  func testProfileImportSaveSuppressesAutomaticEnrichmentWithoutChangingOrdinaryManualSave() {
    let document = CapturedDocument(
      createdAt: "2026-09-05T00:00:00Z",
      origin: .manualLink,
      url: "https://www.douyin.com/video/7661288207509769506",
      title: "Fixture",
      platform: "douyin",
      method: "fixture",
      text: "Fixture body",
      completeness: "best_effort",
      capturedAt: "2026-09-05T00:00:00Z",
      sourceLabel: "fixture",
      media: CaptureMedia(platform: "douyin", videoURL: "https://media.example.test/video.mp4")
    )
    let profileImport = CurrentCapture(
      document: document,
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      requestedAction: .save,
      suppressesAutomaticEnrichment: true
    )
    let ordinaryManualSave = CurrentCapture(
      document: document,
      taskID: TaskID(),
      snapshotID: ContentSnapshotID(),
      requestedAction: .save
    )

    XCTAssertEqual(profileImport.requestedAction, .save)
    XCTAssertFalse(profileImport.allowsAutomaticEnrichment)
    XCTAssertFalse(profileImport.shouldAutomaticallyPersistLegacyMedia)
    XCTAssertTrue(ordinaryManualSave.allowsAutomaticEnrichment)
    XCTAssertTrue(ordinaryManualSave.shouldAutomaticallyPersistLegacyMedia)
  }

  func testDOMReadsOnlyVisibleLikesFromMatchingWorkCard() async throws {
    let result = try await extractFixture("""
      <h1>公开作者</h1><span class="author-card-user-video-like">9999万</span>
      <div data-e2e="user-post-list"><ul>
        <li><a href="/video/7000000000000000001"><img alt="第一条" />
          <span class="author-card-user-video-like" style="display:none">999</span>
          <span class="author-card-user-video-like">1.2万</span></a></li>
        <li><a href="/video/7000000000000000002">第二条
          <span class="author-card-user-video-like">0</span></a></li>
        <li><a href="/video/7000000000000000003">第三条</a></li>
      </ul></div>
      """)
    XCTAssertEqual(result.candidates.map(\.likes), ["1.2万", "0", nil])
    XCTAssertTrue(result.candidates.allSatisfy { $0.comments == nil && $0.collects == nil })
  }

  func testDOMChangedCardStructureCannotBorrowNeighborCounts() async throws {
    let result = try await extractFixture("""
      <div data-e2e="user-post-list">
        <a href="/video/7000000000000000001">标题里有 9999 点赞</a>
        <a href="/video/7000000000000000002"><span class="author-card-user-video-like">53</span></a>
        <article>
          <a href="/video/7000000000000000003">无数据</a>
          <a href="/video/7000000000000000004"><span class="author-card-user-video-like">86</span></a>
        </article>
        <a href="/video/7000000000000000005"><span class="author-card-user-video-like">点赞</span></a>
      </div>
      """)
    XCTAssertEqual(result.candidates.map(\.likes), [nil, "53", nil, "86", nil])
  }

  func testMergeEnrichesDuplicateCountsWithoutLosingKnownValuesOrSelection() {
    let model = makeModel()
    start(model)
    var card = item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)
    card.likes = "1.2万"
    _ = model.merge(snapshot([card]))
    model.toggleSelection("7000000000000000001")
    card.likes = nil
    card.comments = "0"
    card.collects = "23"
    _ = model.merge(snapshot([card, card]))
    XCTAssertEqual(model.candidates.count, 1)
    XCTAssertEqual(model.candidates.first?.likes, "1.2万")
    XCTAssertEqual(model.candidates.first?.comments, "0")
    XCTAssertEqual(model.candidates.first?.collects, "23")
    XCTAssertEqual(model.selectedCount, 1)
    card.likes = "1.3万"
    card.comments = "  "
    card.collects = nil
    model.continueLoading()
    _ = model.merge(snapshot([card]))
    XCTAssertEqual(model.candidates.first?.likes, "1.3万")
    XCTAssertEqual(model.candidates.first?.comments, "0")
    XCTAssertEqual(model.candidates.first?.collects, "23")
  }

  func testOldSnapshotsDecodeMissingMetricsAsUnknown() throws {
    let data = Data(#"{"url":"https://www.douyin.com/video/7000000000000000001","authorID":"fixture"}"#.utf8)
    let card = try JSONDecoder().decode(DouyinProfileDOMCandidate.self, from: data)
    XCTAssertNil(card.likes)
    XCTAssertNil(card.comments)
    XCTAssertNil(card.collects)
  }

  func testDetailMetricsRequireMatchingURLInfoAndPlayerIdentity() async throws {
    let id = "7000000000000000001"
    let body = """
      <div data-e2e="detail-video-info" data-e2e-aweme-id="7000000000000000001">作品</div>
      <div data-e2e="player-container" class="video_7000000000000000001">
        <div data-e2e="video-player-digg">1.2万</div>
        <div data-e2e="feed-comment-icon">0</div>
        <div data-e2e="video-player-collect">25</div>
      </div>
      <div data-e2e="player-container" class="video_7000000000000000002">
        <div data-e2e="video-player-digg">9999</div>
      </div>
      """
    let valid = try await extractMetricsFixture(body, expectedID: id)
    XCTAssertEqual(valid.status, "ready")
    XCTAssertEqual(valid.likes, "1.2万")
    XCTAssertEqual(valid.comments, "0")
    XCTAssertEqual(valid.collects, "25")
    let wrongURL = try await extractMetricsFixture(body, expectedID: "7000000000000000002")
    XCTAssertEqual(wrongURL.status, "wrong_work")
    XCTAssertNil(wrongURL.likes)
    let wrongInfo = try await extractMetricsFixture(body.replacingOccurrences(of: "data-e2e-aweme-id=\"7000000000000000001\"", with: "data-e2e-aweme-id=\"7000000000000000002\""), expectedID: id)
    XCTAssertEqual(wrongInfo.status, "wrong_work")
    XCTAssertNil(wrongInfo.likes)
  }

  func testDetailAccessLimitsAndMissingCountsStayExplicit() async throws {
    let id = "7000000000000000001"
    let login = try await extractMetricsFixture("<p>登录后查看</p>", expectedID: id)
    XCTAssertEqual(login.status, "login")
    let verification = try await extractMetricsFixture("<div class='captcha' style='height:100px'>完成验证</div>", expectedID: id)
    XCTAssertEqual(verification.status, "verification")
    let rateLimit = try await extractMetricsFixture("<p>访问过于频繁</p>", expectedID: id)
    XCTAssertEqual(rateLimit.status, "rate_limit")
    XCTAssertTrue(DouyinProfileMetricsCapture.pausesAutomaticReading(rateLimit.status))
    let result = try await extractMetricsFixture("""
      <div data-e2e="detail-video-info" data-e2e-aweme-id="7000000000000000001">作品</div>
      <div data-e2e="player-container" class="video_7000000000000000001">
        <div data-e2e="video-player-digg">0</div>
        <div data-e2e="feed-comment-icon" style="display:none">9999</div>
      </div>
      """, expectedID: id)
    XCTAssertEqual(result.likes, "0")
    XCTAssertNil(result.comments)
    XCTAssertNil(result.collects)
  }

  func testRequestedMetricsCannotUpdateAnotherWorkAndReaderCancels() async {
    let model = makeModel()
    start(model)
    _ = model.merge(snapshot([item("https://www.douyin.com/video/7000000000000000001", authorID: authorID)]))
    model.toggleSelection("7000000000000000001")
    model.updateMetrics(.init(status: "ready", workID: "7000000000000000002", likes: "99", comments: "99", collects: "99"), expectedWorkID: "7000000000000000001")
    XCTAssertNil(model.candidates[0].likes)
    model.updateMetrics(.init(status: "ready", workID: "7000000000000000001", likes: "10", comments: "0", collects: nil), expectedWorkID: "7000000000000000001")
    XCTAssertEqual(model.candidates[0].comments, "0")
    XCTAssertEqual(model.selectedCount, 1)
    let reader = DouyinProfileMetricsReader()
    var loads = 0
    reader.read(model.candidates[0], dataStore: .nonPersistent(), load: { _, _ in loads += 1 }) { _ in
      XCTFail("Cancelled reader must not deliver data")
    }
    XCTAssertEqual(reader.readingID, "7000000000000000001")
    reader.read(model.candidates[0], dataStore: .nonPersistent(), load: { _, _ in loads += 1 }) { _ in }
    XCTAssertEqual(loads, 1, "Only one work may load at a time")
    reader.cancel()
    XCTAssertNil(reader.readingID)
    XCTAssertEqual(reader.messages["7000000000000000001"], "读取已取消，可重试")
    await Task.yield()
  }

  func testWideDetailLayoutRequiresMatchingCompleteVisibleMetricVector() async throws {
    for (visibleValues, expected) in [(["12", "0", "25"], true), (["0", "12", "25"], false), (["12", "0", "24"], false)] {
      let body = """
        <div data-e2e="detail-video-info" data-e2e-aweme-id="7000000000000000001">
          <h1>标题可能包含 12 0 25</h1>
          <div><div><span>\(visibleValues[0])</span></div><div><span>\(visibleValues[1])</span></div>
            <div><span>\(visibleValues[2])</span></div><div data-e2e="video-share-icon-container"><span>20</span></div></div>
        </div>
        <div data-e2e="player-container" class="video_7000000000000000001" style="height:200px">
          <div style="display:none">
            <div data-e2e="video-player-digg">12</div>
            <div data-e2e="feed-comment-icon">0</div>
            <div data-e2e="video-player-collect">25</div>
          </div>
        </div>
        """
      let result = try await extractMetricsFixture(body, expectedID: "7000000000000000001")
      XCTAssertEqual(result.likes, expected ? "12" : nil)
      XCTAssertEqual(result.comments, expected ? "0" : nil)
      XCTAssertEqual(result.collects, expected ? "25" : nil)
      if expected {
        let duplicate = try await extractMetricsFixture(body.replacingOccurrences(of: "25", with: "12"), expectedID: "7000000000000000001")
        XCTAssertEqual(duplicate.likes, "12")
        XCTAssertEqual(duplicate.collects, "12")
      }
    }
  }

  func testReaderRejectsMismatchedCandidateIdentityBeforeLoading() {
    let reader = DouyinProfileMetricsReader()
    let candidate = DouyinProfileImportCandidate(workID: "7000000000000000001", authorID: authorID,
      canonicalURL: "https://www.douyin.com/video/7000000000000000002", previewText: nil,
      coverURL: nil, publishedText: nil, wasAlreadySaved: false)
    reader.read(candidate, dataStore: .nonPersistent(), load: { _, _ in XCTFail("Mismatched identity must not load") }) { _ in XCTFail("No data expected") }
    XCTAssertNil(reader.readingID)
  }

  func testPartialCacheIsReceivedThenReadingContinues() {
    var cache = DouyinProfileMetricsCache()
    cache.store(.init(
      workID: "7000000000000000001",
      authorID: authorID,
      likes: "1",
      comments: nil,
      collects: "2",
      observedAt: "2026-09-07T14:00:00Z",
      source: DouyinProfileMetricsSource.homepageList
    ))
    let reader = DouyinProfileMetricsReader(cache: cache)
    var received: [DouyinProfileWorkMetrics] = []
    let candidate = DouyinProfileImportCandidate(
      workID: "7000000000000000001",
      authorID: authorID,
      canonicalURL: "https://www.douyin.com/video/7000000000000000001",
      previewText: nil,
      coverURL: nil,
      publishedText: nil,
      wasAlreadySaved: false
    )
    reader.read(candidate, dataStore: .nonPersistent(), load: { _, _ in }) { received.append($0) }
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received[0].likes, "1")
    XCTAssertNil(received[0].comments)
    XCTAssertEqual(received[0].collects, "2")
    XCTAssertEqual(reader.messages["7000000000000000001"], DouyinProfileMetricsCapture.partialMessage)
    XCTAssertEqual(DouyinProfileMetricsCapture.partialMessage, "仍有未读取项")
    XCTAssertEqual(reader.readingID, "7000000000000000001")
    reader.cancel()
    XCTAssertNil(reader.readingID)
  }

  func testCompleteCacheDoesNotOpenDetailPage() {
    var cache = DouyinProfileMetricsCache()
    cache.store(.init(
      workID: "7000000000000000001",
      authorID: authorID,
      likes: "1",
      comments: "0",
      collects: "2",
      observedAt: "2026-09-07T14:00:00Z",
      source: DouyinProfileMetricsSource.homepageList
    ))
    let reader = DouyinProfileMetricsReader(cache: cache)
    var loads = 0
    var received: [DouyinProfileWorkMetrics] = []
    let candidate = DouyinProfileImportCandidate(
      workID: "7000000000000000001",
      authorID: authorID,
      canonicalURL: "https://www.douyin.com/video/7000000000000000001",
      previewText: nil,
      coverURL: nil,
      publishedText: nil,
      wasAlreadySaved: false
    )
    reader.read(candidate, dataStore: .nonPersistent(), load: { _, _ in loads += 1 }) { received.append($0) }
    XCTAssertEqual(loads, 0)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received[0].comments, "0")
    XCTAssertEqual(reader.messages["7000000000000000001"], "数据已更新")
    XCTAssertNil(reader.readingID)
  }

  private func extractMetricsFixture(_ body: String, expectedID: String) async throws -> DouyinProfileWorkMetrics {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
    let loaded = expectation(description: "Detail DOM loaded")
    let delegate = ProfileFixtureNavigation(loaded: loaded)
    webView.navigationDelegate = delegate
    webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://www.douyin.com/video/7000000000000000001")!)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await webView.evaluateJavaScript(DouyinProfileMetricsReader.extractionJavaScript(workID: expectedID))
    return try JSONDecoder().decode(DouyinProfileWorkMetrics.self, from: Data(try XCTUnwrap(raw as? String).utf8))
  }

  func testVisibleMetricsQueueReadsOneVisibleWorkAtATimeInGridOrder() {
    var queue = DouyinProfileVisibleMetricsQueue()
    queue.setVisible("second", true)
    queue.setVisible("first", true)
    XCTAssertEqual(queue.next(in: ["first", "second", "offscreen"]), "first")
    XCTAssertNil(queue.next(in: ["first", "second"]))
    queue.finish("wrong")
    XCTAssertEqual(queue.activeID, "first")
    queue.finish("first")
    XCTAssertEqual(queue.next(in: ["first", "second"]), "second")
    queue.finish("second")
    queue.setVisible("first", false)
    queue.setVisible("first", true)
    XCTAssertNil(queue.next(in: ["first", "second"]), "Scrolling must not retry previously attempted works")
  }

  func testVisibleMetricsQueueDropsUnstartedOffscreenWorks() {
    var queue = DouyinProfileVisibleMetricsQueue()
    queue.setVisible("first", true)
    queue.setVisible("second", true)
    XCTAssertEqual(queue.next(in: ["first", "second"]), "first")
    queue.setVisible("second", false)
    queue.finish("first")
    XCTAssertNil(queue.next(in: ["first", "second"]))
    XCTAssertFalse(queue.attemptedIDs.contains("second"))
    queue.setVisible("second", true)
    XCTAssertEqual(queue.next(in: ["first", "second"]), "second")
  }

  func testVisibleMetricsQueueRetriesOnlyExplicitlyAndNeverAfterClose() {
    var queue = DouyinProfileVisibleMetricsQueue()
    queue.setVisible("first", true)
    XCTAssertEqual(queue.next(in: ["first"]), "first")
    queue.finish("first")
    XCTAssertNil(queue.next(in: ["first"]))
    queue.retry("first")
    XCTAssertEqual(queue.next(in: ["first"]), "first")
    queue.stop()
    queue.finish("first")
    queue.setVisible("second", true)
    queue.retry("first")
    XCTAssertNil(queue.next(in: ["first", "second"]))
    XCTAssertTrue(queue.visibleIDs.isEmpty)
    XCTAssertNil(queue.activeID)
  }

  func testVisibleMetricsQueuePausesWhenHomepageReplacesGrid() {
    var queue = DouyinProfileVisibleMetricsQueue()
    queue.setVisible("first", true)
    queue.setVisible("second", true)
    XCTAssertEqual(queue.next(in: ["first", "second"]), "first")
    queue.clearVisible()
    queue.finish("first")
    XCTAssertNil(queue.next(in: ["first", "second"]))
    queue.setVisible("second", true)
    XCTAssertEqual(queue.next(in: ["first", "second"]), "second")
  }

  func testVisibleMetricsQueuePausesOnVerificationUntilExplicitRetry() {
    var queue = DouyinProfileVisibleMetricsQueue()
    queue.setVisible("first", true)
    queue.setVisible("second", true)
    XCTAssertEqual(queue.next(in: ["first", "second"]), "first")
    queue.finish("first")
    queue.pause()
    XCTAssertNil(queue.next(in: ["first", "second"]))
    queue.retry("second")
    XCTAssertEqual(queue.next(in: ["first", "second"]), "second")
  }

  func testHomepageListMapMergesOntoExistingDOMCandidatesWithoutStartingNewIDs() {
    let model = makeModel()
    start(model)
    var card = item("https://www.douyin.com/video/7682764905618918710", authorID: authorID)
    card.likes = "19"
    _ = model.merge(snapshot([card]))
    XCTAssertEqual(model.incompleteMetricIDs, ["7682764905618918710"])
    card.comments = "2"
    card.collects = "9"
    card.metricsSource = DouyinProfileMetricsSource.homepageList
    card.metricsReadAt = "2026-09-07T14:00:00Z"
    _ = model.merge(snapshot([card]))
    XCTAssertEqual(model.candidates.count, 1)
    XCTAssertEqual(model.candidates[0].likes, "19")
    XCTAssertEqual(model.candidates[0].comments, "2")
    XCTAssertEqual(model.candidates[0].collects, "9")
    XCTAssertEqual(model.candidates[0].metricsSource, DouyinProfileMetricsSource.homepageList)
    XCTAssertTrue(model.incompleteMetricIDs.isEmpty, "Complete homepage list stats must not need per-item detail")
  }

  func testSaveSelectedPassesSeedsWithPreviewAndKeepsLegacyURLEnqueue() {
    final class CaptureBox {
      var urls: [String] = []
      var seeds: [ProfileImportCandidateSeed] = []
    }
    let captured = CaptureBox()
    let model = DouyinProfileImportViewModel(
      alreadySaved: { _ in false },
      enqueue: { urls, _, _ in
        captured.urls = urls
        return .init(queued: urls.count, skipped: 0)
      },
      enqueueCandidates: { seeds, downloads, _ in
        captured.seeds = seeds
        XCTAssertFalse(downloads)
        return .init(queued: seeds.count, skipped: 0)
      }
    )
    start(model)
    let card = DouyinProfileDOMCandidate(
      url: "https://www.douyin.com/video/7682764905618918710", authorID: authorID,
      previewText: "羊羊作品", coverURL: nil, publishedText: nil,
      likes: "19", comments: "2", collects: "9"
    )
    _ = model.merge(snapshot([card]))
    model.toggleSelection("7682764905618918710")
    XCTAssertEqual(model.saveSelected(), 1)
    XCTAssertEqual(model.saveSelected(), 0, "An empty second submit must not navigate or enqueue again")
    XCTAssertEqual(captured.seeds.count, 1)
    XCTAssertEqual(captured.seeds.first?.workID, "7682764905618918710")
    XCTAssertEqual(captured.seeds.first?.authorID, authorID)
    XCTAssertEqual(captured.seeds.first?.canonicalURL, "https://www.douyin.com/video/7682764905618918710")
    XCTAssertEqual(captured.seeds.first?.previewText, "羊羊作品")
    XCTAssertEqual(captured.seeds.first?.likes, "19")
    XCTAssertEqual(captured.seeds.first?.comments, "2")
    XCTAssertEqual(captured.seeds.first?.collects, "9")
    XCTAssertTrue(captured.urls.isEmpty, "Seed path must not fall back to URL-only enqueue")
  }

  func testDOMMergesCapturedHomepageListStatsForMatchingAuthorOnly() async throws {
    let result = try await extractFixture("""
      <div data-e2e="user-post-list"><ul>
        <li><a href="/video/7682764905618918710"><img alt="一条" />
          <span class="author-card-user-video-like">19</span></a></li>
        <li><a href="/video/7682315027700927784">二条
          <span class="author-card-user-video-like">71</span></a></li>
      </ul></div>
      <script>
      window.__linkdigestAwemeStats = {
        "7682764905618918710": {workID:"7682764905618918710",authorID:"\(authorID)",likes:"19",comments:"2",collects:"9",observedAt:"2026-09-07T14:00:00Z",source:"homepage_list"},
        "7682315027700927784": {workID:"7682315027700927784",authorID:"other-author",likes:"0",comments:"0",collects:"0",observedAt:"2026-09-07T14:00:00Z",source:"homepage_list"},
        "7999999999999999999": {workID:"7999999999999999999",authorID:"\(authorID)",likes:"999",comments:"999",collects:"999",observedAt:"2026-09-07T14:00:00Z",source:"homepage_list"}
      };
      </script>
      """)
    XCTAssertEqual(result.candidates.map(\.url), [
      "https://www.douyin.com/video/7682764905618918710",
      "https://www.douyin.com/video/7682315027700927784",
    ])
    XCTAssertEqual(result.candidates[0].likes, "19")
    XCTAssertEqual(result.candidates[0].comments, "2")
    XCTAssertEqual(result.candidates[0].collects, "9")
    XCTAssertEqual(result.candidates[0].metricsSource, DouyinProfileMetricsSource.homepageList)
    XCTAssertEqual(result.candidates[1].likes, "71")
    XCTAssertNil(result.candidates[1].comments)
    XCTAssertNil(result.candidates[1].collects)
    XCTAssertFalse(result.candidates.contains { $0.url.contains("7999999999999999999") })
  }

  private func makeModel(
    alreadySaved: @escaping (String) -> Bool = { _ in false },
    enqueue: @escaping ([String], Bool) -> ManualLinkViewModel.ProfileImportEnqueueOutcome = { urls, _ in
      .init(queued: urls.count, skipped: 0)
    },
    ensureCreator: @escaping (String, String, String?) -> CreatorID? = { _, _, _ in nil },
    refreshCreatorName: @escaping (CreatorID, String?, String?) -> Void = { _, _, _ in },
    attachExisting: @escaping (CreatorID, [String]) -> Void = { _, _ in }
  ) -> DouyinProfileImportViewModel {
    DouyinProfileImportViewModel(
      alreadySaved: alreadySaved,
      enqueue: { urls, downloads, _ in enqueue(urls, downloads) },
      ensureCreator: ensureCreator,
      refreshCreatorName: refreshCreatorName,
      attachExisting: attachExisting
    )
  }

  private func extractFixture(_ body: String) async throws -> DouyinProfileDOMSnapshot {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    let loaded = expectation(description: "Local DOM fixture loaded")
    let delegate = ProfileFixtureNavigation(loaded: loaded)
    webView.navigationDelegate = delegate
    webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://www.douyin.com/user/\(authorID)")!)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await webView.evaluateJavaScript(DouyinProfileImportWebView.Coordinator.extractionJavaScript)
    let json = try XCTUnwrap(raw as? String)
    return try JSONDecoder().decode(DouyinProfileDOMSnapshot.self, from: Data(json.utf8))
  }

  private func start(_ model: DouyinProfileImportViewModel) {
    model.input = "https://www.douyin.com/user/\(authorID)"
    model.start()
    model.acceptNavigation(URL(string: "https://www.douyin.com/user/\(authorID)")!)
    XCTAssertEqual(model.phase, .scanning)
  }

  private func snapshot(_ candidates: [DouyinProfileDOMCandidate]) -> DouyinProfileDOMSnapshot {
    .init(
      status: "ready",
      profileAuthorID: authorID,
      profileName: "毕导",
      activeTab: "作品",
      candidates: candidates
    )
  }

  private func item(_ url: String, authorID: String) -> DouyinProfileDOMCandidate {
    .init(
      url: url,
      authorID: authorID,
      previewText: "预览",
      coverURL: "https://p.example.test/cover.jpg",
      publishedText: "2026-09-05"
    )
  }
}

@MainActor
private final class PendingProfileJavaScript {
  var scripts: [String] = []
  var continuation: CheckedContinuation<Any?, Error>?
}

@MainActor
private final class ProfileFixtureNavigation: NSObject, WKNavigationDelegate {
  let loaded: XCTestExpectation
  init(loaded: XCTestExpectation) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

private actor ProfilePreviewResources: SafeResourceFetching {
  let response: SafeResourceResponse
  private(set) var lastRequest: SafeResourceRequest?
  init(response: SafeResourceResponse) { self.response = response }
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lastRequest = request
    return response
  }
}

private final class ProfilePreviewResolver: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  let rebind: Bool
  init(rebind: Bool) { self.rebind = rebind }
  func resolve() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return rebind && calls == 1 ? ["93.184.216.34"] : ["127.0.0.1"]
  }
}
