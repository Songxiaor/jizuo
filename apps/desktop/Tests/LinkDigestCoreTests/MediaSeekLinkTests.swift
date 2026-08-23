import XCTest
@testable import LinkDigestCore

final class MediaSeekLinkTests: XCTestCase {
  func testRoundTripsSecondsThroughTheURL() {
    for seconds in [0, 9, 59, 60, 3599, 3600, 6301] {
      let url = MediaSeekLink.url(atSeconds: seconds)
      XCTAssertEqual(MediaSeekLink.seconds(from: url), seconds)
    }
    // 负数没有意义，钳到 0 而不是造出一个非法地址。
    XCTAssertEqual(MediaSeekLink.seconds(from: MediaSeekLink.url(atSeconds: -5)), 0)
    // 别人的链接不能被误认成跳转指令。
    XCTAssertNil(MediaSeekLink.seconds(from: URL(string: "https://example.test/12")!))
    XCTAssertNil(MediaSeekLink.seconds(from: URL(string: "linkdigest-wiki:/标题")!))
  }

  /// 两种时间码写法都要认，且换算正确。
  func testLinkifiesBothTimestampShapes() {
    let source = """
    00:00 第一段正文。

    02:16 第二段正文。

    1:44:39 最后一段正文。
    """
    let linked = MediaSeekLink.linkifyingTimestamps(in: source)
    XCTAssertTrue(linked.contains("[00:00](linkdigest-seek:/0)"))
    XCTAssertTrue(linked.contains("[02:16](linkdigest-seek:/136)"))
    XCTAssertTrue(linked.contains("[1:44:39](linkdigest-seek:/6279)"))
    // 正文本身不能被改动。
    XCTAssertTrue(linked.contains("第一段正文。"))
    XCTAssertTrue(linked.contains("最后一段正文。"))
  }

  /// 只认行首。正文中间的时间写法是内容，不是排版。
  func testOnlyLeadingTimestampsBecomeLinks() {
    let source = "他说会议定在 3:15 开始，别迟到。"
    XCTAssertEqual(MediaSeekLink.linkifyingTimestamps(in: source), source, "行中的时间不该变成跳转链接")

    let heading = "## 视频转写"
    XCTAssertEqual(MediaSeekLink.linkifyingTimestamps(in: heading), heading)
  }

  /// 长得像时间码但不是的东西必须放过。
  func testRejectsNonTimestampShapes() {
    for line in [
      "12:30PM 会议纪要",      // 后面不是空白
      "1:5 太短",              // 秒必须两位
      "123:45 帧号",           // 分段超过两位
      "00:99 不存在的秒",       // 秒越界
      ":30 缺前段",
      "正文开头没有时间码"
    ] {
      XCTAssertEqual(
        MediaSeekLink.linkifyingTimestamps(in: line),
        line,
        "不该把「\(line)」当成时间码"
      )
    }
  }

  /// 已经落库的稿子直接就能点——这正是选择在渲染时转换的原因。
  func testWorksOnAlreadyPersistedTranscriptShape() {
    let persisted = "00:00 About career advice in AI.\n\n00:09 但今天我打算只分享几点想法"
    let linked = MediaSeekLink.linkifyingTimestamps(in: persisted)
    XCTAssertTrue(linked.contains("[00:00](linkdigest-seek:/0)"))
    XCTAssertTrue(linked.contains("[00:09](linkdigest-seek:/9)"))
  }
}
