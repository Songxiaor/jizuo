import GRDB
import LinkDigestCore

/// `tasks.content_kind` 与 `tasks.normalized_host` 的**唯一**计算来源。
///
/// 这两列是 Migration021 引入的物化判定。以前每条查询都现算：内容类型靠
/// `canonical_url LIKE 'linkdigest-note:%'` 这种前缀 LIKE（SQLite 的 LIKE 不是
/// 索引可用的前缀查找，EXPLAIN QUERY PLAN 确认是覆盖索引全扫），平台分组靠一个
/// 几百字符、把 `instr/substr` 嵌四层的巨型 CASE，对每行求值几十次。
///
/// 物化之后最大的风险是「列里存的」和「代码算的」漂移。这里把回填、写入维护、
/// 以及等价性测试全部指向同一份表达式字符串，从构造上消除第二个来源：
/// 迁移回填用它，写入路径 `refreshClassification` 用它，测试拿它跟列对账。
public enum TaskClassificationSQL {
  public static let captureKind = "capture"
  public static let noteKind = "note"
  public static let draftKind = "draft"
  public static let workKind = "work"

  /// 内容类型判定。与平台注册表无关，因此永远不会随版本漂移。
  ///
  /// 顺序即语义：笔记、稿件、成品各有互不重叠的 URL scheme，其余一律是抓来的资料。
  public static func contentKind(tableAlias: String) -> String {
    """
    CASE
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%' THEN '\(noteKind)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%' THEN '\(draftKind)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%' THEN '\(workKind)'
      ELSE '\(captureKind)'
    END
    """
  }

  /// SQLite has no URL-host function. URLs stored in `tasks` have already passed
  /// the public-web admission policy, so this expression only extracts and
  /// normalizes that durable canonical host for grouping/filtering; it never
  /// admits a URL or changes network policy.
  ///
  /// 和 `contentKind` 不同，这段是从 `HistoryPlatformRegistry` 生成的——注册表加一个
  /// 平台，同一条旧 URL 的归属就会变。物化列因此需要 `hostExpressionSignature`
  /// 配合 `reconcileHostClassification` 在注册表变更后重算，否则旧记录会永远停在
  /// 加平台之前的那个 host 上，而且不报错、只是分组少了一类。
  public static func normalizedHost(tableAlias: String) -> String {
    let raw = "lower(substr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3), 1, instr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3) || '/', '/') - 1))"
    let normalized = """
      CASE
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.noteHost)'
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.draftHost)'
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.workHost)'
        WHEN \(raw) LIKE 'www.%' THEN substr(\(raw), 5)
        WHEN \(raw) LIKE 'www2.%' THEN substr(\(raw), 6)
        WHEN \(raw) LIKE 'm.%' THEN substr(\(raw), 3)
        WHEN \(raw) LIKE 'mobile.%' THEN substr(\(raw), 8)
        WHEN \(raw) LIKE 'amp.%' THEN substr(\(raw), 5)
        ELSE \(raw)
      END
      """
    let cases = HistoryPlatformRegistry.platforms.flatMap { platform -> [String] in
      var result: [String] = []
      if !platform.exactHosts.isEmpty {
        let hosts = platform.exactHosts
          .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
          .joined(separator: ", ")
        result.append("WHEN \(normalized) IN (\(hosts)) THEN '\(platform.canonicalHost)'")
      }
      for suffix in platform.suffixHosts {
        let safe = suffix.replacingOccurrences(of: "'", with: "''")
        result.append("WHEN \(normalized) = '\(safe)' OR \(normalized) LIKE '%.\(safe)' THEN '\(platform.canonicalHost)'")
      }
      return result
    }.joined(separator: "\n")
    return "CASE\n\(cases)\nELSE \(normalized)\nEND"
  }

  /// 注册表指纹。存的是「用哪段表达式算出来的」，不是版本号——版本号要人记得改，
  /// 表达式自己就会变。
  public static var hostExpressionSignature: String { normalizedHost(tableAlias: "t") }

  /// 回填/重算全表。迁移和注册表漂移修复共用。
  public static func backfillAll(_ db: Database) throws {
    try db.execute(sql: """
      UPDATE tasks SET
        content_kind = \(contentKind(tableAlias: "tasks")),
        normalized_host = \(normalizedHost(tableAlias: "tasks"))
      """)
  }

  /// 单条写入后的维护。`canonical_url` 一变就必须跟着调用——目前只有两个写入点：
  /// `acceptCapture` 建条目，和 `finishPiece` 把稿件原地换成成品。
  public static func refreshClassification(_ db: Database, taskID: String) throws {
    try db.execute(
      sql: """
        UPDATE tasks SET
          content_kind = \(contentKind(tableAlias: "tasks")),
          normalized_host = \(normalizedHost(tableAlias: "tasks"))
        WHERE id = ?
        """,
      arguments: [taskID]
    )
  }

  /// 存下来的指纹跟当前表达式是不是同一份。启动时先读这一行，相同就什么都不做。
  public static func hostClassificationIsCurrent(_ db: Database) throws -> Bool {
    let stored = try String.fetchOne(db, sql: "SELECT expression FROM task_host_classification WHERE id = 1")
    return stored == hostExpressionSignature
  }

  /// 注册表变了就重算一次，并把新指纹存回去。
  public static func reconcileHostClassification(_ db: Database) throws {
    try backfillAll(db)
    try db.execute(
      sql: """
        INSERT INTO task_host_classification (id, expression) VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET expression = excluded.expression
        """,
      arguments: [hostExpressionSignature]
    )
  }
}
