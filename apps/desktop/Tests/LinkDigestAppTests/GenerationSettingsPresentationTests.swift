import XCTest

/// 「生成偏好」这页的排版约定。
///
/// 改这页之前有两处会误导：
/// - 每个设置项是「Section header + 控件 + 卡片外的长 footer」，说明离它控制的
///   控件隔着一整块间距，读的时候对不上号，四五行密字还把页面撑满。
/// - 自动处理管线在代码里是**严格串行且有依赖**的链（整理吃转写产物、脑图吃总结
///   产物），UI 却画成四个平级、无序、互不相关的开关，顺序只在 footer 用一句话
///   交代。于是「只开整理、不开转写」这种基本不会生效的组合，界面完全不拦。
///
/// 这类偏差不报错、不崩溃，只是让人按错误的预期配置，所以用测试钉住。
final class GenerationSettingsPresentationTests: XCTestCase {
  private func source() throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8)
  }

  private func generationTab(in source: String) throws -> String {
    guard let start = source.range(of: "private var generationTab: some View"),
          let end = source.range(of: "// MARK: - 设置卡片零件")
    else {
      throw XCTSkip("generationTab 结构已变，测试需要同步更新")
    }
    return String(source[start.lowerBound..<end.lowerBound])
  }

  /// 管线必须是有编号的链条，不是四个平级开关。
  func testAutoPipelineIsRenderedAsAnOrderedChain() throws {
    let tab = try generationTab(in: try source())
    for index in 1...4 {
      XCTAssertTrue(
        tab.contains("index: \(index)"),
        "管线第 \(index) 步必须带编号——顺序要是结构，不能只写在说明文字里")
    }
    XCTAssertTrue(
      tab.contains("pipelineStep("),
      "四个步骤要走同一个构件，各写各的迟早漂移")
    XCTAssertFalse(
      tab.contains("Toggle(\"自动转写（本机）\""),
      "平级 Toggle 的写法回来了，链条结构就没了")
  }

  /// 上游没开时，下游必须当场说明为什么，而不是让人事后发现没生效。
  func testDownstreamStepsExplainUnmetUpstreamRequirement() throws {
    let tab = try generationTab(in: try source())
    XCTAssertTrue(
      tab.contains("requirementUnmet: model.autoTranscribeNewCaptures"),
      "整理依赖转写产物，转写没开时必须说明")
    XCTAssertTrue(
      tab.contains("requirementUnmet: model.autoSummarizeNewCaptures"),
      "脑图优先吃总结产物，总结没开时必须说明")
  }

  /// 依赖只做视觉降级，不禁用开关。
  ///
  /// 重新抓取一条早先转写过的条目时，整理确实能独立生效（`tidySourceReady` 也认
  /// 历史转写稿）。硬禁用会砍掉这个真实可用的组合。
  func testDependencyDimsButDoesNotDisableDownstreamToggles() throws {
    let text = try source()
    guard let start = text.range(of: "private func pipelineStep(") else {
      return XCTFail("pipelineStep 不见了")
    }
    // 2_200：开关行改为「拨杆靠右」的 HStack 后 pipelineStep 变长，1_600 截不到
    // opacity 修饰符；窗口只是取样范围，不承载断言语义。
    let step = String(text[start.lowerBound...].prefix(2_200))
    XCTAssertTrue(step.contains("opacity(requirementUnmet == nil"), "未满足依赖时应当降低视觉权重")
    XCTAssertFalse(
      step.contains(".disabled(requirementUnmet"),
      "硬禁用会砍掉「重抓已有转写稿的条目时只整理」这个可用组合")
  }

  /// 说明必须在卡片内，不能再堆回卡片外的 footer。
  func testExplanationsLiveInsideCards() throws {
    let tab = try generationTab(in: try source())
    XCTAssertTrue(tab.contains("settingCard("), "设置项要走统一的卡片构件")
    XCTAssertTrue(
      tab.contains("DisclosureGroup(\"了解更多\")"),
      "详细说明默认收起，但一条都不能删")
    XCTAssertFalse(
      tab.contains("在线视频转文字\")\n      } footer: {"),
      "说明回到 footer 就又和控件分家了")
  }

  /// 「留空时…」不能只写在 placeholder 里。
  ///
  /// 右对齐的 placeholder 看起来像已经配好的值——截图里「留空时使用总结模型」
  /// 就被当成了当前设置。
  func testEmptyModelFieldsStateWhatActuallyApplies() throws {
    let tab = try generationTab(in: try source())
    // 2026-07-29 起空值不再是「输入框留空」，而是下拉里的第一个选项——
    // 承载方式变了，要守的东西没变：空值必须说清实际生效的是什么。
    XCTAssertTrue(tab.contains("emptyOptionTitle: \"不使用：只用 Apple 本机转写\""))
    XCTAssertTrue(tab.contains("emptyOptionTitle: \"跟随总结模型\""))
    XCTAssertFalse(
      tab.contains("TextField(\"留空时使用总结模型\""),
      "语义不能只靠 placeholder 承载")
  }

  /// 空值只说一遍。
  ///
  /// 下拉里已经显示着「不使用：只用 Apple 本机转写」，卡片里再画一行虚线圆圈重复同一句，
  /// 读起来像两个不同的状态。是把自由文本改成下拉时漏删的旧行。
  func testEmptyStateIsNotRepeatedBelowThePicker() throws {
    let text = try source()
    XCTAssertFalse(
      text.contains("Label(emptyOptionTitle, systemImage:"),
      "下拉已经显示当前值了，下面不必再画一行重复它")
  }

  /// 主控件必须和自己的标签同一行：标签是什么、控件就答什么。
  ///
  /// 「翻译模型」原来是个开关，2026-08-06 换成了和「转写稿整理」同一个下拉
  /// （第一项「跟随总结模型」）——这一页每一项都该是一个下拉直接答完，
  /// 而不是先开一个开关、再长出一个选择器。
  ///
  /// 2026-08-13 行式重建后，承载方式从「卡片标题行 `} control: {`」换成
  /// `SettingsRow`（标签左、控件右、同一行）——意图相同，机制换了。
  func testPrimaryControlsUseTheCardTitleAsTheirLabel() throws {
    let tab = try generationTab(in: try source())
    XCTAssertFalse(
      tab.contains("Toggle(\"翻译使用不同模型\""),
      "翻译模型不再用开关承载")
    XCTAssertTrue(
      tab.contains("emptyOptionTitle: \"跟随总结模型\""),
      "空值要是下拉里的一个选项，而不是一个需要先关掉的开关")
    XCTAssertTrue(
      tab.contains("SettingsRow("),
      "模型项的主控件要和标签同一行（行式布局），不能落回孤零零的卡内控件")
  }

  /// 说明文字要跟着承载方式一起改。
  ///
  /// 空值从「把输入框留空」变成下拉里的一个选项之后，还写「留空时…」就是在描述
  /// 一个界面上已经不存在的操作。
  func testCopyMatchesHowEmptyIsActuallySelected() throws {
    let tab = try generationTab(in: try source())
    XCTAssertFalse(
      tab.contains("留空时只使用 Apple 本机转写"),
      "已经没有「留空」这个操作了，说明要跟着改")
  }
}
