import XCTest
@testable import LinkDigestCore

/// 第二块画板的提示词。
///
/// 它和起草(`DraftPrompt`)防的是相反方向的事:起草防「凭空编」,
/// 改写防「改着改着把事实改没了」。测试盯的就是这个方向没搞反。
final class RewritePromptTests: XCTestCase {
  private let body = "## 一个小节\n\n2024 年营收是 3.7 亿。张三说这数字有水分。"

  func testBodyIsCarried() {
    let prompt = RewritePrompt.build(body: body, voice: nil)
    XCTAssertTrue(prompt.contains("3.7 亿"))
    XCTAssertTrue(prompt.contains("张三"))
  }

  /// 两档力度都必须钉死「不许动事实」。
  ///
  /// 这是改写画板的底线:用户拿它调语感,不是拿它改数据。
  /// 少了这一条,一次「顺一遍」就可能把 3.7 亿写成 3.7 万,而且神不知鬼不觉。
  func testEveryIntensityForbidsChangingFacts() {
    for intensity in RewritePrompt.Intensity.allCases {
      let prompt = RewritePrompt.build(body: body, voice: nil, intensity: intensity)
      XCTAssertTrue(
        prompt.contains("不要改动事实"),
        "\(intensity.displayName) 这一档漏了「不许动事实」"
      )
    }
  }

  /// 轻的那一档要保住结构。
  func testPolishKeepsStructure() {
    let prompt = RewritePrompt.build(body: body, voice: nil, intensity: .polish)
    XCTAssertTrue(prompt.contains("保留原有的段落顺序"))
    XCTAssertFalse(prompt.contains("可以重新组织段落顺序"))
  }

  /// 重的那一档才放开段落顺序。
  func testRewriteAllowsReordering() {
    let prompt = RewritePrompt.build(body: body, voice: nil, intensity: .rewrite)
    XCTAssertTrue(prompt.contains("可以重新组织段落顺序"))
  }

  /// 两档都不许扩写。
  ///
  /// 「改一下」的产物比原文长一倍是模型最常见的跑偏,而用户按这个按钮时
  /// 想要的是同一篇稿子的另一种说法,不是一篇更长的稿子。
  func testNoIntensityAllowsExpansion() {
    for intensity in RewritePrompt.Intensity.allCases {
      let prompt = RewritePrompt.build(body: body, voice: nil, intensity: intensity)
      XCTAssertTrue(prompt.contains("不要扩写"), "\(intensity.displayName) 允许了扩写")
    }
  }

  func testVoiceIsCarried() {
    var settings = VoiceSettings.default
    settings.tone = .calm
    settings.forbiddenWords = "赋能"
    let prompt = RewritePrompt.build(body: body, voice: settings.promptText)
    XCTAssertTrue(prompt.contains("冷静"))
    XCTAssertTrue(prompt.contains("赋能"))
  }

  /// 没设置过表达方式时,要明确告诉模型「保持原样」。
  ///
  /// 留空的话模型只会按它自己的默认审美「优化」——那正是用户
  /// 最不想要的东西,而且他从没要求过。
  func testUnsetVoiceTellsTheModelToKeepTheOriginalFeel() {
    let prompt = RewritePrompt.build(body: body, voice: nil)
    XCTAssertTrue(prompt.contains("保持稿子原有的语感"))
  }

  func testEmptyVoiceStringIsTreatedAsUnset() {
    let prompt = RewritePrompt.build(body: body, voice: "   \n ")
    XCTAssertTrue(prompt.contains("保持稿子原有的语感"))
  }

  /// 太长的稿子截断。
  ///
  /// 不截断的话模型会中途放弃或截断输出,而结果会**整篇覆盖**原稿——
  /// 表现是「改完短了一半」,比不改糟得多。
  func testOverlongBodyIsTruncated() {
    let long = String(repeating: "字", count: RewritePrompt.bodyCharacterLimit + 500)
    let prompt = RewritePrompt.build(body: long, voice: nil)
    XCTAssertTrue(prompt.contains("已截断"))
    XCTAssertLessThan(prompt.count, long.count)
  }

  func testBodyAtTheLimitIsNotTruncated() {
    let exact = String(repeating: "字", count: RewritePrompt.bodyCharacterLimit)
    XCTAssertFalse(RewritePrompt.build(body: exact, voice: nil).contains("已截断"))
  }
}
