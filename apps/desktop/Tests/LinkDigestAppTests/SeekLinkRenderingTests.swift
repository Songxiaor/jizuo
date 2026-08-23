import XCTest
import LinkDigestCore
@testable import LinkDigestApp

final class SeekLinkRenderingTests: XCTestCase {
  /// 时间码链接必须活着穿过 Markdown 渲染管线。
  ///
  /// 这条链路有两头容易断：链接语法可能被清理步骤吃掉（正文里露出
  /// `[00:09](linkdigest-seek:/9)` 这种字面量），也可能被解析成普通文本
  /// （看着正常，点了没反应）。两种都在界面上很难一眼看出来。
  func testTimestampLinkSurvivesMarkdownParsing() throws {
    let linked = MediaSeekLink.linkifyingTimestamps(in: "00:09 但今天我打算只分享几点想法")
    let attributed = MarkdownPresentation.inlineAttributed(linked)

    // 读者看到的应该是干净的时间码，不是链接语法。
    let plain = String(attributed.characters)
    XCTAssertEqual(plain, "00:09 但今天我打算只分享几点想法")
    XCTAssertFalse(plain.contains("linkdigest-seek"))

    // 而它确实带着可点击的地址，秒数换算正确。
    let links = attributed.runs.compactMap { $0.link }
    XCTAssertEqual(links.count, 1, "应当解析出一个跳转链接")
    XCTAssertEqual(links.first.flatMap(MediaSeekLink.seconds(from:)), 9)
  }

  /// 一小时以上的时间码同样要能点。
  func testHourLongTimestampAlsoBecomesALink() throws {
    let linked = MediaSeekLink.linkifyingTimestamps(in: "1:44:39 最后一段")
    let attributed = MarkdownPresentation.inlineAttributed(linked)
    let links = attributed.runs.compactMap { $0.link }
    XCTAssertEqual(links.first.flatMap(MediaSeekLink.seconds(from:)), 6279)
  }
}
