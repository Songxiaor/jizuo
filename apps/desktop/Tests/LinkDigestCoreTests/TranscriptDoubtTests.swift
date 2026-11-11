import XCTest
import LinkDigestCore

final class TranscriptDoubtTests: XCTestCase {
  private let body = "今天张总讲了奥利克的新方案，大家觉得很有意思。后面还有一段。"

  private func output(_ json: String) -> String { body + "\n" + TranscriptDoubtParser.marker + "\n" + json }

  func testSplitSeparatesBodyAndDoubts() {
    let result = TranscriptDoubtParser.split(output(#"[{"original":"奥利克","suggestion":"欧立克","reason":"像品牌名"}]"#))
    XCTAssertEqual(result.text, body)
    XCTAssertEqual(result.doubts.count, 1)
    XCTAssertEqual(result.doubts.first?.suggestion, "欧立克")
    XCTAssertEqual(result.doubts.first?.status, .pending)
  }

  func testNoMarkerKeepsOutputAsIs() {
    let result = TranscriptDoubtParser.split(body)
    XCTAssertEqual(result.text, body)
    XCTAssertTrue(result.doubts.isEmpty)
  }

  func testBrokenJSONNeverLeaksIntoBody() {
    let result = TranscriptDoubtParser.split(output("[{oops"))
    XCTAssertEqual(result.text, body)
    XCTAssertTrue(result.doubts.isEmpty)
  }

  func testCodeFenceIsTolerated() {
    let result = TranscriptDoubtParser.split(output("```json\n[{\"original\":\"奥利克\",\"suggestion\":\"欧立克\",\"reason\":\"\"}]\n```"))
    XCTAssertEqual(result.doubts.count, 1)
  }

  func testUnmatchedFragmentsAreDropped() {
    let doubts = [
      TranscriptDoubt(original: "奥利克", suggestion: "欧立克", reason: "a"),
      TranscriptDoubt(original: "稿子里没有的话", suggestion: "x", reason: "b"),
      TranscriptDoubt(original: "奥", suggestion: "欧", reason: "太短"),
      TranscriptDoubt(original: "奥利克", suggestion: "欧立克", reason: "重复"),
    ]
    let kept = TranscriptDoubtParser.verified(doubts, in: body)
    XCTAssertEqual(kept.map(\.original), ["奥利克"])
  }

  func testFragmentFoundIgnoringWhitespaceAndPunctuation() {
    let text = "今天，奥利 克很重要。"
    let kept = TranscriptDoubtParser.verified([.init(original: "奥利克", suggestion: "欧立克", reason: "")], in: text)
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(TranscriptDoubtParser.applying(kept[0], to: text), "今天，欧立克很重要。")
  }

  func testApplyingReplacesOnlyThatFragment() {
    let doubt = TranscriptDoubt(original: "奥利克", suggestion: "欧立克", reason: "")
    XCTAssertEqual(
      TranscriptDoubtParser.applying(doubt, to: body),
      "今天张总讲了欧立克的新方案，大家觉得很有意思。后面还有一段。"
    )
    XCTAssertNil(TranscriptDoubtParser.applying(doubt, to: "完全不相干的稿子"))
  }

  func testPerChunkLimit() {
    let items = (0..<10).map { #"{"original":"片段\#($0)号","suggestion":"改\#($0)","reason":""}"# }
    let result = TranscriptDoubtParser.split("x\n" + TranscriptDoubtParser.marker + "[" + items.joined(separator: ",") + "]")
    XCTAssertEqual(result.doubts.count, TranscriptDoubtParser.perChunkLimit)
  }

  func testChangeCountCountsClusters() {
    XCTAssertEqual(TranscriptDoubtParser.changeCount(original: "今天天气很好我们出去玩", revised: "今天天气很好我们出去玩"), 0)
    let two = TranscriptDoubtParser.changeCount(
      original: "厚度只有九点七毫米大家可以感受一下这个甲手机的手感非常不错的",
      revised: "厚度只有九点七毫米大家可以感受一下这个乙手机的手感非常好的"
    )
    XCTAssertEqual(two, 2)
    XCTAssertNil(TranscriptDoubtParser.changeCount(original: "a", revised: "b", characterLimit: 0))
  }

  func testFragmentThatAppearsTwiceIsDroppedUnlessContextMakesItUnique() {
    let text = "他说苹果很好，我也说苹果很好吃"
    let ambiguous = TranscriptDoubt(original: "苹果", suggestion: "萍果", reason: "")
    let withContext = TranscriptDoubt(original: "我也说苹果", suggestion: "我也说萍果", reason: "")
    let kept = TranscriptDoubtParser.verified([ambiguous, withContext], in: text)
    XCTAssertEqual(kept.map(\.original), ["我也说苹果"], "出现两处又没带上下文的，丢弃，不去猜")
  }

  func testApplyingRefusesWhenFragmentIsNowAmbiguous() {
    let doubt = TranscriptDoubt(original: "苹果", suggestion: "萍果", reason: "")
    XCTAssertNil(TranscriptDoubtParser.applying(doubt, to: "苹果和苹果"))
    XCTAssertEqual(TranscriptDoubtParser.applying(doubt, to: "一个苹果"), "一个萍果")
    XCTAssertNil(TranscriptDoubtParser.applying(doubt, to: "没有"))
  }

  func testSummaryLineWording() {
    XCTAssertEqual(
      ProofreadDoubtSummary.line(changeCount: 3, pending: 2, hasDoubts: true),
      "AI 改了 3 处字，有 2 处拿不准，请看高亮"
    )
    XCTAssertEqual(
      ProofreadDoubtSummary.line(changeCount: 0, pending: 1, hasDoubts: true),
      "AI 只补了标点，有 1 处拿不准，请看高亮"
    )
    XCTAssertEqual(ProofreadDoubtSummary.line(changeCount: 0, pending: 0, hasDoubts: false), "AI 只补了标点")
    XCTAssertEqual(
      ProofreadDoubtSummary.line(changeCount: 2, pending: 0, hasDoubts: true),
      "AI 改了 2 处字，拿不准的地方都已处理"
    )
    XCTAssertEqual(ProofreadDoubtSummary.collapsedLine(handled: 4), "已处理 4 处")
  }
}
