import LinkDigestCore

/// 侧栏「自有 / 外部」下面的一行来源（2026-10-12（Syc 定）：「来源」并进归属）。
///
/// 原来「来源」是单独一组，「本地文件 21」把自有和外部的文件混在一起，和「自有」下的
/// 「自有文件」同名不同数。现在每一行都只数这一边的：点「外部 → X」= 外部 + x.com，
/// 子项加起来等于上面那一行。
struct OwnershipSourceRow: Equatable, Identifiable {
  let ownership: ContentOwnership
  /// 侧栏和滚动定位用的 key：单个来源就是它的 host，杂项汇总是 `miscHost`。
  let key: String
  /// 选中时筛的 host。「其他」是一组杂项 host。
  let hosts: [String]
  let count: Int

  /// 同一个 host 可能「自有」「外部」下各有一行，列表 id 和无障碍标识必须分开。
  var id: String { "\(ownership == .own ? "own" : "external")-\(key)" }
  var scope: HistoryListScope { ownership == .own ? .own : .external }
  /// 「自有 → 笔记」仍走「笔记」作用域：新建笔记、今天的笔记都落在这一行，列头的「新建笔记」按钮也跟着它。
  var isNotesScope: Bool { ownership == .own && key == HistoryPlatformDisplay.noteHost }
  var isMisc: Bool { key == HistoryPlatformDisplay.miscHost }
  /// 本机来源（笔记、备忘录、语音备忘录、文件、作品）：它们说的是「从哪个渠道进来」，不是网站。
  var isLocal: Bool { OwnershipSourceNavigation.localHosts.contains(key) }

  /// 侧栏上的名字。本机来源用短名（「文件」不写「本地文件」：上面那一行已经说了归谁）。
  var title: String? {
    switch key {
    case HistoryPlatformDisplay.noteHost: "笔记"
    case HistoryPlatformDisplay.workHost: "作品"
    case LocalImportSource.files.rawValue: "文件"
    default: nil
    }
  }
}

enum OwnershipSourceNavigation {
  /// 「外部」收起时常驻几个网站。和原来「来源」一样 4 个：多露一行，下面几组就得滚动才看得到（2026-10-01）。
  static let collapsedLimit = 4

  /// 本机来源，按固定顺序排在网站前（自有）或后（外部）。
  static let localHosts: [String] = [
    HistoryPlatformDisplay.noteHost,
    LocalImportSource.appleNotes.rawValue,
    LocalImportSource.voiceMemos.rawValue,
    LocalImportSource.files.rawValue,
    HistoryPlatformDisplay.workHost,
  ]

  /// 一边的全部子项。
  ///
  /// - 自有：笔记（没有也留着，新建笔记从这里进）、备忘录、语音备忘录、文件、作品，再跟着有自有条目的网站
  ///   （比如把自己发的帖子改成了自有），最后是「其他」。
  /// - 外部：网站按条数从多到少，其后是本机来源（下载来的文件等），「其他」永远垫底。
  static func rows(for ownership: ContentOwnership, counts: HistoryNavigationCounts) -> [OwnershipSourceRow] {
    let platforms = ownership == .own ? counts.ownPlatforms : counts.externalPlatforms
    let byHost = Dictionary(platforms.map { ($0.host, $0.count) }, uniquingKeysWith: +)
    let local = localHosts.compactMap { host -> OwnershipSourceRow? in
      let count = byHost[host] ?? 0
      let keepsEmptyNotes = ownership == .own && host == HistoryPlatformDisplay.noteHost
      guard count > 0 || keepsEmptyNotes else { return nil }
      return .init(ownership: ownership, key: host, hosts: [host], count: count)
    }
    let others = platforms.filter { !localHosts.contains($0.host) && $0.host != HistoryPlatformDisplay.draftHost }
    let web = others
      .filter { HistoryPlatformDisplay.isWellKnown(host: $0.host) }
      .sorted { $0.count == $1.count ? $0.host < $1.host : $0.count > $1.count }
      .map { OwnershipSourceRow(ownership: ownership, key: $0.host, hosts: [$0.host], count: $0.count) }
    let miscPlatforms = others.filter { !HistoryPlatformDisplay.isWellKnown(host: $0.host) }
    let misc = miscPlatforms.isEmpty ? [] : [OwnershipSourceRow(
      ownership: ownership,
      key: HistoryPlatformDisplay.miscHost,
      hosts: miscPlatforms.map(\.host).sorted(),
      count: miscPlatforms.reduce(0) { $0 + $1.count }
    )]
    return ownership == .own ? local + web + misc : web + local + misc
  }

  /// 「外部」收起时露出的行：前 4 个网站。文件、「其他」这些总在「还有 N 个」里。
  /// 只多出一行时不折：「还有 1 个」那一行和它要藏的那一行一样高。
  static func collapsedVisibleIDs(_ rows: [OwnershipSourceRow], limit: Int = collapsedLimit) -> Set<String>? {
    let leading = rows.prefix { !$0.isLocal && !$0.isMisc }.prefix(limit)
    guard rows.count > leading.count + 1 else { return nil }
    return Set(leading.map(\.id))
  }
}

extension OwnershipSourceNavigation {
  /// 收起时只留正选中的那一行：选中项不能藏在折叠里，否则侧栏一个高亮都没有。
  static func visibleRows(
    _ rows: [OwnershipSourceRow],
    expanded: Bool,
    isSelected: (OwnershipSourceRow) -> Bool
  ) -> [OwnershipSourceRow] {
    expanded ? rows : rows.filter(isSelected)
  }
}

/// 侧栏最下面「实用工具」的几行（2026-10-12（Syc 定）：原「视图 → 工序状态」的三行和回收站
/// 挪到这里，拍平成一层，不再在折叠里套折叠）。
struct SidebarUtilityRow: Equatable {
  let scope: HistoryListScope
  let title: String
  let symbol: String
  let count: Int
  let help: String
  let identifier: String
}

enum SidebarUtilityNavigation {
  /// 清空了就不占一行，正选中时仍留着。
  static func rows(
    counts: HistoryNavigationCounts,
    selectedScope: HistoryListScope,
    autoSummarizesNewCaptures: Bool
  ) -> [SidebarUtilityRow] {
    var rows: [SidebarUtilityRow] = []
    if counts.untranscribed > 0 || selectedScope == .untranscribed {
      rows.append(.init(scope: .untranscribed, title: "待转写", symbol: "waveform", count: counts.untranscribed,
                        help: "带音视频、待转写的内容", identifier: "history-navigation-untranscribed"))
    }
    if counts.untidied > 0 || selectedScope == .untidied {
      rows.append(.init(scope: .untidied, title: "待校对", symbol: "checkmark.seal", count: counts.untidied,
                        help: "有转写、还没用模型校对过的内容", identifier: "history-navigation-untidied"))
    }
    // 自动总结开着时新内容会自己总结，这一行就不占位（2026-10-01 走查：「待总结 475」像一份做不完的作业）。
    if !autoSummarizesNewCaptures || selectedScope == .unsummarized {
      rows.append(.init(scope: .unsummarized, title: "未总结", symbol: MenuIcon.summarize, count: counts.unsummarized,
                        help: "还没有生成总结的内容", identifier: "history-navigation-unsummarized"))
    }
    // 回收站清空后正停在回收站里：行不能凭空消失，否则侧栏一个高亮都没有（2026-10-01 体检）。
    if counts.trash > 0 || selectedScope == .trash {
      rows.append(.init(scope: .trash, title: "回收站", symbol: "trash", count: counts.trash,
                        help: "删除的内容保留 \(HistoryTrashPolicy.retentionDays) 天", identifier: "history-navigation-trash"))
    }
    return rows
  }

  /// 收起时只露正选中的那一行（`selectedScope` 传 nil 表示选中的不在这一组里）。
  static func visibleRows(
    _ rows: [SidebarUtilityRow],
    expanded: Bool,
    selectedScope: HistoryListScope?
  ) -> [SidebarUtilityRow] {
    expanded ? rows : rows.filter { $0.scope == selectedScope }
  }
}
