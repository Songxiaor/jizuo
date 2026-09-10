import LinkDigestCore
import SwiftUI

/// Shared source-platform card gallery. One surface for all hosts (including「其他」).
enum PlatformHistoryGalleryPresentation {
  /// Well-known single-host filters and the misc multi-host aggregate.
  static func showsGallery(for selectedHosts: Set<String>) -> Bool {
    !selectedHosts.isEmpty
  }

  static func title(
    selectedHosts: Set<String>,
    searchText: String,
    navigationCounts: HistoryNavigationCounts
  ) -> String {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = platformDisplayName(for: selectedHosts)
    if !query.isEmpty { return "\(name) · 当前筛选" }
    if let total = matchingPlatformCount(selectedHosts: selectedHosts, in: navigationCounts) {
      return "\(name) · \(total) 条"
    }
    return name
  }

  static func sortCaption(searchActive: Bool) -> String {
    searchActive ? "匹配结果按最近更新排列" : "按最近更新排列"
  }

  static func emptyMessage(selectedHosts: Set<String>, searchActive: Bool) -> String {
    let name = platformDisplayName(for: selectedHosts)
    return searchActive ? "没有匹配的\(name)内容" : "尚未保存\(name)内容"
  }

  static func loadingMessage(selectedHosts: Set<String>) -> String {
    "正在载入\(platformDisplayName(for: selectedHosts))…"
  }

  static func platformDisplayName(for selectedHosts: Set<String>) -> String {
    if selectedHosts.count == 1, let host = selectedHosts.first {
      let full = HistoryPlatformDisplay.name(forHost: host)
      switch full {
      case "微信公众号": return "公众号"
      case "哔哩哔哩": return "B站"
      case "待分类": return "其他"
      default: return full
      }
    }
    if !selectedHosts.isEmpty,
       selectedHosts.allSatisfy({ !HistoryPlatformDisplay.isWellKnown(host: $0) }) {
      return "其他"
    }
    return "来源"
  }

  static func matchingPlatformCount(
    selectedHosts: Set<String>,
    in counts: HistoryNavigationCounts
  ) -> Int? {
    let matched = counts.platforms.filter { selectedHosts.contains($0.host) }
    guard !matched.isEmpty else { return nil }
    return matched.reduce(0) { $0 + $1.count }
  }

  static func filtersRow(_ row: HistoryRowProjection, selectedHosts: Set<String>) -> Bool {
    selectedHosts.contains(HistoryPlatformRegistry.canonicalHost(for: row.host))
      || selectedHosts.contains(HistoryHostNormalizer.normalized(row.host))
  }
}

/// Unified card grid for every source-platform entry. Replaces per-platform gallery copies.
struct PlatformHistoryGallery: View {
  @ObservedObject var model: HistoryViewModel
  let theme: HistoryThemeTokens
  var searchFocused: FocusState<Bool>.Binding
  @Binding var scrollTarget: TaskID?
  let onOpen: (TaskID) -> Void
  let contextMenu: (HistoryRowProjection) -> AnyView
  var accessibilityPrefix: String = "platform-gallery"
  /// 页头右端的排序：只排已加载的卡，不改后台分页顺序。`.original` 即「最近更新」。
  @State private var sortOrder: WorkSortOrder = .original

  private var selectedHosts: Set<String> { model.selectedHosts }

  private var rows: [HistoryRowProjection] {
    let filtered = model.rows.filter { PlatformHistoryGalleryPresentation.filtersRow($0, selectedHosts: selectedHosts) }
    return sortOrder.sorted(filtered, likes: { $0.likes }, published: { $0.published })
  }

  private func sortTitle(_ order: WorkSortOrder) -> String {
    order == .original ? "最近更新" : order.title
  }

  private var titleText: String {
    PlatformHistoryGalleryPresentation.title(
      selectedHosts: selectedHosts,
      searchText: model.searchText,
      navigationCounts: model.navigationCounts
    )
  }

  private var searchActive: Bool {
    !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 页头一行：标题和设置页页头同一字号；右端一个排序下拉，取代原来常驻的
      // 「按最近更新排列」说明文字。
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
        Text(titleText)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(theme.primaryText)
          .lineLimit(1)
          .accessibilityIdentifier("\(accessibilityPrefix)-title")
        Spacer(minLength: 0)
        Picker("排序", selection: $sortOrder) {
          ForEach(WorkSortOrder.allCases) { order in
            Text(sortTitle(order)).tag(order)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("只排序已加载的卡片；\(PlatformHistoryGalleryPresentation.sortCaption(searchActive: searchActive))")
        .accessibilityIdentifier("\(accessibilityPrefix)-sort")
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(theme.secondaryText)
        TextField("搜索标题、正文、总结、标签", text: $model.searchText)
          .textFieldStyle(.plain)
          .focused(searchFocused)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
      .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(theme.hairline, lineWidth: 1))
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityIdentifier("\(accessibilityPrefix)-search")

      GeometryReader { geometry in
        let columns = CreatorDirectoryChrome.xColumnCount(availableWidth: geometry.size.width)
        ScrollViewReader { proxy in
          ScrollView {
            LazyVGrid(
              columns: Array(
                repeating: GridItem(
                  .flexible(minimum: 0),
                  spacing: CreatorDirectoryChrome.xGridSpacing,
                  alignment: .top
                ),
                count: columns
              ),
              spacing: CreatorDirectoryChrome.xGridSpacing
            ) {
              ForEach(rows, id: \.taskID) { row in
                PlatformGalleryCell(
                  row: row,
                  theme: theme,
                  isSelected: model.selectedTaskIDs.contains(row.taskID),
                  selectionActive: !model.selectedTaskIDs.isEmpty,
                  accessibilityPrefix: accessibilityPrefix,
                  localCover: { await model.localCoverURL(for: row.taskID, matching: $0) },
                  onOpen: { onOpen(row.taskID) },
                  onToggleSelection: { model.toggleGallerySelection(row.taskID) },
                  contextMenu: { contextMenu(row) }
                )
                .onAppear { model.loadNextPageIfNeeded(after: row) }
                .id(row.taskID)
              }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            galleryFooter
              .frame(maxWidth: .infinity)
              .padding(.bottom, 16)
          }
          .onAppear { restoreScroll(using: proxy) }
          .onChange(of: scrollTarget) { _, _ in restoreScroll(using: proxy) }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.canvas)
    .accessibilityIdentifier(accessibilityPrefix)
  }

  @ViewBuilder private var galleryFooter: some View {
    if rows.isEmpty {
      if model.listState == .loading || model.listState == .idle {
        ProgressView(PlatformHistoryGalleryPresentation.loadingMessage(selectedHosts: selectedHosts))
          .padding()
          .accessibilityIdentifier("\(accessibilityPrefix)-loading")
      } else if model.listState == .failed {
        Button("载入失败，点击重试", action: model.retryList)
          .padding()
          .accessibilityIdentifier("\(accessibilityPrefix)-retry")
      } else {
        Text(PlatformHistoryGalleryPresentation.emptyMessage(
          selectedHosts: selectedHosts,
          searchActive: searchActive
        ))
        .foregroundStyle(theme.secondaryText)
        .padding()
        .accessibilityIdentifier("\(accessibilityPrefix)-empty")
      }
    } else if model.isLoadingNextPage {
      ProgressView()
        .controlSize(.small)
        .padding(.vertical, 8)
        .accessibilityIdentifier("\(accessibilityPrefix)-page-loading")
    } else if model.listErrorCode != nil, model.canRetryList {
      Button("继续加载失败，点击重试", action: model.retryList)
        .padding(.vertical, 8)
        .accessibilityIdentifier("\(accessibilityPrefix)-page-retry")
    }
  }

  private func restoreScroll(using proxy: ScrollViewProxy) {
    guard let target = scrollTarget else { return }
    DispatchQueue.main.async {
      proxy.scrollTo(target, anchor: .center)
      scrollTarget = nil
    }
  }
}

/// 网格里的一格：卡片 + 悬停才出现的多选圆圈。
///
/// 原来每张卡右上角常驻一个空心圆，一屏几十个圆比内容还抢眼。现在只在鼠标悬停
/// 这张卡、或者已经有卡被选中（进入多选状态）时才画出来。
private struct PlatformGalleryCell<Menu: View>: View {
  let row: HistoryRowProjection
  let theme: HistoryThemeTokens
  let isSelected: Bool
  let selectionActive: Bool
  let accessibilityPrefix: String
  let localCover: (String?) async -> URL?
  let onOpen: () -> Void
  let onToggleSelection: () -> Void
  @ViewBuilder let contextMenu: () -> Menu

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onOpen) {
      CreatorSavedWorkCard(row: row, theme: theme, localCover: localCover)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .contain)
    .accessibilityHint("打开内容")
    .accessibilityIdentifier("\(accessibilityPrefix)-card-\(row.taskID.rawValue)")
    .contextMenu { contextMenu() }
    .overlay(alignment: .topTrailing) {
      CreatorWorkSelectionControl(isSelected: isSelected, theme: theme, onToggle: onToggleSelection)
        .opacity(isHovering || selectionActive || isSelected ? 1 : 0)
        .accessibilityIdentifier("history-work-select-\(row.taskID.rawValue)")
        .padding(6)
    }
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
  }
}
