import XCTest
@testable import LinkDigestCore

final class PromptOutputLanguageTests: XCTestCase {
  private let topicMaterials = [
    TopicPrompt.Material(index: 1, title: "素材1", lane: "最近在看的", excerpt: "正文1"),
    TopicPrompt.Material(index: 2, title: "素材2", lane: "最近在看的", excerpt: "正文2"),
  ]
  private let draftMaterial = DraftPrompt.Material(
    title: "FDE 那篇", source: "X", body: "岗位三年增长 42 倍"
  )
  private let distillPairs = [
    DistillPrompt.Pair(generated: "AI 第一版", revised: "我改的第一版"),
    DistillPrompt.Pair(generated: "AI 第二版", revised: "我改的第二版"),
    DistillPrompt.Pair(generated: "AI 第三版", revised: "我改的第三版"),
  ]

  func testChineseOutputKeepsExistingPromptBodiesUnchanged() {
    XCTAssertEqual(
      TopicPrompt.build(materials: topicMaterials),
      TopicPrompt.build(materials: topicMaterials, outputLanguage: "简体中文")
    )
    XCTAssertEqual(
      TopicPrompt.build(materials: topicMaterials, outputLanguage: "简体中文"),
      TopicPrompt.build(materials: topicMaterials, outputLanguage: "繁體中文")
    )
    XCTAssertEqual(
      DraftPrompt.build(spark: "灵感", materials: [draftMaterial]),
      DraftPrompt.build(spark: "灵感", materials: [draftMaterial], outputLanguage: "简体中文")
    )
    XCTAssertEqual(
      DistillPrompt.build(pairs: distillPairs),
      DistillPrompt.build(pairs: distillPairs, outputLanguage: "简体中文")
    )
    XCTAssertEqual(
      RewritePrompt.build(body: "稿子", voice: nil),
      RewritePrompt.build(body: "稿子", voice: nil, outputLanguage: "简体中文")
    )
    XCTAssertEqual(
      TranscriptTidyPrompt.system(outputLanguage: "简体中文"),
      TranscriptTidyPrompt.system
    )
    XCTAssertEqual(
      TranscriptTidyPrompt.note(outputLanguage: "简体中文"),
      TranscriptTidyPrompt.note
    )
    XCTAssertEqual(
      MindMapPrompt.system(outputLanguage: "简体中文"),
      MindMapPrompt.system
    )
    XCTAssertFalse(
      TopicPrompt.build(materials: topicMaterials, outputLanguage: "简体中文")
        .contains("Write all user-visible output")
    )
  }

  func testEnglishOutputAppendsExplicitEnglishInstruction() {
    let topic = TopicPrompt.build(materials: topicMaterials, outputLanguage: "English")
    let draft = DraftPrompt.build(spark: "灵感", materials: [draftMaterial], outputLanguage: "English")
    let distill = DistillPrompt.build(pairs: distillPairs, outputLanguage: "English")
    let rewrite = RewritePrompt.build(body: "稿子", voice: nil, outputLanguage: "English")
    let tidy = TranscriptTidyPrompt.system(outputLanguage: "English")
    let note = TranscriptTidyPrompt.note(outputLanguage: "English")
    let mindMap = MindMapPrompt.system(outputLanguage: "English")

    for prompt in [topic, draft, distill, rewrite, tidy, note, mindMap] {
      XCTAssertTrue(
        prompt.contains("Write all user-visible output in English."),
        "英文输出语言必须带上明确的英文指令"
      )
      XCTAssertTrue(
        prompt.contains("Keep required machine-readable field labels"),
        "结构化字段名必须保持可解析"
      )
    }

    XCTAssertTrue(topic.hasPrefix(TopicPrompt.build(materials: topicMaterials)))
    XCTAssertTrue(draft.hasPrefix(DraftPrompt.build(spark: "灵感", materials: [draftMaterial])))
    XCTAssertTrue(distill.hasPrefix(DistillPrompt.build(pairs: distillPairs)))
    XCTAssertTrue(rewrite.hasPrefix(RewritePrompt.build(body: "稿子", voice: nil)))
    XCTAssertTrue(tidy.hasPrefix(TranscriptTidyPrompt.system))
    XCTAssertTrue(note.hasPrefix(TranscriptTidyPrompt.note))
    XCTAssertTrue(mindMap.hasPrefix(MindMapPrompt.system))
  }
}
