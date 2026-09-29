import XCTest
@testable import LinkDigestApp

/// 设置按工序重组后（2026-09-28）的排版约定。
///
/// 原来的「生成偏好」页拆成了「工序总览」和七道工序页（汲 录 校 评 摘 译 图）。
/// 这里守的仍是那几条老约定，只是换了承载方式：
/// - 自动处理是**严格串行且有依赖**的链，顺序要是结构（总览链按工序顺序画），不能只写在说明里；
/// - 上游没开时下游当场说明原因，但不禁用、不画淡开关；
/// - 说明贴着控件，不回到卡片外的 footer；
/// - 空值是下拉里的一个选项，不靠 placeholder。
final class GenerationSettingsPresentationTests: XCTestCase {
  private func source() throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8)
  }

  /// 切出工序页那一段；切不出来就是结构变了，断言必须跟着改（失败，不跳过）。
  private func stepPages(in source: String) throws -> String {
    let start = try XCTUnwrap(
      source.range(of: "private var overviewTab: some View"),
      "找不到 overviewTab：工序页的结构变了，这个文件里的断言需要同步更新")
    let end = try XCTUnwrap(
      source.range(of: "// MARK: - 从「生成偏好」拆出来的部件"),
      "找不到部件区的 MARK，断言需要同步更新")
    return String(source[start.lowerBound..<end.lowerBound])
  }

  private func page(_ name: String, in pages: String) -> String {
    guard let start = pages.range(of: "private var \(name): some View") else { return "" }
    let rest = pages[start.upperBound...]
    let end = rest.range(of: "\n  private ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
  }

  /// 工序的顺序是结构：总览链按枚举顺序画，顺序和执行链一致。
  func testProcessChainIsOrderedByStructure() throws {
    XCTAssertEqual(SettingsProcessStep.allCases, [.capture, .record, .proof, .comments, .summary, .translation, .mindMap])
    XCTAssertEqual(SettingsProcessStep.allCases.map(\.glyph.rawValue), ["汲", "录", "校", "评", "摘", "译", "图"])
    let pages = try stepPages(in: try source())
    XCTAssertTrue(pages.contains("SettingsProcessChain("), "总览页必须画出工序链")
    XCTAssertTrue(page("summaryTab", in: pages).contains("读原文、不读译文"), "总结吃的是原文，必须写在页头说明上")
  }

  /// 每道工序的「自动」开关绑到原来那条管线偏好上，一个都不能漏。
  func testAutoSwitchesBindToThePipelinePreferences() throws {
    let text = try source()
    for binding in [
      "case .record: $model.autoTranscribeNewCaptures",
      "case .proof: $model.autoTidyTranscription",
      "case .summary: $model.autoSummarizeNewCaptures",
      "case .translation: $model.autoLocalizeTitleNewCaptures",
      "case .mindMap: $model.autoMindMapNewCaptures",
      "case .comments: autoSaveCommentsBinding",
    ] {
      XCTAssertTrue(text.contains(binding), "缺少开关绑定：\(binding)")
    }
  }

  /// 上游没开时，下游当场说明为什么；只提示，不禁用、不画淡。
  func testDownstreamStepsExplainUnmetUpstreamRequirement() throws {
    let pages = try stepPages(in: try source())
    let proof = page("proofTab", in: pages)
    XCTAssertTrue(proof.contains("model.autoTidyTranscription, !model.autoTranscribeNewCaptures"), "校对依赖转写产物，转写没开时必须说明")
    let mindMap = page("mindMapTab", in: pages)
    XCTAssertTrue(mindMap.contains("model.autoMindMapNewCaptures, !model.autoSummarizeNewCaptures"), "脑图优先吃总结，总结没开时必须说明；脑图没开时不打扰")
    XCTAssertFalse(pages.contains(".disabled(!model.autoTranscribeNewCaptures"), "硬禁用会砍掉「重抓已有转写稿的条目时只校对」这个可用组合")
  }

  /// 说明必须在卡片内；数据去向的详细说明默认收起但一条都不能删。
  func testExplanationsLiveInsideCards() throws {
    let text = try source()
    let pages = try stepPages(in: text)
    XCTAssertTrue(pages.contains("SettingsRowGroup"), "设置项要收进行组卡")
    XCTAssertTrue(page("commentsTab", in: pages).contains("details:"), "行自己的详细说明要跟控件走")
    XCTAssertTrue(page("overviewTab", in: pages).contains("sendAuthorizationSection"), "发送授权留在总览页")
    let consent = try XCTUnwrap(text.range(of: "@ViewBuilder private var sendAuthorizationSection: some View").map { String(text[$0.lowerBound...].prefix(3_000)) })
    XCTAssertTrue(consent.contains("DisclosureGroup(\"了解更多\")"))
    XCTAssertTrue(consent.contains("SettingsThemedCardChrome()"))
  }

  /// 空值是下拉里的一个选项，不靠 placeholder。
  func testEmptyModelFieldsStateWhatActuallyApplies() throws {
    let text = try source()
    XCTAssertTrue(text.contains("emptyOptionTitle: \"不使用：只用 Apple 本机转写\""))
    XCTAssertTrue(text.contains("emptyOptionTitle: \"跟随总结模型\""))
    XCTAssertFalse(text.contains("TextField(\"留空时使用总结模型\""), "语义不能只靠 placeholder 承载")
    XCTAssertFalse(text.contains("Label(emptyOptionTitle, systemImage:"), "下拉已经显示当前值了，下面不必再画一行重复它")
    XCTAssertFalse(text.contains("留空时只使用 Apple 本机转写"), "已经没有「留空」这个操作了")
    XCTAssertFalse(text.contains("Toggle(\"翻译使用不同模型\""), "翻译模型不再用开关承载")
  }

  /// 评论按平台：「跟随默认」「不抓」都是下拉里的选项。
  func testCommentPlatformsOfferFollowDefaultAndOff() throws {
    let comments = page("commentsTab", in: try stepPages(in: try source()))
    XCTAssertTrue(comments.contains("title: \"跟随默认\""))
    XCTAssertTrue(comments.contains("title: \"不抓\""))
    XCTAssertTrue(comments.contains("CapturePreferencesStore.commentPlatforms"))
  }
}
