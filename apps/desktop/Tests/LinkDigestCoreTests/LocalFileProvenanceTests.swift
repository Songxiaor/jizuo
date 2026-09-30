import XCTest
@testable import LinkDigestCore

/// 本地文件的下载来源：quarantine / WhereFroms 的解析、存进 source_label 再读回来、显示名。
final class LocalFileProvenanceTests: XCTestCase {
  func testParsesQuarantineAgentAndDate() throws {
    let parsed = try XCTUnwrap(LocalFileProvenance.parseQuarantine("0083;66f8a1b2;WeChat;9D5A1F3C-0000-4000-8000-000000000000"))
    XCTAssertEqual(parsed.agentName, "WeChat")
    XCTAssertEqual(parsed.downloadedAt, Date(timeIntervalSince1970: TimeInterval(0x66f8a1b2)))

    let noAgent = try XCTUnwrap(LocalFileProvenance.parseQuarantine("0081;66f8a1b2;;"))
    XCTAssertNil(noAgent.agentName)
    // 属性值末尾常带一个 \0。
    XCTAssertEqual(LocalFileProvenance.parseQuarantine("01c1;66f8a1b2;Google Chrome;\u{0}")?.agentName, "Google Chrome")
  }

  func testRejectsValuesThatAreNotQuarantineRecords() {
    XCTAssertNil(LocalFileProvenance.parseQuarantine(""))
    XCTAssertNil(LocalFileProvenance.parseQuarantine("hello;world"))
    XCTAssertNil(LocalFileProvenance.parseQuarantine(";66f8a1b2;WeChat;"))
  }

  func testWhereFromsPreferThePageAndStripSignedDownloadQueries() {
    XCTAssertEqual(
      LocalFileProvenance.preferredWhereFrom(["https://cdn.example.com/a.pdf?X-Amz-Signature=secret", "https://example.com/post?id=7#top"]),
      "https://example.com/post?id=7"
    )
    XCTAssertEqual(
      LocalFileProvenance.preferredWhereFrom(["https://user:pass@cdn.example.com/a.pdf?token=secret"]),
      "https://cdn.example.com/a.pdf"
    )
    XCTAssertNil(LocalFileProvenance.preferredWhereFrom(["file:///Users/x/a.pdf"]))
    XCTAssertNil(LocalFileProvenance.preferredWhereFrom([]))
  }

  func testSourceLabelRoundTrips() {
    let cases = [
      LocalFileProvenance(agentName: "WeChat", sourceURL: nil),
      LocalFileProvenance(agentName: "Google Chrome", sourceURL: "https://example.com/a?b=1"),
      LocalFileProvenance(agentName: nil, sourceURL: "https://example.com/a"),
      LocalFileProvenance(agentName: nil, sourceURL: nil),
    ]
    XCTAssertEqual(cases.map(\.sourceLabel), [
      "本地文件（下载自 WeChat）",
      "本地文件（下载自 Google Chrome：https://example.com/a?b=1）",
      "本地文件（下载自 https://example.com/a）",
      "本地文件（外部下载）",
    ])
    for provenance in cases {
      XCTAssertEqual(LocalFileProvenance.parse(sourceLabel: provenance.sourceLabel), provenance)
    }
    XCTAssertNil(LocalFileProvenance.parse(sourceLabel: LocalFileProvenance.plainSourceLabel))
    XCTAssertNil(LocalFileProvenance.parse(sourceLabel: "语音备忘录"))
  }

  func testDisplayNames() {
    XCTAssertEqual(LocalFileProvenance(agentName: "WeChat", sourceURL: nil).displaySourceName, "微信")
    XCTAssertEqual(LocalFileProvenance(agentName: "WeChat", sourceURL: nil).summaryLabel, "微信下载")
    XCTAssertEqual(LocalFileProvenance(agentName: "sharingd", sourceURL: nil).displaySourceName, "隔空投送")
    XCTAssertEqual(LocalFileProvenance(agentName: "Google Chrome", sourceURL: nil).summaryLabel, "Google Chrome 下载")
    XCTAssertEqual(LocalFileProvenance(agentName: nil, sourceURL: "https://www.example.com/a").displaySourceName, "example.com")
    XCTAssertEqual(LocalFileProvenance(agentName: nil, sourceURL: nil).summaryLabel, "外部下载")
    XCTAssertEqual(LocalFileProvenance.joined("九月二十九日汲自", "微信"), "九月二十九日汲自微信")
    XCTAssertEqual(LocalFileProvenance.joined("九月二十九日汲自", "Google Chrome"), "九月二十九日汲自 Google Chrome")
  }
}
