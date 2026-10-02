import WebKit
import XCTest
@testable import LinkDigestApp

/// App「添加链接」的内置网页不能被拿来访问本机、局域网（2026-10-02）。
@MainActor
final class RenderedPageCaptureSafetyTests: XCTestCase {
  func testPrivateNetworkRulesAreValidJSONAndCompileInWebKit() async throws {
    let data = Data(PrivateNetworkContentRules.encodedRules.utf8)
    let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    XCTAssertEqual(filters.count, rules.count)
    XCTAssertTrue(filters.contains(#"^[a-z]+://192\.168\."#))
    XCTAssertTrue(filters.contains(#"^[a-z]+://127\."#))
    let compiled = await PrivateNetworkContentRules.compiled()
    XCTAssertNotNil(compiled, "WebKit 编译失败时规则会静默失效")
  }

  func testRenderingSkipsSourcesWithDedicatedAdaptersButTakesNotebooks() {
    XCTAssertTrue(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://arena.ai/blog/post")!))
    XCTAssertFalse(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://www.bilibili.com/video/BV1")!))
    XCTAssertFalse(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://github.com/a/b/blob/main/README.md")!))
    XCTAssertTrue(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://github.com/charmbracelet/bubbletea")!))
    XCTAssertTrue(RenderedPageCapturePolicy.allowsDirectFallback(URL(string: "https://github.com/charmbracelet/bubbletea")!))
    XCTAssertTrue(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://github.com/a/b/blob/main/x.ipynb")!))
    XCTAssertFalse(RenderedPageCapturePolicy.allowsDirectFallback(URL(string: "https://github.com/a/b/blob/main/x.ipynb")!))
    XCTAssertFalse(RenderedPageCapturePolicy.prefersRendering(URL(string: "https://example.com/notes.md")!))
  }
}
