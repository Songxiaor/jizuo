import XCTest
@testable import LinkDigestCore

final class SpeakerTranscriptTests: XCTestCase {
  private func p(_ start: Double, _ end: Double, _ text: String) -> TranscriptParagraph {
    TranscriptParagraph(startMilliseconds: Int(start * 1000), endMilliseconds: Int(end * 1000), text: text)
  }

  /// 实测的分离结果形状：引擎编号不按出场顺序（先出场的是 S2），展示时要重编成「说话人 1」。
  func testAssignsSpeakersByOverlapAndNumbersByAppearance() {
    let paragraphs = [p(0, 6, "大家好"), p(8, 12, "我建议推迟"), p(14, 19, "风险大吗"), p(20.5, 27, "风险可控")]
    let segments = [
      SpeakerSegment(startSeconds: 0, endSeconds: 6, speaker: "S2"),
      SpeakerSegment(startSeconds: 7.9, endSeconds: 12.4, speaker: "S1"),
      SpeakerSegment(startSeconds: 13.7, endSeconds: 19.2, speaker: "S2"),
      SpeakerSegment(startSeconds: 20.4, endSeconds: 27, speaker: "S1"),
    ]
    let labeled = SpeakerTranscript.assignSpeakers(to: paragraphs, segments: segments)
    XCTAssertEqual(labeled.map(\.speaker), ["说话人 01", "说话人 02", "说话人 01", "说话人 02"])
  }

  func testParagraphWithoutOverlapTakesNearestSpeaker() {
    let labeled = SpeakerTranscript.assignSpeakers(
      to: [p(30, 31, "尾巴")],
      segments: [SpeakerSegment(startSeconds: 0, endSeconds: 5, speaker: "A"), SpeakerSegment(startSeconds: 25, endSeconds: 29, speaker: "B")]
    )
    XCTAssertEqual(labeled.first?.speaker, "说话人 02")
  }

  func testRenderLabelsOnlyOnSpeakerChangeAndKeepsLeadingTimestamp() {
    let rendered = SpeakerTranscript.render([
      (p(12, 20, "先说安排。"), "说话人 1"),
      (p(20, 30, "再补一句。"), "说话人 1"),
      (p(31, 40, "好的。"), "说话人 2"),
    ])
    XCTAssertEqual(rendered.body, "00:12 **说话人 1**：先说安排。\n\n00:20 再补一句。\n\n00:31 **说话人 2**：好的。")
    XCTAssertEqual(rendered.paragraphs.map(\.text), ["说话人 1：先说安排。", "说话人 1：再补一句。", "说话人 2：好的。"])
    XCTAssertEqual(SpeakerTranscript.speakers(in: rendered.body), ["说话人 1", "说话人 2"])
    // 时间码仍在行首，点击跳转照常生效。
    XCTAssertTrue(MediaSeekLink.linkifyingTimestamps(in: rendered.body).hasPrefix("[00:12](linkdigest-seek:/12)"))
  }

  func testRenameReplacesBodyAndParagraphs() {
    let rendered = SpeakerTranscript.render([(p(0, 5, "你好"), "说话人 1"), (p(6, 9, "嗯"), "说话人 2")])
    let body = SpeakerTranscript.renaming("说话人 1", to: " 张总 ", in: rendered.body)
    XCTAssertEqual(SpeakerTranscript.speakers(in: body), ["张总", "说话人 2"])
    let paragraphs = SpeakerTranscript.renaming("说话人 1", to: "张总", in: rendered.paragraphs)
    XCTAssertEqual(paragraphs.first?.text, "张总：你好")
    XCTAssertEqual(SpeakerTranscript.renaming("说话人 1", to: "  ", in: rendered.body), rendered.body)
  }

  func testRediarizeStripsOldLabelsAndParsesLegacyBody() {
    let body = "00:12 **张总**：先说安排。\n\n00:20 再补一句。\n\n01:05 **说话人 2**：好的。"
    let parsed = SpeakerTranscript.paragraphs(fromTimestampedBody: body)
    XCTAssertEqual(parsed.map(\.text), ["先说安排。", "再补一句。", "好的。"])
    XCTAssertEqual(parsed.map(\.startMilliseconds), [12_000, 20_000, 65_000])
    let stripped = SpeakerTranscript.strippingSpeakers([p(0, 1, "张总：你好")], knownSpeakers: ["张总"])
    XCTAssertEqual(stripped.first?.text, "你好")
  }

  func testOnlineSegmentsMergeSameSpeakerTurns() {
    let labeled = SpeakerTranscript.paragraphs(fromDiarizedSegments: [
      SpeakerSegment(startSeconds: 0, endSeconds: 2, speaker: "A", text: "大家好，"),
      SpeakerSegment(startSeconds: 2.3, endSeconds: 4, speaker: "A", text: "开始吧。"),
      SpeakerSegment(startSeconds: 4.5, endSeconds: 6, speaker: "B", text: "好的。"),
    ])
    XCTAssertEqual(labeled.map(\.speaker), ["说话人 01", "说话人 02"])
    XCTAssertEqual(labeled.first?.paragraph.text, "大家好，开始吧。")
  }

  /// 一整段识别结果里换了人：按短语时间切开，而不是整段算给一个人。
  func testPhrasesSplitAParagraphAtSpeakerChanges() {
    let phrases = [
      SpeakerSegment(startSeconds: 0.2, endSeconds: 5.8, speaker: "", text: "先说时间安排。"),
      SpeakerSegment(startSeconds: 8.0, endSeconds: 12.0, speaker: "", text: "我建议推迟一周。"),
      SpeakerSegment(startSeconds: 14.0, endSeconds: 19.0, speaker: "", text: "风险大吗？"),
    ]
    let segments = [
      SpeakerSegment(startSeconds: 0, endSeconds: 6, speaker: "S2"),
      SpeakerSegment(startSeconds: 7.9, endSeconds: 12.4, speaker: "S1"),
      SpeakerSegment(startSeconds: 13.7, endSeconds: 19.2, speaker: "S2"),
    ]
    let labeled = SpeakerTranscript.paragraphs(fromDiarizedSegments: SpeakerTranscript.labelPhrases(phrases, with: segments))
    XCTAssertEqual(labeled.map(\.speaker), ["说话人 01", "说话人 02", "说话人 01"])
    XCTAssertEqual(labeled[1].paragraph.text, "我建议推迟一周。")
  }

  func testWordSplitAcrossSpeakerBoundaryIsReattached() {
    let labeled = SpeakerTranscript.paragraphs(fromDiarizedSegments: [
      SpeakerSegment(startSeconds: 0, endSeconds: 6, speaker: "A", text: "先说说时间安排。好"),
      SpeakerSegment(startSeconds: 7, endSeconds: 12, speaker: "B", text: "的，我建议推迟。"),
    ])
    XCTAssertEqual(labeled.map(\.paragraph.text), ["先说说时间安排。", "好的，我建议推迟。"])
  }

  /// 阅读页按一轮轮发言排：名字、时间单独拿出来，同一人连着的几行归进同一轮。
  func testTurnsGroupConsecutiveLinesUnderOneSpeaker() {
    let body = "00:00 **说话人 01**：先说安排。\n\n01:07 **说话人 02**：好的。\n\n01:09 我补充一句。"
    let turns = SpeakerTranscript.turns(in: body)
    XCTAssertEqual(turns.map(\.speaker), ["说话人 01", "说话人 02"])
    XCTAssertEqual(turns.map(\.startLabel), ["00:00", "01:07"])
    XCTAssertEqual(turns[1].paragraphs, ["好的。", "我补充一句。"])
    XCTAssertEqual(turns[1].startSeconds, 67)
    // 同一个人接着说的那段保留自己的时间码，不再只剩这一轮开头一个。
    XCTAssertEqual(turns[1].paragraphStartLabels, ["01:07", "01:09"])
    XCTAssertEqual(SpeakerTranscript.turns(in: "00:00 没分过说话人。\n\n00:05 第二段。"), [])
  }

  func testDefaultSpeakerNamesUseTwoDigits() {
    XCTAssertEqual(SpeakerTranscript.defaultName(1), "说话人 01")
    XCTAssertEqual(SpeakerTranscript.defaultName(12), "说话人 12")
  }

  /// 关掉时间码阅读时，每次换人仍然另起一段，粗体完整。
  func testHidingTimecodesKeepsSpeakerTurnsApart() {
    let body = "00:00 **说话人 1**：先说安排。\n\n00:07 **说话人 2**：好的。\n\n00:09 我补充一句。"
    XCTAssertEqual(
      TranscriptReadingText.removingTimecodes(from: body),
      "**说话人 1**：先说安排。\n\n**说话人 2**：好的。我补充一句。"
    )
  }

  func testSentencePunctuationAtStartOfNextSpeakerMovesBack() {
    let labeled: [(paragraph: TranscriptParagraph, speaker: String)] = [
      (TranscriptParagraph(startMilliseconds: 0, endMilliseconds: 5_000, text: "我们就先做一份行"), "说话人 1"),
      (TranscriptParagraph(startMilliseconds: 5_000, endMilliseconds: 9_000, text: "。那但是我觉得现在这个也行"), "说话人 2"),
    ]
    let fixed = SpeakerTranscript.reattachingSplitWords(labeled)
    XCTAssertEqual(fixed[0].paragraph.text, "我们就先做一份行。")
    XCTAssertEqual(fixed[1].paragraph.text, "那但是我觉得现在这个也行")
  }

  func testLongSameSpeakerRunBreaksOnlyAfterASentenceEnds() {
    let long = String(repeating: "内容", count: 110) // 220 字，没有句号
    XCTAssertTrue(SpeakerTranscript.keepsGrowing(long, adding: "出来适合你的"), "句子没说完不能断")
    XCTAssertFalse(SpeakerTranscript.keepsGrowing(long + "。", adding: "下一句"), "说完一句、够长就另起一段")
    XCTAssertFalse(SpeakerTranscript.keepsGrowing(String(repeating: "长", count: 400), adding: "字"), "一直没句号也要在 400 字断开")
  }
}
