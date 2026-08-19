import XCTest
@testable import LinkDigestCore

/// 形态指纹与排版档案。
///
/// 这些判据错了不会报错，只表现为「这一类排版怪」——图集被拆成一张张平铺，
/// 或者作者安排的配图位置被打乱。所以逐条钉死。
///
/// 用例里的数字取自真实库：40 条记录跑下来，微信图文的图/段比是 32/32、18/18、
/// 4/3，图集是 4/1、3/1。阈值就是照着这两簇之间的空当定的。
final class ReadingFormatProfileTests: XCTestCase {
  private func context(
    _ markdown: String, platform: String = "generic", isTranscript: Bool = false
  ) -> ReadingFormatContext {
    ReadingFormatContext(
      shape: ContentShape.measure(markdown: markdown),
      platform: platform,
      isTranscript: isTranscript
    )
  }

  // MARK: 指纹

  func testFenceContentsAreNotCountedAsHeadingsOrImages() {
    // 代码块里的 `#` 是注释，`![...]()` 是示例。当成标题和图片会把一篇代码教程
    // 量成「多标题图集」。标题重基那里已经踩过同一个坑。
    let shape = ContentShape.measure(markdown: """
      正文一段。

      ```bash
      # 这是注释不是标题
      # 这也是
      echo '![假图](x.png)'
      ```

      ## 真标题
      """)
    XCTAssertEqual(shape.headingCount, 1)
    XCTAssertEqual(shape.imageCount, 0)
    XCTAssertTrue(shape.hasCode)
  }

  func testConsecutiveImagesFormOneRunEvenAcrossBlankLines() {
    // `![](a)\n\n![](b)` 在 Markdown 里仍是并列的两张图，空行不该把图集拆开。
    let shape = ContentShape.measure(markdown: """
      ![](https://x.test/1.png)

      ![](https://x.test/2.png)

      ![](https://x.test/3.png)
      """)
    XCTAssertEqual(shape.imageCount, 3)
    XCTAssertEqual(shape.imageRunCount, 1)
    XCTAssertEqual(shape.averageImagesPerRun, 3, accuracy: 0.001)
  }

  func testImagesSeparatedByProseAreSeparateRuns() {
    let shape = ContentShape.measure(markdown: """
      第一段说明文字。

      ![](https://x.test/1.png)

      第二段说明文字。

      ![](https://x.test/2.png)

      第三段说明文字。
      """)
    XCTAssertEqual(shape.imageCount, 2)
    XCTAssertEqual(shape.imageRunCount, 2)
  }

  /// 图片和文字同一行时是穿插配图，不能算进画廊。
  func testImageSharingALineWithProseBreaksTheRun() {
    let shape = ContentShape.measure(markdown: """
      ![](https://x.test/1.png) 图一说明
      ![](https://x.test/2.png)
      """)
    XCTAssertEqual(shape.imageCount, 2)
    XCTAssertEqual(shape.imageRunCount, 2)
  }

  func testTableAndCodeAreDetected() {
    let shape = ContentShape.measure(markdown: """
      | 键 | 值 |
      | --- | --- |
      | a | b |
      """)
    XCTAssertTrue(shape.hasTable)
    XCTAssertFalse(shape.hasCode)
  }

  /// 抽取质量仪表：长而无标题多半是抽取把结构丢了。
  func testStructurallyThinFlag() {
    let long = String(repeating: "正文。", count: 800)
    XCTAssertTrue(ContentShape.measure(markdown: long).looksStructurallyThin)
    XCTAssertFalse(ContentShape.measure(markdown: "短文。").looksStructurallyThin)
  }

  // MARK: 档案分派

  func testTranscriptWinsBeforeLengthRules() {
    // 转写稿字数常常过万，不先拦住就会落进长文档。
    let long = String(repeating: "口播内容。", count: 900)
    XCTAssertEqual(context(long, isTranscript: true).matchedProfileID, "video-transcript")
  }

  func testGroupedImagesBecomeAGallery() {
    let markdown = ([String](repeating: "![](https://x.test/i.png)", count: 4)).joined(separator: "\n\n")
    XCTAssertEqual(context(markdown).matchedProfileID, "image-gallery")
  }

  /// 微信图文的真实形态：图片一张张夹在文字之间，位置是作者安排的。
  /// **判据不写平台**——同样形态的 generic 长文也应当落在这里。
  func testInlineIllustratedKeepsImagePositions() {
    var markdown = ""
    for index in 0..<6 {
      markdown += "第\(index)段正文，讲一件事情。\n\n![](https://x.test/\(index).png)\n\n"
    }
    let wechat = context(markdown, platform: "wechat")
    let generic = context(markdown, platform: "generic")
    XCTAssertEqual(wechat.matchedProfileID, "inline-illustrated")
    XCTAssertEqual(generic.matchedProfileID, "inline-illustrated", "同样的形态换个平台必须落同一个档案")
    XCTAssertTrue(ReadingFormatRegistry.decisions(for: wechat).keepsImagePositions)
    XCTAssertTrue(ReadingFormatRegistry.decisions(for: generic).keepsImagePositions)
  }

  func testGalleryDoesNotKeepImagePositions() {
    let markdown = ([String](repeating: "![](https://x.test/i.png)", count: 5)).joined(separator: "\n\n")
    XCTAssertFalse(ReadingFormatRegistry.decisions(for: context(markdown)).keepsImagePositions)
  }

  func testLongArticleAllowsOutline() {
    let long = String(repeating: "正文一句话。", count: 400)
    let ctx = context(long)
    XCTAssertEqual(ctx.matchedProfileID, "long-form-article")
    XCTAssertTrue(ReadingFormatRegistry.decisions(for: ctx).allowsOutline)
  }

  func testTranscriptAndGalleryDisallowOutline() {
    XCTAssertFalse(ReadingFormatRegistry.decisions(for: context("口播", isTranscript: true)).allowsOutline)
    let gallery = ([String](repeating: "![](https://x.test/i.png)", count: 4)).joined(separator: "\n\n")
    XCTAssertFalse(ReadingFormatRegistry.decisions(for: context(gallery)).allowsOutline)
  }

  /// 每一条内容都必须落到某个档案上；返回可选值只会把判断推回调用方。
  func testEverythingMatchesSomeProfile() {
    for markdown in ["", "一句话。", "![](https://x.test/a.png)"] {
      XCTAssertFalse(ReadingFormatRegistry.profile(for: context(markdown)).id.isEmpty)
    }
  }
}

private extension ReadingFormatContext {
  var matchedProfileID: String { ReadingFormatRegistry.profile(for: self).id }
}
