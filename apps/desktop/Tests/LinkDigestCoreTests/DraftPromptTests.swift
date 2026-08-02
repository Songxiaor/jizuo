import XCTest
@testable import LinkDigestCore

/// 起草提示词。
///
/// 它是这个功能的产品定义:同样的素材、同样的模型,提示词决定了产出是
/// 一篇有观点的稿子,还是几段素材的转述拼接。所以这里钉的是那几条约束。
final class DraftPromptTests: XCTestCase {
  private let material = DraftPrompt.Material(
    title: "FDE 那篇", source: "X", body: "岗位三年增长 42 倍"
  )

  func testCarriesSparkAndMaterialsWithTheirSource() {
    let prompt = DraftPrompt.build(spark: "AI 时代的创作", materials: [material])
    XCTAssertTrue(prompt.contains("AI 时代的创作"))
    XCTAssertTrue(prompt.contains("FDE 那篇"))
    XCTAssertTrue(prompt.contains("岗位三年增长 42 倍"))
    XCTAssertTrue(prompt.contains("来源:X"), "素材要带来源，否则写出来无法回溯")
  }

  /// 不许编造。这是这个功能可用的前提——素材里没有的事实一旦被编出来，
  /// 用户就再也不敢直接用它的产出。
  func testForbidsInventingFactsBeyondTheMaterials() {
    let prompt = DraftPrompt.build(spark: "灵感", materials: [material])
    XCTAssertTrue(prompt.contains("只能用素材里出现过的事实"))
  }

  /// 要求素材之间发生关系。单份素材的复述没有增量。
  func testRequiresMaterialsToInteract() {
    let prompt = DraftPrompt.build(spark: "灵感", materials: [material, material])
    XCTAssertTrue(prompt.contains("至少让两份素材发生关系"))
  }

  /// 没有素材时不能装作有——改成把想法展开，并标出该补例子的地方。
  func testWithoutMaterialsItAsksForPlaceholdersInsteadOfInventing() {
    let prompt = DraftPrompt.build(spark: "一个念头", materials: [])
    XCTAssertTrue(prompt.contains("还没有素材"))
    XCTAssertTrue(prompt.contains("不要编造"))
    XCTAssertTrue(prompt.contains("[这里需要一个例子]"))
  }

  /// 长素材要截断:几份长文就能把上下文吃满,而模型需要的是论点和证据,
  /// 不是逐字全文。
  func testLongMaterialIsTruncated() {
    let long = DraftPrompt.Material(
      title: "长文", source: "网页",
      body: String(repeating: "字", count: DraftPrompt.materialCharacterLimit + 500)
    )
    let prompt = DraftPrompt.build(spark: "灵感", materials: [long])
    XCTAssertTrue(prompt.contains("已截断"))
    XCTAssertLessThan(prompt.count, DraftPrompt.materialCharacterLimit + 800)
  }

  func testVoiceIsIncludedOnlyWhenProvided() {
    XCTAssertFalse(DraftPrompt.build(spark: "x", materials: []).contains("我的表达方式"))
    let withVoice = DraftPrompt.build(spark: "x", materials: [], voice: "短句为主")
    XCTAssertTrue(withVoice.contains("我的表达方式"))
    XCTAssertTrue(withVoice.contains("短句为主"))
  }
}
