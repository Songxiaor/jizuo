import WebKit
import XCTest
@testable import LinkDigestAdapters

@MainActor
final class WeChatWKWebViewCaptureServiceTests: XCTestCase {
  /// WeChat serves the article inside `visibility: hidden; opacity: 0` and
  /// reveals it later. `innerText` honours CSS visibility and returns "" for a
  /// hidden subtree, so the extractor polled an empty string until the 20s
  /// deadline and reported `emptyContent` on a page whose body was fully
  /// present — a real capture went from failing to 4685 characters in 1.6s by
  /// reading `textContent` instead. Reintroducing `innerText` here would
  /// silently break every WeChat capture, so the script is pinned.
  func testArticleExtractionDoesNotDependOnCSSVisibility() throws {
    let script = WeChatWKWebViewCaptureSession.extractionJavaScriptForTesting
    XCTAssertTrue(script.contains("textContent"))
    XCTAssertFalse(
      script.contains("#js_content')") && script.contains("content.innerText"),
      "Article text must not be read through innerText — hidden subtrees yield an empty string"
    )
    XCTAssertTrue(
      script.contains("blockText"),
      "Paragraph structure has to be rebuilt from block elements once innerText is gone"
    )
  }

  func testArticleExtractionPreservesCodeSnippetsAsFencedBlocks() {
    let script = WeChatWKWebViewCaptureSession.extractionJavaScriptForTesting
    // 微信 code-snippet：每行一个 <code>；行号栏是 chrome；
    // 空格折叠不得进入 fenced code 行，否则缩进被毁。
    XCTAssertTrue(script.contains("fencedCode"))
    XCTAssertTrue(script.contains("current.tagName === 'PRE'"))
    XCTAssertTrue(script.contains("code-snippet__line-index"))
    XCTAssertTrue(script.contains("skipRoot"))
    XCTAssertTrue(script.contains("inFence"))
  }

  func testArticleExtractionIncludesOrderedImagesAndPublicSourceMetadata() {
    let script = WeChatWKWebViewCaptureSession.extractionJavaScriptForTesting
    XCTAssertTrue(script.contains("document.createTreeWalker"))
    XCTAssertTrue(script.contains("data-src"))
    XCTAssertTrue(script.contains("![]("))
    XCTAssertTrue(script.contains("meta[property=\"og:image\"]"))
    XCTAssertTrue(script.contains("window.nickname"))
    XCTAssertTrue(script.contains("#js_author_name"))
    XCTAssertTrue(script.contains("window.ct"))
    XCTAssertTrue(script.contains("#publish_time"))
  }

  func testSameHostNavigationInvalidatesOnlyTheOldPollingGeneration() {
    var generation = WeChatPollingGeneration()
    let firstPoll = generation.value

    generation.navigationStarted()
    let secondPoll = generation.value

    XCTAssertFalse(generation.isCurrent(firstPoll))
    XCTAssertTrue(generation.isCurrent(secondPoll))
  }

  func testConfigurationIsEphemeralAndDisablesUnneededCapabilities() {
    let configuration = WeChatWKWebViewCaptureService.makeConfiguration()
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    XCTAssertFalse(configuration.preferences.plugInsEnabled)
    XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
    XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
  }
}
