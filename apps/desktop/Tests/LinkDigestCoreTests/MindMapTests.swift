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

  // MARK: - 中心节点随标题长度自适应

  /// 这是修复的核心不变量：**文字必须待在框里**。
  ///
  /// 原来中心框宽度写死 250、标题完全不测量也不换行，
  /// 「Databricks编码基准测试核心结论」在 19pt 下约 317pt，直接印到框外。
  func testCenterTitleAlwaysFitsInsideItsBox() {
    for title in [
      "Databricks编码基准测试核心结论",
      "短标题",
      String(repeating: "长", count: MindMapOutline.maximumTitleCharacters),
      String(repeating: "Benchmark", count: 4),
    ] {
      let layout = MindMapLayout.compute(
        outline: .init(title: title, subtitle: nil, branches: [.init(title: "分支", leaves: ["要点"])])
      )
      let widest = layout.center.lines.prefix(layout.centerTitleLineCount)
        .map { MindMapLayout.textWidth($0, fontSize: 19) }.max() ?? 0
      XCTAssertLessThanOrEqual(
        widest + 48, layout.center.width,
        "标题「\(title)」比它的框还宽，会印到框外"
      )
    }
  }

  /// 换行后框要跟着长高，否则文字改成从框底溢出，问题只是换了个方向。
  func testCenterBoxGrowsTallerWhenTitleWraps() {
    let short = MindMapLayout.compute(
      outline: .init(title: "短", subtitle: nil, branches: [.init(title: "分支", leaves: ["要点"])])
    )
    let long = MindMapLayout.compute(
      outline: .init(
        title: String(repeating: "长", count: MindMapOutline.maximumTitleCharacters),
        subtitle: nil,
        branches: [.init(title: "分支", leaves: ["要点"])]
      )
    )
    XCTAssertEqual(short.centerTitleLineCount, 1)
    XCTAssertGreaterThan(long.centerTitleLineCount, 1)
    XCTAssertGreaterThan(long.center.height, short.center.height)
  }

  /// 短标题不该把框缩成小方块，也不该长到撞上分支列。
  func testCenterBoxStaysWithinItsWidthBounds() {
    for title in ["短", String(repeating: "长", count: MindMapOutline.maximumTitleCharacters)] {
      let layout = MindMapLayout.compute(
        outline: .init(title: title, subtitle: nil, branches: [.init(title: "分支", leaves: ["要点"])])
      )
      XCTAssertGreaterThanOrEqual(layout.center.width, MindMapLayout.centerMinWidth)
      XCTAssertLessThan(
        layout.center.x + layout.center.width, MindMapLayout.branchX,
        "中心框顶到了分支列上"
      )
    }
  }

  /// 换行不设行数上限：硬切两行只是把溢出从第一行搬到第二行。
  func testWrappingNeverLeavesAnOverlongLine() {
    let text = String(repeating: "长", count: 60)
    for line in MindMapLayout.wrapped(text, limit: 100, fontSize: 13) {
      XCTAssertLessThanOrEqual(MindMapLayout.textWidth(line, fontSize: 13), 100 + 13)
    }
    XCTAssertEqual(MindMapLayout.wrapped(text, limit: 100, fontSize: 13).joined(), text)
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
