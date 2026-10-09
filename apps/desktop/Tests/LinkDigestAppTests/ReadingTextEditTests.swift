import AppKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

/// 边翻边看时正文只往后长：上面的字和图不能跟着整份重建，否则每译完一行整页闪一下（2026-10-09）。
@MainActor
final class ReadingTextEditTests: XCTestCase {
  private let font = NSFont.systemFont(ofSize: 15)

  private func text(_ string: String) -> NSMutableAttributedString {
    NSMutableAttributedString(string: string, attributes: [.font: font])
  }

  private func block() -> HostedBlockAttachment {
    HostedBlockAttachment(width: .full) { AnyView(Color.clear) }
  }

  func testIdenticalTextNeedsNoEdit() {
    XCTAssertNil(ReadingTextEdit.tail(from: text("第一段\n第二段"), to: text("第一段\n第二段")))
  }

  func testAppendingReplacesFromLastParagraphOnly() throws {
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: text("第一段\n第二段写了一半"), to: text("第一段\n第二段写了一半，写完了\n第三段")))
    XCTAssertEqual(edit.range, NSRange(location: 4, length: 7))
    XCTAssertEqual(edit.replacement.location, 4)
  }

  func testKeepsSameAttachmentInPrefix() throws {
    let image = block()
    let old = text("开头\n")
    old.append(NSAttributedString(attachment: image))
    old.append(text("\n译文一"))
    let new = text("开头\n")
    new.append(NSAttributedString(attachment: image))
    new.append(text("\n译文一\n译文二"))
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: old, to: new))
    XCTAssertEqual(edit.range.location, 5, "图片之后才开始替换")
  }

  func testNewAttachmentInstanceIsReplaced() throws {
    let old = text("开头\n")
    old.append(NSAttributedString(attachment: block()))
    let new = text("开头\n")
    new.append(NSAttributedString(attachment: block()))
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: old, to: new))
    XCTAssertEqual(edit.range.location, 3)
  }

  func testStyleChangeBacksOffToParagraphStart() throws {
    let old = text("第一段\n第二段")
    let new = text("第一段\n第二段")
    new.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 6, length: 1))
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: old, to: new))
    XCTAssertEqual(edit.range, NSRange(location: 4, length: 3))
  }

  func testShrinkingDeletesTail() throws {
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: text("第一段\n第二段"), to: text("第一段")))
    XCTAssertEqual(edit.range, NSRange(location: 0, length: 7))
    XCTAssertEqual(edit.replacement, NSRange(location: 0, length: 3))
  }

  func testApplyingEditMatchesNewText() throws {
    let image = block()
    let old = text("标题\n")
    old.append(NSAttributedString(attachment: image))
    old.append(text("\n正文写到一半"))
    let new = text("标题\n")
    new.append(NSAttributedString(attachment: image))
    new.append(text("\n正文写完了。\n下一段"))
    let storage = NSTextStorage(attributedString: old)
    let edit = try XCTUnwrap(ReadingTextEdit.tail(from: storage, to: new))
    storage.replaceCharacters(in: edit.range, with: new.attributedSubstring(from: edit.replacement))
    XCTAssertEqual(storage.string, new.string)
    // 存储自己会补字体，拿它跟新正文比会在第一个汉字就判不同；所以视图拿上次交进去的那份比。
    let afterFixing = try XCTUnwrap(ReadingTextEdit.tail(from: storage, to: new))
    XCTAssertLessThan(afterFixing.range.location, 6, "存储补过的字体确实和原样不同，证明不能拿存储来比")
    XCTAssertTrue(storage.attribute(.attachment, at: 3, effectiveRange: nil) as AnyObject === image)
  }

  func testCacheHandsBackSameBlockForSameContent() {
    let cache = ArticleDocumentCache()
    var first: [HostedBlockAttachment] = []
    _ = cache.document(for: AnyHashable("v1"), reuseScope: AnyHashable("style")) {
      first = [cache.block(reuseKey: "image|a") { block() }, cache.block(reuseKey: "image|a") { block() }]
      return ArticleDocument(text: NSAttributedString(), anchors: [:])
    }
    var second: [HostedBlockAttachment] = []
    _ = cache.document(for: AnyHashable("v2"), reuseScope: AnyHashable("style")) {
      second = [
        cache.block(reuseKey: "image|a") { block() },
        cache.block(reuseKey: "image|a") { block() },
        cache.block(reuseKey: "image|b") { block() },
      ]
      return ArticleDocument(text: NSAttributedString(), anchors: [:])
    }
    XCTAssertTrue(second[0] === first[0])
    XCTAssertTrue(second[1] === first[1])
    XCTAssertFalse(second[2] === first[0] || second[2] === first[1])
    var third: HostedBlockAttachment?
    _ = cache.document(for: AnyHashable("v3"), reuseScope: AnyHashable("换了字体")) {
      third = cache.block(reuseKey: "image|a") { block() }
      return ArticleDocument(text: NSAttributedString(), anchors: [:])
    }
    XCTAssertFalse(third === first[0], "样子变了不能沿用旧块")
  }
}

/// 翻译做完那一刻不能跳：2026-10-09 Syc 录屏里的三处（重影、目录行挤一行、提示把整页顶下去）。
final class TranslationFinishSteadinessSourceTests: XCTestCase {
  private func source(_ file: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(file)"),
      encoding: .utf8
    )
  }

  private func section(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start), let upper = text.range(of: end, range: lower.upperBound..<text.endIndex)
    else { return "" }
    return String(text[lower.lowerBound..<upper.lowerBound])
  }

  func testLiveBodySwapsToFinalWithoutCrossfade() throws {
    let detail = try source("HistoryContentView.swift")
    let body = section(detail, from: "private func readingPaneBody(", to: "private func readingPaneContent(")
    XCTAssertTrue(body.contains(".animation(nil, value: showsLiveRunInReadingPane)"))
  }

  func testCompletionNoticeFloatsOverReadingArea() throws {
    let detail = try source("HistoryContentView.swift")
    let scroll = section(detail, from: "private var scrollBody: some View", to: "titleView")
    XCTAssertFalse(scroll.contains("history-step-stamp-banner"), "提示排在标题上面会把整页顶下去")
    XCTAssertFalse(scroll.contains("history-run-completion-banner"))
    let notice = section(detail, from: "@ViewBuilder private var completionNotice", to: "private var pinnedReadingHeader")
    XCTAssertTrue(notice.contains("history-step-stamp-banner"))
    XCTAssertTrue(notice.contains(".allowsHitTesting(false)"))
  }

  func testLiveTranslationHidesOutlineRow() throws {
    let detail = try source("HistoryContentView.swift")
    let live = section(detail, from: "private func liveTranslationMarkdown(", to: "/// 标题下的一行浅字")
    XCTAssertTrue(live.contains("hidesOutlineEntry: true"))
  }
}
