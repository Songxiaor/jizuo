import SwiftUI
import LinkDigestCore

/// 标签管理（2026-09-24）：看每个标签用了几次，改名、合并、删除。
///
/// 标签多半是总结后自动打的，只增不减，一年下来几百个、大半只挂了一条，
/// 按标签筛选就失去意义。这里给用户一个收拢的地方：
/// - 顶部列出「写法相近」的组（只差空格、大小写、全角半角），一键合并；
/// - 下面是全部标签，按条数排，可搜索、多选合并、单个改名或删除。
/// 删除只摘标签，资料本身不动；系统标记（已使用、自有…）不在这里出现。
struct TagManagerView: View {
  @Bindable var model: HistoryViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var search = ""
  @State private var selection: Set<String> = []
  @State private var renameText = ""
  @State private var mergeName = ""
  @State private var pendingDelete: HistoryTag?

  private var tags: [HistoryNavigationTag] {
    model.manageableTags.sorted { $0.count == $1.count ? $0.tag.name < $1.tag.name : $0.count > $1.count }
  }

  private var filteredTags: [HistoryNavigationTag] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return tags }
    return tags.filter { $0.tag.name.lowercased().contains(needle) }
  }

  private var similarGroups: [[HistoryNavigationTag]] { HistoryTagSimilarity.groups(model.manageableTags) }

  private var selectedTags: [HistoryNavigationTag] {
    tags.filter { selection.contains($0.tag.normalizedName) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      header
      if let message = model.tagManagementMessage {
        Text(message)
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("tag-manager-message")
      }
      if !similarGroups.isEmpty { similarSection }
      TextField("搜索标签", text: $search)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("tag-manager-search")
      List(filteredTags, selection: $selection) { item in
        HStack {
          Text(item.tag.name).lineLimit(1)
          if HistoryContentView.hiddenSidebarTagNames.contains(item.tag.normalizedName) {
            // 说明侧栏和这里数字为什么差几个。
            Text("和来源重名，侧栏不显示")
              .themedFont(.caption)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Text("\(item.count)")
            .themedFont(.caption, monospacedDigit: true)
            .foregroundStyle(.secondary)
        }
        .tag(item.tag.normalizedName)
        .contextMenu {
          Button("删除标签…") { pendingDelete = item.tag }
        }
      }
      .listStyle(.inset)
      .accessibilityIdentifier("tag-manager-list")
      actionBar
    }
    .padding(DesignTokens.Space.lg)
    .frame(width: 520, height: 620)
    .onChange(of: selection) { _, _ in syncEditingNames() }
    .onAppear { model.clearTagManagementMessage() }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除标签", role: .destructive) {
        if let tag = pendingDelete {
          model.deleteTagEverywhere(tag)
          selection.remove(tag.normalizedName)
        }
        pendingDelete = nil
      }
      Button("取消", role: .cancel) { pendingDelete = nil }
    } message: {
      Text("资料本身不会删除，只是不再带这个标签。")
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("管理标签").themedFont(.headline)
        let once = tags.filter { $0.count == 1 }.count
        Text("共 \(tags.count) 个 · 只用过一次的 \(once) 个")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("完成") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
  }

  private var similarSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("写法相近，可能是同一个")
        .themedFont(.subheadline, weight: .medium)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(similarGroups, id: \.first!.tag.normalizedName) { group in
            HStack {
              Text(group.map { "\($0.tag.name)（\($0.count)）" }.joined(separator: " · "))
                .themedFont(.callout)
                .lineLimit(1)
              Spacer()
              Button("合并为「\(group[0].tag.name)」") {
                model.mergeTags(group.map(\.tag), into: group[0].tag.name)
              }
              .accessibilityIdentifier("tag-manager-merge-similar-\(group[0].tag.normalizedName)")
            }
          }
        }
      }
      // 按组数给高度：固定 120 时只有一两组也会留下一大块空白；组多了再滚动。
      .frame(height: min(CGFloat(similarGroups.count) * 34, 136))
    }
    .accessibilityIdentifier("tag-manager-similar")
  }

  @ViewBuilder private var actionBar: some View {
    let chosen = selectedTags
    HStack(spacing: 8) {
      if chosen.count == 1, let only = chosen.first {
        TextField("新名字", text: $renameText)
          .textFieldStyle(.roundedBorder)
          .onSubmit { rename(only.tag) }
        Button("改名") { rename(only.tag) }
          .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty || renameText == only.tag.name)
        Button("删除…", role: .destructive) { pendingDelete = only.tag }
      } else if chosen.count >= 2 {
        TextField("合并后的名字", text: $mergeName)
          .textFieldStyle(.roundedBorder)
          .onSubmit(merge)
        Button("合并所选 \(chosen.count) 个", action: merge)
          .disabled(mergeName.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("tag-manager-merge-selected")
      } else {
        Text("选一个标签可以改名或删除；按住 ⌘ 多选可以合并。改成已有的名字等于合并。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(minHeight: 28)
  }

  private var deleteTitle: String {
    guard let tag = pendingDelete else { return "删除标签" }
    let count = tags.first { $0.tag.normalizedName == tag.normalizedName }?.count ?? 0
    return "从 \(count) 条资料上摘掉「\(tag.name)」？"
  }

  /// 选中一个时，改名框预填它的名字；选中多个时，合并名预填用得最多的那个。
  private func syncEditingNames() {
    let chosen = selectedTags
    if chosen.count == 1 { renameText = chosen[0].tag.name }
    if chosen.count >= 2 { mergeName = chosen.max { $0.count < $1.count }?.tag.name ?? "" }
  }

  private func rename(_ tag: HistoryTag) {
    model.renameTag(tag, to: renameText)
    selection = []
  }

  private func merge() {
    model.mergeTags(selectedTags.map(\.tag), into: mergeName)
    selection = []
  }
}
