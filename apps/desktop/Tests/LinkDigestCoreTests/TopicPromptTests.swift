import XCTest
@testable import LinkDigestCore

/// 选题提示词。
final class TopicPromptTests: XCTestCase {
  private func materials(_ n: Int) -> [TopicPrompt.Material] {
    (1...n).map {
      .init(index: $0, title: "素材\($0)", lane: "最近在看的", excerpt: "正文\($0)")
    }
  }

  /// 这块板最容易的失败方式:五条候选其实是五份素材的摘要。
  ///
  /// 那种东西看起来像模像样,但用户扫一眼就知道没用。约束必须在。
  func testForbidsPerMaterialSummaries() {
    let prompt = TopicPrompt.build(materials: materials(3))
    XCTAssertTrue(prompt.contains("至少两份素材发生关系"))
    XCTAssertTrue(prompt.contains("一份素材的摘要不是选题"))
  }

  /// 每天留一条不受偏好约束的。
  ///
  /// 纯按偏好优化的必然结果是规则收敛、候选越来越像你写过的东西。
  func testAsksForOneOutOfBoundsCandidate() {
    XCTAssertTrue(TopicPrompt.build(materials: materials(3)).contains("越界"))
  }

  /// 摘要必须短。读不完的选题等于没出。
  func testCapsSummaryLength() {
    XCTAssertTrue(TopicPrompt.build(materials: materials(3)).contains("60 字以内"))
  }

  func testRecentTopicsAreListedToAvoidRepeats() {
    let prompt = TopicPrompt.build(materials: materials(2), recentTopics: ["上周写过的角度"])
    XCTAssertTrue(prompt.contains("上周写过的角度"))
    XCTAssertTrue(prompt.contains("不要再出这些角度"))
  }

  func testNoRecentTopicsSectionWhenEmpty() {
    XCTAssertFalse(TopicPrompt.build(materials: materials(2)).contains("最近已经出过的选题"))
  }

  /// 长素材截断。
  ///
  /// 选题只需要知道每份素材在说什么。十几份各放全文会把上下文吃满,
  /// 而模型真正要做的是找关系。
  func testLongExcerptIsTruncated() {
    let long = String(repeating: "字", count: TopicPrompt.excerptCharacterLimit + 200)
    let prompt = TopicPrompt.build(materials: [
      .init(index: 1, title: "长素材", lane: "最近在看的", excerpt: long),
    ])
    XCTAssertFalse(prompt.contains(long), "全文原样进了提示词")
    XCTAssertTrue(prompt.contains(String(repeating: "字", count: 100)), "截断得太狠")
  }

  func testExcerptAtTheLimitIsNotTruncated() {
    let exact = String(repeating: "字", count: TopicPrompt.excerptCharacterLimit)
    let prompt = TopicPrompt.build(materials: [
      .init(index: 1, title: "刚好", lane: "最近在看的", excerpt: exact),
    ])
    XCTAssertTrue(prompt.contains(exact))
  }
}

/// 解析模型的输出。
///
/// 这是整条链上最容易**静默**失效的一环:解析不出来时用户看到的是
/// 「今天没出选题」,他不会知道是格式差了一行。所以宽松解析,
/// 并且每种模型爱犯的格式毛病都单独钉一条。
final class TopicParseTests: XCTestCase {
  func testParsesTheStandardFormat() {
    let parsed = TopicPrompt.parse("""
    标题: 岗位名称在变，底层能力没变
    摘要: 从两份招聘数据里看能力要求的连续性
    素材: 1, 3
    越界: 否

    标题: 另一条
    摘要: 另一句
    素材: 2
    越界: 是
    """)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0].title, "岗位名称在变，底层能力没变")
    XCTAssertEqual(parsed[0].materialIndexes, [1, 3])
    XCTAssertFalse(parsed[0].isOutOfBounds)
    XCTAssertTrue(parsed[1].isOutOfBounds)
  }

  /// 模型很爱把字段名加粗。认不出来的话整批候选静默变空。
  func testParsesBoldFieldNames() {
    let parsed = TopicPrompt.parse("""
    **标题**: 加粗了
    **摘要**: 也加粗了
    """)
    XCTAssertEqual(parsed.first?.title, "加粗了")
    XCTAssertEqual(parsed.first?.summary, "也加粗了")
  }

  /// 全角冒号。中文输入法下模型经常这么写。
  func testParsesFullWidthColon() {
    let parsed = TopicPrompt.parse("标题：全角\n摘要：也是全角")
    XCTAssertEqual(parsed.first?.title, "全角")
    XCTAssertEqual(parsed.first?.summary, "也是全角")
  }

  /// 写成 Markdown 列表。
  func testParsesListItems() {
    let parsed = TopicPrompt.parse("- 标题: 列表里的\n- 摘要: 一句话")
    XCTAssertEqual(parsed.first?.title, "列表里的")
  }

  /// 前后多写了寒暄 —— 不能因此整批作废。
  func testIgnoresChatterAroundTheFields() {
    let parsed = TopicPrompt.parse("""
    好的，这是我为你准备的选题：

    标题: 真正的那条
    摘要: 一句话

    希望对你有帮助！
    """)
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.title, "真正的那条")
  }

  /// 缺字段按默认值走,不丢这一条。
  func testMissingOptionalFieldsFallBack() {
    let parsed = TopicPrompt.parse("标题: 只有标题")
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.summary, "")
    XCTAssertEqual(parsed.first?.materialIndexes, [])
    XCTAssertFalse(parsed.first?.isOutOfBounds ?? true)
  }

  /// 标题为空的才丢。
  func testEntriesWithoutATitleAreDropped() {
    XCTAssertTrue(TopicPrompt.parse("摘要: 没有标题\n素材: 1").isEmpty)
    XCTAssertTrue(TopicPrompt.parse("").isEmpty)
    XCTAssertTrue(TopicPrompt.parse("完全不相干的一段话").isEmpty)
  }

  /// 素材编号写成各种样子都要认。
  func testMaterialIndexesTolerateFormatting() {
    XCTAssertEqual(TopicPrompt.parse("标题: a\n素材: 1、2、3").first?.materialIndexes, [1, 2, 3])
    XCTAssertEqual(TopicPrompt.parse("标题: a\n素材: 素材 1 和素材 4").first?.materialIndexes, [1, 4])
    XCTAssertEqual(TopicPrompt.parse("标题: a\n素材: 无").first?.materialIndexes, [])
  }
}

/// 取数规格。
final class TopicRecallTests: XCTestCase {
  private let day: Int64 = 24 * 60 * 60 * 1000
  private let now: Int64 = 1_700_000_000_000

  /// 两路而不是一路:碰撞需要距离。
  func testDefaultHasBothARecentAndADormantLane() {
    let windows = TopicRecall.default.lanes.map(\.window)
    XCTAssertTrue(windows.contains { if case .recent = $0 { true } else { false } })
    XCTAssertTrue(windows.contains { if case .dormant = $0 { true } else { false } })
  }

  /// 一次送进模型的素材不该太多——超过十几份它就开始逐份转述。
  func testDefaultKeepsTheMaterialCountSmall() {
    XCTAssertLessThanOrEqual(TopicRecall.default.lanes.reduce(0) { $0 + $1.limit }, 15)
  }

  func testRecentWindowLooksBackward() {
    let range = TopicRecall.range(for: .recent(days: 7), now: now)
    XCTAssertEqual(range.from, now - 7 * day)
    XCTAssertEqual(range.through, now)
  }

  /// 沉睡窗口没有下界:再老的东西同样算「翻出来的旧东西」。
  func testDormantWindowHasNoLowerBound() {
    let range = TopicRecall.range(for: .dormant(sinceDays: 30), now: now)
    XCTAssertEqual(range.from, 0)
    XCTAssertEqual(range.through, now - 30 * day)
  }

  /// 两个窗口不重叠。
  ///
  /// 重叠的话同一份素材会在两路里各出现一次,模型会以为它特别重要。
  func testDefaultLanesDoNotOverlap() {
    let lanes = TopicRecall.default.lanes
    let recent = try? XCTUnwrap(lanes.first { if case .recent = $0.window { true } else { false } })
    let dormant = try? XCTUnwrap(lanes.first { if case .dormant = $0.window { true } else { false } })
    guard let recent, let dormant else { return XCTFail("默认规格少了一路") }
    let a = TopicRecall.range(for: recent.window, now: now)
    let b = TopicRecall.range(for: dormant.window, now: now)
    XCTAssertLessThan(b.through, a.from, "两路窗口重叠了，同一份素材会被送两次")
  }

  func testNegativeDaysDoNotProduceFutureRanges() {
    let range = TopicRecall.range(for: .recent(days: -5), now: now)
    XCTAssertEqual(range.from, now)
    XCTAssertEqual(range.through, now)
  }
}

/// 候选。
final class TopicCandidateTests: XCTestCase {
  /// 「今天的选题」指的是用户日历上的今天,不是 UTC 的今天。
  func testDayStartUsesTheLocalCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try! XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    let date = try! XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 1))
    )
    let start = TopicCandidate.dayStart(of: date, calendar: calendar)
    // 东八区 8/2 凌晨 1 点属于 8/2，不是 UTC 下的 8/1。
    let expected = try! XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))
    )
    XCTAssertEqual(start, Int64(expected.timeIntervalSince1970 * 1000))
  }

  func testNewCandidatesStartPending() {
    let candidate = TopicCandidate(
      dayStartMilliseconds: 0, title: "t", summary: "s", createdAtMilliseconds: 1
    )
    XCTAssertEqual(candidate.verdict, .pending)
    XCTAssertFalse(candidate.isOutOfBounds)
  }
}
