import XCTest
@testable import LinkDigestCore

/// 长正文派生结果的备忘（2026-10-16 提速）：结果只由原文决定，原文变了必须重算。
final class TextDerivationMemoTests: XCTestCase {
  private func longText(_ marker: String) -> String {
    "---\nauthor: \(marker)\n---\n\n" + String(repeating: "正文第一段，有中文也有 English。\n", count: 200)
  }

  func testSameTextIsComputedOnce() {
    let memo = TextDerivationMemo<Int>()
    var calls = 0
    let text = longText("甲")
    let first = memo.value(for: text) { calls += 1; return $0.utf8.count }
    let second = memo.value(for: text) { calls += 1; return $0.utf8.count }
    XCTAssertEqual(first, second)
    XCTAssertEqual(calls, 1)
  }

  func testEqualTextInDifferentStorageStillHits() {
    let memo = TextDerivationMemo<Int>()
    var calls = 0
    let text = longText("甲")
    _ = memo.value(for: text) { calls += 1; return 1 }
    let copy = String(text.unicodeScalars)  // 内容相同、存储不同
    _ = memo.value(for: copy) { calls += 1; return 1 }
    XCTAssertEqual(calls, 1)
  }

  func testDifferentTextOfSameLengthRecomputes() {
    let memo = TextDerivationMemo<String>()
    let a = longText("甲")
    let b = longText("乙")
    XCTAssertEqual(a.utf8.count, b.utf8.count)
    XCTAssertEqual(memo.value(for: a) { String($0.prefix(14)) }, String(a.prefix(14)))
    XCTAssertEqual(memo.value(for: b) { String($0.prefix(14)) }, String(b.prefix(14)))
  }

  func testShortTextIsNotCached() {
    let memo = TextDerivationMemo<Int>()
    var calls = 0
    _ = memo.value(for: "短") { calls += 1; return 0 }
    _ = memo.value(for: "短") { calls += 1; return 0 }
    XCTAssertEqual(calls, 2)
  }

  func testOldestEntryIsEvictedPastCapacity() {
    let memo = TextDerivationMemo<Int>(capacity: 2)
    var calls = 0
    let texts = ["甲", "乙", "丙"].map(longText)
    for text in texts { _ = memo.value(for: text) { calls += 1; return 0 } }
    _ = memo.value(for: texts[0]) { calls += 1; return 0 }
    XCTAssertEqual(calls, 4, "容量 2 时最早那份已被挤掉，要重算")
    _ = memo.value(for: texts[2]) { calls += 1; return 0 }
    XCTAssertEqual(calls, 4, "最近用过的还在")
  }

  /// 接上备忘的两个入口，结果和备忘前一致。
  func testFrontmatterAndLayeredBodyMatchUncachedResults() {
    let text = longText("作者甲")
    let parsed = MarkdownNoteFrontmatter.parse(text)
    XCTAssertEqual(parsed.author, "作者甲")
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(text), parsed)
    let snapshot = ContentSnapshot(
      id: ContentSnapshotID(), taskID: TaskID(), sequence: 1,
      envelopeCreatedAtMilliseconds: 0, capturedAtMilliseconds: 0,
      sourceKind: "browser", sourceURL: "https://example.com", title: "t", platform: "web",
      captureMethod: "extension", completeness: "complete", bodyText: text,
      characterCount: text.unicodeScalars.count,
      bodySHA256: String(repeating: "a", count: 64), sourceLabel: "web", usedCookie: false
    )
    let expected = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(LayeredSourceDocument.body(of: snapshot), expected)
    XCTAssertEqual(LayeredSourceDocument.body(of: snapshot), expected)
  }
}
