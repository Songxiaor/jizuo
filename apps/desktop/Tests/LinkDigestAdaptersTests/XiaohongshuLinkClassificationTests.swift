import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 独立复核补充（2026-11-11）：小红书失败要分清三种情况——
/// 「带着访问码但过期」「裸链接没有访问码」「真的要求登录」。
/// 只测 Adapter 的公开行为，不改业务代码。
final class XiaohongshuLinkClassificationTests: XCTestCase {
  private let noteID = "aabbccddeeff001122334455"

  private var expiredPageURL: URL {
    URL(string: "https://www.xiaohongshu.com/404?source=note&error_code=300031")!
  }

  private var expiredHTML: String {
    "<html><head><title>小红书 - 你访问的页面不见了</title></head><body></body></html>"
  }

  /// 登录墙：URL 还是笔记地址，页面本身没有笔记内容。
  private var loginWallHTML: String {
    "<html><head><title>登录 - 小红书</title></head><body>请登录后查看笔记</body></html>"
  }

  private func adapter(_ fetcher: any WebPageFetcher) -> XiaohongshuSourceAdapter {
    XiaohongshuSourceAdapter(
      fetcher: fetcher,
      resources: ClassificationUnusedResourceFetcher(),
      cookieHeader: { nil }
    )
  }

  private func expect(
    _ expected: ManualLinkError,
    url: URL,
    fetcher: any WebPageFetcher,
    _ message: String = "",
    line: UInt = #line
  ) async {
    do {
      _ = try await adapter(fetcher).capture(url: url)
      XCTFail("应当抛 \(expected)。\(message)", line: line)
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, expected, message, line: line)
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)。\(message)", line: line)
    }
  }

  // MARK: - 带访问码：过期就是过期

  func testDiscoveryItemWithExpiredTokenIsExpiredNotMissingToken() async {
    let url = URL(string: "https://www.xiaohongshu.com/discovery/item/\(noteID)?xsec_token=TESTTOKEN&xsec_source=app_share")!
    await expect(
      .shareLinkExpired,
      url: url,
      fetcher: ClassificationStaticFetcher(resultURL: expiredPageURL, html: expiredHTML)
    )
  }

  // MARK: - 裸链接：404 才算缺访问码

  func testDiscoveryItemBareLinkOn404IsMissingToken() async {
    let url = URL(string: "https://www.xiaohongshu.com/discovery/item/\(noteID)")!
    await expect(
      .shareLinkMissingToken,
      url: url,
      fetcher: ClassificationStaticFetcher(resultURL: expiredPageURL, html: expiredHTML)
    )
  }

  // MARK: - 真要登录：不能报成缺访问码，也不能报成过期

  func testBareExploreLinkOnLoginWallStaysLoginRequired() async {
    let url = URL(string: "https://www.xiaohongshu.com/explore/\(noteID)")!
    await expect(
      .loginRequired,
      url: url,
      fetcher: ClassificationStaticFetcher(resultURL: url, html: loginWallHTML)
    )
  }

  func testTokenLinkOnLoginWallStaysLoginRequired() async {
    let url = URL(string: "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=TESTTOKEN")!
    await expect(
      .loginRequired,
      url: url,
      fetcher: ClassificationStaticFetcher(resultURL: url, html: loginWallHTML)
    )
  }

  // MARK: - 短链：看它跳到哪，再分三种

  func testShortLinkResolvedToBareNoteOn404IsMissingToken() async {
    let short = "https://xhslink.com/o/AbCdEf"
    let bare = "https://www.xiaohongshu.com/explore/\(noteID)"
    let fetcher = ClassificationRoutingFetcher(routes: [
      short: (URL(string: bare)!, "<html></html>"),
      bare: (expiredPageURL, expiredHTML),
    ])
    await expect(.shareLinkMissingToken, url: URL(string: short)!, fetcher: fetcher)
  }

  func testShortLinkResolvedToTokenNoteOn404IsExpired() async {
    let short = "https://xhslink.com/o/AbCdEf"
    let shared = "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=TESTTOKEN&xsec_source=app_share"
    let fetcher = ClassificationRoutingFetcher(routes: [
      short: (URL(string: shared)!, "<html></html>"),
      shared: (expiredPageURL, expiredHTML),
    ])
    await expect(.shareLinkExpired, url: URL(string: short)!, fetcher: fetcher)
  }

  // MARK: - 裸链接识别（MCP 提前警告就靠它）

  func testBareNoteLinkRecognitionCoversDiscoveryAndExcludesShortLinks() {
    XCTAssertTrue(XiaohongshuURL.isBareNoteLink(URL(string: "https://www.xiaohongshu.com/explore/\(noteID)")!))
    XCTAssertTrue(XiaohongshuURL.isBareNoteLink(URL(string: "https://www.xiaohongshu.com/discovery/item/\(noteID)")!))
    XCTAssertFalse(
      XiaohongshuURL.isBareNoteLink(URL(string: "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=T")!),
      "带访问码的不是裸链接"
    )
    XCTAssertFalse(
      XiaohongshuURL.isBareNoteLink(URL(string: "https://xhslink.com/o/AbCdEf")!),
      "短链跳转时会带上访问码，不能提前判成裸链接"
    )
    XCTAssertFalse(XiaohongshuURL.isBareNoteLink(URL(string: "https://www.xiaohongshu.com/explore/notanote")!))
  }
}

// MARK: - 夹具

private struct ClassificationStaticFetcher: WebPageFetcher, @unchecked Sendable {
  let resultURL: URL
  let html: String

  func fetch(url _: URL) async throws -> WebPageFetchResult {
    WebPageFetchResult(url: resultURL, html: html, contentType: "text/html")
  }
}

private struct ClassificationRoutingFetcher: WebPageFetcher, @unchecked Sendable {
  let routes: [String: (URL, String)]

  func fetch(url: URL) async throws -> WebPageFetchResult {
    guard let route = routes[url.absoluteString] else { throw ManualLinkError.network }
    return WebPageFetchResult(url: route.0, html: route.1, contentType: "text/html")
  }
}

private final class ClassificationUnusedResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  func fetchResource(_: SafeResourceRequest) async throws -> SafeResourceResponse {
    throw ManualLinkError.network
  }
}
