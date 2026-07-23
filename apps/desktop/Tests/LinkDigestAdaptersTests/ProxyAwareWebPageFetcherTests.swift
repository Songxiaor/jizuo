import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

private final class RecordingWebPageFetcher: WebPageFetcher, @unchecked Sendable {
  private let lock = NSLock()
  private let marker: String
  private var urls: [URL] = []

  init(marker: String) { self.marker = marker }

  func fetch(url: URL) async throws -> WebPageFetchResult {
    lock.withLock { urls.append(url) }
    return .init(url: url, html: marker, contentType: "text/html")
  }

  var calls: [URL] { lock.withLock { urls } }
}

private final class RecordingSafeResourceFetcher: WebPageFetcher, SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var resources: [SafeResourceRequest] = []
  func fetch(url: URL) async throws -> WebPageFetchResult { .init(url: url, html: "html", contentType: "text/html") }
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { resources.append(request) }
    return .init(url: request.url, statusCode: 200, contentType: "text/plain", body: Data("fixture".utf8))
  }
  var requests: [SafeResourceRequest] { lock.withLock { resources } }
}

final class ProxyAwareWebPageFetcherTests: XCTestCase {
  func testFakeIPUsesProxyWhilePublicUsesPeerBoundAndPrivateStillFailsClosed() async throws {
    let policy = PublicWebURLPolicy(resolver: { host in
      switch host {
      case "fake.example": ["198.18.1.20"]
      case "public.example": ["8.8.8.8"]
      case "private.example": ["10.0.0.8"]
      default: []
      }
    })
    let direct = RecordingWebPageFetcher(marker: "direct")
    let proxy = RecordingWebPageFetcher(marker: "proxy")
    let fetcher = ProxyAwareWebPageFetcher(policy: policy, direct: direct, proxy: proxy)

    let fakeURL = URL(string: "https://fake.example/page")!
    let publicURL = URL(string: "https://public.example/page")!
    let fakeResult = try await fetcher.fetch(url: fakeURL)
    let publicResult = try await fetcher.fetch(url: publicURL)
    XCTAssertEqual(fakeResult.html, "proxy")
    XCTAssertEqual(publicResult.html, "direct")
    await XCTAssertThrowsErrorAsync(try await fetcher.fetch(url: URL(string: "https://private.example/page")!)) {
      XCTAssertEqual($0 as? ManualLinkError, .unsafeURL)
    }
    XCTAssertEqual(proxy.calls, [fakeURL])
    XCTAssertEqual(direct.calls, [publicURL])
  }

  func testConfiguredSystemProxyRoutesPublicHostnameWithoutAdmittingPrivateTargets() async throws {
    let policy = PublicWebURLPolicy(resolver: { host in
      host == "public.example" ? ["8.8.8.8"] : ["10.0.0.8"]
    })
    let direct = RecordingWebPageFetcher(marker: "direct")
    let proxy = RecordingWebPageFetcher(marker: "proxy")
    let fetcher = ProxyAwareWebPageFetcher(
      policy: policy,
      direct: direct,
      proxy: proxy,
      shouldUseSystemProxy: { _ in true }
    )
    let publicURL = URL(string: "https://public.example/page")!

    let result = try await fetcher.fetch(url: publicURL)

    XCTAssertEqual(result.html, "proxy")
    XCTAssertTrue(direct.calls.isEmpty)
    await XCTAssertThrowsErrorAsync(
      try await fetcher.fetch(url: URL(string: "https://private.example/page")!)
    ) { XCTAssertEqual($0 as? ManualLinkError, .unsafeURL) }
  }

  func testProxyRoutesRejectHTTPWithReadableBrowserExtensionRecovery() async throws {
    let policy = PublicWebURLPolicy(resolver: { host in
      switch host {
      case "fake.example": ["198.18.1.20"]
      default: ["8.8.8.8"]
      }
    })
    let direct = RecordingWebPageFetcher(marker: "direct")
    let proxy = RecordingWebPageFetcher(marker: "proxy")
    let fakeIPFetcher = ProxyAwareWebPageFetcher(policy: policy, direct: direct, proxy: proxy)
    let configuredProxyFetcher = ProxyAwareWebPageFetcher(
      policy: policy,
      direct: direct,
      proxy: proxy,
      shouldUseSystemProxy: { _ in true }
    )

    for fetcher in [fakeIPFetcher, configuredProxyFetcher] {
      await XCTAssertThrowsErrorAsync(
        try await fetcher.fetch(url: URL(string: "http://fake.example/page")!)
      ) {
        XCTAssertEqual($0 as? ManualLinkError, .proxyHTTPSRequired)
        XCTAssertTrue(ManualLinkError.proxyHTTPSRequired.userMessage.contains("HTTPS"))
        XCTAssertTrue(ManualLinkError.proxyHTTPSRequired.userMessage.contains("浏览器扩展"))
      }
    }
    XCTAssertTrue(proxy.calls.isEmpty)
    XCTAssertTrue(direct.calls.isEmpty)
  }

  func testRawSourceAdapterResourcesUseTheSameRoutingAdmission() async throws {
    let policy = PublicWebURLPolicy(resolver: { host in
      ["public.example": ["8.8.8.8"], "fake.example": ["198.18.1.2"], "private.example": ["10.0.0.2"]][host] ?? []
    })
    let direct = RecordingSafeResourceFetcher(), proxy = RecordingSafeResourceFetcher()
    let fetcher = ProxyAwareWebPageFetcher(policy: policy, direct: direct, proxy: proxy)
    let request = SafeResourceRequest(url: URL(string: "https://public.example/readme")!, headers: ["Accept": "application/vnd.github.raw+json"], byteLimit: 1024)
    let response = try await fetcher.fetchResource(request)
    XCTAssertEqual(response.body, Data("fixture".utf8))
    XCTAssertEqual(direct.requests.first?.headers["Accept"], "application/vnd.github.raw+json")
    _ = try await fetcher.fetchResource(.init(url: URL(string: "https://fake.example/readme")!, byteLimit: 1024))
    XCTAssertEqual(proxy.requests.count, 1)
    await XCTAssertThrowsErrorAsync(try await fetcher.fetchResource(.init(url: URL(string: "https://private.example/readme")!, byteLimit: 1024))) {
      XCTAssertEqual($0 as? ManualLinkError, .unsafeURL)
    }
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure @escaping () async throws -> T,
  _ handler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("expected error")
  } catch {
    handler(error)
  }
}
