import XCTest
@testable import LinkDigestApp

/// 设置三页纯展示文案与结构约定（U1）。
final class UISettingsPresentationTests: XCTestCase {
  func testPipelineStepTitlesStayVerbFirstAndOrdered() {
    XCTAssertEqual(UISettingsPresentation.pipelineStepTitle(index: 1), "译成中文标题")
    XCTAssertEqual(UISettingsPresentation.pipelineStepTitle(index: 2), "本机转写")
    XCTAssertEqual(UISettingsPresentation.pipelineStepTitle(index: 3), "校对转写稿")
    XCTAssertEqual(UISettingsPresentation.pipelineStepTitle(index: 4), "生成总结")
    XCTAssertEqual(UISettingsPresentation.pipelineStepTitle(index: 5), "生成脑图")
  }

  func testModelPageCopyAvoidsSummarizeAndTranslateCollision() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    let service = section(in: source, from: "private var serviceTab", to: "// MARK: - 生成与数据")
    XCTAssertTrue(service.contains("UISettingsPresentation.summaryAssignmentTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.translationAssignmentTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.localTranscriptionTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.onlineTranscriptionTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.tidyAssignmentTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.imageRecognitionTitle"))
    XCTAssertTrue(service.contains("UISettingsPresentation.modelServicesCardTitle"))
    XCTAssertTrue(service.contains("translation-model-name"))
    XCTAssertTrue(service.contains("transcription-model-name"))
    XCTAssertTrue(service.contains("tidy-model-name"))
    XCTAssertFalse(service.contains("\"已添加的模型\""))
    XCTAssertFalse(service.contains("\"总结与翻译\""))
    XCTAssertFalse(service.contains("翻译另选模型见"))
  }

  func testGenerationTabKeepsRealPreferenceSaveAndIndependentConsentGroup() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    let tab = section(in: source, from: "private var generationTab: some View", to: "// MARK: - 设置卡片零件")
    XCTAssertTrue(tab.contains("UISettingsPresentation.newCaptureAutoProcessTitle"))
    XCTAssertTrue(tab.contains("model.preferencesStatusText"))
    XCTAssertTrue(tab.contains("model.canSavePreferences"))
    XCTAssertTrue(tab.contains("save-model-preferences"))
    XCTAssertTrue(tab.contains("safeAreaInset(edge: .bottom"))
    XCTAssertTrue(tab.contains("generation-preferences-save-bar"))
    XCTAssertTrue(tab.contains("revoke-remembered-consents"))
    // 脑图未开启时不展示前置条件警告。
    XCTAssertTrue(tab.contains("model.autoMindMapNewCaptures"))
    XCTAssertFalse(tab.contains("\"自动处理管线\""))
    XCTAssertFalse(tab.contains("translation-model-name"), "翻译模型已集中到模型与识别")
    XCTAssertFalse(tab.contains("tidy-model-name"), "校对模型已集中到模型与识别")
  }

  func testAppearanceKeepsImmediateApplyWithoutFakeSave() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    let tab = section(in: source, from: "private var appearanceTab: some View", to: "// MARK: - 生成与数据")
    XCTAssertTrue(tab.contains("即时生效"))
    XCTAssertFalse(tab.contains("保存外观"))
    XCTAssertFalse(tab.contains("save-appearance"))
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    let afterStart = source.range(of: start).map { source[$0.lowerBound...] } ?? Substring()
    return afterStart.range(of: end).map { String(afterStart[..<$0.lowerBound]) } ?? String(afterStart)
  }
}
