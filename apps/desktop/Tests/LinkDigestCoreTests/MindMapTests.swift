import XCTest
@testable import LinkDigestCore

final class MindMapTests: XCTestCase {
  private let sample = MindMapOutline(
    title: "Galaxy Z Fold8",
    subtitle: "首发体验",
    branches: [
      .init(title: "外观与手感", leaves: ["折叠态 9.7mm", "201g 同品类最轻", "磨砂玻璃背板"]),
      .init(title: "屏幕", leaves: ["内屏 4:3", "折痕收敛"]),
    ]
  )

  // MARK: - 模型输出解析

  func testParsesFencedJSONAndClampsExcess() throws {
    let branches = (0 ..< 12).map { index in
      "{\"title\":\"分支\(index)\",\"leaves\":[\"要点\"]}"
    }.joined(separator: ",")
    let raw = """
    ```json
    {"title":"主题","subtitle":"来源","branches":[\(branches)]}
    ```
    """
    let outline = try MindMapOutline.fromModelOutput(raw)
    XCTAssertEqual(outline.title, "主题")
    XCTAssertEqual(outline.branches.count, MindMapOutline.maximumBranches)
  }

  func testRejectsNonJSONAndEmptyOutline() {
    XCTAssertThrowsError(try MindMapOutline.fromModelOutput("抱歉，我无法生成。")) {
      XCTAssertEqual($0 as? MindMapOutlineError, .invalidJSON)
    }
    XCTAssertThrowsError(try MindMapOutline.fromModelOutput(#"{"title":"","branches":[]}"#)) {
      XCTAssertEqual($0 as? MindMapOutlineError, .emptyOutline)
    }
  }

  func testTagsParseClampAndDedupe() throws {
    let raw = """
    {"title":"主题","branches":[{"title":"分支","leaves":["要点"]}],
     "tags":["Agent 工程","agent 工程","折叠屏","Claude Code","效率","知识管理","第七个"]}
    """
    let outline = try MindMapOutline.fromModelOutput(raw)
    // 大小写去重 + 上限 5 个。
    XCTAssertEqual(outline.tags, ["Agent 工程", "折叠屏", "Claude Code", "效率", "知识管理"])
    // 旧存档没有 tags 键：解码为 nil，不影响渲染。
    let legacy = try MindMapOutline.fromModelOutput(
      #"{"title":"主题","branches":[{"title":"分支","leaves":["要点"]}]}"#
    )
    XCTAssertNil(legacy.tags)
  }

  func testMindMapPromptDemandsTopicTagsAndForbidsSectionNames() {
    let prompt = MindMapPrompt.system
    XCTAssertTrue(prompt.contains("tags"))
    XCTAssertTrue(prompt.contains("跨文章"))
    XCTAssertTrue(prompt.contains("严禁使用分支标题"))
  }

  func testOverlongLeafTruncatesWithEllipsis() throws {
    let long = String(repeating: "长", count: 80)
    let outline = try MindMapOutline.fromModelOutput(
      #"{"title":"主题","branches":[{"title":"分支","leaves":["\#(long)"]}]}"#
    )
    let leaf = outline.branches[0].leaves[0]
    XCTAssertEqual(leaf.count, MindMapOutline.maximumLeafCharacters)
    XCTAssertTrue(leaf.hasSuffix("…"))
  }

  // MARK: - 布局

  func testLayoutStacksBranchGroupsWithoutOverlap() {
    let layout = MindMapLayout.compute(outline: sample)
    XCTAssertEqual(layout.branches.count, 2)
    XCTAssertEqual(layout.leaves.map(\.count), [3, 2])
    // 分支组自上而下排列，叶子不重叠。
    let allLeaves = layout.leaves.flatMap { $0 }
    for (index, leaf) in allLeaves.enumerated() where index > 0 {
      XCTAssertGreaterThanOrEqual(leaf.y, allLeaves[index - 1].y + allLeaves[index - 1].height)
    }
    // 画布覆盖全部节点。
    for leaf in allLeaves {
      XCTAssertLessThanOrEqual(leaf.x + leaf.width, layout.canvasWidth)
      XCTAssertLessThanOrEqual(leaf.y + leaf.height, layout.canvasHeight)
    }
    XCTAssertEqual(layout.centerEdges.count, 2)
  }

  // MARK: - 渲染

  func testRendererEmitsTextsThemeColorsAndEscapes() {
    let outline = MindMapOutline(
      title: "A & B <测试>",
      subtitle: nil,
      branches: [.init(title: "分支", leaves: ["要点"])]
    )
    let svg = MindMapSVGRenderer.render(outline: outline, theme: .darkCode)
    XCTAssertTrue(svg.contains("A &amp; B &lt;测试&gt;"))
    XCTAssertTrue(svg.contains(MindMapTheme.darkCode.background))
    XCTAssertTrue(svg.contains("分支"))
    XCTAssertFalse(svg.contains("<测试>"))

    // 同一大纲换主题即换风格，结构文本不变。
    let light = MindMapSVGRenderer.render(outline: outline, theme: .minimalLight)
    XCTAssertTrue(light.contains(MindMapTheme.minimalLight.background))
    XCTAssertTrue(light.contains("要点"))
  }

  func testThemeLookupFallsBackToMinimalLight() {
    XCTAssertEqual(MindMapTheme.named("不存在").id, MindMapTheme.minimalLight.id)
    XCTAssertEqual(MindMapTheme.named("dark-code").id, "dark-code")
  }
}
