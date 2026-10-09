import AppKit
import LinkDigestCore
import XCTest
@testable import LinkDigestApp

/// 转写稿正文排成一块原生文字（2026-10-06 滑动性能改造）：样子要和原来逐段排时一致。
final class TranscriptTextBlockTests: XCTestCase {
  private let style = TranscriptTextStyle(
    readingFont: .serif, primaryText: .labelColor, secondaryText: .secondaryLabelColor, showsTimecodes: true
  )

  func testTimecodesHangInTheGutterAndSeek() {
    let document = TranscriptTextDocument.make([
      TranscriptTextLine(kind: .body, stamp: "1:09:34", seekSeconds: 4174, text: "一般电影都是配乐"),
      TranscriptTextLine(kind: .body, stamp: "1:10:39", seekSeconds: 4239, text: "还在讲"),
    ], style: style)
    XCTAssertEqual(document.string, "1:09:34\t一般电影都是配乐\n1:10:39\t还在讲")
    let link = document.attribute(.link, at: 0, effectiveRange: nil) as? URL
    XCTAssertEqual(link.flatMap(TranscriptTextDocument.seconds(from:)), 4174)
    let paragraph = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(paragraph?.headIndent, TranscriptGutter.textInset)
    XCTAssertEqual(paragraph?.tabStops.first?.location, TranscriptGutter.textInset)
    // 正文不是链接，点了不跳。
    XCTAssertNil(document.attribute(.link, at: 9, effectiveRange: nil))
  }

  func testSpeakerNameCarriesTheTurnTimecode() {
    let turns = SpeakerTranscript.turns(in: "00:01 **说话人 01**：第一段\n\n00:10 第二段\n\n00:19 **说话人 02**：换人了")
    let lines = SpeakerTranscriptView.lines(turns)
    XCTAssertEqual(lines.map(\.kind), [.speaker, .body, .body, .speaker, .body])
    XCTAssertEqual(lines.first?.stamp, "00:01")
    XCTAssertEqual(lines[3].spacingBefore, TranscriptGutter.turnSpacing)
    XCTAssertGreaterThan(lines[3].spacingBefore, lines[2].spacingBefore)
  }

  func testWithoutTimecodesThereIsNoGutter() {
    let plain = TranscriptTextStyle(
      readingFont: .serif, primaryText: .labelColor, secondaryText: .secondaryLabelColor, showsTimecodes: false
    )
    let document = TranscriptTextDocument.make([
      TranscriptTextLine(kind: .body, stamp: "00:01", seekSeconds: 1, text: "正文"),
    ], style: plain)
    XCTAssertEqual(document.string, "正文")
    let paragraph = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(paragraph?.headIndent, 0)
  }

  /// 展开 / 收起只换末尾那截（2026-10-07）：换完必须和整份替换一模一样，文字、时间码链接、段落样式都不能错。
  @MainActor func testExpandAndCollapseOnlyReplaceTheTailAndMatchAFullReplace() {
    let all = (0..<6).map { index in
      TranscriptTextLine(kind: .body, stamp: "00:0\(index)", seekSeconds: Double(index), text: "第\(index)段正文")
    }
    let preview = TranscriptTextDocument.make(Array(all.prefix(2)), style: style)
    let full = TranscriptTextDocument.make(all, style: style)
    // 预览最后一段不带换行、全文里同一段带：相同的开头停在那个换行前。
    XCTAssertEqual(TranscriptTextBlockView.sharedPrefixLength(preview, full), preview.length)

    let view = TranscriptTextBlockView()
    view.setDocument(preview, linkColor: .secondaryLabelColor)
    view.setDocument(full, linkColor: .secondaryLabelColor)
    XCTAssertTrue(view.documentForTesting.isEqual(to: full), "展开后应与全文一致")
    view.setDocument(preview, linkColor: .secondaryLabelColor)
    XCTAssertTrue(view.documentForTesting.isEqual(to: preview), "收起后应与预览一致")
  }

  @MainActor func testRestyledDocumentIsReplacedWhole() {
    let lines = [TranscriptTextLine(kind: .body, stamp: "00:01", seekSeconds: 1, text: "正文")]
    let plain = TranscriptTextStyle(
      readingFont: .serif, primaryText: .labelColor, secondaryText: .secondaryLabelColor, showsTimecodes: true
    )
    let tinted = TranscriptTextStyle(
      readingFont: .serif, primaryText: .systemRed, secondaryText: .secondaryLabelColor, showsTimecodes: true
    )
    let before = TranscriptTextDocument.make(lines, style: plain)
    let after = TranscriptTextDocument.make(lines, style: tinted)
    XCTAssertEqual(TranscriptTextBlockView.sharedPrefixLength(before, after), 0)
  }
}
