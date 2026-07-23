import Foundation
import XCTest
@testable import LinkDigestCore

final class WeChatWebCapturePolicyTests: XCTestCase {
  func testHostAllowlistAcceptsOnlyExactHTTPSWeChatHost() throws {
    XCTAssertNoThrow(try WeChatWebCapturePolicy.validateNavigationURL(
      URL(string: "https://mp.weixin.qq.com/s/article")!
    ))

    for raw in [
      "http://mp.weixin.qq.com/s/article",
      "https://www.mp.weixin.qq.com/s/article",
      "https://mp.weixin.qq.com.evil.example/s/article",
      "https://example.com/article",
      "file:///tmp/article.html",
      "about:blank",
      "https://user:password@mp.weixin.qq.com/s/article",
      "https://mp.weixin.qq.com:8443/s/article",
    ] {
      XCTAssertThrowsError(try WeChatWebCapturePolicy.validateNavigationURL(URL(string: raw)!)) {
        XCTAssertEqual($0 as? ManualLinkError, .webHostNotAllowed, raw)
      }
    }
  }

  func testEveryRedirectTargetUsesTheSameFailClosedPolicy() throws {
    let sameHostRedirect = URL(string: "https://mp.weixin.qq.com/s/redirected")!
    XCTAssertNoThrow(try WeChatWebCapturePolicy.validateNavigationURL(sameHostRedirect))

    let outsideRedirect = URL(string: "https://weixin.qq.com/redirected")!
    XCTAssertThrowsError(try WeChatWebCapturePolicy.validateNavigationURL(outsideRedirect)) {
      XCTAssertEqual($0 as? ManualLinkError, .webHostNotAllowed)
    }
  }

  func testUntrustedJavaScriptResultRequiresStringTitleAndTextAndDropsExtras() throws {
    for raw: Any in [
      ["title": "Title"],
      ["title": "Title", "text": 42],
      ["title": 42, "text": "Body"],
      ["text": "Body"],
      ["Title", "Body"],
      "not an object",
    ] {
      XCTAssertThrowsError(try WeChatWebCapturePolicy.validateJavaScriptResult(raw)) {
        XCTAssertEqual($0 as? ManualLinkError, .invalidPageResult)
      }
    }

    let accepted = try WeChatWebCapturePolicy.validateJavaScriptResult([
      "title": "  Article title  ",
      "text": "  Article body  ",
      "images": [],
      "redirect": "https://evil.example/",
      "execute": true,
    ])
    XCTAssertEqual(accepted, .init(title: "Article title", text: "Article body"))
  }

  func testEmptyAndOversizedResultsFailBeforeIngest() {
    XCTAssertThrowsError(try WeChatWebCapturePolicy.validateJavaScriptResult([
      "title": "Title", "text": "  \n  ", "images": [],
    ])) {
      XCTAssertEqual($0 as? ManualLinkError, .emptyContent)
    }

    let oversized = String(
      repeating: "x",
      count: WeChatWebCapturePolicy.maximumResultScalars + 1
    )
    XCTAssertThrowsError(try WeChatWebCapturePolicy.validateJavaScriptResult([
      "title": "", "text": oversized, "images": [],
    ])) {
      XCTAssertEqual($0 as? ManualLinkError, .responseTooLarge)
    }
  }

  func testUntrustedSupplementalFieldsRequireBoundedStringsAndCTNormalizesToISO() throws {
    let accepted = try WeChatWebCapturePolicy.validateJavaScriptResult([
      "title": "Title",
      "text": "Body",
      "images": ["https://mmbiz.qpic.cn/one", "https://mmbiz.qpic.cn/one"],
      "coverImage": "https://mmbiz.qpic.cn/cover",
      "accountName": "公众号",
      "author": "作者",
      "publishedAt": "1704067200",
      "ignored": ["never copied"],
    ])
    XCTAssertEqual(accepted.images, ["https://mmbiz.qpic.cn/one"])
    XCTAssertEqual(accepted.coverImage, "https://mmbiz.qpic.cn/cover")
    XCTAssertEqual(accepted.accountName, "公众号")
    XCTAssertEqual(accepted.author, "作者")
    XCTAssertEqual(accepted.publishedAt, "2024-01-01T00:00:00Z")

    let maximumCover = String(repeating: "x", count: WeChatWebCapturePolicy.maximumImageURLScalars)
    XCTAssertEqual(
      try WeChatWebCapturePolicy.validateJavaScriptResult([
        "title": "Title", "text": "Body", "images": [], "coverImage": maximumCover,
      ]).coverImage,
      maximumCover
    )
    XCTAssertThrowsError(try WeChatWebCapturePolicy.validateJavaScriptResult([
      "title": "Title", "text": "Body", "images": [],
      "coverImage": String(repeating: "x", count: WeChatWebCapturePolicy.maximumImageURLScalars + 1),
    ])) { XCTAssertEqual($0 as? ManualLinkError, .responseTooLarge) }

    for malformed: [String: Any] in [
      ["title": "Title", "text": "Body", "images": "not-array"],
      ["title": "Title", "text": "Body", "images": [42]],
      ["title": "Title", "text": "Body", "images": [], "author": 42],
      ["title": "Title", "text": "Body", "images": Array(repeating: "https://mmbiz.qpic.cn/x", count: WeChatWebCapturePolicy.maximumImageCount + 1)],
    ] {
      XCTAssertThrowsError(try WeChatWebCapturePolicy.validateJavaScriptResult(malformed)) {
        XCTAssertEqual($0 as? ManualLinkError, .invalidPageResult)
      }
    }
    XCTAssertNil(WeChatWebCapturePolicy.iso8601FromCT("not-a-time"))
  }

  func testHardDeadlineDistinguishesTimeoutFromBodyThatStayedEmpty() {
    XCTAssertEqual(
      WeChatWebCapturePolicy.deadlineFailure(
        pageDidFinish: false,
        completedEmptyReadinessCheck: false
      ),
      .timedOut
    )
    XCTAssertEqual(
      WeChatWebCapturePolicy.deadlineFailure(
        pageDidFinish: true,
        completedEmptyReadinessCheck: true
      ),
      .emptyContent
    )
  }

  func testRequiredFailuresHaveDifferentReadableMessages() {
    let errors: [ManualLinkError] = [
      .webHostNotAllowed,
      .network,
      .timedOut,
      .emptyContent,
      .invalidPageResult,
      .responseTooLarge,
    ]
    let messages = errors.map(\.userMessage)
    XCTAssertEqual(Set(messages).count, errors.count)
    XCTAssertTrue(messages.allSatisfy { !$0.isEmpty && !$0.contains("抓取失败") })
  }
}

extension WeChatWebCapturePolicyTests {
  func testNavigationDecisionSeparatesMainFrameFromSubframes() {
    let wechat = URL(string: "https://mp.weixin.qq.com/s/xjUh6_4REQk1J4K3uSzzJw")!
    let offSite = URL(string: "https://v.qq.com/iframe/player.html")!
    let insecure = URL(string: "http://mp.weixin.qq.com/s/abc")!

    // 主框架：站内放行，离站/降级/缺 URL 终止捕获。
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: wechat, isMainFrame: true), .allow)
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: offSite, isMainFrame: true), .failCapture)
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: insecure, isMainFrame: true), .failCapture)
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: nil, isMainFrame: true), .failCapture)

    // 子框架：文章页内嵌的广告/视频 iframe 是页面自带的，站外只静默拦截，
    // 绝不把用户提交的整页捕获判死——这正是 7/23 微信抓取失效的回归根因。
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: offSite, isMainFrame: false), .blockSilently)
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: nil, isMainFrame: false), .blockSilently)
    XCTAssertEqual(WeChatWebCapturePolicy.navigationDecision(url: wechat, isMainFrame: false), .allow)
  }
}
