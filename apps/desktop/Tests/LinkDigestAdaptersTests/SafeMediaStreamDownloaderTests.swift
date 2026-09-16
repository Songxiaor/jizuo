import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 播放链路上的媒体下载走的是同一道公网门禁。
///
/// 这些 URL 来自抓取回来的页面内容，攻击者能左右它指向哪里；一旦门禁缺席，
/// 「播放一条已保存的内容」就成了一个可以打内网的请求发起器。下面的断言只看
/// 门禁，不发任何真实请求。
final class SafeMediaStreamDownloaderTests: XCTestCase {
  private func downloader(resolving addresses: [String]) -> SafeMediaStreamDownloader {
    SafeMediaStreamDownloader(policy: .init(resolver: { _ in addresses }))
  }

  private func assertRejected(
    _ url: String,
    resolving addresses: [String],
    _ message: String,
    line: UInt = #line
  ) async {
    do {
      try await downloader(resolving: addresses).admit(URL(string: url)!)
      XCTFail(message, line: line)
    } catch let failure as SafeMediaStreamDownloader.Failure {
      XCTAssertEqual(failure, .unsafeURL, message, line: line)
    } catch {
      XCTFail("\(message)（实际抛出 \(error)）", line: line)
    }
  }

  func testPrivateNetworkAnswersAreRejected() async {
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["10.0.0.5"], "10/8 必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["192.168.1.9"], "192.168/16 必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["172.16.4.4"], "172.16/12 必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["127.0.0.1"], "回环必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["169.254.169.254"], "链路本地元数据地址必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["::1"], "IPv6 回环必须拒绝")
    await assertRejected("https://cdn.example.com/a.m4s", resolving: ["::ffff:10.1.1.1"], "IPv4-mapped 私有地址必须拒绝")
    // 一条公网一条内网也算内网：判定要求全部答案都可公网路由。
    await assertRejected(
      "https://cdn.example.com/a.m4s",
      resolving: ["93.184.216.34", "10.0.0.5"],
      "混入内网答案仍必须拒绝"
    )
  }

  func testNonPublicSchemesAndPortsAreRejected() async {
    await assertRejected("file:///etc/passwd", resolving: ["93.184.216.34"], "file:// 必须拒绝")
    await assertRejected("https://cdn.example.com:8443/a.m4s", resolving: ["93.184.216.34"], "非标准端口必须拒绝")
    await assertRejected("https://user:pw@cdn.example.com/a.m4s", resolving: ["93.184.216.34"], "带凭据的地址必须拒绝")
    await assertRejected("https://localhost/a.m4s", resolving: ["93.184.216.34"], "localhost 必须拒绝")
  }

  func testGloballyRoutableAnswerIsAdmitted() async throws {
    try await downloader(resolving: ["93.184.216.34"]).admit(URL(string: "https://cdn.example.com/a.m4s")!)
  }

  /// TUN/透明代理把域名解析成 fake-IP，那类网络仍要能播；放行的是这条路由，
  /// 不是内网。
  func testFakeIPAnswerStaysAdmittedForProxiedNetworks() async throws {
    try await downloader(resolving: ["198.18.0.7"]).admit(URL(string: "https://cdn.example.com/a.m4s")!)
  }

  func testHTTPSToHTTPRedirectIsRejectedWithoutIssuingTheDowngrade() {
    let https = URL(string: "https://cdn.example.com/a.m4s")!
    let http = URL(string: "http://cdn.example.com/a.m4s")!
    XCTAssertFalse(
      SafeMediaStreamDownloader.allowsRedirect(from: https, to: http),
      "https 降到 http 必须在跟跳之前掐掉"
    )
    XCTAssertTrue(SafeMediaStreamDownloader.allowsRedirect(from: https, to: https))
    XCTAssertTrue(SafeMediaStreamDownloader.allowsRedirect(from: http, to: https))
    XCTAssertTrue(SafeMediaStreamDownloader.allowsRedirect(from: http, to: http))
  }
}
