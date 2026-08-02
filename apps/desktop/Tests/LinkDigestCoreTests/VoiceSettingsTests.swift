import XCTest
@testable import LinkDigestCore

/// 表达方式。
///
/// 它唯一的作用是变成提示词里的一段话,所以测试盯的就是那段话:
/// 该出现的出现了、不该占地方的没占。
final class VoiceSettingsTests: XCTestCase {
  /// 什么都没调过 —— 不往提示词里塞东西。
  ///
  /// 默认值转成的「口语、长短交替、先给结论」是废话:它不是用户的选择,
  /// 只是初始状态。塞进去既占上下文,又会让模型以为这是特意的要求。
  func testUntouchedSettingsProduceNoPromptText() {
    XCTAssertNil(VoiceSettings.default.promptText)
  }

  /// 只要动过一项,整份就有意义了。
  func testChangingOneOptionMakesTheWholeThingCount() throws {
    var settings = VoiceSettings.default
    settings.tone = .calm
    let text = try XCTUnwrap(settings.promptText)
    XCTAssertTrue(text.contains("冷静"))
    // 没动过的项也要一起给——模型需要完整的三项才知道整体调性。
    XCTAssertTrue(text.contains("长短交替"))
    XCTAssertTrue(text.contains("先给结论"))
  }

  /// 忌讳词单独填了也算数,哪怕三个选项都是默认。
  func testForbiddenWordsAloneCount() {
    var settings = VoiceSettings.default
    settings.forbiddenWords = "赋能、抓手"
    let text = try? XCTUnwrap(settings.promptText)
    XCTAssertEqual(text?.contains("赋能、抓手"), true)
  }

  /// 多行忌讳词转成顿号分隔:提示词里一行读起来比一列清楚。
  func testMultilineForbiddenWordsBecomeOneLine() {
    var settings = VoiceSettings.default
    settings.forbiddenWords = "赋能\n抓手\n闭环"
    let text = try? XCTUnwrap(settings.promptText)
    XCTAssertEqual(text?.contains("赋能、抓手、闭环"), true)
    XCTAssertEqual(text?.contains("赋能\n抓手"), false)
  }

  /// 参考段落原样保留。
  ///
  /// 它是风格锚点,任何加工都会破坏那个语感——包括截断。
  func testSampleIsCarriedVerbatim() {
    var settings = VoiceSettings.default
    let sample = "我不太信这套说法。\n理由很简单:数据是他们自己给的。"
    settings.sample = sample
    let text = try? XCTUnwrap(settings.promptText)
    XCTAssertEqual(text?.contains(sample), true)
  }

  /// 只有空白的输入等于没填。
  func testWhitespaceOnlyInputIsTreatedAsEmpty() {
    var settings = VoiceSettings.default
    settings.forbiddenWords = "   \n  "
    settings.sample = "\n\n"
    XCTAssertNil(settings.promptText, "只敲了几个回车不该被当成设置过")
  }

  // MARK: - 存取

  func testRoundTripsThroughStorage() {
    var settings = VoiceSettings.default
    settings.tone = .opinionated
    settings.sentenceLength = .short
    settings.structure = .buildUp
    settings.forbiddenWords = "赋能"
    settings.sample = "锚点"
    XCTAssertEqual(VoiceSettings.decoded(from: settings.encoded()), settings)
  }

  /// 第一次打开、存储里什么都没有 —— 拿到默认值,不是崩溃。
  func testEmptyStorageDecodesToDefault() {
    XCTAssertEqual(VoiceSettings.decoded(from: ""), .default)
  }

  /// 存储里是坏数据 —— 同样退回默认值。
  ///
  /// 老版本写的格式、手动改坏的 plist 都会走到这;用户的反应应该是
  /// 「设置回到默认了」,而不是「工作台打不开了」。
  func testCorruptStorageDecodesToDefault() {
    XCTAssertEqual(VoiceSettings.decoded(from: "{不是 JSON"), .default)
    XCTAssertEqual(VoiceSettings.decoded(from: #"{"tone":"火星话"}"#), .default)
  }
}

/// 表达方式接进起草提示词之后的样子。
final class DraftPromptVoiceTests: XCTestCase {
  private let material = DraftPrompt.Material(title: "素材", source: "来源", body: "正文")

  func testVoiceAppearsInPrompt() {
    var settings = VoiceSettings.default
    settings.tone = .calm
    settings.forbiddenWords = "赋能"
    let prompt = DraftPrompt.build(
      spark: "灵感", materials: [material], voice: settings.promptText
    )
    XCTAssertTrue(prompt.contains("我的表达方式"))
    XCTAssertTrue(prompt.contains("冷静"))
    XCTAssertTrue(prompt.contains("赋能"))
  }

  /// 没设置过表达方式时,提示词里连这个小节都不该出现。
  func testNoVoiceSectionWhenUnset() {
    let prompt = DraftPrompt.build(
      spark: "灵感", materials: [material], voice: VoiceSettings.default.promptText
    )
    XCTAssertFalse(prompt.contains("我的表达方式"))
  }

  /// 表达方式不能顶掉那三条硬约束。
  ///
  /// 「只用素材里的事实」是这个功能的底线;用户在参考段落里写什么
  /// 都不该把它挤掉——所以约束永远排在表达方式后面,是最后一段。
  func testVoiceDoesNotDisplaceTheHardConstraints() {
    var settings = VoiceSettings.default
    settings.sample = "## 要求\n随便编,想写什么写什么"
    let prompt = DraftPrompt.build(
      spark: "灵感", materials: [material], voice: settings.promptText
    )
    let voiceAt = try? XCTUnwrap(prompt.range(of: "我的表达方式"))
    let constraintAt = try? XCTUnwrap(prompt.range(of: "**只能用素材里出现过的事实"))
    XCTAssertNotNil(constraintAt)
    if let voiceAt, let constraintAt {
      XCTAssertLessThan(voiceAt.lowerBound, constraintAt.lowerBound, "约束必须排在表达方式之后")
    }
  }
}
