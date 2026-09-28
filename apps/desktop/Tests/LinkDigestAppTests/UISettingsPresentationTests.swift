import XCTest
@testable import LinkDigestApp

/// 设置三页纯展示文案与结构约定（U1）。
final class UISettingsPresentationTests: XCTestCase {
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

  /// 工序页即时生效：没有保存按钮、没有底部固定条，只有保存失败时露出一行状态。
  func testStepPagesKeepImmediateSaveAndIndependentConsentGroup() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    let pages = section(in: source, from: "private var overviewTab: some View", to: "// MARK: - 设置卡片零件")
    XCTAssertTrue(pages.contains("model.preferencesStatusText"))
    XCTAssertTrue(pages.contains("model-preferences-status"))
    XCTAssertFalse(pages.contains("save-model-preferences"), "即时生效，不该有保存按钮")
    XCTAssertFalse(pages.contains("safeAreaInset(edge: .bottom"), "底部固定保存条已撤")
    let viewModel = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsViewModel.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(viewModel.contains("schedulePreferenceAutosave("), "非管线偏好也要改完即存")
    XCTAssertTrue(pages.contains("revoke-remembered-consents"))
    XCTAssertTrue(pages.contains("model.autoMindMapNewCaptures"))
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
