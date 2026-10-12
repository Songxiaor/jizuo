import LinkDigestCore
import SwiftUI

/// 列表列头的「显示」菜单：只看某一种形式（2026-10-12（Syc 定），照「照片」的「显示：全部项目 ▾」）。
///
/// 原来「形式」是侧栏一组，点了会把侧栏别的选择清掉，「外部里的视频」看不了。现在它和侧栏是
/// 「且」：侧栏选什么都行，这里再按形式收窄；换侧栏时留着。按钮上一直写着当前形式，
/// 不是「全部」时着强调色，筛选不会藏起来。菜单里每种形式后面的数是当前侧栏选择里的条数，
/// 0 条的不列（正选着的那种例外，免得选中项凭空消失）。
struct ListFormFilterMenu: View {
  var model: HistoryViewModel
  let theme: HistoryThemeTokens
  var accessibilityPrefix = "history-list-form"

  /// 菜单里的形式。「笔记」也列：它是备忘录、自己写的笔记这类东西的形式，按当前选择数，
  /// 在「外部」里自然是 0、不出现；原来侧栏把它藏起来，是怕和「自有 → 笔记」同名不同数挤在一处。
  static func menuItems(counts: [HistoryNavigationForm], selected: ContentForm?) -> [HistoryNavigationForm] {
    var items = counts.filter { $0.count > 0 }
    if let selected, !items.contains(where: { $0.form == selected }) {
      items.append(.init(form: selected, count: 0))
    }
    let order = ContentForm.allCases
    return items.sorted { (order.firstIndex(of: $0.form) ?? 0) < (order.firstIndex(of: $1.form) ?? 0) }
  }

  private var selection: Binding<ContentForm?> {
    Binding(get: { model.selectedForm }, set: { model.selectForm($0) })
  }

  var body: some View {
    let current = model.selectedForm
    let active = current != nil
    Menu {
      Picker("显示", selection: selection) {
        Label("全部形式", systemImage: "square.stack").tag(ContentForm?.none)
          .accessibilityIdentifier("\(accessibilityPrefix)-all")
        Divider()
        ForEach(Self.menuItems(counts: model.listFormCounts, selected: current), id: \.form) { item in
          Label("\(item.form.rawValue)  \(item.count)", systemImage: item.form.systemImage)
            .tag(Optional(item.form))
            .accessibilityIdentifier("\(accessibilityPrefix)-\(item.form.rawValue)")
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      // 没选形式时写「全部形式」，不写「全部」：侧栏「全部」那一行常常正亮着，同一个词不说两遍。
      // 文字和小箭头拼成一个 Text：分成两个视图时，读屏把它当成两个同名的菜单按钮各念一遍。
      Text("\(current?.rawValue ?? "全部形式") \(Image(systemName: "chevron.down"))")
        .lineLimit(1)
        .imageScale(.small)
      .themedFont(.subheadline, weight: active ? .semibold : .medium)
      .foregroundStyle(active ? theme.accent : theme.secondaryText)
      .padding(.horizontal, DesignTokens.Space.sm)
      .padding(.vertical, 2)
      .background(
        Capsule().fill(active ? theme.accent.opacity(0.12) : Color.clear)
      )
      .overlay(
        Capsule().strokeBorder(active ? theme.accent.opacity(0.45) : theme.primaryText.opacity(0.15))
      )
      .contentShape(Capsule())
      .accessibilityElement(children: .combine)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(current.map { "只看「\($0.rawValue)」。点开换成别的形式，或选「全部形式」" } ?? "按形式筛选：只看视频、录音、图文……")
    .accessibilityLabel("显示的形式")
    .accessibilityValue(current?.rawValue ?? "全部形式")
    .accessibilityIdentifier("\(accessibilityPrefix)-menu")
  }
}
