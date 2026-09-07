import Foundation
import Combine
import WebKit
import XCTest
@testable import LinkDigestApp

@MainActor
final class DouyinProfileMetricsTests: XCTestCase {
  private let authorID = "MS4wLjABAAAA26unzRl4eTG2pAGnxD1pS3kMvjaUIcNxvLGr3VJOiKU"
  private let observedAt = "2026-09-07T14:00:00Z"

  func testJSONIntegerZeroAndOneAreNotBooleans() throws {
    let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[0,1,true,false]".utf8)) as? [Any])
    XCTAssertEqual(DouyinProfileMetricsCapture.count(values[0]), "0")
    XCTAssertEqual(DouyinProfileMetricsCapture.count(values[1]), "1")
    XCTAssertNil(DouyinProfileMetricsCapture.count(values[2]))
    XCTAssertNil(DouyinProfileMetricsCapture.count(values[3]))
  }

  func testDeadlineReleasesReaderWithoutAnyPageResponse() async {
    let reader = DouyinProfileMetricsReader()
    let finished = expectation(description: "Independent timeout releases current work")
    let observation = reader.$readingID.dropFirst().filter { $0 == nil }.sink { _ in finished.fulfill() }
    let candidate = DouyinProfileImportCandidate(
      workID: "7000000000000000001", authorID: authorID,
      canonicalURL: "https://www.douyin.com/video/7000000000000000001",
      previewText: nil, coverURL: nil, publishedText: nil, wasAlreadySaved: false
    )
    reader.read(candidate, dataStore: .nonPersistent(), deadlineSeconds: 0.05, load: { _, _ in }) { _ in
      XCTFail("An unresponsive page must not invent values")
    }
    XCTAssertEqual(reader.readingID, candidate.id)
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertNil(reader.readingID)
    XCTAssertEqual(reader.messages[candidate.id], "读取超时，可重试")
    observation.cancel()
  }

  func testAllowsOnlyHTTPSDouyinListAndDetailPaths() {
    XCTAssertTrue(DouyinProfileMetricsCapture.allows(URL(string: "https://www.douyin.com/aweme/v1/web/aweme/post/?sec_uid=x")!))
    XCTAssertTrue(DouyinProfileMetricsCapture.allows(URL(string: "https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=1")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "https://www.douyin.com/aweme/v1/web/comment/list/")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "http://www.douyin.com/aweme/v1/web/aweme/post/")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "https://evil.example/aweme/v1/web/aweme/post/")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "https://user:pass@www.douyin.com/aweme/v1/web/aweme/post/")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "https://www.douyin.com/other/aweme/v1/web/aweme/post/")!))
    XCTAssertFalse(DouyinProfileMetricsCapture.allows(URL(string: "https://other.douyin.com/aweme/v1/web/aweme/post/")!))
    XCTAssertTrue(DouyinProfileMetricsCapture.allows(URL(string: "https://douyin.com/aweme/v1/web/aweme/post/")!))
  }

  func testCountRejectsBooleanFractionAndWhitespaceAndKeepsZero() {
    XCTAssertEqual(DouyinProfileMetricsCapture.count(0), "0")
    XCTAssertEqual(DouyinProfileMetricsCapture.count("0"), "0")
    XCTAssertNil(DouyinProfileMetricsCapture.count(true))
    XCTAssertNil(DouyinProfileMetricsCapture.count(NSNumber(value: true)))
    XCTAssertNil(DouyinProfileMetricsCapture.count(1.5))
    XCTAssertNil(DouyinProfileMetricsCapture.count(" "))
    XCTAssertNil(DouyinProfileMetricsCapture.count("1.5"))
    XCTAssertTrue(DouyinProfileMetricsCapture.pausesAutomaticReading("login"))
    XCTAssertTrue(DouyinProfileMetricsCapture.pausesAutomaticReading("verification"))
    XCTAssertTrue(DouyinProfileMetricsCapture.pausesAutomaticReading("rate_limit"))
    XCTAssertFalse(DouyinProfileMetricsCapture.pausesAutomaticReading("ready"))
  }

  func testDifferentAuthorDoesNotInheritPriorCounts() {
    let first = DouyinProfileMetricsProjection(
      workID: "7000000000000000010",
      authorID: "author-fixture",
      likes: "5",
      comments: nil,
      collects: nil,
      observedAt: observedAt,
      source: DouyinProfileMetricsSource.homepageList
    )
    let second = DouyinProfileMetricsProjection(
      workID: "7000000000000000010",
      authorID: "other-author",
      likes: nil,
      comments: "4",
      collects: nil,
      observedAt: "2026-09-07T14:01:00Z",
      source: DouyinProfileMetricsSource.homepageList
    )
    let merged = DouyinProfileMetricsCapture.merging(first, with: second)
    XCTAssertEqual(merged.authorID, "other-author")
    XCTAssertNil(merged.likes)
    XCTAssertEqual(merged.comments, "4")
  }

  func testProjectsYangyangListCountsByAuthorAndAwemeID() throws {
    let json = try JSONSerialization.jsonObject(with: Data(yangyangListJSON().utf8))
    let projected = DouyinProfileMetricsCapture.project(
      jsonObject: json,
      observedAt: observedAt,
      source: DouyinProfileMetricsSource.homepageList
    )
    XCTAssertEqual(projected.count, 21)
    let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.workID, $0) })
    XCTAssertEqual(byID["7682764905618918710"]?.likes, "19")
    XCTAssertEqual(byID["7682764905618918710"]?.comments, "2")
    XCTAssertEqual(byID["7682764905618918710"]?.collects, "9")
    XCTAssertEqual(byID["7682315027700927784"]?.likes, "71")
    XCTAssertEqual(byID["7682315027700927784"]?.comments, "11")
    XCTAssertEqual(byID["7682315027700927784"]?.collects, "42")
    XCTAssertEqual(byID["7681288365844614446"]?.likes, "73")
    XCTAssertEqual(byID["7681288365844614446"]?.comments, "10")
    XCTAssertEqual(byID["7681288365844614446"]?.collects, "33")
    XCTAssertTrue(projected.allSatisfy { $0.authorID == authorID })
    XCTAssertTrue(projected.allSatisfy { $0.source == DouyinProfileMetricsSource.homepageList })
  }

  func testMatchingKeepsDiscoveredSameAuthorWorksAndDropsNeighbors() throws {
    let json = try JSONSerialization.jsonObject(with: Data(yangyangListJSON(includeNeighbor: true).utf8))
    let projected = DouyinProfileMetricsCapture.project(
      jsonObject: json,
      observedAt: observedAt,
      source: DouyinProfileMetricsSource.homepageList
    )
    let discovered: Set<String> = ["7682764905618918710", "7682315027700927784"]
    let matched = DouyinProfileMetricsCapture.matching(projected, authorID: authorID, discoveredWorkIDs: discovered)
    XCTAssertEqual(Set(matched.keys), discovered)
    XCTAssertNil(matched["7681288365844614446"], "Not yet discovered on the current homepage")
    XCTAssertNil(matched["7999999999999999999"], "Recommended neighbor must not be borrowed")
  }

  func testZeroIsKeptAndNilDoesNotOverwrite() {
    let first = DouyinProfileMetricsProjection(
      workID: "7682764905618918710",
      authorID: authorID,
      likes: "0",
      comments: nil,
      collects: "9",
      observedAt: observedAt,
      source: DouyinProfileMetricsSource.homepageList
    )
    let second = DouyinProfileMetricsProjection(
      workID: "7682764905618918710",
      authorID: authorID,
      likes: nil,
      comments: "2",
      collects: nil,
      observedAt: "2026-09-07T14:01:00Z",
      source: DouyinProfileMetricsSource.detailList
    )
    let merged = DouyinProfileMetricsCapture.merging(first, with: second)
    XCTAssertEqual(merged.likes, "0")
    XCTAssertEqual(merged.comments, "2")
    XCTAssertEqual(merged.collects, "9")
    XCTAssertEqual(DouyinProfileMetricsCapture.count(0), "0")
    XCTAssertNil(DouyinProfileMetricsCapture.count(NSNull()))
  }

  func testCacheDedupsByWorkAndExpires() {
    var cache = DouyinProfileMetricsCache()
    cache.ttl = 60
    let now = Date(timeIntervalSince1970: 1_000)
    cache.store(
      .init(
        workID: "7682764905618918710",
        authorID: authorID,
        likes: "19",
        comments: "2",
        collects: "9",
        observedAt: observedAt,
        source: DouyinProfileMetricsSource.homepageList
      ),
      now: now
    )
    XCTAssertEqual(cache.lookup(workID: "7682764905618918710", authorID: authorID, now: now.addingTimeInterval(10))?.likes, "19")
    XCTAssertNil(cache.lookup(workID: "7682764905618918710", authorID: "other", now: now))
    XCTAssertNil(cache.lookup(workID: "7682764905618918710", authorID: authorID, now: now.addingTimeInterval(61)))
  }

  func testDocumentStartScriptInstallsEmptyProjectionStore() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.addUserScript(DouyinProfileMetricsCapture.documentStartUserScript())
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    let loaded = expectation(description: "User script page loaded")
    let delegate = MetricsFixtureNavigation(loaded: loaded)
    webView.navigationDelegate = delegate
    webView.loadHTMLString("<html><body>主页</body></html>", baseURL: URL(string: "https://www.douyin.com/user/\(authorID)")!)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await webView.evaluateJavaScript("JSON.stringify(window.__linkdigestAwemeStats || null)")
    XCTAssertEqual(raw as? String, "{}")
  }

  func testDetailScriptReadsNoteStructuredProjectionWithoutPlayer() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
    let loaded = expectation(description: "Note fixture loaded")
    let delegate = MetricsFixtureNavigation(loaded: loaded)
    webView.navigationDelegate = delegate
    let html = """
      <div data-e2e="note-detail" style="width:200px;height:200px">图文</div>
      <script>
      window.__linkdigestAwemeStats = {
        "7000000000000000001": {
          workID: "7000000000000000001",
          authorID: "\(authorID)",
          likes: "0",
          comments: "2",
          collects: "1",
          observedAt: "2026-09-07T14:00:00Z",
          source: "detail_list"
        }
      };
      </script>
      """
    webView.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: "https://www.douyin.com/note/7000000000000000001")!)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await webView.evaluateJavaScript(
      DouyinProfileMetricsCapture.detailExtractionJavaScript(workID: "7000000000000000001", authorID: authorID)
    )
    let metrics = try JSONDecoder().decode(DouyinProfileWorkMetrics.self, from: Data(try XCTUnwrap(raw as? String).utf8))
    XCTAssertEqual(metrics.status, "ready")
    XCTAssertEqual(metrics.likes, "0")
    XCTAssertEqual(metrics.comments, "2")
    XCTAssertEqual(metrics.collects, "1")
    XCTAssertEqual(metrics.source, DouyinProfileMetricsSource.detailList)
  }

  func testStructuredCountsArePreferredOverDetailDOM() async throws {
    let html = """
      <div data-e2e="detail-video-info" data-e2e-aweme-id="7000000000000000001" style="width:200px;height:80px">
        <div data-e2e="video-share-icon-container">分享</div>
      </div>
      <div data-e2e="player-container" class="video_7000000000000000001" style="width:200px;height:200px">
        <div data-e2e="video-player-digg">99</div>
        <div data-e2e="feed-comment-icon">88</div>
        <div data-e2e="video-player-collect">77</div>
      </div>
      <script>
      window.__linkdigestAwemeStats = {
        "7000000000000000001": {
          workID: "7000000000000000001",
          authorID: "\(authorID)",
          likes: "5",
          comments: null,
          collects: "1",
          observedAt: "2026-09-07T14:00:00Z",
          source: "detail_list"
        }
      };
      </script>
      """
    let metrics = try await evaluateDetail(html: html, path: "/video/7000000000000000001")
    XCTAssertEqual(metrics.status, "ready")
    XCTAssertEqual(metrics.likes, "5")
    XCTAssertEqual(metrics.comments, "88")
    XCTAssertEqual(metrics.collects, "1")
    XCTAssertEqual(metrics.source, DouyinProfileMetricsSource.detailList)
  }

  func testNoteWithoutAuthorIdentityStaysUnknownAndSkipsCommentLikes() async throws {
    let html = """
      <div data-e2e="note-detail" style="width:240px;height:240px">
        <div data-e2e="comment-list" class="comment-list" style="width:120px;height:40px">
          <span aria-label="点赞" style="display:inline-block;width:40px;height:20px">999</span>
        </div>
      </div>
      """
    let metrics = try await evaluateDetail(html: html, path: "/note/7000000000000000001")
    XCTAssertEqual(metrics.status, "pending")
    XCTAssertNil(metrics.likes)
    XCTAssertNil(metrics.comments)
    XCTAssertNil(metrics.collects)
  }

  func testNoteUserInfoAllowsToolbarAndSkipsCommentLikes() async throws {
    let html = """
      <div data-e2e="note-detail" style="width:240px;height:240px">
        <div data-e2e="user-info" style="width:160px;height:24px">
          <a href="/user/\(authorID)" style="display:inline-block;width:120px;height:20px">作者</a>
        </div>
        <span aria-label="点赞" style="display:inline-block;width:40px;height:20px">12</span>
        <div data-e2e="feed-comment-icon" style="width:40px;height:20px">3</div>
        <span aria-label="收藏" style="display:inline-block;width:40px;height:20px">4</span>
        <div data-e2e="comment-list" class="comment-list" style="width:120px;height:40px">
          <span aria-label="点赞" style="display:inline-block;width:40px;height:20px">999</span>
        </div>
      </div>
      """
    let metrics = try await evaluateDetail(html: html, path: "/note/7000000000000000001")
    XCTAssertEqual(metrics.status, "ready")
    XCTAssertEqual(metrics.likes, "12")
    XCTAssertEqual(metrics.comments, "3")
    XCTAssertEqual(metrics.collects, "4")
  }

  func testRateLimitStatusIsExplicit() async throws {
    let metrics = try await evaluateDetail(
      html: "<p style='width:120px;height:20px'>访问过于频繁</p>",
      path: "/video/7000000000000000001"
    )
    XCTAssertEqual(metrics.status, "rate_limit")
    XCTAssertNil(metrics.likes)
  }

  private func evaluateDetail(html: String, path: String) async throws -> DouyinProfileWorkMetrics {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
    let loaded = expectation(description: "Detail fixture loaded")
    let delegate = MetricsFixtureNavigation(loaded: loaded)
    webView.navigationDelegate = delegate
    webView.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: "https://www.douyin.com\(path)")!)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await webView.evaluateJavaScript(
      DouyinProfileMetricsCapture.detailExtractionJavaScript(workID: "7000000000000000001", authorID: authorID)
    )
    return try JSONDecoder().decode(DouyinProfileWorkMetrics.self, from: Data(try XCTUnwrap(raw as? String).utf8))
  }

  private func yangyangListJSON(includeNeighbor: Bool = false) -> String {
    var items = (0..<21).map { index -> String in
      let known: [(String, Int, Int, Int)] = [
        ("7682764905618918710", 19, 2, 9),
        ("7682315027700927784", 71, 11, 42),
        ("7681288365844614446", 73, 10, 33),
      ]
      let id: String
      let likes: Int
      let comments: Int
      let collects: Int
      if index < known.count {
        (id, likes, comments, collects) = known[index]
      } else {
        id = String(7_600_000_000_000_000_000 + index)
        likes = index
        comments = 0
        collects = index * 2
      }
      return aweme(id: id, authorID: authorID, likes: likes, comments: comments, collects: collects)
    }
    if includeNeighbor {
      items.append(aweme(id: "7999999999999999999", authorID: "other-sec-uid", likes: 999, comments: 999, collects: 999))
    }
    return "{\"aweme_list\":[\(items.joined(separator: ","))]}"
  }

  private func aweme(id: String, authorID: String, likes: Int, comments: Int, collects: Int) -> String {
    """
    {"aweme_id":"\(id)","author":{"sec_uid":"\(authorID)"},"statistics":{"digg_count":\(likes),"comment_count":\(comments),"collect_count":\(collects),"share_count":1}}
    """
  }
}

@MainActor
private final class MetricsFixtureNavigation: NSObject, WKNavigationDelegate {
  let loaded: XCTestExpectation
  init(loaded: XCTestExpectation) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
