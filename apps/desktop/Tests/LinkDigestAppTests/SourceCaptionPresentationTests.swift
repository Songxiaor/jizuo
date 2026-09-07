import XCTest
import AppKit
@testable import LinkDigestApp

final class SourceCaptionPresentationTests: XCTestCase {
  func testRealCaptionOpeningSurvivesForIndependentTitlePlatforms() {
    let title = "一间温暖的房子"
    let body = title + "\n\n保留作者的描述与 #空间设计\n\n![](https://example.test/image.jpg)"
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: title, from: body, style: .stripSyntheticTitleHeadingOnly
    ), body)
  }

  func testGeneratedHeadingIsRemovedWithoutDeletingCaptionOrMedia() {
    let body = "# 视频标题\n\n视频标题\n补充介绍。\n\n![封面](https://example.test/cover.jpg)"
    let rendered = CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: "视频标题", from: body, style: .stripSyntheticTitleHeadingOnly
    )
    XCTAssertEqual(rendered, "视频标题\n补充介绍。\n\n![封面](https://example.test/cover.jpg)")
  }

  func testHashtagCaptionIsNotAHeading() {
    let body = "#家居\n今天的新发现"
    XCTAssertEqual(CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: "家居", from: body, style: .stripSyntheticTitleHeadingOnly
    ), body)
  }
  func testLegacySoleHeadingAndWhitespaceDoNotRepeat() {
    let name = CapturedContentNaming.Name(text: "Hello  world", origin: .caption)
    XCTAssertTrue(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "# Hello  world"))
    XCTAssertTrue(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "Hello world"))
    XCTAssertFalse(CapturedContentNaming.hidesRepeatedHeading(name: name, body: "Hello world\nMore details"))
  }

  func testCaptionLineBreaksSeparateTopicsAndMixedLanguage() {
    let source = "沉静之旅\n#海瑞温斯顿\nUltimate 胸针搭配\nOcean 腕表"
    let displayed = CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "xiaohongshu")
    let blocks = MarkdownPresentation.blocks(from: displayed)
    XCTAssertEqual(blocks.count, 1)
    guard let first = blocks.first, case let .paragraph(text) = first else { return XCTFail("Caption paragraph missing") }
    XCTAssertEqual(text, source)
    XCTAssertEqual(String(MarkdownPresentation.inlineAttributed(text).characters), source)
    XCTAssertEqual(CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "github"), source)
  }

  func testCaptionFormattingKeepsCodeAndImagesIntact() {
    let source = "配文\n```text\nline one\nline two\n```\n![](https://example.test/image.jpg)"
    let displayed = CapturedSourceBodyPresentation.preservingCaptionParagraphs(source, platform: "douyin")
    XCTAssertTrue(displayed.contains("```text\nline one\nline two\n```"))
    XCTAssertTrue(displayed.contains("![](https://example.test/image.jpg)"))
  }

  func testReaderDatesKeepOriginalPrecisionAndWallClock() {
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-09-06 10:00:45"), "2026年9月6日 10:00")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-09-06"), "2026年9月6日")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text("2026-02-31"), "2026-02-31")
    XCTAssertEqual(HistoryPublishedTimestampFormatter.text(nil), "发布时间未获取")
  }

  func testHardBreakDoesNotAddAnotherParagraphGap() {
    let composed = ReadingTextComposer.attributed(
      blocks: [.paragraph("配文第一行\n#话题第二行"), .paragraph("下一段")],
      readingFont: .sans,
      palette: .init(primary: .black, secondary: .darkGray, accent: .blue)
    )
    XCTAssertEqual(composed.string, "配文第一行\u{2028}#话题第二行\n下一段\n")
  }

}
