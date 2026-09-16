import GRDB
import LinkDigestCore

/// 把「这条是什么内容」和「它来自哪个平台」从每次查询现算，改成落在 `tasks` 两列上。
///
/// 以前笔记/稿件/成品靠 `canonical_url LIKE 'linkdigest-note:%'` 判定。SQLite 的 LIKE
/// 走不了索引前缀查找，EXPLAIN QUERY PLAN 确认这九条侧边栏计数全是覆盖索引全扫；
/// 平台分组更重，`normalizedTaskHostSQL` 是个把 `instr/substr` 嵌四层、再按平台注册表
/// 展开几十个 WHEN 的巨型 CASE，每行求值几十次，GROUP BY 还要再算一遍。
///
/// 两列都是**派生**数据，语义由 `TaskClassificationSQL` 一处定义：这次回填、以后每次
/// 写入、以及等价性测试用的是同一份表达式字符串，不存在「列里存的」和「代码算的」
/// 两套判定。
///
/// `content_kind` 取值：capture / note / draft / work。ALTER TABLE 加不了 CHECK，
/// 约束落在 `TaskClassificationSQL.contentKind` 这唯一的写入口。
///
/// 顺带补 `topic_candidate_materials(task_id)`：那张表只有 (candidate_id, task_id)
/// 主键，删一条 task 触发 CASCADE 时按 task_id 找行是全表扫。
public enum Migration021 {
  public static let schemaVersion = 21

  static func apply(to db: Database) throws {
    try db.execute(sql: "ALTER TABLE tasks ADD COLUMN content_kind TEXT NOT NULL DEFAULT '\(TaskClassificationSQL.captureKind)'")
    try db.execute(sql: "ALTER TABLE tasks ADD COLUMN normalized_host TEXT")

    /// 平台注册表是编译期常量，加一个平台旧记录的归属就会变。存下算它用的表达式，
    /// 启动时比对一次，不同才重算——否则旧记录会永远停在加平台之前的分组里。
    try db.execute(sql: """
      CREATE TABLE task_host_classification (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        expression TEXT NOT NULL
      )
      """)

    try TaskClassificationSQL.backfillAll(db)
    try db.execute(
      sql: "INSERT INTO task_host_classification (id, expression) VALUES (1, ?)",
      arguments: [TaskClassificationSQL.hostExpressionSignature]
    )

    // 侧边栏九条计数和分页都按 (类型, 更新时间倒序, id 倒序) 取，索引照这个形状建。
    try db.execute(sql: "CREATE INDEX idx_tasks_kind_order ON tasks(content_kind, updated_at_ms DESC, id DESC)")
    try db.execute(sql: "CREATE INDEX idx_tasks_normalized_host ON tasks(normalized_host)")
    try db.execute(sql: "CREATE INDEX idx_topic_candidate_materials_task ON topic_candidate_materials(task_id)")

    try db.execute(sql: "PRAGMA user_version = 21")
  }
}
