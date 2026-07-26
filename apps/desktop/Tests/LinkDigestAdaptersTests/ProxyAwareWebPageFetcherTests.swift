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
  func testFakeIPUsesSystemManagedHostnameTransportWhilePublicUsesPeerBoundAndPrivateStillFailsClosed() async throws {
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
    let fakeIPDirect = RecordingWebPageFetcher(marker: "fake-ip-direct")
    // 有系统代理时，fake-IP 交给系统 hostname transport。
    let proxied = ProxyAwareWebPageFetcher(
      policy: policy, direct: direct, proxy: proxy, fakeIPDirect: fakeIPDirect,
      shouldUseSystemProxy: { _ in true }
    )
    // 没有经典代理设置时也先走系统 hostname transport：macOS Network
    // Extension/TUN 可能只在这条路径上接管请求。
    let tunnelled = ProxyAwareWebPageFetcher(
      policy: policy, direct: direct, proxy: proxy, fakeIPDirect: fakeIPDirect
    )

    let fakeURL = URL(string: "https://fake.example/page")!
    let publicURL = URL(string: "https://public.example/page")!
    let proxiedFake = try await proxied.fetch(url: fakeURL)
    let tunnelledFake = try await tunnelled.fetch(url: fakeURL)
    let tunnelledPublic = try await tunnelled.fetch(url: publicURL)
    XCTAssertEqual(proxiedFake.html, "proxy")
    XCTAssertEqual(tunnelledFake.html, "proxy")
    XCTAssertEqual(tunnelledPublic.html, "direct")

    // 私有地址在任何一条路径下都必须照旧关死——放开的只有 fake-IP 段。
    for fetcher in [proxied, tunnelled] {
      await XCTAssertThrowsErrorAsync(try await fetcher.fetch(url: URL(string: "https://private.example/page")!)) {
        XCTAssertEqual($0 as? ManualLinkError, .unsafeURL)
      }
    }
    XCTAssertEqual(proxy.calls, [fakeURL, fakeURL])
    XCTAssertTrue(fakeIPDirect.calls.isEmpty)
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
    let fakeIPDirect = RecordingSafeResourceFetcher()
    let fetcher = ProxyAwareWebPageFetcher(
      policy: policy, direct: direct, proxy: proxy, fakeIPDirect: fakeIPDirect
    )
    let request = SafeResourceRequest(url: URL(string: "https://public.example/readme")!, headers: ["Accept": "application/vnd.github.raw+json"], byteLimit: 1024)
    let response = try await fetcher.fetchResource(request)
    XCTAssertEqual(response.body, Data("fixture".utf8))
    XCTAssertEqual(direct.requests.first?.headers["Accept"], "application/vnd.github.raw+json")
    // 无经典代理设置（TUN 模式）：资源下载也先走系统 hostname transport。
    _ = try await fetcher.fetchResource(.init(url: URL(string: "https://fake.example/readme")!, byteLimit: 1024))
    XCTAssertEqual(fakeIPDirect.requests.count, 0)
    XCTAssertEqual(proxy.requests.count, 1)

    // 有系统代理时，资源下载同样把 fake-IP 交回代理。
    let proxied = ProxyAwareWebPageFetcher(
      policy: policy, direct: direct, proxy: proxy, fakeIPDirect: fakeIPDirect,
      shouldUseSystemProxy: { _ in true }
    )
    _ = try await proxied.fetchResource(.init(url: URL(string: "https://fake.example/readme")!, byteLimit: 1024))
    XCTAssertEqual(proxy.requests.count, 2)

    for fetcher in [fetcher, proxied] {
      await XCTAssertThrowsErrorAsync(try await fetcher.fetchResource(.init(url: URL(string: "https://private.example/readme")!, byteLimit: 1024))) {
        XCTAssertEqual($0 as? ManualLinkError, .unsafeURL)
      }
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
