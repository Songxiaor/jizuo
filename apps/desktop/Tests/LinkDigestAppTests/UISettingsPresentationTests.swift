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

  /// 「模型服务」卡片标题不再和页标题重复（同名两次是走查 #27）；副标题直接说明分组方式。
  func testModelServicesCardTitleNoLongerRepeatsPageTitle() throws {
    XCTAssertEqual(UISettingsPresentation.modelServicesCardTitle, "已添加的模型")
    XCTAssertNotEqual(UISettingsPresentation.modelServicesCardTitle, "模型服务")
    XCTAssertTrue(UISettingsPresentation.modelServicesSummary.contains("分组"))
  }

  /// 字号显示取整：「15」不是「15.0」（走查 #16），半档仍写「15.5」。
  func testReadingFontSizeTextFormatsIntegersWithoutDecimals() throws {
    XCTAssertEqual(ProviderSettingsView.readingFontSizeText(15.0), "15")
    XCTAssertEqual(ProviderSettingsView.readingFontSizeText(15.5), "15.5")
    XCTAssertEqual(ProviderSettingsView.readingFontSizeText(13.0), "13")
    XCTAssertEqual(ProviderSettingsView.readingFontSizeText(24.0), "24")
  }

  /// 设置里「AI 处理」改名「AI 模型与工序」（和「处理流程」只差两个字，
  /// https://github.com/Songxiaor/jizuo 走查命名对照表），别处跟读 `SettingsTab` 的 title。
  func testProcessingTabTitleAvoidsCollisionWithProcessChain() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("case .processing: return \"AI 模型与工序\""))
    XCTAssertFalse(source.contains("case .processing: return \"AI 处理\""))
  }

  /// 阅读风格分段选择器的读取必须把旧偏好（sansSerif / serif / songti / kaiti）归一
  /// 成新家族（"sansSerif" 迁到 "PingFang SC"），不然旧用户选的「黑体」档不亮
  /// （2026-10-13 审查 #8）。断言源码里通过 `ReadingFontSelection(storedValue:)` 归一。
  func testReadingStylePickerNormalizesLegacyFontValues() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("ReadingFontSelection(storedValue: readingFontRaw).storedValue"))
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    let afterStart = source.range(of: start).map { source[$0.lowerBound...] } ?? Substring()
    return afterStart.range(of: end).map { String(afterStart[..<$0.lowerBound]) } ?? String(afterStart)
  }
}
