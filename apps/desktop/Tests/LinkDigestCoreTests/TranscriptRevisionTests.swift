import XCTest
import LinkDigestCore

/// 朱批：只标改过的字，不标补上的标点。例句取自 2026-09-28 真实转写与校对。
final class TranscriptRevisionTests: XCTestCase {
  private func revisedText(_ result: TranscriptRevision.Result, in text: String) -> [String] {
    let characters = Array(text)
    return result.changes.map { String(characters[$0.offset..<($0.offset + $0.length)]) }
  }

  func testAddedPunctuationAloneIsNotAChange() {
    let original = "00:00 短视频有一个趋势 ，要么就是越发的生活化要么就越发的精致感"
    let revised = "00:00 短视频有一个趋势，要么就是越发的生活化，要么就越发的精致感。"
    let result = TranscriptRevision.compare(original: original, revised: revised)
    XCTAssertEqual(result.changes, [])
    XCTAssertEqual(result.deletions, [])
  }

  func testWordFixesAreFoundWithTheirOriginalAndPosition() {
    let original = "00:00 文案会越来越不重要前三方重要但第一句话真的没那么重要 IP本质上适合观众的一种社交的解读。"
    let revised = "00:00 文案会越来越不重要，前3秒重要，但第一句话真的没那么重要。IP本质上是和观众的一种社交的解读。"
    let result = TranscriptRevision.compare(original: original, revised: revised)
    XCTAssertEqual(result.changes.map(\.original), ["三方", "适合"])
    XCTAssertEqual(result.changes.map(\.revised), ["3秒", "是和"])
    XCTAssertEqual(revisedText(result, in: revised), ["3秒", "是和"])
    XCTAssertEqual(result.changes.map(\.timestamp), ["00:00", "00:00"])
  }

  func testBlocksAreMatchedByTimestampEvenWhenTheRevisionSplitsParagraphs() {
    let original = "00:00 第一段的内容\n\n00:39 其实他拍视频大部分都是工作计时就是与客户的对话"
    let revised = "00:00 第一段的内容。\n\n00:39 其实他拍视频，\n\n大部分都是工作纪实，就是与客户的对话。"
    let result = TranscriptRevision.compare(original: original, revised: revised)
    XCTAssertEqual(result.changes.map(\.original), ["计时"])
    XCTAssertEqual(result.changes.map(\.revised), ["纪实"])
    XCTAssertEqual(result.changes.first?.timestamp, "00:39")
    XCTAssertEqual(revisedText(result, in: revised), ["纪实"])
  }

  func testDroppedFillerIsADeletionNotAChange() {
    let original = "00:00 呃你可以理解为要么就越来越像影视飓风"
    let revised = "00:00 你可以理解为，要么就越来越像影视飓风"
    let result = TranscriptRevision.compare(original: original, revised: revised)
    XCTAssertEqual(result.changes, [])
    XCTAssertEqual(result.deletions.map(\.original), ["呃"])
  }

  func testLatinCaseAndSpacingAreIgnored() {
    let original = "00:00 教大家拍 vlog教这种生活的随拍"
    let revised = "00:00 教大家拍VLOG，教这种生活的随拍"
    XCTAssertEqual(TranscriptRevision.compare(original: original, revised: revised).changes, [])
  }

  /// 校对时插入的小标题是分节，不算改字。
  func testInsertedSectionHeadingsAreNotChanges() {
    let original = "00:00 第一段的内容\n\n00:39 其实他拍视频"
    let revised = "## 开场先讲趋势\n\n00:00 第一段的内容。\n\n## 工作纪实就是内容\n\n00:39 其实他拍视频。"
    let result = TranscriptRevision.compare(original: original, revised: revised)
    XCTAssertEqual(result.changes, [])
    XCTAssertEqual(result.deletions, [])
  }

  func testTextWithoutTimestampsIsComparedAsOneBlock() {
    let result = TranscriptRevision.compare(original: "今天天汽很好", revised: "今天天气很好。")
    XCTAssertEqual(result.changes.map(\.revised), ["气"])
    XCTAssertNil(result.changes.first?.timestamp)
  }
}
