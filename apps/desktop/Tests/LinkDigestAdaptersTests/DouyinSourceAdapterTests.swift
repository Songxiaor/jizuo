import XCTest
import LinkDigestCore
@testable import LinkDigestAdapters

private final class DouyinFixtureFetcher: WebPageFetcher, @unchecked Sendable {
  var htmlByHostPath: [String: String] = [:]
  var resultURL: URL?
  var error: Error?

  func fetch(url: URL) async throws -> WebPageFetchResult {
    if let error { throw error }
    let key = "\(url.host ?? "")\(url.path)"
    let html = htmlByHostPath[key]
      ?? htmlByHostPath.values.first
      ?? ""
    return .init(
      url: resultURL ?? url,
      html: html,
      contentType: "text/html; charset=utf-8"
    )
  }
}

final class DouyinSourceAdapterTests: XCTestCase {
  func testTakesOwnershipOfDouyinHostsOnly() {
    let adapter = DouyinSourceAdapter(fetcher: DouyinFixtureFetcher())
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://v.douyin.com/AbCdEf/")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.douyin.com/video/7123456789012345678")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.iesdouyin.com/share/video/1")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.douyin.com/jingxuan?modal_id=7635842095491632418")!))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://example.com/video/1")!))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://github.com/foo/bar")!))
  }

  func testAwemeIDFromModalQueryAndPath() {
    XCTAssertEqual(
      DouyinURL.awemeID(from: URL(string: "https://www.douyin.com/jingxuan?modal_id=7635842095491632418")!),
      "7635842095491632418"
    )
    XCTAssertEqual(
      DouyinURL.awemeID(from: URL(string: "https://www.douyin.com/video/7123456789012345678")!),
      "7123456789012345678"
    )
    XCTAssertNil(DouyinURL.awemeID(from: URL(string: "https://www.douyin.com/jingxuan")!))
    XCTAssertEqual(
      DouyinURL.canonicalVideoURL(from: URL(string: "https://www.douyin.com/jingxuan?modal_id=7635842095491632418")!)?.absoluteString,
      "https://www.douyin.com/video/7635842095491632418"
    )
  }

  func testParsesVideoTagAndBuildsDocument() async throws {
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/1"] = """
      <html><head>
      <meta property="og:title" content="口播示例">
      <meta property="og:description" content="这是描述">
      <meta property="og:image" content="https://cdn.example.test/cover.jpg">
      </head><body>
      <video src="https://cdn.example.test/clip.mp4"></video>
      </body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    let document = try await adapter.capture(url: URL(string: "https://www.douyin.com/video/1")!)
    XCTAssertEqual(document.platform, "douyin")
    XCTAssertEqual(document.method, "douyin_public_html")
    XCTAssertEqual(document.origin, .manualLink)
    XCTAssertEqual(document.media?.videoURL, "https://cdn.example.test/clip.mp4")
    XCTAssertEqual(document.media?.coverURL, "https://cdn.example.test/cover.jpg")
    XCTAssertTrue(document.text.contains("口播示例") || document.text.contains("这是描述"))
  }

  func testParsesSSRPlayAddr() async throws {
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/2"] = """
      <html><body>
      <script>
      window._ROUTER_DATA = {"loaderData":{"video":{"play_addr":{"url_list":["https://cdn.example.test/ssr.mp4"]},"desc":"SSR标题","author":{"nickname":"作者甲"},"duration":15000}}};
      </script>
      </body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    let document = try await adapter.capture(url: URL(string: "https://www.douyin.com/video/2")!)
    XCTAssertEqual(document.media?.videoURL, "https://cdn.example.test/ssr.mp4")
    XCTAssertEqual(document.media?.author, "作者甲")
    XCTAssertEqual(document.media?.durationSeconds, 15.0)
  }

  func testRiskControlSurfacesExtensionGuide() async {
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/blocked"] = "<html><body>请完成安全验证 滑动验证</body></html>"
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    do {
      _ = try await adapter.capture(url: URL(string: "https://www.douyin.com/video/blocked")!)
      XCTFail("expected extensionCaptureRequired")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .extensionCaptureRequired)
      XCTAssertTrue(error.userMessage.contains("扩展发送"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testEmptyShellWithoutMediaGuidesExtension() async {
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/empty"] = String(repeating: "<div>placeholder</div>", count: 40)
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    do {
      _ = try await adapter.capture(url: URL(string: "https://www.douyin.com/video/empty")!)
      XCTFail("expected extensionCaptureRequired")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .extensionCaptureRequired)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }
}

final class LocalMediaStoreTests: XCTestCase {
  func testRejectsNonISOMediaAndAcceptsFtyp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalMediaStore(applicationSupportRoot: root)

    XCTAssertThrowsError(try LocalMediaStore.validatedContainer(body: Data("hello".utf8), contentType: "video/mp4")) {
      XCTAssertEqual($0 as? MediaDownloadError, .unsupportedContainer)
    }

    // Minimal ftyp-shaped payload: size(4) + 'ftyp' + brand
    var mp4 = Data([0x00, 0x00, 0x00, 0x18])
    mp4.append(contentsOf: Array("ftyp".utf8))
    mp4.append(contentsOf: Array("isom".utf8))
    mp4.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    mp4.append(contentsOf: Array("isom".utf8))
    let ext = try LocalMediaStore.validatedContainer(body: mp4, contentType: "video/mp4")
    XCTAssertEqual(ext, "mp4")

    let stored = try store.store(data: mp4, preferredExtension: ext)
    XCTAssertEqual(stored.sha256.count, 64)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.absoluteURL(relativePath: stored.relativePath).path))
  }

  func testContentTypeQuickTimeMapsToMovWhenFtypPresent() throws {
    var mov = Data([0x00, 0x00, 0x00, 0x14])
    mov.append(contentsOf: Array("ftyp".utf8))
    mov.append(contentsOf: Array("qt  ".utf8))
    mov.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    let ext = try LocalMediaStore.validatedContainer(body: mov, contentType: "video/quicktime")
    XCTAssertEqual(ext, "mov")
  }
}
