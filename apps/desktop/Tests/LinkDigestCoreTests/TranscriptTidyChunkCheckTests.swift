import XCTest
import LinkDigestCore

/// 校对稿逐段核对：2026-09-28 第 1 段的位置拿到了第 7 段的校对稿，开头 4 分钟被覆盖。
final class TranscriptTidyChunkCheckTests: XCTestCase {
  private let chunk = "00:00 从有互联网的那一天开始 ，所有的商家都被迫卷进了一场全国性的斗争以前你的竞争对手就是方圆5公里\n\n00:57 那很多人说我读书多没用那是你读的书不够多看哲学看多了容易让人生进入迷茫"

  func testTidiedVersionOfTheSameChunkPasses() {
    let tidied = "00:00 从有互联网的那一天开始，所有的商家都被迫卷进了一场全国性的斗争。以前你的竞争对手就是方圆5公里。\n\n00:57 那很多人说我读书多没用，那是你读的书不够多。看哲学看多了容易让人生进入迷茫。"
    XCTAssertTrue(TranscriptTidyChunkCheck.belongs(output: tidied, to: chunk))
  }

  func testReplyForAnotherChunkIsRejected() {
    let other = "32:10 不是有个非常简单的道理吗？你想跟一个人真正建立关系，要么让他欠你点什么，或者你欠他点什么。\n\n32:55 我永远就欠你一点，欠你一点，你会不会一直跟我保持关系？"
    XCTAssertFalse(TranscriptTidyChunkCheck.belongs(output: other, to: chunk))
  }

  func testDroppedFirstTimestampOrForeignTimestampIsRejected() {
    let droppedFirst = "从有互联网的那一天开始，所有的商家都被迫卷进了一场全国性的斗争。以前你的竞争对手就是方圆5公里。\n\n00:57 那很多人说我读书多没用，那是你读的书不够多。看哲学看多了容易让人生进入迷茫。"
    XCTAssertFalse(TranscriptTidyChunkCheck.belongs(output: droppedFirst, to: chunk))
    let foreign = "00:00 从有互联网的那一天开始，所有的商家都被迫卷进了一场全国性的斗争。以前你的竞争对手就是方圆5公里。\n\n09:99 那很多人说我读书多没用，那是你读的书不够多。看哲学看多了容易让人生进入迷茫。"
    XCTAssertFalse(TranscriptTidyChunkCheck.belongs(output: foreign, to: chunk))
  }

  func testLengthFarOffIsRejectedEvenWithoutTimestamps() {
    let plain = String(repeating: "字", count: 1_000)
    XCTAssertTrue(TranscriptTidyChunkCheck.belongs(output: String(repeating: "字", count: 1_050), to: plain))
    XCTAssertFalse(TranscriptTidyChunkCheck.belongs(output: String(repeating: "字", count: 300), to: plain))
    XCTAssertFalse(TranscriptTidyChunkCheck.belongs(output: String(repeating: "字", count: 2_000), to: plain))
  }

  func testTimestampsAreReadFromParagraphStarts() {
    XCTAssertEqual(TranscriptTidyChunkCheck.timestamps(in: "1:02:03 开头\n\n21:15 第二段 提到 3:00 不算"), ["1:02:03", "21:15"])
  }
}
