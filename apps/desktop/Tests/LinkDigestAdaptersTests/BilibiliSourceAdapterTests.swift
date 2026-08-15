import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestAdapters

private struct BilibiliShortLinkFetcher: WebPageFetcher {
  let finalURL: URL
  func fetch(url _: URL) async throws -> WebPageFetchResult {
    .init(url: finalURL, html: "<html><body>Bilibili shell is deliberately ignored.</body></html>", contentType: "text/html")
  }
}

private final class BilibiliAPIFixture: SafeResourceFetching, @unchecked Sendable {
  enum ViewMode { case success, loginRestricted, changedShape }
  let mode: ViewMode
  private let lock = NSLock()
  private var recorded: [SafeResourceRequest] = []

  init(_ mode: ViewMode) { self.mode = mode }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { recorded.append(request) }
    let body: Data
    if request.url.path == "/x/web-interface/view" {
      switch mode {
      case .success:
        body = try Data(contentsOf: Self.successFixtureURL)
      case .loginRestricted:
        body = Data(#"{"code":-101,"message":"redacted"}"#.utf8)
      case .changedShape:
        body = Data(#"{"code":0,"data":{"bvid":"BV1xx411c7mD","cid":987654321,"desc":"title field disappeared"}}"#.utf8)
      }
    } else {
      body = Data(#"{"code":0,"data":{"quality":64,"timelength":125000,"accept_quality":[64],"durl":[{"url":"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/redacted.mp4"}]}}"#.utf8)
    }
    return .init(url: request.url, statusCode: 200, contentType: "application/json", body: body)
  }

  var requests: [SafeResourceRequest] { lock.withLock { recorded } }

  private static var successFixtureURL: URL {
    Bundle.module.url(
      forResource: "bilibili-view-success-redacted",
      withExtension: "json",
      subdirectory: "Fixtures"
    )!
  }
}

final class BilibiliSourceAdapterTests: XCTestCase {
  private let shortURL = URL(string: "https://b23.tv/redacted")!
  private let finalURL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?share_source=copy_web")!

  func testSuccessFixtureResolvesShortLinkAndDeliversCanonicalMetadataAndMedia() async throws {
    let api = BilibiliAPIFixture(.success)
    let adapter = BilibiliSourceAdapter(
      fetcher: BilibiliShortLinkFetcher(finalURL: finalURL),
      resources: api,
      now: { Date(timeIntervalSince1970: 1_786_636_800) }
    )

    let document = try await adapter.capture(url: shortURL)

    XCTAssertEqual(document.url, "https://www.bilibili.com/video/BV1xx411c7mD")
    XCTAssertEqual(document.title, "脱敏的公开演示视频")
    XCTAssertEqual(document.platform, "bilibili")
    XCTAssertEqual(document.method, "bilibili_public_api")
    XCTAssertTrue(document.text.contains("author: \"演示创作者\""))
    XCTAssertTrue(document.text.contains("views: \"1200\""))
    XCTAssertTrue(document.text.contains("这是一段不含真实账号数据的公开视频简介"))
    XCTAssertTrue(document.text.contains("![视频封面](https://i0.hdslb.com/bfs/archive/redacted-cover.jpg)"))
    XCTAssertEqual(document.media?.platform, "bilibili")
    XCTAssertEqual(document.media?.durationSeconds, 125)
    XCTAssertEqual(document.media?.coverURL, "https://i0.hdslb.com/bfs/archive/redacted-cover.jpg")
    XCTAssertTrue(api.requests.contains { $0.url.path == "/x/web-interface/view" })
    XCTAssertTrue(api.requests.contains { $0.url.path == "/x/player/playurl" })
  }

  func testLoginRestrictedViewAPIDoesNotFallBackToTheHTMLShell() async {
    let api = BilibiliAPIFixture(.loginRestricted)
    let adapter = BilibiliSourceAdapter(
      fetcher: BilibiliShortLinkFetcher(finalURL: finalURL),
      resources: api
    )

    do {
      _ = try await adapter.capture(url: shortURL)
      XCTFail("受限响应不应被当作成功正文")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .loginRequired)
    } catch {
      XCTFail("应抛 ManualLinkError，实际为 \(error)")
    }
    XCTAssertFalse(api.requests.contains { $0.url.path == "/x/player/playurl" })
  }

  func testChangedAPIShapeFailsExplainablyInsteadOfSavingAdjacentShellContent() async {
    let api = BilibiliAPIFixture(.changedShape)
    let adapter = BilibiliSourceAdapter(
      fetcher: BilibiliShortLinkFetcher(finalURL: finalURL),
      resources: api
    )

    do {
      _ = try await adapter.capture(url: shortURL)
      XCTFail("缺失关键 title 字段时不应静默成功")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .invalidPageResult)
    } catch {
      XCTFail("应抛 ManualLinkError，实际为 \(error)")
    }
    XCTAssertFalse(api.requests.contains { $0.url.path == "/x/player/playurl" })
  }

  func testOwnershipIsLimitedToOfficialShortLinksAndConcreteVideoPages() {
    let adapter = BilibiliSourceAdapter(
      fetcher: BilibiliShortLinkFetcher(finalURL: finalURL),
      resources: BilibiliAPIFixture(.success)
    )
    XCTAssertTrue(adapter.takesOwnership(of: shortURL))
    XCTAssertTrue(adapter.takesOwnership(of: finalURL))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://www.bilibili.com/")!))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://b23.tv.evil.test/redacted")!))
  }
}
