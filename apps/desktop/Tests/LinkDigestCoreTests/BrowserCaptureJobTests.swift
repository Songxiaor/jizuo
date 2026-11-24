import Foundation
import XCTest
@testable import LinkDigestCore

/// 浏览器代抓的 App/扩展约定：任务查询请求、地址对号、哪些失败值得代抓。
final class BrowserCaptureJobTests: XCTestCase {
  private func decodeRequest(_ object: [String: Any]) throws -> BrowserCaptureJobRequest? {
    try BrowserCaptureJobRequest.decode(try JSONSerialization.data(withJSONObject: object))
  }

  private func query(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = [
      "kind": "browserCaptureJob", "version": 1, "requestId": "q", "tabID": 7,
      "urls": ["https://example.test/page"],
    ]
    for (key, value) in overrides { object[key] = value }
    return object
  }

  func testDecodesJobQueryWithUpToFourHTTPURLs() throws {
    let request = try decodeRequest(query([
      "requestId": "req-1",
      "urls": ["https://v.douyin.com/abc/", "https://www.douyin.com/video/1"],
    ]))
    XCTAssertEqual(request?.requestId, "req-1")
    XCTAssertEqual(request?.tabID, 7)
    XCTAssertEqual(request?.urls.count, 2)
  }

  func testIgnoresOtherMessageKinds() throws {
    XCTAssertNil(try decodeRequest(["kind": "pageStatus", "version": 1, "requestId": "r"]))
  }

  func testRequiresTheAskingTabSoOneJobCannotBeClaimedTwice() {
    XCTAssertThrowsError(try decodeRequest(query(["tabID": 0])))
    XCTAssertThrowsError(try decodeRequest(query(["tabID": -3])))
    XCTAssertThrowsError(try decodeRequest(query(["tabID": "7"])))
    var missing = query()
    missing.removeValue(forKey: "tabID")
    XCTAssertThrowsError(try decodeRequest(missing))
  }

  func testRejectsUnsupportedVersionAndBadURLs() {
    XCTAssertThrowsError(try decodeRequest([
      "kind": "browserCaptureJob", "version": 2, "requestId": "r", "urls": ["https://example.test"],
    ]))
    XCTAssertThrowsError(try decodeRequest([
      "kind": "browserCaptureJob", "version": 1, "requestId": "r", "urls": ["file:///etc/passwd"],
    ]))
    XCTAssertThrowsError(try decodeRequest([
      "kind": "browserCaptureJob", "version": 1, "requestId": "r", "urls": [],
    ]))
  }

  func testMatchesSameContentAcrossRedirectAndTrackingParameters() {
    // 抖音详情页会加自己的查询参数；作品编号一样就认同一篇。
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://www.douyin.com/video/7420000000000000001?previous_page=app_code_link",
      jobURL: "https://www.douyin.com/video/7420000000000000001"
    ))
    // 短链跳转后地址完全换了：扩展把导航过程中见过的短链一起带来，靠它认回 job。
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://v.douyin.com/iFakeShort/",
      jobURL: "https://v.douyin.com/iFakeShort"
    ))
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://www.xiaohongshu.com/discovery/item/66aa00bb?xsec_token=xyz&xsec_source=pc",
      jobURL: "https://www.xiaohongshu.com/explore/66aa00bb"
    ))
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://x.com/someone/status/1234567890?s=20",
      jobURL: "https://x.com/someone/status/1234567890"
    ))
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://www.bilibili.com/video/BV1xx411c7mD/?spm_id_from=x",
      jobURL: "https://www.bilibili.com/video/BV1xx411c7mD"
    ))
  }

  func testDoesNotMatchDifferentContentOrHosts() {
    XCTAssertFalse(BrowserCaptureJobMatching.matches(
      candidate: "https://www.douyin.com/video/111",
      jobURL: "https://www.douyin.com/video/222"
    ))
    XCTAssertFalse(BrowserCaptureJobMatching.matches(
      candidate: "https://example.test/article",
      jobURL: "https://other.test/article"
    ))
  }

  func testMatchingIgnoresFragmentAndTrailingSlash() {
    XCTAssertTrue(BrowserCaptureJobMatching.matches(
      candidate: "https://Example.test/Story/#comments",
      jobURL: "https://example.test/Story"
    ))
  }

  func testRelayPolicyCoversEnvironmentFailuresOnly() {
    for error in [ManualLinkError.extensionCaptureRequired, .timedOut, .verificationRequired,
                  .emptyContent, .invalidPageResult, .loginRequired,
                  .shareLinkMissingToken] {
      XCTAssertTrue(BrowserCaptureRelayPolicy.shouldRelay(error), "\(error) 应该代理给浏览器")
    }
    for error in [ManualLinkError.invalidURL, .unsafeURL, .webHostNotAllowed, .cancelled,
                  .shareLinkExpired, .unsupportedContentType, .proxyAuthenticationRequired] {
      XCTAssertFalse(BrowserCaptureRelayPolicy.shouldRelay(error), "\(error) 不应代抓")
    }
  }

  func testRelayFailureMessagesNeverSendTheUserToTheBrowserByHand() {
    let failures: [BrowserCaptureRelayFailure] = [.browserUnavailable, .extensionNotConnected, .timedOut, .cancelled]
    for failure in failures {
      XCTAssertFalse(failure.code.isEmpty)
      XCTAssertFalse(failure.userMessage.isEmpty)
      for phrase in ["请在浏览器里打开", "用浏览器扩展保存", "请在浏览器中打开"] {
        XCTAssertFalse(failure.userMessage.contains(phrase), "\(failure.code) 仍在要求用户手动操作：\(failure.userMessage)")
      }
    }
  }

  func testNativeResponseCarriesJobIDBothWays() throws {
    let data = try JSONEncoder().encode(
      NativeResponse.browserCaptureJob(version: 1, requestId: "req", jobID: "job-123")
    )
    XCTAssertEqual(
      try JSONDecoder().decode(NativeResponse.self, from: data),
      .browserCaptureJob(version: 1, requestId: "req", jobID: "job-123")
    )
    let none = try JSONEncoder().encode(
      NativeResponse.browserCaptureJob(version: 1, requestId: "req", jobID: nil)
    )
    XCTAssertEqual(
      try JSONDecoder().decode(NativeResponse.self, from: none),
      .browserCaptureJob(version: 1, requestId: "req", jobID: nil)
    )
    // 查询回包不是「送达」，不能算成浏览器刚把内容送进 App。
    XCTAssertFalse(NativeResponse.browserCaptureJob(version: 1, requestId: "r", jobID: "j").isSuccessfulBrowserDelivery)
  }

  func testRelayMarkerSurvivesExistingAnchorsAndStripsCleanly() {
    XCTAssertEqual(
      BrowserCaptureMarker.markedURL("https://v.douyin.com/abc"),
      "https://v.douyin.com/abc#jizuo-relay"
    )
    XCTAssertEqual(
      BrowserCaptureMarker.markedURL("https://example.test/a#top"),
      "https://example.test/a#top&jizuo-relay"
    )
    XCTAssertTrue(BrowserCaptureMarker.contains("https://example.test/a#top&jizuo-relay"))
    XCTAssertFalse(BrowserCaptureMarker.contains("https://example.test/a#top"))
    XCTAssertEqual(
      BrowserCaptureMarker.stripping("https://example.test/a#top&jizuo-relay"),
      "https://example.test/a#top"
    )
    XCTAssertEqual(
      BrowserCaptureMarker.stripping("https://example.test/a#jizuo-relay"),
      "https://example.test/a"
    )
    // 已经是标记过的地址就不要再叠一次。
    XCTAssertEqual(
      BrowserCaptureMarker.markedURL(BrowserCaptureMarker.markedURL("https://example.test/a")),
      "https://example.test/a#jizuo-relay"
    )
  }

  func testHostPolicyMatchesTheExtensionWhitelist() throws {
    XCTAssertTrue(BrowserCaptureHostPolicy.allows(URL(string: "https://v.douyin.com/abc")!))
    XCTAssertTrue(BrowserCaptureHostPolicy.allows(URL(string: "https://www.xiaohongshu.com/explore/1")!))
    XCTAssertTrue(BrowserCaptureHostPolicy.allows(URL(string: "https://mp.weixin.qq.com/s/1")!))
    XCTAssertFalse(BrowserCaptureHostPolicy.allows(URL(string: "https://example.test/article")!))
    XCTAssertFalse(BrowserCaptureHostPolicy.allows(URL(string: "https://notdouyin.com/video/1")!))

    // 运行时读到的名单与扩展读的同一份 JSON 必须一致；兜底名单也不能漂。
    let resource = try XCTUnwrap(
      CoreResourceBundle.resolved()?.url(forResource: "relay-host-permissions", withExtension: "json")
    )
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any]
    )
    let hosts = try XCTUnwrap(object["hosts"] as? [String])
    XCTAssertEqual(hosts, BrowserCaptureHostPolicy.hosts)
    XCTAssertEqual(BrowserCaptureHostPolicy.fallbackHosts, hosts)
  }

  func testPermissionFailureHasItsOwnCodeAndSaysWhatToAllow() {
    let failure = BrowserCaptureRelayFailure.permissionMissing(host: "example.test")
    XCTAssertEqual(failure.code, "browser_capture_permission_missing")
    XCTAssertTrue(failure.userMessage.contains("example.test"))
    XCTAssertTrue(failure.userMessage.contains("允许访问该网站"))
    XCTAssertFalse(failure.userMessage.contains("请在浏览器里打开"))
  }

  func testEnvelopeJobIDIsOptionalAndReadOnlyTopLevel() {
    let withJob = Data(#"{"version":1,"captureJobID":"job-1"}"#.utf8)
    XCTAssertEqual(CaptureWireEnvelope.captureJobID(in: withJob), "job-1")
    let without = Data(#"{"version":1,"source":{"url":"https://example.test"}}"#.utf8)
    XCTAssertNil(CaptureWireEnvelope.captureJobID(in: without))
    let oversized = Data((#"{"version":1,"captureJobID":""# + String(repeating: "a", count: 65) + #""}"#).utf8)
    XCTAssertNil(CaptureWireEnvelope.captureJobID(in: oversized))
  }
  func testOutcomeRequestCarriesTheJobAndThePlatformReason() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "kind": "browserCaptureJobOutcome",
      "version": 1,
      "requestId": "o1",
      "jobID": "job-1",
      "finalURL": "https://www.xiaohongshu.com/404?source=/404/sec_x&error_code=300031",
      "reason": "note_unavailable",
    ])
    let outcome = try XCTUnwrap(try BrowserCaptureJobOutcomeRequest.decode(data))
    XCTAssertEqual(outcome.jobID, "job-1")
    XCTAssertEqual(outcome.reason, .noteUnavailable)
  }

  func testOutcomeRequestRejectsUnknownReasonsAndNonWebURLs() {
    func payload(_ overrides: [String: Any] = [:]) -> Data {
      var object: [String: Any] = [
        "kind": "browserCaptureJobOutcome", "version": 1, "requestId": "o1",
        "jobID": "job-1", "finalURL": "https://example.test/404", "reason": "not_found",
      ]
      for (key, value) in overrides { object[key] = value }
      return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
    XCTAssertNil(try BrowserCaptureJobOutcomeRequest.decode(Data(#"{"kind":"pageStatus"}"#.utf8)))
    XCTAssertThrowsError(try BrowserCaptureJobOutcomeRequest.decode(payload(["reason": "bogus"])))
    XCTAssertThrowsError(try BrowserCaptureJobOutcomeRequest.decode(payload(["finalURL": "file:///etc/passwd"])))
    XCTAssertThrowsError(try BrowserCaptureJobOutcomeRequest.decode(payload(["jobID": ""])))
  }

  func testRelayTabFallbackFlagIsOptionalOnTheQuery() throws {
    XCTAssertEqual(try decodeRequest(query())?.allowsRelayTabFallback, false)
    XCTAssertEqual(try decodeRequest(query(["relayTab": true]))?.allowsRelayTabFallback, true)
  }

  func testLandingDescriptionKeepsHostAndPathOnly() {
    XCTAssertEqual(
      BrowserCaptureLanding.describe("https://www.xiaohongshu.com/404?source=/x&error_code=300031"),
      "www.xiaohongshu.com/404"
    )
    XCTAssertEqual(BrowserCaptureLanding.describe("not a url"), "unknown")
  }

}
