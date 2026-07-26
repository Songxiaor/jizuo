import XCTest

@testable import LinkDigestAdapters

/// 请求头重复不会崩、不会报错，只会让对端在两个值里随便挑一个——
/// 表现出来就是"同样的代码在某些站点上突然不认浏览器 UA 了"。只能靠断言字节。
final class PeerBoundRequestHeaderTests: XCTestCase {
  private func headerLines(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    return text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
  }

  private func values(of name: String, in data: Data) -> [String] {
    headerLines(data)
      .filter { $0.lowercased().hasPrefix("\(name.lowercased()):") }
      .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
  }

  func testCallerUserAgentReplacesDefaultInsteadOfDuplicating() throws {
    let data = try PeerBoundNetworkWebPageFetcher.requestBytes(
      path: "/owner/repo",
      host: "github.com",
      headers: ["User-Agent": "Mozilla/5.0 (Macintosh)"]
    )
    // 之前默认 UA 写死在状态行后面，调用方传的会被再追加一次。
    XCTAssertEqual(values(of: "User-Agent", in: data), ["Mozilla/5.0 (Macintosh)"])
  }

  func testDefaultUserAgentStillPresentWhenCallerPassesNone() throws {
    let data = try PeerBoundNetworkWebPageFetcher.requestBytes(
      path: "/",
      host: "example.com",
      headers: [:]
    )
    XCTAssertEqual(values(of: "User-Agent", in: data), ["LinkDigest/0.1"])
  }

  func testCaseInsensitiveHeaderNameStillReplaces() throws {
    let data = try PeerBoundNetworkWebPageFetcher.requestBytes(
      path: "/",
      host: "example.com",
      headers: ["user-agent": "custom/1.0"]
    )
    // HTTP 头名不区分大小写；字典键区分。不清一遍就又是两条。
    XCTAssertEqual(values(of: "User-Agent", in: data), ["custom/1.0"])
  }

  func testCallerCannotInjectSecondHostOrConnectionHeader() throws {
    let data = try PeerBoundNetworkWebPageFetcher.requestBytes(
      path: "/",
      host: "example.com",
      headers: ["Host": "evil.example", "Connection": "keep-alive"]
    )
    // Host 已经过 TLS 证书名校验和 SSRF 门禁；再塞一个进来等于让对端自己挑。
    XCTAssertEqual(values(of: "Host", in: data), ["example.com"])
    XCTAssertEqual(values(of: "Connection", in: data), ["close"])
  }

  func testRequestLineAndFramingStayIntact() throws {
    let body = Data("x=1".utf8)
    let data = try PeerBoundNetworkWebPageFetcher.requestBytes(
      path: "/activate",
      host: "api.example.com",
      headers: [:],
      method: "POST",
      body: body
    )
    let lines = headerLines(data)
    XCTAssertEqual(lines.first, "POST /activate HTTP/1.1")
    XCTAssertEqual(values(of: "Content-Length", in: data), ["3"])
    XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("\r\n\r\nx=1"))
  }
}
