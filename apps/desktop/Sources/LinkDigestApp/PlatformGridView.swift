import LinkDigestCore
import SwiftUI

/// 侧栏「平台」分组的网格排布。
///
/// 从「一平台一行」换成三列网格：平台数量固定（当前 7 个），每行只放一个
/// 图标加一个名字，纵向要占掉七行，而侧栏下面还有标签云。图标本身就是
/// 平台最强的识别符号——X、抖音、B 站的 logo 比它们的中文名认得更快——
/// 名字只在悬停时给出。
///
/// 计数没有丢，做成右上角标：它是「这个平台有多少条」，属于次要信息，
/// 但抓完东西想确认有没有进来时又必须看得见。
struct PlatformGridView: View {
  struct Item: Identifiable {
    let host: String
    let count: Int
    var id: String { host }
  }

  let items: [Item]
  let theme: HistoryThemeTokens
  let isSelected: (String) -> Bool
  let onSelect: (String) -> Void

  /// 三列。四列会让每格窄到装不下角标，两列又回到接近列表的密度。
  private let columns = [
    GridItem(.flexible(), spacing: DesignTokens.Space.xs),
    GridItem(.flexible(), spacing: DesignTokens.Space.xs),
    GridItem(.flexible(), spacing: DesignTokens.Space.xs),
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: DesignTokens.Space.xs) {
      ForEach(items) { item in
        PlatformGridCell(
          item: item,
          theme: theme,
          isSelected: isSelected(item.host),
          onSelect: { onSelect(item.host) }
        )
      }
    }
    .padding(.vertical, DesignTokens.Space.xxs)
  }
}

private struct PlatformGridCell: View {
  let item: PlatformGridView.Item
  let theme: HistoryThemeTokens
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var name: String { HistoryPlatformDisplay.name(forHost: item.host) }

  var body: some View {
    Button(action: onSelect) {
      // 角标贴住图标本身，不是贴住格子。
      //
      // 第一版把它挂在 40pt 高格子的右上角，而图标在格子正中，两者之间空出
      // 一截，角标看起来像飘在旁边的另一个东西。ZStack 收到图标的尺寸上，
      // 它才读得出"这是这个平台的条数"。
      ZStack(alignment: .topTrailing) {
        // 方形而不是圆形容器——平台 logo 形状各异，圆形裁切会切掉 X 那种
        // 方形标记的边角。
        PlatformNavigationIcon(host: item.host)
          .frame(width: 22, height: 22)

        if item.count > 0 {
          Text("\(item.count)")
            .font(.system(size: BadgeTypography.size, weight: .semibold).monospacedDigit())
            .foregroundStyle(isSelected ? theme.selectionFill : theme.primaryText.opacity(0.75))
            .padding(.horizontal, 3)
            .frame(minWidth: 13, minHeight: 13)
            .background(
              Capsule()
                // 不用 `theme.badge`：阶段 3 把 canvas 压低之后，那个色号
                // （#E8E6DC）和新的侧栏底（#EFEDE5）只差几级灰，角标背景
                // 等于隐形，屏幕上只剩一个数字浮在图标旁边。
                .fill(isSelected ? theme.selectionText : theme.primaryText.opacity(0.13))
                // 描边让角标从图标上"浮"起来，压在 logo 边缘时也不糊在一起。
                .overlay(Capsule().strokeBorder(cellBackground, lineWidth: 1.5))
            )
            .offset(x: 9, y: -7)
        }
      }
      .frame(height: 38)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
          .fill(cellBackground)
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
    // 图标格子没有可见文字，名称必须另外给：tooltip 给鼠标，label 给 VoiceOver。
    .help(item.count > 0 ? "\(name)（\(item.count) 条）" : name)
    .accessibilityLabel(name)
    .accessibilityValue("\(item.count) 条")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("history-navigation-platform-\(item.host)")
  }

  /// 格子底色。角标的描边也用它，这样描边在选中／悬停／静止三种状态下
  /// 都恰好"挖掉"角标周围一圈，而不是画出一道突兀的白边。
  private var cellBackground: Color {
    if isSelected { return theme.selectionFill }
    return isHovering ? theme.primaryText.opacity(0.06) : theme.canvas
  }
}
