import XCTest
@testable import LinkDigestCore

final class TranscriptTidyTests: XCTestCase {
  // MARK: - Chunker

  func testShortTranscriptStaysOneChunk() {
    XCTAssertEqual(TranscriptTidyChunker.chunks(of: "大家好，今天讲本地优先。"), ["大家好，今天讲本地优先。"])
    XCTAssertEqual(TranscriptTidyChunker.chunks(of: "  \n \n"), [])
  }

  func testChunksPackParagraphsUpToLimitAndNeverCutInsideAParagraph() {
    let paragraph = String(repeating: "这是一段口播内容", count: 10) // 80 字
    let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
    let chunks = TranscriptTidyChunker.chunks(of: text, limit: 200)
    XCTAssertGreaterThan(chunks.count, 1)
    for chunk in chunks {
      XCTAssertLessThanOrEqual(chunk.count, 200)
      // 每个 chunk 都由完整段落组成，重新拼回应与原文一致。
    }
    XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
  }

  func testOverlongSingleParagraphStaysWholeRatherThanCutMidSentence() {
    let wall = String(repeating: "没有分段的连续语流", count: 100) // 900 字，无段落边界
    XCTAssertEqual(TranscriptTidyChunker.chunks(of: wall, limit: 200), [wall])
  }

  // MARK: - Normalizer

  func testSentencePerLineOutputBecomesParagraphs() {
    // 模型“每句一行”方言：单换行在 Markdown 里折叠成空格，必须升为段落。
    let modelOutput = "好了，大家我现在正在发布会现场。\n我手里拿的是新的折叠屏。"
    XCTAssertEqual(
      TranscriptTidyNormalizer.normalize(modelOutput),
      "好了，大家我现在正在发布会现场。\n\n我手里拿的是新的折叠屏。"
    )
  }

  func testBlankLineParagraphsKeepStructureAndHardWrapsMerge() {
    // 空行分段方言：段内 hard wrap 拼回一行，CJK 边界不补空格。
    let modelOutput = "第一段的前半句，\n后半句在同一段。\n\n第二段独立成段。"
    XCTAssertEqual(
      TranscriptTidyNormalizer.normalize(modelOutput),
      "第一段的前半句，后半句在同一段。\n\n第二段独立成段。"
    )
  }

  func testLatinLineWrapKeepsSpaceAndCJKSpacesCollapse() {
    let wrapped = "the quick brown\nfox jumps"
    XCTAssertEqual(TranscriptTidyNormalizer.normalize(wrapped), "the quick brown\n\nfox jumps")
    // 中文标点后的半角空格清除；中西文之间的空格保留。
    XCTAssertEqual(
      TranscriptTidyNormalizer.normalize("好了，  大家看这款 Galaxy Z Fold 8。 很轻薄。"),
      "好了，大家看这款 Galaxy Z Fold 8。很轻薄。"
    )
    XCTAssertEqual(TranscriptTidyNormalizer.normalize("  \n\n "), "")
  }

  // MARK: - Prompt contract

  func testTidyPromptForbidsRewriting() {
    let prompt = TranscriptTidyPrompt.system
    for constraint in ["标点", "分段", "错别字", "禁止", "翻译", "改写"] {
      XCTAssertTrue(prompt.contains(constraint), "prompt 缺少约束词: \(constraint)")
    }
  }

  // MARK: - ModelPreferences compatibility

  func testStoredPreferencesFromBeforeTidyFieldsStillDecode() throws {
    // 旧版本落盘的 JSON 没有 tidyModel / autoTidyTranscription 键。
    let legacy = """
      {"summaryPrompt":"总结","outputLanguage":"简体中文","transcriptionModel":"whisper-1"}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ModelPreferences.self, from: legacy)
    XCTAssertNil(decoded.tidyModel)
    XCTAssertNil(decoded.autoTidyTranscription)
    XCTAssertEqual(decoded.transcriptionModel, "whisper-1")
  }

  func testTidyModelValidatesAndNormalizes() throws {
    let preferences = try ModelPreferences(tidyModel: "  gpt-x  ", autoTidyTranscription: false)
    XCTAssertEqual(preferences.tidyModel, "gpt-x")
    // false 归一化为 nil：从未开启过与显式关闭在语义上等价。
    XCTAssertNil(preferences.autoTidyTranscription)
    XCTAssertEqual(try ModelPreferences(autoTidyTranscription: true).autoTidyTranscription, true)
    XCTAssertNil(try ModelPreferences(tidyModel: "   ").tidyModel)
    XCTAssertThrowsError(try ModelPreferences(tidyModel: String(repeating: "m", count: 257))) {
      XCTAssertEqual($0 as? ModelPreferencesError, .tidyModelTooLong)
    }
  }
}
