import CoreMedia
import XCTest
@testable import LinkDigestCore

final class LocalVideoTranscriptionTests: XCTestCase {
  func testVolatileReplacementEmptyRevocationFinalCoverageAndOrdering() {
    var value = TimedTranscriptionAccumulator()
    // The 1s silence between these ranges is a paragraph break, so the joiner
    // emits a blank line — a single newline would render as one Markdown block.
    XCTAssertEqual(value.apply(range: range(2, 1), text: "后段草稿", isFinal: false), "00:02 后段草稿")
    XCTAssertEqual(value.apply(range: range(0, 1), text: "前段定稿", isFinal: true), "00:00 前段定稿\n\n00:02 后段草稿")
    XCTAssertEqual(value.apply(range: range(2, 1), text: "后段修正", isFinal: false), "00:00 前段定稿\n\n00:02 后段修正")
    XCTAssertEqual(value.apply(range: range(2, 1), text: "", isFinal: false), "00:00 前段定稿")
    XCTAssertEqual(value.finalText, "00:00 前段定稿")

    _ = value.apply(range: range(2, 2), text: "会被覆盖的草稿", isFinal: false)
    XCTAssertEqual(value.apply(range: range(2.5, 3), text: "后段定稿", isFinal: true), "00:00 前段定稿\n\n00:02 后段定稿")
    XCTAssertEqual(value.finalText, "00:00 前段定稿\n\n00:02 后段定稿")
  }

  func testFinalReplacementRemovesOverlappingOlderFinalAndNeverPersistsVolatile() {
    var value = TimedTranscriptionAccumulator()
    _ = value.apply(range: range(0, 2), text: "旧定稿", isFinal: true)
    _ = value.apply(range: range(2, 1), text: "临时尾巴", isFinal: false)
    XCTAssertEqual(value.apply(range: range(0, 2.5), text: "新定稿", isFinal: true), "00:00 新定稿")
    XCTAssertEqual(value.finalText, "00:00 新定稿")
    XCTAssertFalse(value.finalText.contains("临时尾巴"))
  }

  func testContinuousSpeechStaysOneParagraphAndSilenceStartsANewOne() {
    var value = TimedTranscriptionAccumulator()
    // 0.2s apart: the speaker never stopped, so this is one thought. Chinese
    // runs together — inserting a separator here would be wrong.
    _ = value.apply(range: range(0, 1), text: "我知道了", isFinal: true)
    _ = value.apply(range: range(1.2, 1), text: "十万粉丝的博主", isFinal: true)
    XCTAssertEqual(value.finalText, "00:00 我知道了十万粉丝的博主")

    // 2s of silence: a new paragraph.
    _ = value.apply(range: range(4.2, 1), text: "自从我发了几条视频", isFinal: true)
    XCTAssertEqual(value.finalText, "00:00 我知道了十万粉丝的博主\n\n00:04 自从我发了几条视频")
  }

  func testCommaOnlySpeechStillBreaksAtSoftTerminators() {
    var value = TimedTranscriptionAccumulator()
    // ASR 中文常整段只有逗号；超过两倍软上限后必须允许在逗号处断段，
    // 否则输出是一面无法阅读的文字墙。
    let clause = String(repeating: "这段话完全没有句号只有逗号", count: 30) + "，"
    _ = value.apply(range: range(0, 1), text: clause + clause, isFinal: true)
    let paragraphs = value.finalText.components(separatedBy: "\n\n")
    XCTAssertGreaterThan(paragraphs.count, 1)
    // 每段都以逗号收尾（在软终止符处断开），而不是任意位置硬切。
    for paragraph in paragraphs.dropLast() {
      XCTAssertEqual(paragraph.last, "，")
    }
  }

  func testLatinSegmentsKeepTheSpaceTheSegmentBoundaryAte() {
    var value = TimedTranscriptionAccumulator()
    _ = value.apply(range: range(0, 1), text: "hello there", isFinal: true)
    _ = value.apply(range: range(1.1, 1), text: "friend", isFinal: true)
    XCTAssertEqual(value.finalText, "00:00 hello there friend")
  }

  func testAFastTalkerWithoutPausesStillBreaksAtSentenceEnds() {
    var value = TimedTranscriptionAccumulator()
    let sentence = String(repeating: "这是一段很长的话", count: 12) + "。"
    // One continuous run, no qualifying silence anywhere.
    for (index, _) in [0, 1, 2].enumerated() {
      _ = value.apply(
        range: range(Double(index) * 1.1, 1),
        text: sentence,
        isFinal: true
      )
    }
    let paragraphs = value.finalText.components(separatedBy: "\n\n")
    XCTAssertGreaterThan(paragraphs.count, 1, "A wall of text must be broken up")
    XCTAssertTrue(
      paragraphs.dropLast().allSatisfy { $0.hasSuffix("。") },
      "Breaks belong at sentence ends, never mid-sentence"
    )
  }

  func testUnpunctuatedRunIsLeftIntactRatherThanCutMidSentence() {
    var value = TimedTranscriptionAccumulator()
    // Long, no terminator at all: cutting at an arbitrary offset would be worse
    // than one long paragraph, so it stays whole.
    let run = String(repeating: "没有标点的连续语流", count: 30)
    _ = value.apply(range: range(0, 5), text: run, isFinal: true)
    XCTAssertEqual(value.finalText, "00:00 \(run)")
    XCTAssertFalse(value.finalText.contains("\n"))
  }

  func testDecimalNumberSurvivesPauseAtSegmentSeam() {
    var value = TimedTranscriptionAccumulator()
    // 说数字时的微停顿会把“9.7”切成两个识别结果；断段或补空格都会把数字腰斩。
    _ = value.apply(range: range(0, 1), text: "本季度评分9", isFinal: true)
    _ = value.apply(range: range(2, 1), text: ".7分", isFinal: true)
    XCTAssertEqual(value.finalText, "00:00 本季度评分9.7分")

    // 中文标点模型常把 decimal 写成句号：同样不能在“9”“。7”之间断段。
    var fullwidth = TimedTranscriptionAccumulator()
    _ = fullwidth.apply(range: range(0, 1), text: "增长了9", isFinal: true)
    _ = fullwidth.apply(range: range(2, 1), text: "。7个百分点", isFinal: true)
    XCTAssertEqual(fullwidth.finalText, "00:00 增长了9。7个百分点")
  }

  func testLongParagraphNeverSplitsInsideADecimal() {
    for decimal in ["9.7", "9。7"] {
      var value = TimedTranscriptionAccumulator()
      // 让唯一的“句末标点”恰好是小数点，且正好落在软上限之后：
      // 守卫缺席时会在小数点处切段，把“7”甩到下一段开头。
      let filler = String(repeating: "字", count: TimedTranscriptionAccumulator.softParagraphCharacterCount)
      _ = value.apply(range: range(0, 5), text: filler + decimal + "分", isFinal: true)
      XCTAssertFalse(value.finalText.contains("\n"), "不得在 \(decimal) 内部切段")
      XCTAssertTrue(value.finalText.contains(decimal + "分"))
    }
  }

  func testParagraphClockUsesHoursWhenNeeded() {
    XCTAssertEqual(TimedTranscriptionAccumulator.clock(0), "00:00")
    XCTAssertEqual(TimedTranscriptionAccumulator.clock(65), "01:05")
    XCTAssertEqual(TimedTranscriptionAccumulator.clock(3661), "1:01:01")
  }

  private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 1_000),
      duration: CMTime(seconds: duration, preferredTimescale: 1_000)
    )
  }

  /// 长段落切片后，每片必须有自己的时间码。
  ///
  /// 原实现让所有切片复用段落起始时间，于是识别得越准问题越明显：内容变多 →
  /// 段落变长 → 每段切得更碎，而锚点数量一点没涨。实测 105 分钟的稿子 457 段
  /// 只有 41 个不同时间码，点击定位基本失去意义。
  func testSplitPiecesOfALongParagraphGetDistinctAscendingTimestamps() {
    var value = TimedTranscriptionAccumulator()
    // 一段没有停顿的连续讲话，长到必然被按字数切开。
    let sentence = "这是一句足够长的话用来把段落撑过软切分的字数上限。"
    let longSpeech = String(repeating: sentence, count: 12)
    value.merge(range: range(0, 120), text: longSpeech, isFinal: true)
    let lines = value.finalText
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    XCTAssertGreaterThan(lines.count, 1, "fixture 前提：这段话必须被切成多片")

    let stamps = lines.compactMap { $0.split(separator: " ").first.map(String.init) }
    XCTAssertEqual(stamps.count, lines.count)
    XCTAssertGreaterThan(Set(stamps).count, 1, "切片不能共用同一个时间码")
    // 递增而不是乱跳，且不越出这段话的真实时间范围。
    let seconds = stamps.map { stamp -> Int in
      let parts = stamp.split(separator: ":").compactMap { Int($0) }
      return parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2]
        : (parts.count == 2 ? parts[0] * 60 + parts[1] : 0)
    }
    XCTAssertEqual(seconds, seconds.sorted(), "时间码必须递增")
    XCTAssertEqual(seconds.first, 0)
    XCTAssertLessThanOrEqual(seconds.last ?? 0, 120, "插值不能超出段落结束时间")
  }

  /// 没有可用时长的段落不许造出假时间。
  func testParagraphWithoutDurationKeepsTheParagraphStartForEveryPiece() {
    var value = TimedTranscriptionAccumulator()
    let sentence = "这是一句足够长的话用来把段落撑过软切分的字数上限。"
    // duration 为 0：起止相同，无法插值。
    value.merge(range: range(30, 0), text: String(repeating: sentence, count: 12), isFinal: true)
    let stamps = value.finalText
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { $0.split(separator: " ").first.map(String.init) }
    XCTAssertGreaterThan(stamps.count, 1)
    XCTAssertEqual(Set(stamps), ["00:30"], "无时长可插值时应保持段落起始时间")
  }
}
