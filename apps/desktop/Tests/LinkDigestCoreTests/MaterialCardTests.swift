import Foundation
import XCTest
@testable import LinkDigestCore

/// 素材卡：解析、金句必须是转写稿原句、「真人口播」标签去留。纯函数，不联网。
final class MaterialCardTests: XCTestCase {
  private let transcript = "大家好，我是做独立开发的。我想说一件事：把复杂的事情讲清楚，比把简单的事情讲复杂难得多。很多人上来就堆功能，结果用户根本不知道这东西能干嘛。所以先跑通最小的链路，再去优化最慢的那一段。"

  private func json(_ quotes: String = "[\"把复杂的事情讲清楚\"]", live: String = "true", extra: String = "") -> String {
    "{\"speaker\":\"一位独立开发者\",\"viewpoints\":[\"先跑通链路\"],\"hook\":\"开头先打招呼再抛观点\",\"quotes\":\(quotes),\"live_speaker\":\(live),\"live_speaker_reason\":\"出镜讲解\"\(extra)}"
  }

  func testParsesWellFormedCard() throws {
    let card = try MaterialCardPrompt.parse("```json\n\(json())\n```", transcript: transcript)
    XCTAssertEqual(card.speaker, "一位独立开发者")
    XCTAssertEqual(card.viewpoints, ["先跑通链路"])
    XCTAssertEqual(card.quotes, ["把复杂的事情讲清楚"])
    XCTAssertTrue(card.isLiveSpeaker)
  }

  func testQuotesNotInTranscriptAreDropped() throws {
    let quotes = "[\"把复杂的事情讲清楚\",\"这句话视频里根本没有出现过\",\"先跑通最小的链路，再去优化最慢的那一段\"]"
    let card = try MaterialCardPrompt.parse(json(quotes), transcript: transcript)
    XCTAssertEqual(card.quotes, ["把复杂的事情讲清楚", "先跑通最小的链路，再去优化最慢的那一段"])
  }

  func testQuoteMatchingIgnoresPunctuationWhitespaceAndRejectsParaphrase() {
    XCTAssertEqual(
      MaterialCardPrompt.validatedQuotes(["把复杂的事情 讲清楚！", "把复杂事情讲明白"], transcript: transcript),
      ["把复杂的事情 讲清楚！"]
    )
    XCTAssertEqual(MaterialCardPrompt.validatedQuotes(["我想说"], transcript: transcript), [], "太短不算句子")
  }

  func testQuoteMatchingNormalizesFullwidthAndHalfwidthButNotTraditional() {
    let source = "今天用ＡＩ工具做了１０个视频。我们开始吧。這是繁體字的句子。"
    XCTAssertEqual(MaterialCardPrompt.validatedQuotes(["今天用AI工具做了10个视频"], transcript: source), ["今天用AI工具做了10个视频"])
    XCTAssertEqual(MaterialCardPrompt.validatedQuotes(["这是繁体字的句子"], transcript: source), [], "繁简不做归一")
  }

  func testMinimumQuoteLengthIsFourCharacters() {
    let source = "今天天气不错。我们开始。"
    XCTAssertEqual(MaterialCardPrompt.minimumQuoteCharacters, 4)
    XCTAssertEqual(MaterialCardPrompt.validatedQuotes(["我们开始"], transcript: source), ["我们开始"])
    XCTAssertEqual(MaterialCardPrompt.validatedQuotes(["今天天"], transcript: source), [])
  }

  func testQuotesAreDedupedAndCappedAtThree() {
    let long = "第一句话是这样的内容。第二句话是这样的内容。第三句话是这样的内容。第四句话是这样的内容。"
    let kept = MaterialCardPrompt.validatedQuotes(
      ["第一句话是这样的内容", "第一句话是这样的内容。", "第二句话是这样的内容", "第三句话是这样的内容", "第四句话是这样的内容"], transcript: long
    )
    XCTAssertEqual(kept.count, 3)
    XCTAssertEqual(Set(kept.map { MaterialCardPrompt.comparable($0) }).count, 3)
  }

  func testMalformedOrIncompleteResponsesThrow() {
    XCTAssertThrowsError(try MaterialCardPrompt.parse("不是 JSON", transcript: transcript))
    XCTAssertThrowsError(try MaterialCardPrompt.parse("{\"speaker\":\"x\",\"quotes\":[]}", transcript: transcript), "缺 live_speaker")
    XCTAssertThrowsError(try MaterialCardPrompt.parse(
      "{\"speaker\":\"\",\"viewpoints\":[],\"hook\":\"\",\"quotes\":[],\"live_speaker\":true}", transcript: transcript
    ), "全空的卡没有价值")
  }

  func testViewpointsCappedAtThree() throws {
    let raw = "{\"speaker\":\"a\",\"viewpoints\":[\"1\",\"2\",\"3\",\"4\"],\"hook\":\"h\",\"quotes\":[],\"live_speaker\":false}"
    XCTAssertEqual(try MaterialCardPrompt.parse(raw, transcript: transcript).viewpoints, ["1", "2", "3"])
  }

  func testUserContentIsCappedAndCarriesTitle() {
    let body = String(repeating: "字", count: MaterialCardPrompt.transcriptCharacterLimit + 500)
    let content = MaterialCardPrompt.userContent(transcript: body, title: "标题")
    XCTAssertTrue(content.hasPrefix("标题：标题"))
    XCTAssertEqual(content.filter { $0 == "字" }.count, MaterialCardPrompt.transcriptCharacterLimit)
  }

  // MARK: 真人口播标签

  private func card(live: Bool) -> MaterialCard {
    MaterialCard(speaker: "a", viewpoints: [], hook: "", quotes: [], isLiveSpeaker: live, liveSpeakerReason: "")
  }

  private func record(applied: Bool = false, suppressed: Bool = false) -> TaskMaterialCardRecord {
    TaskMaterialCardRecord(
      taskID: TaskID(UUID()), card: card(live: true), liveSpeakerTagApplied: applied, liveSpeakerTagSuppressed: suppressed,
      createdAtMilliseconds: 1, updatedAtMilliseconds: 1
    )
  }

  func testLiveSpeakerAttachesWhenNeverSeenBefore() {
    let decision = MaterialCardTagDecision.decide(card: card(live: true), previous: nil, tagCurrentlyOnItem: false)
    XCTAssertEqual(decision, .init(attach: true, suppressed: false, applied: true))
  }

  func testNotLiveSpeakerNeverAttaches() {
    let decision = MaterialCardTagDecision.decide(card: card(live: false), previous: nil, tagCurrentlyOnItem: false)
    XCTAssertEqual(decision, .init(attach: false, suppressed: false, applied: false))
  }

  func testTagRemovedByUserIsNotReAttachedOnRegeneration() {
    let first = MaterialCardTagDecision.decide(card: card(live: true), previous: record(applied: true), tagCurrentlyOnItem: false)
    XCTAssertFalse(first.attach)
    XCTAssertTrue(first.suppressed)
    // 记成 suppressed 之后一直不再挂。
    let second = MaterialCardTagDecision.decide(card: card(live: true), previous: record(applied: false, suppressed: true), tagCurrentlyOnItem: false)
    XCTAssertFalse(second.attach)
    XCTAssertTrue(second.suppressed)
  }

  func testExistingTagIsLeftAloneAndNotDuplicated() {
    let decision = MaterialCardTagDecision.decide(card: card(live: false), previous: record(applied: true), tagCurrentlyOnItem: true)
    XCTAssertEqual(decision, .init(attach: false, suppressed: false, applied: true))
  }

  func testLiveSpeakerTagIsReservedAndProtected() {
    XCTAssertTrue(MaterialCatalog.protectedTagNormalizedNames.contains(MaterialCatalog.liveSpeakerTagNormalizedName))
  }
}
