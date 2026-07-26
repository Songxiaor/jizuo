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
    fetcher.htmlByHostPath["www.douyin.com/video/7000000000000000002"] = """
      <html><body>
      <script>
      window._ROUTER_DATA = {"loaderData":{"video":{"awemeId":"7000000000000000002","play_addr":{"url_list":["https://cdn.example.test/ssr.mp4"]},"desc":"SSR标题","author":{"nickname":"作者甲"},"duration":15000}}};
      </script>
      </body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    let document = try await adapter.capture(url: URL(string: "https://www.douyin.com/video/7000000000000000002")!)
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

extension DouyinSourceAdapterTests {
  func testMetadataIsAnchoredToTheRequestedVideoNotThePageShell() async throws {
    // 登录后的抖音页外壳里到处是 `"desc"` / `"nickname"`：推荐流作者、按钮文案、
    // 当前登录用户资料。不锚定到 URL 里的视频 id 就会抓到它们——真机实测抓到过
    // 标题「PC Tab」（按钮文案）和推荐位博主的昵称。两个都长得像真数据，存进库
    // 看不出错，比抓不到严重得多。
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/7562143889449585970"] = """
      <html><body><script>
      window.__SHELL__ = {"tab":{"desc":"PC Tab"},"feed":[{"author":{"nickname":"推荐位博主"},"desc":"别人的视频"}]};
      window._ROUTER_DATA = {"loaderData":{"video":{"awemeId":"7562143889449585970","play_addr":{"url_list":["https://cdn.example.test/anchored.mp4"]},"desc":"这条视频真正的标题","author":{"nickname":"真正的作者"},"duration":9000}}};
      </script></body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    let document = try await adapter.capture(
      url: URL(string: "https://www.douyin.com/video/7562143889449585970")!)
    XCTAssertTrue(document.text.contains("这条视频真正的标题"), "实际正文：\(document.text)")
    XCTAssertFalse(document.text.contains("PC Tab"))
    XCTAssertEqual(document.media?.author, "真正的作者")
  }

  func testUnanchorableShellDoesNotInventMetadata() async {
    // 页面里没有这条视频的数据时（客户端渲染的登录页就是这样），绝不能从外壳里
    // 凑一份看着像真的元数据出来。
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/7562143889449585970"] = """
      <html><body><script>
      window.__SHELL__ = {"tab":{"desc":"PC Tab"},"feed":[{"author":{"nickname":"推荐位博主"}}],"player":{"play_addr":{"url_list":["https://cdn.example.test/unrelated.mp4"]}}};
      </script></body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    do {
      let document = try await adapter.capture(
        url: URL(string: "https://www.douyin.com/video/7562143889449585970")!)
      XCTAssertFalse(document.text.contains("PC Tab"), "外壳文案不该成为标题：\(document.text)")
      XCTAssertNotEqual(document.media?.author, "推荐位博主", "推荐位博主不该成为作者")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .extensionCaptureRequired)
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }
}

extension DouyinSourceAdapterTests {
  func testAvatarURLIsNotMistakenForTheVideo() async {
    // `url_list` 是通用键：作者头像 avatar_thumb/avatar_larger、封面、相关推荐
    // 每条都用它。不锚定 + 不排头像，就会把作者头像的 JPEG 当成 media.videoURL
    // 存进去，而 parse 依然「成功」，不会回落到「请用扩展」。
    let fetcher = DouyinFixtureFetcher()
    fetcher.htmlByHostPath["www.douyin.com/video/7000000000000000009"] = """
      <html><body><script>
      window._ROUTER_DATA = {"loaderData":{"video":{"awemeId":"7000000000000000009","author":{"nickname":"某作者","avatar_thumb":{"url_list":["https://p3.douyinpic.test/aweme/100x100/avatar.jpeg"]}},"desc":"标题在这里"}}};
      </script></body></html>
      """
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    do {
      let document = try await adapter.capture(
        url: URL(string: "https://www.douyin.com/video/7000000000000000009")!)
      XCTAssertNil(document.media?.videoURL, "头像不该成为视频地址：\(document.media?.videoURL ?? "nil")")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .extensionCaptureRequired, "没有可播放视频时应引导用扩展")
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }
}
