import AppKit
import XCTest
@testable import LinkDigestApp

@MainActor
final class MarkdownEditorTextInputTests: XCTestCase {
  func testPlainTextNeverOffersDocumentCompletion() {
    let textView = MarkdownNSTextView()
    textView.allowsWikiComplete = true
    textView.string = "前文拼音后文"
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    XCTAssertEqual(textView.rangeForUserCompletion.location, NSNotFound)
    XCTAssertNil(textView.pendingWikiCompletion)
  }

  func testWikiLinkKeepsItsExplicitCompletionRange() throws {
    let textView = MarkdownNSTextView()
    textView.allowsWikiComplete = true
    textView.string = "前文 [[笔记"
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

    let pending = try XCTUnwrap(textView.pendingWikiCompletion)
    XCTAssertEqual(pending.query, "笔记")
    XCTAssertEqual(
      pending.range,
      NSRange(location: 3, length: ("[[笔记" as NSString).length)
    )
    XCTAssertEqual(textView.rangeForUserCompletion, pending.range)
  }

  func testSystemInlinePredictionAndAutomaticCompletionStayDisabled() {
    let textView = MarkdownNSTextView()

    textView.isAutomaticTextCompletionEnabled = true
    textView.inlinePredictionType = .yes

    XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
    XCTAssertEqual(textView.inlinePredictionType, .no)
  }
}
