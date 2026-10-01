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
      // 全局统一口径：数的是「已保存的内容」，不是「抓过几次」。
      return "\(name) · 已保存 \(total) 条内容"
    }
    return name
  }

  static func sortCaption(searchActive: Bool) -> String {
    searchActive ? "匹配结果按保存时间排列，新的在前" : "按保存时间排列，新的在前"
  }

  static func emptyMessage(selectedHosts: Set<String>, searchActive: Bool) -> String {
    let name = platformDisplayName(for: selectedHosts)
    return searchActive ? "没有匹配的\(name)内容" : "还没有保存过\(name)内容"
  }

  /// 空态的补充说明：图库只按当前来源筛选，出口在内容列表那边。
  /// 原来这里只有一行「还没有保存过X内容」，不带图标也不带动作，用户只能去侧栏再点一次。
  static let emptyHint = "这里只显示当前来源已保存的内容。回到内容列表可以看全部来源，或换一个来源。"

  /// 页头左侧的返回：回到左中右三栏的内容列表，和博主作品页的「返回」同一个说法。
  static let backToListTitle = "返回内容列表"

  static let retryActionTitle = "重试"

  static func loadFailureTitle(selectedHosts: Set<String>) -> String {
    "无法载入\(platformDisplayName(for: selectedHosts))图库"
  }

  /// 三句：发生了什么、数据安不安全、现在能做什么。第三句对应「重试」按钮。
  static let loadFailureMessage =
    "这次没能从本机读出图库。已保存的内容都还在，这期间也不会写入任何变更。点「重试」再读一次。"

  static let pageLoadFailureTitle = "无法继续载入"

  static let pageLoadFailureMessage =
    "这一页没能继续载入。已经显示的内容都还在，这期间也不会写入任何变更。点「重试」再读一次。"

  static func loadingMessage(selectedHosts: Set<String>) -> String {
    "正在载入\(platformDisplayName(for: selectedHosts))…"
  }

  static func platformDisplayName(for selectedHosts: Set<String>) -> String {
    if selectedHosts.count == 1, let host = selectedHosts.first {
      return HistoryPlatformDisplay.shortName(forHost: host)
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
  var model: HistoryViewModel
  let theme: HistoryThemeTokens
  var searchFocused: FocusState<Bool>.Binding
  @Binding var scrollTarget: TaskID?
  let onOpen: (TaskID) -> Void
  let contextMenu: (HistoryRowProjection) -> AnyView
  var accessibilityPrefix: String = "platform-gallery"
  /// 返回三栏列表。传了就只收起卡片墙、保留当前来源；不传（独立的来源页）才清空来源选择。
  /// 原来一律清空，从 X 的卡片墙返回会落到「全部」（2026-09-25 走查）。
  var onBack: (() -> Void)? = nil
  /// 多选后「移到回收站」：走三栏同一套确认弹窗。不传就不显示这个按钮。
  var onDeleteSelection: (() -> Void)? = nil
  /// 页头右端的排序：只排已加载的卡，不改后台分页顺序。`.original` 是后台的顺序——
  /// 按**保存时间**新到旧（listFilter 的 ordersBySavedTime），和三栏列表的「今天 / 昨天」一致。
  /// 原来叫「最近更新」，名不副实；选过的排序也每次进来都被重置（2026-10-01 走查）。
  @AppStorage("platformGallerySortOrder") private var sortOrderRaw = WorkSortOrder.original.rawValue
  private var sortOrder: WorkSortOrder {
    get { WorkSortOrder(rawValue: sortOrderRaw) ?? .original }
    nonmutating set { sortOrderRaw = newValue.rawValue }
  }

  private var selectedHosts: Set<String> { model.selectedHosts }

  private var rows: [HistoryRowProjection] {
    let filtered = model.rows.filter { PlatformHistoryGalleryPresentation.filtersRow($0, selectedHosts: selectedHosts) }
    return sortOrder.sorted(filtered, likes: { $0.likes }, published: { $0.published })
  }

  /// 这一页都是同一个作者（常见于抖音按博主抓的一批）时，每张卡再写一遍作者名只是噪音。
  /// 和列表「同一作者连续只写一次」同一个道理（2026-09-25）。
  private var rowsShareOneAuthor: Bool {
    let authors = Set(rows.compactMap { $0.author?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    return rows.count > 1 && authors.count == 1
  }

  private func sortTitle(_ order: WorkSortOrder) -> String {
    order == .original ? "最近保存" : order.title
  }

  private var titleText: String {
    PlatformHistoryGalleryPresentation.title(
      selectedHosts: selectedHosts,
      searchText: model.searchText,
      navigationCounts: model.navigationCounts
    )
  }

  private func goBack() {
    if let onBack { onBack() } else { model.clearHostSelection() }
  }

  private var searchActive: Bool {
    !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 页头一行：标题和设置页页头同一字号；右端一个排序下拉，取代原来常驻的
      // 「按最近更新排列」说明文字。
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
        // 图库是一条独立的路：进来之后原本没有出口，只能靠侧栏再点一次。
        // 和博主作品页的「返回」同一个位置、同一个样式。
        // 三栏里打开的卡片墙把「返回」放在工具栏（onBack）；独立来源页仍用页内按钮。
        if onBack == nil {
          Button(PlatformHistoryGalleryPresentation.backToListTitle, action: goBack)
            .buttonStyle(.appQuiet)
            .controlSize(.small)
            .help("回到左中右三栏的内容列表")
            .accessibilityLabel(PlatformHistoryGalleryPresentation.backToListTitle)
            .accessibilityIdentifier("\(accessibilityPrefix)-back-to-list")
        }
        Text(titleText)
          .themedFont(.title3, weight: .semibold)
          .foregroundStyle(theme.primaryText)
          .lineLimit(1)
          .accessibilityIdentifier("\(accessibilityPrefix)-title")
        Spacer(minLength: 0)
        // 从三栏列头的「卡片视图」进来时，回去的开关就放在同一页的同一类位置：
        // 「列表 / 卡片」两段，当前在「卡片」。原来只有工具栏左上一个不写字的「<」，
        // 要找半天才知道怎么回去（2026-10-01 Syc 反馈）。
        if onBack != nil {
          Picker("显示方式", selection: Binding(get: { 1 }, set: { if $0 == 0 { goBack() } })) {
            Label("列表", systemImage: "list.bullet").tag(0)
            Label("卡片", systemImage: "square.grid.2x2").tag(1)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .help("切回左中右三栏的列表")
          .accessibilityIdentifier("\(accessibilityPrefix)-view-mode")
        }
        Picker("排序", selection: Binding(get: { sortOrder }, set: { sortOrder = $0 })) {
          ForEach(WorkSortOrder.allCases) { order in
            Text(sortTitle(order)).tag(order)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        // 系统蓝会在三套主题里都跳出来；排序不是强调项，收回主题色。
        .tint(theme.accent)
        .help("只排序已加载的卡片；\(PlatformHistoryGalleryPresentation.sortCaption(searchActive: searchActive))")
        .accessibilityLabel("排序")
        .accessibilityIdentifier("\(accessibilityPrefix)-sort")
      }
      .padding(.horizontal, DesignTokens.Layout.columnInset)
      .padding(.top, 12)

      // 和三栏列表、博主目录同一个搜索框；原来这里是白底、左右缩进 12，切过来会「跳」（2026-10-01）。
      ThemedSearchField {
        DebouncedSearchField(placeholder: "搜索标题、正文、总结、标签", committed: model.searchText,
                             onChange: { model.searchText = $0 })
          .focused(searchFocused)
      }
      .padding(.horizontal, DesignTokens.Layout.columnInset)
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
                  showsAuthor: !rowsShareOneAuthor,
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
    // 卡片墙没有详情列，三栏里多选时的批量面板到不了这里：原来勾了几张卡之后，
    // 既看不到选了几张，也没有「取消选择」，只能一张张再点掉（2026-10-01 走查）。
    .overlay(alignment: .bottom) {
      if !model.selectedTaskIDs.isEmpty {
        selectionBar
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.18), value: model.selectedTaskIDs.isEmpty)
    .onChange(of: rows.map(\.taskID), initial: true) { _, order in
      model.galleryDisplayOrder = sortOrder == .original ? nil : order
    }
    .accessibilityIdentifier(accessibilityPrefix)
  }

  private var selectionBar: some View {
    HStack(spacing: DesignTokens.Space.md) {
      Text("已选择 \(model.selectedTaskIDs.count) 项")
        .themedFont(.callout, weight: .semibold)
        .foregroundStyle(theme.primaryText)
        .monospacedDigit()
      if let onDeleteSelection {
        Button(action: onDeleteSelection) {
          Label("移到回收站", systemImage: "trash")
        }
        .buttonStyle(.appQuiet)
        .accessibilityIdentifier("\(accessibilityPrefix)-delete-selection")
      }
      Button("取消选择") { model.selectedTaskIDs = [] }
        .buttonStyle(.appQuiet)
        .help("取消选择（Esc）")
        .accessibilityIdentifier("\(accessibilityPrefix)-clear-selection")
    }
    // 按钮文字整句显示：浮条自己按内容定宽，原来被挤成「移到…」（2026-10-02 自测）。
    .fixedSize()
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(theme.card, in: Capsule())
    .overlay(Capsule().strokeBorder(theme.hairline))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(accessibilityPrefix)-selection-bar")
  }

  @ViewBuilder private var galleryFooter: some View {
    if rows.isEmpty {
      if model.listState == .loading || model.listState == .idle {
        InlineLoadingLabel(PlatformHistoryGalleryPresentation.loadingMessage(selectedHosts: selectedHosts))
          .padding()
          .accessibilityIdentifier("\(accessibilityPrefix)-loading")
      } else if model.listState == .failed {
        HistoryInlineState(
          symbol: "exclamationmark.triangle",
          title: PlatformHistoryGalleryPresentation.loadFailureTitle(selectedHosts: selectedHosts),
          message: PlatformHistoryGalleryPresentation.loadFailureMessage,
          actionTitle: PlatformHistoryGalleryPresentation.retryActionTitle,
          action: { model.retryList() }
        )
        .padding()
        .accessibilityIdentifier("\(accessibilityPrefix)-retry")
      } else {
        HistoryInlineState(
          symbol: "tray",
          title: PlatformHistoryGalleryPresentation.emptyMessage(
            selectedHosts: selectedHosts,
            searchActive: searchActive
          ),
          message: PlatformHistoryGalleryPresentation.emptyHint,
          actionTitle: PlatformHistoryGalleryPresentation.backToListTitle,
          action: goBack
        )
        .padding()
        .accessibilityIdentifier("\(accessibilityPrefix)-empty")
      }
    } else if model.isLoadingNextPage {
      ProgressView()
        .controlSize(.small)
        .padding(.vertical, 8)
        .accessibilityIdentifier("\(accessibilityPrefix)-page-loading")
    } else if model.listErrorCode != nil, model.canRetryList {
      HistoryInlineState(
        symbol: "exclamationmark.triangle",
        title: PlatformHistoryGalleryPresentation.pageLoadFailureTitle,
        message: PlatformHistoryGalleryPresentation.pageLoadFailureMessage,
        actionTitle: PlatformHistoryGalleryPresentation.retryActionTitle,
        action: { model.retryList() }
      )
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
  var showsAuthor: Bool = true
  let localCover: (String?) async -> URL?
  let onOpen: () -> Void
  let onToggleSelection: () -> Void
  @ViewBuilder let contextMenu: () -> Menu

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // 多选原来只有悬停才露出的右上角小框，键盘、读屏和没想到要悬停的人都用不上
    // （2026-10-01 走查）。和访达一样：⌘ 点卡片就是勾选；已经在多选时，单击也是勾选，
    // 不会一不小心打开一张、把选好的几张丢掉。
    Button {
      if selectionActive || NSEvent.modifierFlags.contains(.command) {
        onToggleSelection()
      } else {
        onOpen()
      }
    } label: {
      CreatorSavedWorkCard(
        row: row, theme: theme, localCover: localCover,
        showsAuthor: showsAuthor,
        showsPrimaryMetricOnly: true
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    // 原来只有一句 hint「打开内容」挂在没有名字的元素上，VoiceOver 念出来是
    // 「按钮，打开内容」，一屏几十张卡全一样。名字改用这条内容的标题。
    .accessibilityLabel(CreatorDirectoryCardCopy.accessibilityTitle(row: row))
    .accessibilityIdentifier("\(accessibilityPrefix)-card-\(row.taskID.rawValue)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: isSelected ? "取消选择" : "选择") { onToggleSelection() }
    .help(selectionActive ? "单击勾选或取消；按 Esc 取消全部选择" : "单击打开；⌘ 单击可多选")
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
