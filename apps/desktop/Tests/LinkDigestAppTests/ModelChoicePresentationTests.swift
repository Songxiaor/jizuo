import XCTest

/// 能选就别让人打字；必须打字时输入框要看得见。
///
/// 起因：「整理模型」「在线转写模型」原来是自由文本，而模型名（`whisper-large-v3-turbo`
/// 这种）拼错不会当场报错，只会在真正调用时失败，失败信息来自服务端、未必说得清是名字错了。
/// 用户已经添加过的模型是现成的事实来源，让人选比让人背准确得多。
///
/// 第二个问题同样实在：那两个输入框在 Form 的 LabeledContent 里且右对齐，**没有边框**，
/// 光标落在一片空白里，得拿鼠标在右侧空白反复点才能找到落点。
final class ModelChoicePresentationTests: XCTestCase {
  private func source(_ name: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(name)"),
      encoding: .utf8)
  }

  func testModelFieldsOfferChoicesInsteadOfFreeText() throws {
    let settings = try source("ProviderSettingsView.swift")
    XCTAssertTrue(
      settings.contains("private func modelChoicePicker("),
      "模型名要从已添加的模型里选")
    XCTAssertFalse(
      settings.contains("private func modelNameField("),
      "自由文本那版回来了，模型名又要靠手打")
    // 两个字段各自只列能用的模型：在线转写要服务支持转写，整理是聊天模型这一侧。
    XCTAssertTrue(settings.contains("options: model.transcriptionEntryDisplays"))
    XCTAssertTrue(settings.contains("options: model.summaryEntryDisplays"))
  }

  /// 空值有明确语义，应当是选项之一，而不是「把输入框清空」才能达到的状态。
  func testEmptyValueIsAFirstClassOption() throws {
    let settings = try source("ProviderSettingsView.swift")
    XCTAssertTrue(settings.contains(#"emptyOptionTitle: "跟随总结模型""#))
    XCTAssertTrue(settings.contains(#"emptyOptionTitle: "不使用：只用 Apple 本机转写""#))
  }

  /// 2026-09-17 改：只能从「模型服务」里已添加的模型中选，不再提供「自定义…」。
  /// 手填的名字没有自己的服务地址和密钥，只能套用总结模型那家的配置，填错也看不出来。
  /// 以前手填过的旧值仍显示成当前值（并提示不在模型服务里），不会凭空变成空白。
  /// 没有可选模型时下拉变灰，并说明要先添加什么模型。
  func testChoicesComeOnlyFromModelServices() throws {
    let settings = try source("ProviderSettingsView.swift")
    // 只看模型下拉那一段：输出语言的「自定义…」是另一回事，保留。
    let start = try XCTUnwrap(settings.range(of: "private func modelChoiceSections("))
    let end = try XCTUnwrap(settings.range(of: "private func isCustomModelName(", range: start.upperBound..<settings.endIndex))
    let modelChoices = settings[start.lowerBound..<end.lowerBound]
    XCTAssertFalse(modelChoices.contains(#""自定义…""#), "模型下拉的「自定义…」回来了")
    XCTAssertTrue(settings.contains(#"subtitle: "不在模型服务里""#))
    XCTAssertTrue(settings.contains("unavailableHint:"))
    XCTAssertTrue(settings.contains(".disabled(options.isEmpty"))
  }

  /// 凡是留给用户打字的输入框，都必须有可见边框。
  func testEveryFreeTextFieldIsVisible() throws {
    let settings = try source("ProviderSettingsView.swift")
    // 右对齐 + 无边框是这次问题的成因组合。只管输入框——只读的状态行右对齐没问题，
    // 一刀切会把无关的 Text 也拦下来。
    for line in settings.split(separator: "\n") {
      guard line.contains("TextField(") else { continue }
      XCTAssertFalse(
        line.contains(".multilineTextAlignment(.trailing)"),
        "右对齐的输入框回来了：\(line.trimmingCharacters(in: .whitespaces))")
    }
    // 留给用户打字的地方都要显式给边框。
    XCTAssertGreaterThanOrEqual(
      settings.components(separatedBy: ".textFieldStyle(.roundedBorder)").count - 1, 4,
      "可见边框的输入框变少了")
  }

  /// 重新生成里的临时模型是同一类问题，同样改成选择。
  func testRegenerateTemporaryModelIsAPicker() throws {
    let history = try source("HistoryContentView.swift")
    XCTAssertTrue(history.contains(#"accessibilityIdentifier("regenerate-temporary-model")"#))
    XCTAssertFalse(
      history.contains(#"TextField("临时模型（留空使用当前模型）""#),
      "临时模型又变回手打了")
  }
}
