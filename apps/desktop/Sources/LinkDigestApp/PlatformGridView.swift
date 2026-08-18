import LinkDigestCore
import SwiftUI

/// 侧栏「平台」分组。
///
/// 类型名保留 `PlatformGridView`，避免把这次视觉调整扩大成无意义的调用链改名；
/// 实际呈现已从无文字的三列图标网格收拢为紧凑列表。平台筛选不是启动器，名称
/// 不能只藏在 tooltip 里：图标负责扫视，文字负责确认，数量负责反馈抓取结果。
struct PlatformGridView: View {
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

  var body: some View {
    VStack(spacing: DesignTokens.Space.xxs) {
      ForEach(items) { item in
        PlatformNavigationRow(
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

private struct PlatformNavigationRow: View {
  let item: PlatformGridView.Item
  let theme: HistoryThemeTokens
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var name: String { HistoryPlatformDisplay.name(forHost: item.host) }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: DesignTokens.Space.sm) {
        PlatformNavigationIcon(
          host: item.host,
          faviconURL: item.faviconURL,
          faviconTaskID: item.faviconTaskID
        )
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)
        Text(name)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: DesignTokens.Space.xs)
        if item.count > 0 {
          Text("\(item.count)")
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
            .padding(.horizontal, DesignTokens.Space.xs + DesignTokens.Space.xxs)
            .padding(.vertical, DesignTokens.Space.xxs)
            .background(
              isSelected ? theme.accent.opacity(0.12) : theme.badge,
              in: Capsule()
            )
        }
      }
      .font(.callout)
      .foregroundStyle(theme.primaryText)
      .padding(.horizontal, DesignTokens.Space.sm)
      .frame(height: 30)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
          .fill(rowBackground)
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
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
    .help(item.count > 0 ? "\(name)（\(item.count) 条）" : name)
    .accessibilityLabel(name)
    .accessibilityValue("\(item.count) 条")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("history-navigation-platform-\(item.host)")
  }

  private var rowBackground: Color {
    if isSelected { return theme.accent.opacity(0.10) }
    if isHovering { return theme.primaryText.opacity(0.035) }
    return .clear
  }
}
