import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 2026-10-14 翻译入口修复：处理面板里「翻译」一直显示；判成「已经是输出语言」只改小字，点了照样翻译。
final class TranslateEntryTests: XCTestCase {
  private func source(_ name: String = "HistoryContentView.swift") throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("Sources/LinkDigestApp/\(name)"), encoding: .utf8)
  }

  func testProcessPanelAlwaysListsTranslateAndLanguageMatchOnlyChangesTheSubtitle() throws {
    let content = try source()
    let start = try XCTUnwrap(content.range(of: "for (step, kind) in [(ProcessStep.summary, RunKind.summarize)"))
    let end = try XCTUnwrap(content.range(of: "if !isOwnWriting {\n      let done = model.mindMapRecord", range: start.upperBound..<content.endIndex))
    let loop = String(content[start.lowerBound..<end.lowerBound])
    // 不再因为「不用翻译」跳过这一行。
    XCTAssertFalse(loop.contains("continue"), "翻译这一行不能被藏掉")
    XCTAssertFalse(loop.contains("translationNotNeeded"))
    // 只被语言判断拦着时：行可点，小字写「看起来已经是中文」，点了照样翻译。
    XCTAssertTrue(loop.contains("blocked == nil || languageMatchBlock"))
    XCTAssertTrue(loop.contains("看起来已经是\\(outputLanguageShortName)"))
    XCTAssertTrue(loop.contains("startRun(kind, ignoreLanguageMatch: kind == .translate)"))
  }

  func testEveryExplicitTranslateEntryIgnoresTheLanguageGuess() throws {
    let content = try source()
    // 菜单栏「内容 → 翻译」（⇧⌘E）。
    XCTAssertTrue(content.contains("RunCurrentAction(key: runActionKey) { startRun(.translate, ignoreLanguageMatch: true) }"))
    // 「…」里的翻译项、换个模型重跑里的翻译钮：只被语言拦着时仍可点。
    XCTAssertFalse(content.contains(".disabled(translateUnavailableReason != nil)"))
    XCTAssertEqual(content.components(separatedBy: ".disabled(!translateIsClickable)").count - 1, 2)
    XCTAssertEqual(content.components(separatedBy: "ignoreLanguageMatch: true").count - 1, 5)
    XCTAssertTrue(content.contains("translateUnavailableReason?.contains(\"不用翻译\") == true"))
  }

  func testTranslationLayerCapsulesUseTheNewNames() throws {
    let content = try source()
    let start = try XCTUnwrap(content.range(of: "private func layerPicker("))
    let end = try XCTUnwrap(content.range(of: "Spacer(minLength: 0)", range: start.upperBound..<content.endIndex))
    let picker = String(content[start.lowerBound..<end.lowerBound])
    XCTAssertTrue(picker.contains("Text(layerDisplayName(layer))"))
    XCTAssertFalse(picker.contains("layer.tabTitle"), "胶囊名字要走 layerDisplayName（文案 / 正文 / 转写稿）")
    XCTAssertFalse(picker.contains("layer.heading"), "悬停提示不再露「配文」「视频转写」")
    XCTAssertTrue(content.contains("layer == .caption ? captionTabTitle : layer.tabTitle"))
  }

  func testTranslationCacheKeyCoversEveryLayer() throws {
    let content = try source()
    XCTAssertTrue(content.contains("let layersKey = detail.snapshots.map"))
    XCTAssertTrue(content.contains("\"needsTranslation|\\(layersKey)|\\(language)\""))
  }

  /// 译文拆层：中文配文被模型原样抄回来时，配文层不列（避免点开和原文一字不差）；
  /// 配文和转写都翻成不同的话时，两层都在，胶囊就是「文案 / 转写稿」两颗。
  func testSplitTranslatedDocumentIntoCaptionAndTranscriptLayers() {
    let composed = "# 标题\n\n## 配文\n\n配文的译文。\n\n## 视频转写\n\n00:00 转写的译文。"
    let layers = LayeredSourceDocument.split(composed)
    XCTAssertEqual(layers.map(\.heading), [nil, "配文", "视频转写"])
    XCTAssertEqual(layers[2].body, "00:00 转写的译文。")
  }
}
