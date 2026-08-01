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
