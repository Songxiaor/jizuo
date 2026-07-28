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
      "author": "青山言粉丝3.4万获赞11.8万",
      "publishedAt": "发布时间：2026-07-11 23:11",
      "videoURL": "https://v3.douyinvod.com/example",
      "coverURL": "https://p3.douyinpic.com/example.jpeg",
      "durationSeconds": 510.0,
    ])

    XCTAssertEqual(page.awemeID, "7661288207509769506")
    XCTAssertEqual(page.author, "青山言")
    XCTAssertEqual(page.publishedAt, "2026-07-11 23:11")
    XCTAssertEqual(page.durationSeconds, 510)
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
  }
}
