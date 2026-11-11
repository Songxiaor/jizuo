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

  /// 「真人口播」：视频里有真人在出镜或口播表达。由素材卡的判定贴上，用户可手动摘掉；
  /// 摘掉后再次生成素材卡不会自动贴回（见 `MaterialCardLedger`）。
  /// 它是保留标签：不合并、不改名、不删除，也不算「讲什么」的主题标签。
  public static let liveSpeakerTagName = "真人口播"

  public static var liveSpeakerTagNormalizedName: String {
    HistoryTagNormalizer.normalized(liveSpeakerTagName)?.normalizedName ?? liveSpeakerTagName
  }

  /// 受保护的标签（规范化名）：系统标记 + 六个素材类型 + 「真人口播」。
  /// 这些名字不能被合并、改名、删除，也不进常用标签表、AI 整理方案和建议候选。
  public static var protectedTagNormalizedNames: Set<String> {
    var names = systemTagNormalizedNames
    for type in MaterialType.allCases {
      names.insert(HistoryTagNormalizer.normalized(type.tagName)?.normalizedName ?? type.tagName)
    }
    names.insert(liveSpeakerTagNormalizedName)
    return names
  }

  /// 模型打标签（总结、脑图、单独的标签调用）永远不能写入的名字：系统标记（自有/外部/已使用/已归档）
  /// 和「真人口播」。素材类型（灵感/观点…）不在此列，保持现有行为。
  /// 「真人口播」只能由素材卡路径按规则贴；不论常用表空不空都一样。
  public static var modelForbiddenTagNormalizedNames: Set<String> {
    systemTagNormalizedNames.union([liveSpeakerTagNormalizedName])
  }

  /// 同 `protectedTagNormalizedNames`，给常用标签表和整理方案用的名字。
  public static var reservedTagNormalizedNames: Set<String> { protectedTagNormalizedNames }

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
