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

  func testTidyPromptRestoresSpeechWithoutInventingAnArticle() {
    let prompt = TranscriptTidyPrompt.system
    for constraint in ["还原", "标点", "分段", "时间戳", "禁止", "翻译", "编造", "原样"] {
      XCTAssertTrue(prompt.contains(constraint), "prompt 缺少约束词: \(constraint)")
    }
    XCTAssertTrue(prompt.contains("不是润色成一篇新文章"))
  }

  func testUserMessageWrapsTitleAndCaptionAndEmptyContextIsPassthrough() {
    let chunk = "21:15 I've sate sorry"
    XCTAssertEqual(TranscriptTidyPrompt.userMessage(chunk: chunk, context: .empty), chunk)

    let context = TranscriptTidyContext(title: "今晚别刷 Netflix 了。", caption: "引用了一堂课")
    let wrapped = TranscriptTidyPrompt.userMessage(chunk: chunk, context: context)
    XCTAssertTrue(wrapped.contains("标题：今晚别刷 Netflix 了。"))
    XCTAssertTrue(wrapped.contains("配文：引用了一堂课"))
    XCTAssertTrue(wrapped.hasSuffix("转写片段：\n" + chunk))
  }

  func testStripEchoedContextRemovesHeaderOnly() {
    let chunk = "21:15 I've sate sorry"
    let context = TranscriptTidyContext(title: "评测视频", caption: "占位正文")
    let echoed = TranscriptTidyPrompt.userMessage(chunk: chunk, context: context)
    XCTAssertEqual(
      TranscriptTidyPrompt.stripEchoedContext(echoed, chunk: chunk, context: context),
      chunk
    )
    XCTAssertEqual(
      TranscriptTidyPrompt.stripEchoedContext("I've said sorry.", chunk: chunk, context: context),
      "I've said sorry."
    )
    XCTAssertEqual(
      TranscriptTidyPrompt.stripEchoedContext(chunk, chunk: chunk, context: .empty),
      chunk
    )
  }

  func testContextDropsCaptionThatDuplicatesTranscriptAndClipsLongCaption() {
    let transcript = "厚度只有9。7毫米"
    XCTAssertNil(TranscriptTidyContext(title: "评测", caption: transcript, transcript: transcript).caption)
    let long = String(repeating: "配", count: TranscriptTidyContext.captionCharacterLimit + 40)
    let clipped = TranscriptTidyContext(caption: long)
    XCTAssertEqual(clipped.caption?.count, TranscriptTidyContext.captionCharacterLimit)
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

  /// 字幕校对的提示词是**独立契约**，不能退化成听写那一套。
  ///
  /// 两类稿子错的不是一种字：听写错在同音近音，OCR 错在字形相近
  /// （实测「衡量」→「後置」、「时间」→「时狗」）。让模型按同音去猜只会越改
  /// 越远，所以提示词必须明确指向字形，并且要求删掉粘进句尾的画面角标。
  func testSubtitlePromptTargetsShapeErrorsAndBadgeResidue() {
    let prompt = TranscriptTidyPrompt.subtitles
    XCTAssertTrue(prompt.contains("字形"), "必须指明错的是字形相近，而不是同音")
    XCTAssertTrue(prompt.contains("角标"), "必须要求删掉粘进来的画面角标")
    XCTAssertTrue(prompt.contains("时间戳"), "时间戳是跳转的锚点，不能被改动")

    // 和听写稿共有的红线：还原不是重写。
    for forbidden in ["翻译", "概括", "改写"] {
      XCTAssertTrue(prompt.contains(forbidden), "必须明令禁止「\(forbidden)」")
    }
    // 两份提示词必须是两份，别不小心指向同一个常量。
    XCTAssertNotEqual(prompt, TranscriptTidyPrompt.system)
  }

  /// 每种 style 都要有自己的提示词，新增时不能漏配。
  func testEveryTidyStyleHasItsOwnPrompt() {
    var seen: Set<String> = []
    for style in TidyStyle.allCases {
      let prompt = style.systemPrompt
      XCTAssertFalse(prompt.isEmpty, "\(style.rawValue) 没有提示词")
      XCTAssertTrue(seen.insert(prompt).inserted, "\(style.rawValue) 与别的 style 共用了同一份提示词")
    }
    // 笔记的产物是 Markdown，换行有语义，只有它不做段落归一化。
    XCTAssertFalse(TidyStyle.note.normalizesParagraphs)
    XCTAssertTrue(TidyStyle.transcript.normalizesParagraphs)
    XCTAssertTrue(TidyStyle.subtitles.normalizesParagraphs)
  }
}
