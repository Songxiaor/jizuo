import GRDB
import LinkDigestCore

/// Migration021 / Migration022 **之前**那几条查询，原样保留，只给 benchmark 用。
///
/// 「优化了多少」必须在同一份数据、同一次运行里量，否则比的是两台机器的状态。
/// 所以把旧实现留成一个显式命名的基线，而不是靠记忆里的数字或者另一次跑。
///
/// 这里的 SQL **不在任何生产路径上**：`GRDBHistoryRepository` 已经全部改读
/// `content_kind` / `normalized_host` 和 FTS 索引。改那边时不必同步改这里——
/// 基线的意义正是停在改动之前的那一版。
public enum LegacyQueryBaseline {
  /// 旧的内容类型判定：前缀 LIKE。SQLite 的 LIKE 走不了索引前缀查找。
  public static let isNote = "canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'"
  public static let isDraft = "canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'"
  public static let isWork = "canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'"
  public static let isCaptured = "NOT (\(isNote)) AND NOT (\(isDraft)) AND NOT (\(isWork))"

  /// 旧的平台表达式：几百字符、`instr/substr` 嵌四层，再按注册表展开几十个 WHEN。
  public static func host(tableAlias: String) -> String {
    TaskClassificationSQL.normalizedHost(tableAlias: tableAlias)
  }

  /// 旧的侧边栏九条计数。返回值只用于防止编译器把测量整段优化掉。
  public static func navigationCounts(_ repository: GRDBHistoryRepository) throws -> Int {
    try repository.database.read { db in
      var total = 0
      total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isNote)") ?? 0
      total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isWork)") ?? 0
      total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured)") ?? 0
      total += try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured) AND updated_at_ms >= (unixepoch('now') - 604800) * 1000"
      ) ?? 0
      total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured) AND is_favorite = 1") ?? 0
      total += try Int.fetchOne(db, sql: """
        SELECT COUNT(*)
        FROM tasks t
        WHERE NOT (t.\(isNote)) AND NOT (t.\(isDraft)) AND NOT (t.\(isWork)) AND NOT EXISTS (
          SELECT 1
          FROM runs successful_run
          INNER JOIN artifacts successful_artifact ON successful_artifact.run_id = successful_run.id
          WHERE successful_run.task_id = t.id AND successful_run.status = 'completed'
        )
        """) ?? 0
      let expression = host(tableAlias: "t")
      total += try Row.fetchAll(db, sql: """
        SELECT \(expression) AS host, COUNT(*) AS count
        FROM tasks t
        WHERE \(expression) <> '' AND NOT (t.\(isNote)) AND NOT (t.\(isDraft)) AND NOT (t.\(isWork))
        GROUP BY \(expression)
        ORDER BY count DESC, host COLLATE NOCASE ASC
        """).count
      return total
    }
  }

  /// 旧的搜索：6 处 `LIKE '%x%'`，其中两处扫全部 snapshot 正文和 artifact 正文。
  public static func search(_ repository: GRDBHistoryRepository, text: String, limit: Int) throws -> Int {
    let pattern = "%" + text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_") + "%"
    return try repository.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT t.id
        FROM tasks t
        LEFT JOIN content_snapshots es ON es.task_id = t.id AND es.id = (
          SELECT s.id FROM content_snapshots s
          WHERE s.task_id = t.id AND s.source_kind NOT IN ('local_transcription', 'burned_in_subtitles')
          ORDER BY s.sequence DESC LIMIT 1
        )
        WHERE NOT (t.\(isDraft)) AND (
          t.canonical_url LIKE ? ESCAPE '\\'
          OR COALESCE(es.title, '') LIKE ? ESCAPE '\\'
          OR COALESCE(es.source_label, '') LIKE ? ESCAPE '\\'
          OR COALESCE(es.body_text, '') LIKE ? ESCAPE '\\'
          OR EXISTS (
            SELECT 1 FROM task_tags stt
            INNER JOIN tags stg ON stg.id = stt.tag_id
            WHERE stt.task_id = t.id
              AND (stg.display_name LIKE ? ESCAPE '\\' OR stg.normalized_name LIKE ? ESCAPE '\\')
          )
          OR EXISTS (
            SELECT 1 FROM runs sr
            INNER JOIN artifacts sa ON sa.run_id = sr.id
            WHERE sr.task_id = t.id AND sa.body_text LIKE ? ESCAPE '\\'
          )
        )
        ORDER BY t.updated_at_ms DESC, t.id DESC
        LIMIT ?
        """, arguments: [pattern, pattern, pattern, pattern, pattern, pattern, pattern, limit]).count
    }
  }

  /// 旧的「待总结」筛选：三条前缀 LIKE 叠在 NOT EXISTS 外面。
  public static func unsummarized(_ repository: GRDBHistoryRepository, limit: Int) throws -> Int {
    try repository.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT t.id FROM tasks t
        WHERE NOT (t.\(isDraft)) AND NOT (t.\(isNote)) AND NOT (t.\(isWork))
          AND NOT EXISTS (
            SELECT 1 FROM runs sr
            INNER JOIN artifacts sa ON sa.run_id = sr.id
            WHERE sr.task_id = t.id AND sr.status = 'completed'
          )
        ORDER BY t.updated_at_ms DESC, t.id DESC
        LIMIT ?
        """, arguments: [limit]).count
    }
  }
}
