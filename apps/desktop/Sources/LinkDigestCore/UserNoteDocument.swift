import Foundation

/// 用户在 App 内自建的笔记。
///
/// 笔记和抓取记录共用 `tasks` + `content_snapshots`，靠 `origin == .userNote` 与
/// `CanonicalURL.noteScheme` 区分。这样做的好处是**标签、搜索、翻译、总结、脑图、
/// 导出、收藏全部零改动直接可用**——它们本来就作用于「一条记录的正文」，而笔记正是
/// 一条正文由用户自己写的记录。
///
/// 代价是笔记也会出现在「全部」列表里。这是刻意的：用户想找一段自己写的想法时，
/// 不应该先想起它是笔记还是网页。
public enum UserNoteDocument {
  /// 新笔记的默认标题。空标题会让历史列表出现一行没有抓手的空白。
  public static let untitledTitle = "无标题笔记"
  /// 新笔记的初始正文。
  ///
  /// **不能是空字符串**：`CapturedDocumentValidator` 拒绝空内容（`emptyContent`），
  /// 而一条建不出来的笔记比一条带占位文字的笔记糟糕得多。
  public static let placeholderBody = "在这里写下你的想法…"

  /// 从正文首个一级标题派生标题；没有就返回 nil。
  ///
  /// 写笔记的人极少先想标题——先写下来，标题是写着写着才有的。所以正文里出现
  /// `# 某某` 时就拿它当标题，而不是让用户在两个地方各写一遍同一句话。
  ///
  /// 只认**第一个非空行**，且只认一级标题：正文中段的 `#` 是章节，不是这条笔记
  /// 叫什么。派生只在标题仍是默认值时发生，用户手改过就不再覆盖。
  public static func derivedTitle(fromBody body: String) -> String? {
    for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      guard line.hasPrefix("# ") else { return nil }
      let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      guard !title.isEmpty else { return nil }
      // 列表一行放不下的长标题截断，省略号让人知道后面还有。
      return title.count > 120 ? String(title.prefix(120)) + "…" : title
    }
    return nil
  }

  /// 「今天」这条笔记的标题。
  ///
  /// 每日笔记不是一个新功能，是**取消一个决定**：随手记东西时最大的摩擦不是打字，
  /// 是「这条该记去哪」。给每天一个默认容器，这个决定就不存在了。
  ///
  /// 标题用本地日期而不是 UUID，因为它要能被人一眼认出、也能被搜索命中。
  public static func dailyTitle(for date: Date = Date(), calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }

  /// 「今天」这条笔记的固定 URL。
  ///
  /// 同一天必须解析出同一个值——`tasks` 的 UNIQUE 约束因此成为幂等保证：第二次点
  /// 「今天」不会再建一条，而是撞上已存在的那条。这比在应用层查一次再决定要可靠，
  /// 竞态下也不会产生两条。
  public static func dailyURL(for date: Date = Date(), calendar: Calendar = .current) throws -> CanonicalURL {
    try CanonicalURL("\(CanonicalURL.noteScheme):daily-\(dailyTitle(for: date, calendar: calendar))")
  }

  /// 组装「今天」的笔记。
  public static func makeDaily(
    date: Date = Date(),
    calendar: Calendar = .current,
    body: String? = nil
  ) throws -> CapturedDocument {
    let timestamp = ISO8601DateFormatter().string(from: date)
    return CapturedDocument(
      createdAt: timestamp,
      origin: .userNote,
      url: try dailyURL(for: date, calendar: calendar).value,
      title: dailyTitle(for: date, calendar: calendar),
      platform: HistoryPlatformDisplay.noteHost,
      method: "user_note_daily",
      text: body?.isEmpty == false ? body! : placeholderBody,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "每日笔记"
    )
  }

  /// 组装一条新笔记。落库仍走与手动链接相同的 `ingest(_:)` 路径，不另开写入口。
  public static func make(
    id: UUID = UUID(),
    title: String? = nil,
    body: String? = nil,
    now: Date = Date()
  ) throws -> CapturedDocument {
    let timestamp = ISO8601DateFormatter().string(from: now)
    let text = body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? body!
      : placeholderBody
    let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? title!
      : untitledTitle
    return CapturedDocument(
      createdAt: timestamp,
      origin: .userNote,
      url: try CanonicalURL.note(id: id).value,
      title: resolvedTitle,
      platform: HistoryPlatformDisplay.noteHost,
      method: "user_note",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "我的笔记"
    )
  }
}
