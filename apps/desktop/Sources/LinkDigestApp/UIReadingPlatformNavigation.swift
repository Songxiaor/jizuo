import LinkDigestCore
import SwiftUI

/// 来源平台侧栏行：无常驻卡片底，只给选中项浅底高亮。
/// 计数仍由调用方传入实时 `navigationCounts`，本文件不改筛选或导航模型。
/// 2026-10-12（Syc 定）起挂在「自有 / 外部」下面，不再有单独的「来源」一组。
struct UIReadingPlatformNavigation: View {
  struct Item: Identifiable {
    let host: String
    let count: Int
    let faviconURL: URL?
    let faviconTaskID: TaskID?
    /// 悬停说明；nil 时用默认的「平台（N 条）」。同名两行口径不同时由调用方写清楚（2026-10-01）。
    var helpText: String? = nil
    /// 显示名；nil 时按 host 取平台名。本机来源用短名（「文件」「笔记」）。
    var title: String? = nil
    /// 列表 id。同一个 host 可能「自有」「外部」下各一行，两行的 id 必须不同。nil 时用 host。
    var rowID: String? = nil
    /// 无障碍标识；nil 时用 `history-navigation-platform-<host>`。侧栏滚动记忆靠它认行，同样不能重复。
    var identifier: String? = nil
    /// 没有平台图标的合成来源（笔记、作品）用系统符号，和原来侧栏那一行同一个图标。
    var systemImage: String? = nil
    var id: String { rowID ?? host }
  }

  let items: [Item]
  let theme: HistoryThemeTokens
  /// 参数是 `Item.id`。
  let isSelected: (String) -> Bool
  let onSelect: (String) -> Void
  /// 收起时常驻的行（`Item.id`）；nil 表示不折叠。其余收进「还有 N 个」，当前选中的一定露出，
  /// 否则选了一个折叠里的来源，侧栏却看不出选中了谁。
  var collapsedVisibleIDs: Set<String>? = nil
  var isExpanded: Binding<Bool> = .constant(true)
  var moreIdentifier = "history-navigation-platforms-more"

  private var visibleItems: [Item] {
    guard let collapsedVisibleIDs, !isExpanded.wrappedValue else { return items }
    return items.filter { collapsedVisibleIDs.contains($0.id) || isSelected($0.id) }
  }

  private var hiddenCount: Int { items.count - visibleItems.count }

  var body: some View {
    ForEach(visibleItems) { item in
      UIReadingPlatformRow(
        item: item,
        theme: theme,
        isSelected: isSelected(item.id),
        onSelect: { onSelect(item.id) }
      )
      .id(item.id)
    }
    if let collapsedVisibleIDs, items.count > collapsedVisibleIDs.count {
      Button {
        isExpanded.wrappedValue.toggle()
      } label: {
        // 箭头放在图标那一列、文字和平台名对齐（和平台行同样 8pt / 18pt）。
        HStack(spacing: 8) {
          // 展开/收起统一 chevron.right 转 90°（2026-10-01）；chevron.up/down 只留给翻条目，
          // 否则侧栏里这颗箭头和详情页「上一条/下一条」长得一样。
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            .frame(width: 18, height: 16)
          // 收起时说清还藏着几个（选中的那个已经露出来，不算在内）。
          Text(isExpanded.wrappedValue ? "收起" : "还有 \(hiddenCount) 个")
            .themedFont(.subheadline)
          Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, DesignTokens.Space.xs)
        .padding(.horizontal, DesignTokens.Space.sm)
        .frame(minHeight: 24)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, -6)
      .accessibilityIdentifier(moreIdentifier)
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

  /// 看见的、悬停说明和读屏念的都是这一个名字（2026-10-12（Syc 定））：原来读屏念全名，
  /// 杂项那一行屏幕上写「其他」、读屏念「待分类」，公众号念成「微信公众号」，同一行两个名字。
  private var name: String { item.title ?? HistoryPlatformDisplay.shortName(forHost: item.host) }

  var body: some View {
    Button(action: onSelect) {
      // 间距、图标框和主导航行一致（8pt / 18pt 宽）：原来 4pt / 16pt，
      // 来源这一组的文字比上面几组往左缩了一截（2026-09-25 走查）。
      HStack(spacing: 8) {
        Group {
          if let systemImage = item.systemImage {
            Image(systemName: systemImage)
              .font(.system(size: DesignTokens.IconSize.sidebar, weight: .regular))
          } else {
            PlatformNavigationIcon(
              host: item.host,
              faviconURL: item.faviconURL,
              faviconTaskID: item.faviconTaskID,
              monochrome: true
            )
          }
        }
        // 选中时显示平台自己的颜色；黑色系品牌用正文色，免得深色主题下看不见。
        .foregroundStyle(isSelected ? (PlatformIconCatalog.sidebarBrandColor(for: item.host) ?? theme.primaryText) : theme.secondaryText)
        .frame(width: 18, height: 16)
        .accessibilityHidden(true)
        Text(name)
          .themedFont(.body)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        // 数字列和主导航行（`countBadge`，左右各 6pt）对齐：原来只留 2pt，「自有」下
        // 笔记「3」和备忘录「740」、「形式」和「来源」两组的数字右缘差 4pt（2026-10-04 走查）。
        Text("\(item.count)")
          .themedFont(.subheadline, weight: isSelected ? .medium : .regular, monospacedDigit: true)
          .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
          .padding(.horizontal, 6)
      }
      .foregroundStyle(theme.primaryText)
      .padding(.vertical, DesignTokens.Space.xxs)
      .padding(.horizontal, DesignTokens.Space.sm)
      // 与主导航行同高（见 HistoryContentView.navigationButton）。
      .frame(minHeight: 24)
      .frame(maxWidth: .infinity)
      .background(
        isSelected ? theme.accent.opacity(0.12) : hoverFill,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
      )
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
    .help(item.helpText ?? "\(name)（\(item.count) 条）")
    .accessibilityLabel(name)
    .accessibilityValue("\(item.count) 条")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(item.identifier ?? "history-navigation-platform-\(item.host)")
  }

  private var hoverFill: Color {
    isHovering ? theme.primaryText.opacity(0.035) : .clear
  }
}
