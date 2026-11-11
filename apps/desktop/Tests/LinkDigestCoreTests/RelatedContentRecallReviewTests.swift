import XCTest
@testable import LinkDigestCore

/// 独立复核（汲作开发A）：用「相关内容」实际传给引擎的参数（limit 200、门槛 0.48、
/// 不套相对窗口）验证召回；同时钉住搜索界面的窗口行为没有跟着变。
final class RelatedContentRecallReviewTests: XCTestCase {
  private func index() -> SemanticIndex {
    // 2 维单位向量：与查询 (1,0) 的点积就是第一维。
    func entry(_ score: Float) -> SemanticIndex.Entry {
      .init(updatedAtMilliseconds: 1, vector: [score, (1 - score * score).squareRoot()])
    }
    var idx = SemanticIndex(modelID: "t", dimension: 2)
    idx.set("self-or-external-top", entry(0.90))   // 当前这条自身 / 外部强相关
    idx.set("own-memo", entry(0.70))               // 用户自己的备忘录，相关且高于 0.48 门槛
    return idx
  }

  /// 期望：自有备忘录 0.70 高于门槛，应当进入候选。
  ///
  /// 修法（2026-11-11）：「相关内容」在引擎里不套相对窗口，只按门槛 + 条数取；
  /// 搜索界面照旧按全局第一名卡 0.05，两边的调用参数分开。
  func testOwnMemoSurvivesWhenGlobalTopIsMuchHigher() {
    let ranked = index().ranked(query: [1, 0], limit: 200, minimumScore: 0.48)
    XCTAssertTrue(ranked.map(\.taskID).contains("own-memo"),
                  "0.70 高于门槛，不套相对窗口就该留下：\(ranked)")

    // 原来那组参数（搜索界面的 0.05 窗口）确实会把它滤掉——这正是相关内容要绕开的路径。
    let windowed = index().ranked(query: [1, 0], limit: 200, minimumScore: 0.48, relativeWindow: 0.05)
    XCTAssertFalse(windowed.map(\.taskID).contains("own-memo"), "搜索界面的窗口行为不变")
  }
}
