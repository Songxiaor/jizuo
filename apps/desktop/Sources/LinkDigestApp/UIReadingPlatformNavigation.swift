import LinkDigestCore
import SwiftUI

/// 来源平台侧栏行：无常驻卡片底，只给选中项浅底高亮。
/// 计数仍由调用方传入实时 `navigationCounts`，本文件不改筛选或导航模型。
struct UIReadingPlatformNavigation: View {
  struct Item: Identifiable {
    let host: String
    let count: Int
    let faviconURL: URL?
    let faviconTaskID: TaskID?
    var id: String { host }
  }

  let items: [Item]
  let theme: HistoryThemeTokens
  let isSelected: (String) -> Bool
  let onSelect: (String) -> Void

  private var orderedItems: [Item] {
    let order = ["X", "抖音", "微信公众号", "哔哩哔哩", "GitHub", "YouTube", "Discourse", "Reddit", "Substack", "小红书", "待分类"]
    return items.sorted {
      let left = order.firstIndex(of: HistoryPlatformDisplay.name(forHost: $0.host)) ?? order.count
      let right = order.firstIndex(of: HistoryPlatformDisplay.name(forHost: $1.host)) ?? order.count
      return left == right ? $0.host < $1.host : left < right
    }
  }

  var body: some View {
    ForEach(orderedItems) { item in
      UIReadingPlatformRow(
        item: item,
        theme: theme,
        isSelected: isSelected(item.host),
        onSelect: { onSelect(item.host) }
      )
      .id(item.host)
    }
  }
}

private struct UIReadingPlatformRow: View {
  let item: UIReadingPlatformNavigation.Item
  let theme: HistoryThemeTokens
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var fullName: String { HistoryPlatformDisplay.name(forHost: item.host) }
  private var name: String {
    switch fullName {
    case "微信公众号": "公众号"
    case "哔哩哔哩": "B站"
    case "待分类": "其他"
    default: fullName
    }
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: DesignTokens.Space.xs) {
        PlatformNavigationIcon(
          host: item.host,
          faviconURL: item.faviconURL,
          faviconTaskID: item.faviconTaskID
        )
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        Text(name)
          .themedFont(.body)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("\(item.count)")
          .themedFont(.caption, weight: .medium, monospacedDigit: true)
          .foregroundStyle(isSelected ? theme.accent : .secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(
            isSelected ? theme.accent.opacity(0.12) : theme.badge,
            in: Capsule()
          )
      }
      .foregroundStyle(theme.primaryText)
      .padding(.vertical, DesignTokens.Space.xs)
      .padding(.horizontal, DesignTokens.Space.sm)
      .frame(minHeight: 28)
      .frame(maxWidth: .infinity)
      .background(
        isSelected ? theme.accent.opacity(0.12) : hoverFill,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
      )
      .overlay(alignment: .leading) {
        if isSelected {
          Capsule()
            .fill(theme.accent)
            .frame(width: 3, height: 16)
            .padding(.leading, DesignTokens.Space.xxs)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, -6)
    .fontWeight(isSelected ? .semibold : .regular)
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .animation(reduceMotion ? nil : DesignTokens.Motion.instant, value: isSelected)
    .onHover { isHovering = $0 }
    .help("\(fullName)（\(item.count) 条）")
    .accessibilityLabel(fullName)
    .accessibilityValue("\(item.count) 条")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("history-navigation-platform-\(item.host)")
  }

  private var hoverFill: Color {
    isHovering ? theme.primaryText.opacity(0.035) : .clear
  }
}
