import Foundation

/// 「相关内容」（2026-11-11）：打开一条资料时，从用户自己的备忘录和录音里找出意思相近的几条。
///
/// 这里只放与界面、模型调度都无关的部分：查询文本怎么取、候选怎么筛。向量检索本身
/// 复用「按意思搜」（`SemanticSearchEngine`），调度见 App 的 `RelatedContentService`。
public enum RelatedContentQuery {
  /// 查询文本的上限。模型一次最多读 512 个词片，中文约 500 字；标题加上一段总结
  /// 已经足够说明这条在讲什么，再长只会把模型注意力拉散，也可能被截断。
  public static let limit = 240

  /// 标题 + 总结；没有总结时用正文开头。结果定长截断。
  ///
  /// 正文全文直接当查询并不好：长文里的细枝末节会和更多条目沾边，把真正相关的那几条
  /// 挤下去。总结是这条内容最浓缩的说法，正文开头则是最先交代主题的地方。
  ///
  /// 正文走 `@autoclosure`：有总结时整段正文（要先拆 markdown、去属性区）根本不会被求值，
  /// 打开一条长文不会为了算这个白拆一遍（2026-11-11）。
  public static func text(title: String?, summary: String?, body: @autoclosure () -> String?) -> String {
    let hasSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    if hasSummary {
      return SemanticDocumentText.make(title: title, sourcePreview: nil, artifactPreview: summary, limit: limit)
    }
    return SemanticDocumentText.make(title: title, sourcePreview: body(), artifactPreview: nil, limit: limit)
  }
}

/// 从「按意思搜」的候选里挑出要展示的那几条。
///
/// 规则（2026-11-11）：
/// - 只要用户自己的备忘录和录音（`applenotes` / `voicememos`），且按归属判断是「自有」；
/// - 排除当前打开的这一条自身；
/// - 低于相似度门槛的不硬凑；
/// - 最多 5 条，保持相似度从高到低。
public enum RelatedContentSelection {
  public static let limit = 5
  /// 只从这两类本机来源里找：用户自己写的备忘录、自己录的音。
  public static let hostNames: Set<String> = [
    LocalImportSource.appleNotes.rawValue,
    LocalImportSource.voiceMemos.rawValue,
  ]
  /// 列表里一条内容旁边带的那一小段文字。
  static let previewLimit = 100

  public struct Item: Sendable, Equatable, Identifiable {
    public let taskID: TaskID
    public let title: String
    public let preview: String
    public let host: String

    public var id: TaskID { taskID }

    public init(taskID: TaskID, title: String, preview: String, host: String) {
      self.taskID = taskID
      self.title = title
      self.preview = preview
      self.host = host
    }
  }

  /// `ranked` 是相似度从高到低的候选；`rows` 是这些候选的列表信息（按 id 取）。
  public static func select(
    ranked: [(taskID: TaskID, score: Float)],
    currentTaskID: TaskID,
    rows: [HistoryRowProjection],
    minimumScore: Float
  ) -> [Item] {
    let rowsByID = Dictionary(rows.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<TaskID>()
    var items: [Item] = []
    for (taskID, score) in ranked {
      guard items.count < limit else { break }
      guard taskID != currentTaskID, score >= minimumScore, seen.insert(taskID).inserted else { continue }
      guard let row = rowsByID[taskID] else { continue }
      let host = HistoryPlatformRegistry.canonicalHost(for: row.host)
      guard hostNames.contains(host) else { continue }
      guard ContentOwnership.resolve(
        canonicalURL: row.canonicalURL, host: host, tagNames: row.tagNames ?? []
      ) == .own else { continue }
      items.append(Item(
        taskID: taskID,
        title: displayTitle(row, host: host),
        preview: preview(row),
        host: host
      ))
    }
    return items
  }

  private static func displayTitle(_ row: HistoryRowProjection, host: String) -> String {
    let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !title.isEmpty { return title }
    return host == LocalImportSource.voiceMemos.rawValue ? "语音备忘录" : "备忘录"
  }

  /// 正文开头一小段；老记录没有正文预览时退回总结。去掉属性区、图片和链接。
  private static func preview(_ row: HistoryRowProjection) -> String {
    if let source = row.sourcePreview, !source.isEmpty {
      return SemanticDocumentText.make(title: nil, sourcePreview: source, artifactPreview: nil, limit: previewLimit)
    }
    return SemanticDocumentText.make(title: nil, sourcePreview: nil, artifactPreview: row.artifactPreview, limit: previewLimit)
  }
}
