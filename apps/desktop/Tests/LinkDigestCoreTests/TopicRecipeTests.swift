import XCTest
@testable import LinkDigestCore

/// 选题配方:参数怎么折成取数、模板怎么渲染。
///
/// 这里钉的每一条,坏掉之后用户看到的都是同一句话——「今天没出选题」。
/// 从那句话回推是哪一步出的问题非常贵,所以在这一层拦住。
final class TopicRecipeTests: XCTestCase {
  // MARK: - 取数

  func testDefaultRecipeKeepsBothLanes() {
    let lanes = TopicRecipe.default.recall.lanes
    XCTAssertEqual(lanes.count, 2)
    XCTAssertEqual(lanes[0].window, .recent(days: 7))
    XCTAssertEqual(lanes[0].limit, 10)
    XCTAssertEqual(lanes[1].window, .dormant(sinceDays: 30))
    XCTAssertEqual(lanes[1].limit, 5)
  }

  /// 取 0 条 = 关掉那一路,而不是发一条取 0 条的查询。
  func testZeroLimitDropsTheLane() {
    var recipe = TopicRecipe.default
    recipe.dormantLimit = 0
    let lanes = recipe.recall.lanes
    XCTAssertEqual(lanes.count, 1)
    XCTAssertEqual(lanes[0].window, .recent(days: 7))
  }

  func testTagsReachEveryLane() {
    var recipe = TopicRecipe.default
    recipe.tags = ["AI", "创业"]
    XCTAssertTrue(recipe.recall.lanes.allSatisfy { $0.tags == ["AI", "创业"] })
  }

  // MARK: - 夹范围

  /// 界面上是输入框,所以任何值都会进来。夹在类型里,不是夹在界面里——
  /// 定时触发和试跑读的是同一份存下来的值。
  func testSanitizeClampsOutOfRangeValues() {
    var recipe = TopicRecipe(
      recentDays: 0, recentLimit: -3, dormantSinceDays: 9999,
      excerptLimit: 1, count: 0, boundaryCount: 99
    )
    recipe = recipe.sanitized()
    XCTAssertEqual(recipe.recentDays, 1)
    XCTAssertEqual(recipe.recentLimit, 0)
    XCTAssertEqual(recipe.dormantSinceDays, 365)
    XCTAssertEqual(recipe.excerptLimit, 100)
    XCTAssertEqual(recipe.count, 1)
    // 越界条数不能超过总条数——否则模型收到一条自相矛盾的要求。
    XCTAssertEqual(recipe.boundaryCount, 1)
  }

  func testDecodingGarbageFallsBackToDefault() {
    XCTAssertEqual(TopicRecipe.decoded(from: ""), .default)
    XCTAssertEqual(TopicRecipe.decoded(from: "{不是 JSON"), .default)
  }

  func testRoundTripSurvivesEncoding() {
    var recipe = TopicRecipe.default
    recipe.count = 8
    recipe.tags = ["AI"]
    recipe.template = "我自己的问法 {素材}"
    XCTAssertEqual(TopicRecipe.decoded(from: recipe.encoded()), recipe)
  }

  // MARK: - 模板

  func testPresetIsNotCountedAsCustomized() {
    XCTAssertFalse(TopicRecipe.default.isTemplateCustomized)
    XCTAssertEqual(TopicRecipe.default.effectiveTemplate, TopicPrompt.presetTemplate)

    var blank = TopicRecipe.default
    // 清空编辑器不等于「我要一份空提示词」,那样跑出来的东西没有任何约束。
    blank.template = "   \n  "
    XCTAssertFalse(blank.isTemplateCustomized)
    XCTAssertEqual(blank.effectiveTemplate, TopicPrompt.presetTemplate)
  }

  func testCustomTemplateWins() {
    var recipe = TopicRecipe.default
    recipe.template = "只按我说的来"
    XCTAssertTrue(recipe.isTemplateCustomized)
    XCTAssertEqual(recipe.effectiveTemplate, "只按我说的来")
  }
}

/// 模板渲染。空值的两条规则是用户唯一需要预测的行为。
final class TopicPromptRenderTests: XCTestCase {
  private func material(_ index: Int, excerpt: String = "正文") -> TopicPrompt.Material {
    .init(index: index, title: "素材\(index)", lane: "最近在看的", excerpt: excerpt)
  }

  /// 规则一:值为空,那一行整行消失。
  func testEmptyValueRemovesItsLine() {
    let rendered = TopicPrompt.render(
      template: "开头\n名字是 {名字}\n结尾",
      values: ["{名字}": ""]
    )
    XCTAssertEqual(rendered, "开头\n结尾")
  }

  /// 规则二:一段只剩下标题行,整段消失。
  func testHeadingOnlyBlockDisappears() {
    let rendered = TopicPrompt.render(
      template: "## 甲\n{甲}\n\n## 乙\n有内容",
      values: ["{甲}": ""]
    )
    XCTAssertFalse(rendered.contains("## 甲"))
    XCTAssertTrue(rendered.contains("## 乙"))
  }

  func testFilledValueKeepsTheLine() {
    let rendered = TopicPrompt.render(
      template: "## 甲\n{甲}",
      values: ["{甲}": "内容"]
    )
    XCTAssertTrue(rendered.contains("## 甲"))
    XCTAssertTrue(rendered.contains("内容"))
  }

  /// 没设表达方式、也没出过选题时,那两段不该留下空标题。
  func testPresetDropsUnusedSectionsForAFreshUser() {
    let prompt = TopicPrompt.build(materials: [material(1), material(2)])
    XCTAssertFalse(prompt.contains("## 我的表达方式"))
    XCTAssertFalse(prompt.contains("## 最近已经出过的选题"))
    XCTAssertTrue(prompt.contains("## 素材"))
    XCTAssertTrue(prompt.contains("## 输出格式"))
  }

  func testPresetKeepsSectionsWhenValuesExist() {
    let prompt = TopicPrompt.build(
      materials: [material(1), material(2)],
      recentTopics: ["上周那条"],
      voice: "短句，别用形容词"
    )
    XCTAssertTrue(prompt.contains("## 我的表达方式"))
    XCTAssertTrue(prompt.contains("短句，别用形容词"))
    XCTAssertTrue(prompt.contains("- 上周那条"))
    // 「不要再出这些角度」写在标题里而不是单独一行:它单独成行的话,
    // 一条选题都没出过时会留下一句指向空气的指令。
    XCTAssertTrue(prompt.contains("不要再出这些角度"))
  }

  /// 越界 0 条时那一行必须消失,而不是写成「其中 0 条标成越界」。
  func testZeroBoundaryRemovesTheRequirement() {
    let none = TopicPrompt.build(materials: [material(1), material(2)], boundaryCount: 0)
    XCTAssertFalse(none.contains("越界」"))

    let one = TopicPrompt.build(materials: [material(1), material(2)], boundaryCount: 1)
    XCTAssertTrue(one.contains("其中 1 条标成「越界」"))
  }

  func testCountReachesEveryPlaceOfTheTemplate() {
    let prompt = TopicPrompt.build(materials: [material(1), material(2)], count: 8)
    XCTAssertTrue(prompt.contains("给出 8 条"))
    XCTAssertTrue(prompt.contains("8 条要是 8 个不同角度"))
    XCTAssertFalse(prompt.contains("{条数}"))
  }

  func testExcerptLimitTruncates() {
    let long = String(repeating: "字", count: 50)
    let prompt = TopicPrompt.build(
      materials: [material(1, excerpt: long), material(2)], excerptLimit: 10
    )
    XCTAssertTrue(prompt.contains(String(repeating: "字", count: 10) + "…"))
    XCTAssertFalse(prompt.contains(String(repeating: "字", count: 11)))
  }

  /// 渲染完的提示词仍然要能被自己的解析器读回来——
  /// 「输出格式」那一段被改没了,是改坏模板最常见的方式。
  func testPresetStillDescribesTheFormatTheParserReads() {
    let prompt = TopicPrompt.build(materials: [material(1), material(2)])
    let parsed = TopicPrompt.parse("""
    标题: 一条主张
    摘要: 很短
    素材: 1, 2
    越界: 否
    """)
    XCTAssertEqual(parsed.count, 1)
    for field in ["标题:", "摘要:", "素材:", "越界:"] {
      XCTAssertTrue(prompt.contains(field), "提示词里少了 \(field)")
    }
  }

  func testNoPlaceholderSurvivesRendering() {
    let prompt = TopicPrompt.build(
      materials: [material(1), material(2)], recentTopics: ["甲"], voice: "乙"
    )
    for (placeholder, _) in TopicPrompt.Placeholder.all {
      XCTAssertFalse(prompt.contains(placeholder), "\(placeholder) 没被替换")
    }
  }
}
