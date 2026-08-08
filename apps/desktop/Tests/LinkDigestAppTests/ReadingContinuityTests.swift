import XCTest
@testable import LinkDigestApp

@MainActor
final class ReadingContinuityTests: XCTestCase {
  func testCitationIncludesSelectionTitleAndSource() {
    let value = ReadingCitationFormatter.format(
      selection: "  一段值得保留的话。  ",
      title: "文章标题",
      sourceURL: "https://example.test/article"
    )
    XCTAssertTrue(value.hasPrefix("一段值得保留的话。"))
    XCTAssertTrue(value.contains("《文章标题》"))
    XCTAssertTrue(value.hasSuffix("https://example.test/article"))
  }

  func testSummaryCitationMatcherKeepsOnlyExactSourceQuotes() {
    let source = "开头。\n\n这是一段来自原文的完整引用。\n\n结尾。"
    let summary = "> 这是一段来自原文的完整引用。\n\n> 这段并不在原文里。"
    XCTAssertEqual(
      SummaryCitationMatcher.exactQuotes(summary: summary, source: source),
      ["这是一段来自原文的完整引用。"]
    )
  }

  func testReadingPositionClampsAndRoundTrips() throws {
    let suite = "reading-position-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    ReadingPositionStore.save(1.4, for: "fixture", defaults: defaults)
    XCTAssertEqual(ReadingPositionStore.progress(for: "fixture", defaults: defaults), 1)
    ReadingPositionStore.save(-0.2, for: "fixture", defaults: defaults)
    XCTAssertEqual(ReadingPositionStore.progress(for: "fixture", defaults: defaults), 0)
  }
}
