import Foundation

/// 工作台里那份正在写的稿子。
///
/// 它和笔记(`UserNoteDocument`)长得很像——都是用户自己写的正文,都用独立
/// scheme,都走同一条落库通道。分开的理由不在技术,在**心里的分类**:
///
/// - 笔记是原料。随手记下、越攒越多、只进不出。
/// - 稿件是半成品。属于某一件创作,做完就该离开视野。
///
/// 混在一起的后果实测过:找灵感时翻到一堆写了一半的稿子,而写稿时又被
/// 自己的随手记打断。所以它们在列表层面必须是两个东西。
///
/// 底层仍共用 `tasks` + `content_snapshots`,因此 Markdown 编辑器、全文搜索、
/// 双链、导出这些能力对稿件全部零改动可用。
public enum PieceDraftDocument {
  /// 新稿件的初始正文。
  ///
  /// 和笔记一样不能为空——`CapturedDocumentValidator` 拒绝空内容。
  public static let placeholderBody = "从这里开始写…"

  /// 组装一份新稿件。
  ///
  /// `title` 一般传灵感原句:列表里一眼能认出是哪件创作的稿子,
  /// 而真正的标题往往是写到一半才想出来的。
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
      ? UserNoteDocument.sanitizedTitle(title!)
      : UserNoteDocument.untitledTitle
    return CapturedDocument(
      createdAt: timestamp,
      origin: .pieceDraft,
      url: try CanonicalURL.draft(id: id).value,
      title: resolvedTitle.isEmpty ? UserNoteDocument.untitledTitle : resolvedTitle,
      platform: HistoryPlatformDisplay.draftHost,
      method: "piece_draft",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "工作台稿件"
    )
  }
}
