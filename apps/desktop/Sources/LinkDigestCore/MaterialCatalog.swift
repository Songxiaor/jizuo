import Foundation

/// 素材整理层：给素材标「是什么」和「用没用过」。
///
/// 两件事都落在现有标签上，不另建表：标签本来就能筛选、计数、搜索、导出，也已经
/// 通过 MCP 暴露给内容创作系统。这里只规定「用哪几个名字」，让 App、MCP 和
/// 创作系统说同一种话。
public enum MaterialCatalog {
  /// 素材类型。创作系统按类型取素材，比全文搜索准得多：要开头就找金句，要论据就找数据和案例。
  public enum MaterialType: String, CaseIterable, Sendable {
    case inspiration = "灵感"
    case viewpoint = "观点"
    case example = "案例"
    case quote = "金句"
    case data = "数据"
    case topic = "选题"

    public var tagName: String { rawValue }

    public var systemImage: String {
      switch self {
      case .inspiration: "lightbulb"
      case .viewpoint: "text.bubble"
      case .example: "books.vertical"
      case .quote: "quote.opening"
      case .data: "chart.bar"
      case .topic: "scope"
      }
    }
  }

  /// 被创作系统用过的素材带这个标签。只由 MCP 的 `jizuo_mark_used` 写入、`unused_only` 读取，
  /// 界面不再有「已使用 / 收件箱」（2026-09-24）。
  public static let usedTagName = "已使用"

  public static var usedTagNormalizedName: String {
    HistoryTagNormalizer.normalized(usedTagName)?.normalizedName ?? usedTagName
  }

  /// 旧版「归档」按钮留下的标签（2026-09-23 引入，2026-09-24 随收件箱 / 已归档一起撤下）。
  ///
  /// 界面不再提供归档，也不再按它分区；已贴上的标签不删（资料本身不受影响），
  /// 只在侧栏标签云里隐藏。
  public static let archivedTagName = "已归档"

  public static var archivedTagNormalizedName: String {
    HistoryTagNormalizer.normalized(archivedTagName)?.normalizedName ?? archivedTagName
  }

  public static var typeTagNames: [String] { MaterialType.allCases.map(\.tagName) }

  /// 系统用的标记，不是「讲什么」的主题标签：归属的两个保留标签、MCP 的「已使用」、
  /// 旧版「已归档」。界面上不当作标签胶囊显示（2026-09-24），数据照留、MCP 照常读写。
  public static var systemTagNormalizedNames: Set<String> {
    [usedTagNormalizedName, archivedTagNormalizedName,
     ContentOwnership.ownTagNormalizedName, ContentOwnership.externalTagNormalizedName]
  }

  /// 记在条目笔记里的一行用途记录。标签只能说「用过」，这一行说「用在哪、哪天用的」。
  public static func usageLine(usedIn: String?, at date: Date = Date(), calendar: Calendar = .current) -> String {
    let day = UserNoteDocument.dailyTitle(for: date, calendar: calendar)
    let target = usedIn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return target.isEmpty ? "- \(day) 已被创作系统使用" : "- \(day) 已用于《\(target)》"
  }

  /// 把用途记录追加到已有条目笔记末尾；同一天同一去处不重复记。
  public static func appendingUsage(_ line: String, to note: String?) -> String {
    let existing = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
      return existing
    }
    if existing.isEmpty { return "## 使用记录\n\n\(line)" }
    if existing.contains("## 使用记录") { return existing + "\n" + line }
    return existing + "\n\n## 使用记录\n\n" + line
  }
}
