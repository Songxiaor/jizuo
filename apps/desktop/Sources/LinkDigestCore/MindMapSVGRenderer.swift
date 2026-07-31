import Foundation

/// Deterministic left-to-right tree layout: center node on the left, branch
/// column in the middle, leaf column on the right. All geometry derives from
/// character counts, so rendering needs no font machinery and is testable.
public struct MindMapLayout: Sendable, Equatable {
  public struct Node: Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public let lines: [String]
  }
  public struct Edge: Sendable, Equatable {
    public let fromX: Double, fromY: Double, toX: Double, toY: Double
  }

  public let canvasWidth: Double
  public let canvasHeight: Double
  public let center: Node
  /// `center.lines` 里属于标题的行数；其后的一行（若有）是副标题。标题现在可能
  /// 换行，所以两者的边界不能再靠「第 0 行是标题」这个约定。
  public let centerTitleLineCount: Int
  public let branches: [Node]
  public let leaves: [[Node]]
  public let centerEdges: [Edge]
  public let leafEdges: [[Edge]]

  // Fixed metrics tuned against the approved samples.
  static let leftMargin = 60.0
  /// 中心节点的**下限**宽度，短标题仍保持这个体量，不会缩成一个小方块。
  static let centerMinWidth = 250.0
  /// 中心标题的文字宽度上限。
  ///
  /// 原来中心框宽度写死 250 且标题完全不测量、不换行，于是标题一长就直接印到框
  /// 外——「Databricks编码基准测试核心结论」在 19pt 下实测约 317pt，溢出 115pt。
  /// 分支和叶子早就是「量一量，超了就换行」，只有中心节点漏掉了。
  ///
  /// 上限取 300：加左右各 24 的内边距后最宽 348，右边缘落在 408，距分支列
  /// （`branchX` = 420）仍留得下连线，不会撞上去。
  static let centerMaxTextWidth = 300.0
  static let centerHeight = 86.0
  static let centerLineHeight = 26.0
  static let branchX = 420.0
  static let branchHeight = 48.0
  static let leafX = 650.0
  static let leafHeight = 34.0
  static let leafLineHeight = 22.0
  static let leafGap = 14.0
  static let branchGap = 56.0
  static let topMargin = 58.0
  static let bottomMargin = 40.0
  /// Approximate glyph advance: CJK ≈ 13pt at font 13, Latin ≈ 7.4pt.
  static func textWidth(_ text: String, fontSize: Double) -> Double {
    text.reduce(0) { $0 + ($1.isASCII ? fontSize * 0.57 : fontSize * 1.0) }
  }

  public static func compute(outline: MindMapOutline) -> MindMapLayout {
    let maxLeafTextWidth = 340.0
    var branchNodes: [Node] = []
    var leafColumns: [[Node]] = []
    var y = topMargin

    // First pass: stack each branch group (branch + its leaves) vertically.
    for branch in outline.branches {
      var leafNodes: [Node] = []
      var leafY = y
      for leaf in branch.leaves {
        let lines = wrapped(leaf, limit: maxLeafTextWidth, fontSize: 13)
        let height = leafHeight + Double(lines.count - 1) * leafLineHeight
        let width = min(
          maxLeafTextWidth + 32,
          (lines.map { textWidth($0, fontSize: 13) }.max() ?? 0) + 32
        )
        leafNodes.append(.init(x: leafX, y: leafY, width: width, height: height, lines: lines))
        leafY += height + leafGap
      }
      let groupHeight = max(branchHeight, leafY - leafGap - y)
      let branchWidth = textWidth(branch.title, fontSize: 15) + 48
      let branchNode = Node(
        x: branchX,
        y: y + groupHeight / 2 - branchHeight / 2,
        width: max(150, branchWidth),
        height: branchHeight,
        lines: [branch.title]
      )
      branchNodes.append(branchNode)
      leafColumns.append(leafNodes)
      y += groupHeight + branchGap
    }
    let contentBottom = y - branchGap
    let canvasHeight = max(360, contentBottom + bottomMargin)

    // 中心节点跟叶子用同一套办法：先按上限换行，再按实际最宽的一行收窄，
    // 高度随行数增长。短标题得到一个紧凑的框，长标题换行而不是印到框外。
    let titleLines = wrapped(outline.title, limit: centerMaxTextWidth, fontSize: 19)
    let centerTextWidth = titleLines.map { textWidth($0, fontSize: 19) }.max() ?? 0
    let centerNodeWidth = max(centerMinWidth, min(centerMaxTextWidth, centerTextWidth) + 48)
    let centerNodeHeight = centerHeight + Double(titleLines.count - 1) * centerLineHeight
    let centerNode = Node(
      x: leftMargin,
      y: canvasHeight / 2 - centerNodeHeight / 2,
      width: centerNodeWidth,
      height: centerNodeHeight,
      lines: titleLines + (outline.subtitle.map { [$0] } ?? [])
    )
    let centerEdges = branchNodes.map { branch in
      Edge(
        fromX: centerNode.x + centerNode.width, fromY: centerNode.y + centerNode.height / 2,
        toX: branch.x, toY: branch.y + branch.height / 2
      )
    }
    let leafEdges = zip(branchNodes, leafColumns).map { branch, leafNodes in
      leafNodes.map { leaf in
        Edge(
          fromX: branch.x + branch.width, fromY: branch.y + branch.height / 2,
          toX: leaf.x, toY: leaf.y + leaf.height / 2
        )
      }
    }
    let canvasWidth = (leafColumns.flatMap { $0 }.map { $0.x + $0.width }.max() ?? 1_000) + 60
    return MindMapLayout(
      canvasWidth: max(1_000, canvasWidth),
      canvasHeight: canvasHeight,
      center: centerNode,
      centerTitleLineCount: titleLines.count,
      branches: branchNodes,
      leaves: leafColumns,
      centerEdges: centerEdges,
      leafEdges: leafEdges
    )
  }

  /// 贪心逐字换行，行数不设上限。
  ///
  /// 原来硬切成最多两行，多出来的一律塞进第二行——那一行想多长就多长，照样溢出。
  /// 叶子有 42 字上限，两行基本够用所以没暴露；中心标题上限 40 字、字号 19，两行
  /// 装不下，硬切就等于把问题从「一行溢出」搬成「第二行溢出」。切到装得下为止才是
  /// 真的换行。
  static func wrapped(_ text: String, limit: Double, fontSize: Double) -> [String] {
    guard textWidth(text, fontSize: fontSize) > limit else { return [text] }
    var lines: [String] = []
    var current = ""
    var width = 0.0
    for character in text {
      let advance = character.isASCII ? fontSize * 0.57 : fontSize
      // 单字就超限时仍要放进去，否则这一行永远填不满，循环白转。
      if !current.isEmpty, width + advance > limit {
        lines.append(current)
        current = ""
        width = 0
      }
      current.append(character)
      width += advance
    }
    if !current.isEmpty { lines.append(current) }
    return lines.isEmpty ? [text] : lines
  }
}

/// Visual identity of a rendered map. Values are lifted from the two approved
/// style samples; adding a theme means adding one value table, never touching
/// layout.
public struct MindMapTheme: Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let background: String
  public let fontFamily: String
  public let centerFill: String, centerStroke: String
  public let centerTitleColor: String, centerSubtitleColor: String
  public let branchFills: [String], branchStrokes: [String], branchTitleColors: [String]
  public let leafFill: String, leafStroke: String, leafTextColor: String
  public let linkColor: String
  public let watermarkColor: String

  public static let minimalLight = MindMapTheme(
    id: "minimal-light",
    displayName: "极简浅色",
    background: "#fafaf8",
    fontFamily: "'PingFang SC', 'Hiragino Sans GB', -apple-system, sans-serif",
    centerFill: "#ffffff", centerStroke: "#d4d4d0",
    centerTitleColor: "#1a1a18", centerSubtitleColor: "#8a8a85",
    branchFills: ["#ffffff"], branchStrokes: ["#e2e2de"], branchTitleColors: ["#2a2a28"],
    leafFill: "#f5f5f2", leafStroke: "none", leafTextColor: "#55554f",
    linkColor: "#c8c8c2",
    watermarkColor: "#a0a09a"
  )

  public static let darkCode = MindMapTheme(
    id: "dark-code",
    displayName: "暗色代码风",
    background: "#020617",
    fontFamily: "'JetBrains Mono', ui-monospace, Menlo, 'PingFang SC', monospace",
    centerFill: "rgba(15,23,42,0.8)", centerStroke: "#34d399",
    centerTitleColor: "#ffffff", centerSubtitleColor: "#94a3b8",
    branchFills: [
      "rgba(8,51,68,0.5)", "rgba(6,78,59,0.5)", "rgba(76,29,149,0.45)", "rgba(120,53,15,0.4)",
    ],
    branchStrokes: ["#22d3ee", "#34d399", "#a78bfa", "#fbbf24"],
    branchTitleColors: ["#22d3ee", "#34d399", "#a78bfa", "#fbbf24"],
    leafFill: "rgba(15,23,42,0.6)", leafStroke: "#1e293b", leafTextColor: "#cbd5e1",
    linkColor: "#334155",
    watermarkColor: "#475569"
  )

  public static let all: [MindMapTheme] = [.minimalLight, .darkCode]

  public static func named(_ id: String) -> MindMapTheme {
    all.first { $0.id == id } ?? .minimalLight
  }
}

public enum MindMapSVGRenderer {
  public static func render(outline: MindMapOutline, theme: MindMapTheme) -> String {
    let layout = MindMapLayout.compute(outline: outline)
    var svg = """
    <svg viewBox="0 0 \(Int(layout.canvasWidth)) \(Int(layout.canvasHeight))" \
    width="\(Int(layout.canvasWidth))" height="\(Int(layout.canvasHeight))" \
    xmlns="http://www.w3.org/2000/svg">
    <style>svg { font-family: \(theme.fontFamily); }</style>
    <rect width="\(Int(layout.canvasWidth))" height="\(Int(layout.canvasHeight))" fill="\(theme.background)"/>
    """

    for edge in layout.centerEdges { svg += curve(edge, color: theme.linkColor) }
    for edges in layout.leafEdges { for edge in edges { svg += curve(edge, color: theme.linkColor) } }

    // Center node.
    let center = layout.center
    svg += rect(center, fill: theme.centerFill, stroke: theme.centerStroke, strokeWidth: 1.5, radius: 10)
    let titleLineCount = layout.centerTitleLineCount
    for (index, line) in center.lines.prefix(titleLineCount).enumerated() {
      svg += text(
        escaped(line),
        x: center.x + 24,
        y: center.y + 38 + Double(index) * MindMapLayout.centerLineHeight,
        size: 19, weight: "700", color: theme.centerTitleColor
      )
    }
    // 副标题跟在标题最后一行下方，不再固定在第二行的位置。
    if center.lines.count > titleLineCount {
      svg += text(
        escaped(center.lines[titleLineCount]),
        x: center.x + 24,
        y: center.y + 64 + Double(titleLineCount - 1) * MindMapLayout.centerLineHeight,
        size: 11, weight: "400", color: theme.centerSubtitleColor
      )
    }

    for (index, branch) in layout.branches.enumerated() {
      let fill = theme.branchFills[index % theme.branchFills.count]
      let stroke = theme.branchStrokes[index % theme.branchStrokes.count]
      let titleColor = theme.branchTitleColors[index % theme.branchTitleColors.count]
      svg += rect(branch, fill: fill, stroke: stroke, strokeWidth: 1, radius: 8)
      svg += text(escaped(branch.lines.first ?? ""), x: branch.x + 24, y: branch.y + 30, size: 15, weight: "600", color: titleColor)
      for leaf in layout.leaves[index] {
        svg += rect(leaf, fill: theme.leafFill, stroke: theme.leafStroke, strokeWidth: 1, radius: 6)
        for (lineIndex, line) in leaf.lines.enumerated() {
          svg += text(
            escaped(line),
            x: leaf.x + 16,
            y: leaf.y + 22 + Double(lineIndex) * MindMapLayout.leafLineHeight,
            size: 13, weight: "400", color: theme.leafTextColor
          )
        }
      }
    }
    svg += "</svg>"
    return svg
  }

  private static func rect(
    _ node: MindMapLayout.Node, fill: String, stroke: String, strokeWidth: Double, radius: Double
  ) -> String {
    let strokeAttr = stroke == "none" ? "" : " stroke=\"\(stroke)\" stroke-width=\"\(strokeWidth)\""
    return "<rect x=\"\(Int(node.x))\" y=\"\(Int(node.y))\" width=\"\(Int(node.width))\" height=\"\(Int(node.height))\" rx=\"\(Int(radius))\" fill=\"\(fill)\"\(strokeAttr)/>\n"
  }

  private static func text(
    _ value: String, x: Double, y: Double, size: Double, weight: String, color: String
  ) -> String {
    "<text x=\"\(Int(x))\" y=\"\(Int(y))\" font-size=\"\(Int(size))\" font-weight=\"\(weight)\" fill=\"\(color)\">\(value)</text>\n"
  }

  private static func curve(_ edge: MindMapLayout.Edge, color: String) -> String {
    let midX = (edge.fromX + edge.toX) / 2
    return "<path d=\"M\(Int(edge.fromX)) \(Int(edge.fromY)) C \(Int(midX)) \(Int(edge.fromY)), \(Int(midX)) \(Int(edge.toY)), \(Int(edge.toX)) \(Int(edge.toY))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.2\"/>\n"
  }

  private static func escaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
