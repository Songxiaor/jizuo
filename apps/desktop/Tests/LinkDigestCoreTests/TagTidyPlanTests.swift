import XCTest
@testable import LinkDigestCore

/// 「AI 整理标签」方案：模型输出不可信，解析和过滤全在代码里。
final class TagTidyPlanTests: XCTestCase {
  private func nav(_ pairs: [(String, Int)]) -> [HistoryNavigationTag] {
    pairs.map { HistoryNavigationTag(tag: HistoryTag(rawValue: $0.0)!, count: $0.1) }
  }

  private let sample: [(String, Int)] = [("AI工具", 5), ("人工智能工具", 3), ("Swift", 4), ("灵感", 9), ("真人口播", 6), ("已使用", 7)]

  func testUserContentHasOnlyNamesAndCountsAndNoReservedTags() {
    let content = TagTidyPrompt.userContent(tags: nav(sample))
    XCTAssertEqual(content, "AI工具\t5\nSwift\t4\n人工智能工具\t3")
    XCTAssertFalse(content.contains("灵感"))
    XCTAssertFalse(content.contains("真人口播"))
  }

  func testParseKeepsRealTagsAndDropsNonexistentOnes() throws {
    let raw = #"{"merges":[{"target":"AI 工具","sources":["AI工具","人工智能工具","根本不存在"]}],"frequent":["AI 工具","Swift","编造的"]}"#
    let plan = try TagTidyPrompt.parse(raw, tags: nav(sample))
    XCTAssertEqual(plan.merges.count, 1)
    XCTAssertEqual(plan.merges[0].sources, ["AI工具", "人工智能工具"])
    XCTAssertEqual(plan.merges[0].sourceCounts, [5, 3])
    XCTAssertEqual(plan.merges[0].affectedItemCount, 8)
    XCTAssertEqual(plan.frequent, ["AI 工具", "Swift"], "不存在的标签不进常用表")
  }

  func testParseFiltersReservedTagsEvenIfModelReturnsThem() throws {
    let raw = #"{"merges":[{"target":"灵感","sources":["Swift"]},{"target":"开发","sources":["Swift","灵感","真人口播","已使用"]}],"frequent":["灵感","真人口播","Swift"]}"#
    let plan = try TagTidyPrompt.parse(raw, tags: nav(sample))
    XCTAssertEqual(plan.merges.count, 1, "目标是保留标签的组整组丢弃")
    XCTAssertEqual(plan.merges[0].target, "开发")
    XCTAssertEqual(plan.merges[0].sources, ["Swift"], "保留标签不能作为来源")
    XCTAssertEqual(plan.frequent, ["开发"], "被并走的旧名在常用表里换成新名；保留标签不进表")
  }

  func testEnabledMergesDropsDisabledGroupsAndProtectedTargets() {
    var plan = TagTidyPlan(merges: [
      .init(id: 0, target: "AI 工具", sources: ["AI工具"], sourceCounts: [5]),
      .init(id: 1, target: "开发", sources: ["Swift"], sourceCounts: [4], isEnabled: false),
      .init(id: 2, target: "  ", sources: ["x"], sourceCounts: [1]),
    ], frequent: [])
    XCTAssertEqual(plan.enabledMerges().count, 1)
    plan.merges[0].target = "真人口播"   // 用户把名字改成了保留标签
    XCTAssertTrue(plan.enabledMerges().isEmpty)
  }

  func testInvalidResponsesBecomePlainErrors() {
    XCTAssertThrowsError(try TagTidyPrompt.parse("抱歉我做不到", tags: nav(sample))) {
      XCTAssertEqual($0 as? TagTidyError, .invalidResponse)
    }
    XCTAssertThrowsError(try TagTidyPrompt.parse("{\"merges\":[],\"frequent\":[]}", tags: nav(sample))) {
      XCTAssertEqual($0 as? TagTidyError, .emptyPlan)
    }
    XCTAssertFalse(TagTidyError.invalidResponse.userMessage.isEmpty)
  }

  func testParseToleratesCodeFencesAndDuplicateSources() throws {
    let raw = "```json\n{\"merges\":[{\"target\":\"A\",\"sources\":[\"Swift\"]},{\"target\":\"B\",\"sources\":[\"Swift\",\"AI工具\"]}],\"frequent\":[]}\n```"
    let plan = try TagTidyPrompt.parse(raw, tags: nav(sample))
    XCTAssertEqual(plan.merges.map(\.sources), [["Swift"], ["AI工具"]], "一个旧标签只出现在一组")
  }

  func testPromptSizeEstimatorCountsCJKPerCharacter() {
    XCTAssertEqual(PromptSizeEstimator.estimatedTokens("标签整理"), 4)
    XCTAssertEqual(PromptSizeEstimator.estimatedTokens("abcd"), 2)
  }

  func testResolvedFrequentFollowsFullMergeChainAndRenames() {
    let plan = TagTidyPlan(merges: [
      .init(id: 0, target: "B", sources: ["A"], sourceCounts: [1]),
      .init(id: 1, target: "C新", sources: ["B"], sourceCounts: [1]),
      .init(id: 2, target: "D", sources: ["X"], sourceCounts: [1]),
    ], frequent: ["A", "B", "C", "X", "Y"])
    // 第二组的目标原名是 C，用户改成了「C新」。
    XCTAssertEqual(plan.resolvedFrequent(originalTargets: [0: "B", 1: "C", 2: "D"]), ["C新", "C新", "C新", "D", "Y"])
  }

  func testResolvedFrequentIgnoresDisabledGroups() {
    var plan = TagTidyPlan(merges: [
      .init(id: 0, target: "B", sources: ["A"], sourceCounts: [1]),
      .init(id: 1, target: "C", sources: ["B"], sourceCounts: [1], isEnabled: false),
    ], frequent: ["A", "B"])
    XCTAssertEqual(plan.resolvedFrequent(originalTargets: [0: "B", 1: "C"]), ["B", "B"], "被取消的组不参与链")
    plan.merges[0].isEnabled = false
    XCTAssertEqual(plan.resolvedFrequent(originalTargets: [:]), ["A", "B"])
  }
}
