import XCTest
@testable import LinkDigestCore

final class SummaryTemplateTests: XCTestCase {
  func testSelectsByFormAndSource() {
    XCTAssertEqual(
      SummaryTemplate.select(origin: .browserCapture, url: "https://github.com/groue/GRDB.swift", text: "README"),
      .repository
    )
    XCTAssertEqual(
      SummaryTemplate.select(origin: .browserCapture, url: "https://github.com/groue", text: "主页"),
      .general,
      "只有一级路径的是个人主页，不是仓库"
    )
    XCTAssertEqual(
      SummaryTemplate.select(origin: .localTranscription, url: "https://www.bilibili.com/video/BV1", text: "讲了什么"),
      .media
    )
    XCTAssertEqual(
      SummaryTemplate.select(
        origin: .browserCapture,
        url: "https://www.youtube.com/watch?v=1",
        text: "## 配文\n\n简介\n\n## 视频转写\n\n00:01 你好"
      ),
      .media
    )
    XCTAssertEqual(
      SummaryTemplate.select(origin: .browserCapture, url: "https://x.com/a/status/1", text: "00:01 第一句\n\n00:15 第二句"),
      .media,
      "正文是带时间码的转写稿也算视频"
    )
    XCTAssertEqual(
      SummaryTemplate.select(origin: .browserCapture, url: "https://x.com/a/status/1", text: "帖子正文\n\n## 评论（12 条）\n\n- 不同意"),
      .discussion
    )
    XCTAssertEqual(
      SummaryTemplate.select(origin: .browserCapture, url: "https://example.com/post", text: "普通文章"),
      .general
    )
  }

  func testMediaWithCommentsAddsCommentSection() {
    let text = "00:01 开头\n\n00:20 继续\n\n## 评论（3 条）\n\n- 评论"
    let template = SummaryTemplate.select(origin: .localTranscription, url: "https://b23.tv/x", text: text)
    XCTAssertEqual(template, .media)
    XCTAssertTrue(SummaryTemplate.appendsCommentAnalysis(template, text: text))
    XCTAssertFalse(SummaryTemplate.appendsCommentAnalysis(.media, text: "00:01 开头"))
  }

  func testDefaultPromptFollowsTemplateButCustomPromptWins() {
    let media = ModelPreferences.summaryPrompt(configuredPrompt: "", outputLanguage: "简体中文", template: .media)
    XCTAssertTrue(media.contains("### [mm:ss]"))
    XCTAssertTrue(media.contains("Write the final answer in 简体中文"))

    let fromStoredDefault = ModelPreferences.summaryPrompt(
      configuredPrompt: ModelPreferences.defaultSummaryPrompt,
      outputLanguage: "简体中文",
      template: .repository
    )
    XCTAssertTrue(fromStoredDefault.hasPrefix(SummaryTemplate.repository.prompt()))

    let custom = ModelPreferences.summaryPrompt(configuredPrompt: "只写三句话", outputLanguage: "简体中文", template: .media)
    XCTAssertTrue(custom.hasPrefix("只写三句话"))
    XCTAssertFalse(custom.contains("[mm:ss]"), "用户改过的提示词不能被形式模板覆盖")

    XCTAssertEqual(
      ModelPreferences.summaryPrompt(configuredPrompt: "", outputLanguage: "简体中文"),
      ModelPreferences.summaryPrompt(configuredPrompt: "", outputLanguage: "简体中文", template: .general),
      "通用写法与原来完全一致"
    )
  }

  func testBracketedTimestampsBecomeSeekLinks() {
    let summary = "### [03:12] 第一节\n- [1:04:09] 关键一刻\n- 第 3:15 条不是时间码\n- 已有 [00:05](linkdigest-seek:/5)\n- [7:99] 不合法"
    let linked = MediaSeekLink.linkifyingBracketedTimestamps(in: summary)
    XCTAssertTrue(linked.contains("### [03:12](linkdigest-seek:/192) 第一节"))
    XCTAssertTrue(linked.contains("- [1:04:09](linkdigest-seek:/3849) 关键一刻"))
    XCTAssertTrue(linked.contains("第 3:15 条不是时间码"))
    XCTAssertTrue(linked.contains("[00:05](linkdigest-seek:/5)"))
    XCTAssertFalse(linked.contains("[00:05](linkdigest-seek:/5)](")) // 不重复包
    XCTAssertTrue(linked.contains("[7:99] 不合法"))
  }

  func testClockParsing() {
    XCTAssertEqual(MediaSeekLink.seconds(ofClock: "00:00"), 0)
    XCTAssertEqual(MediaSeekLink.seconds(ofClock: "12:34"), 754)
    XCTAssertEqual(MediaSeekLink.seconds(ofClock: "1:02:03"), 3723)
    XCTAssertNil(MediaSeekLink.seconds(ofClock: "1:2"))
    XCTAssertNil(MediaSeekLink.seconds(ofClock: "12:60"))
  }
}
