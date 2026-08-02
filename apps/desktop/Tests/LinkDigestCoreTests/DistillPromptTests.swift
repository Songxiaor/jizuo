import XCTest
@testable import LinkDigestCore

/// 从修改里提炼方法。
///
/// 这是判断沉淀真正兑现价值的地方——在此之前那张表只是在攒数据。
final class DistillPromptTests: XCTestCase {
  private let pairs = [
    DistillPrompt.Pair(generated: "AI 第一版", revised: "我改的第一版"),
    DistillPrompt.Pair(generated: "AI 第二版", revised: "我改的第二版"),
    DistillPrompt.Pair(generated: "AI 第三版", revised: "我改的第三版"),
  ]

  func testBothVersionsAreCarried() {
    let prompt = DistillPrompt.build(pairs: pairs)
    XCTAssertTrue(prompt.contains("AI 第一版"))
    XCTAssertTrue(prompt.contains("我改的第三版"))
  }

  /// 只出现一次的差异不是方法。
  ///
  /// 这条约束是整个功能可信的前提:不加的话，模型会把某一篇的
  /// 特殊处理总结成一条普适规则，而那条规则会进之后每一次起草。
  func testOnlyRepeatedDifferencesCount() {
    let prompt = DistillPrompt.build(pairs: pairs)
    XCTAssertTrue(prompt.contains("反复出现"))
    XCTAssertTrue(prompt.contains("只出现一次的是这一篇的特殊情况"))
  }

  /// 入库标准要在提示词里就说清楚。
  ///
  /// 光靠事后过滤会让模型三条全被拦掉，用户看到的是「什么都没提炼出来」。
  func testTheAdmissionStandardIsStatedUpFront() {
    let prompt = DistillPrompt.build(pairs: pairs)
    XCTAssertTrue(prompt.contains("能照着做的动作"))
    XCTAssertTrue(prompt.contains("要写得更简洁"), "没给一个反例，模型不知道什么算不合格")
  }

  /// 找不到就直说，不要硬凑。
  func testAllowsAnEmptyAnswer() {
    XCTAssertTrue(DistillPrompt.build(pairs: pairs).contains("没看出反复出现的差异"))
  }

  func testExistingMethodsAreListedToAvoidRepeats() {
    let prompt = DistillPrompt.build(pairs: pairs, existing: ["先给结论再给证据"])
    XCTAssertTrue(prompt.contains("先给结论再给证据"))
    XCTAssertTrue(prompt.contains("不要重复这些"))
  }

  func testLongVersionsAreTruncated() {
    let long = String(repeating: "字", count: DistillPrompt.versionCharacterLimit + 300)
    let prompt = DistillPrompt.build(pairs: [.init(generated: long, revised: "短的")])
    XCTAssertTrue(prompt.contains("已截断"))
    XCTAssertFalse(prompt.contains(long))
  }

  /// 一两对里看到的「规律」多半是巧合。
  func testMinimumPairsIsMoreThanTwo() {
    XCTAssertGreaterThan(DistillPrompt.minimumPairs, 2)
  }
}

/// 解析提炼产出。
final class DistillParseTests: XCTestCase {
  func testOneLineEach() {
    let parsed = DistillPrompt.parse("""
    每段控制在三句以内，超了就拆开
    开头不要铺垫，第一句直接给判断
    """)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed.first, "每段控制在三句以内，超了就拆开")
  }

  /// 模型爱加列表符号和编号，去掉。
  func testStripsListMarkersAndNumbering() {
    XCTAssertEqual(
      DistillPrompt.parse("- 每段控制在三句以内").first, "每段控制在三句以内"
    )
    XCTAssertEqual(
      DistillPrompt.parse("1. 每段控制在三句以内").first, "每段控制在三句以内"
    )
    XCTAssertEqual(
      DistillPrompt.parse("2、每段控制在三句以内").first, "每段控制在三句以内"
    )
    XCTAssertEqual(
      DistillPrompt.parse("**每段控制在三句以内**").first, "每段控制在三句以内"
    )
  }

  func testSkipsHeadingsAndBlankLines() {
    let parsed = DistillPrompt.parse("""
    ## 提炼结果

    每段控制在三句以内

    """)
    XCTAssertEqual(parsed, ["每段控制在三句以内"])
  }

  func testEmptyOutputParsesToNothing() {
    XCTAssertTrue(DistillPrompt.parse("").isEmpty)
    XCTAssertTrue(DistillPrompt.parse("\n\n  \n").isEmpty)
  }

  /// 解析器不做质量判断。
  ///
  /// 那道门是 MethodAdmission 的活，而且必须是确定性的——不能让
  /// 模型的产出自己判自己合不合格。
  func testParserDoesNotFilterByQuality() {
    XCTAssertEqual(DistillPrompt.parse("要写得更简洁"), ["要写得更简洁"])
    XCTAssertFalse(MethodAdmission.isAdmissible("要写得更简洁"))
  }
}
