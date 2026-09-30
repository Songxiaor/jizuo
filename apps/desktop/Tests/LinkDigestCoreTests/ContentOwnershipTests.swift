import XCTest
@testable import LinkDigestCore

final class ContentOwnershipTests: XCTestCase {
  func testDefaultsFollowWhoIsSpeaking() {
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "linkdigest-note:abc", host: "note"), .own)
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "linkdigest-work:abc", host: "work"), .own)
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "linkdigest-local://voicememos/x", host: "voicememos"), .own)
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "linkdigest-local://applenotes/x", host: "applenotes"), .own)
    // 2026-09-29 起本地文件默认算自有；下载来的由导入时贴的「外部」标签判为外部。
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "linkdigest-local://localfiles/x", host: "localfiles"), .own)
    XCTAssertEqual(ContentOwnership.defaultOwnership(canonicalURL: "https://x.com/a/status/1", host: "x.com"), .external)
  }

  /// 下载来的本地文件：导入时按 `tagChanges` 贴「外部」，改回自有时两个保留标签都摘掉。
  func testDownloadedLocalFileIsTaggedExternalAndCanBeFlippedBack() {
    let file = "linkdigest-local://localfiles/abc"
    let toExternal = ContentOwnership.tagChanges(to: .external, canonicalURL: file, host: "localfiles")
    XCTAssertEqual(toExternal.add, ["外部"])
    XCTAssertEqual(toExternal.remove, ["自有"])
    XCTAssertEqual(ContentOwnership.resolve(canonicalURL: file, host: "localfiles", tagNames: toExternal.add), .external)
    XCTAssertEqual(ContentOwnership.resolve(canonicalURL: file, host: "localfiles", tagNames: []), .own)
    let back = ContentOwnership.tagChanges(to: .own, canonicalURL: file, host: "localfiles")
    XCTAssertEqual(back.add, [])
    XCTAssertEqual(Set(back.remove), ["自有", "外部"])
  }

  func testManualTagWinsOverTheDefault() {
    let post = "https://x.com/me/status/1"
    XCTAssertEqual(ContentOwnership.resolve(canonicalURL: post, host: "x.com", tagNames: ["自有"]), .own)
    XCTAssertEqual(ContentOwnership.resolve(canonicalURL: "linkdigest-note:a", host: "note", tagNames: ["外部"]), .external)
    XCTAssertEqual(ContentOwnership.resolve(canonicalURL: post, host: "x.com", tagNames: ["AI"]), .external)
  }

  /// 改回和默认一致时两个保留标签都摘掉，不在库里留多余标签。
  func testTagChangesOnlyKeepATagWhenItDiffersFromTheDefault() {
    let post = "https://x.com/me/status/1"
    let toOwn = ContentOwnership.tagChanges(to: .own, canonicalURL: post, host: "x.com")
    XCTAssertEqual(toOwn.add, ["自有"])
    XCTAssertEqual(toOwn.remove, ["外部"])
    let back = ContentOwnership.tagChanges(to: .external, canonicalURL: post, host: "x.com")
    XCTAssertEqual(back.add, [])
    XCTAssertEqual(Set(back.remove), ["自有", "外部"])
  }

  func testReservedNamesAreValidTags() {
    XCTAssertNotNil(HistoryTagNormalizer.normalized(ContentOwnership.ownTagName))
    XCTAssertNotNil(HistoryTagNormalizer.normalized(ContentOwnership.externalTagName))
    XCTAssertEqual(ContentForm.allCases.map(\.rawValue), ["图文", "视频", "录音", "图片", "文档", "笔记", "作品"])
  }
}
