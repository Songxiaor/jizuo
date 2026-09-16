import GRDB

/// 回收站与阅读进度。
///
/// ## `tasks.deleted_at_ms`：删除从「立刻没了」改成「先放一边」
///
/// 在此之前 `deleteTasks` 是唯一的删除路径，而它是真删：行没了、媒体文件没了、
/// 关联表 CASCADE 跟着没了，没有任何一步可以反悔。批量删是一次点击就能触发的
/// 动作，删错的代价却是永久的——这种不对称本身就是缺陷。
///
/// 软删除只加一列：`NULL` 表示没删，有值表示「什么时候放进回收站的」。所有浏览、
/// 搜索、计数、召回一律加 `deleted_at_ms IS NULL`；回收站是唯一反过来看的地方。
///
/// 索引带 `WHERE deleted_at_ms IS NOT NULL`（部分索引）：回收站里通常只有几条，
/// 而未删除的是全库——给整列建索引等于把全库再抄一遍键，只为服务那几条。
///
/// 真删仍然保留（`deleteTasks`），回收站清空和 30 天自动清理都走它，媒体文件和
/// 关联表的清理逻辑因此只有一份。
///
/// ## `reading_progress`：阅读位置从 UserDefaults 搬进库
///
/// 旧实现把「这篇读到 43%」写在 UserDefaults 的 `reading.position.v1.<id>` 下。
/// 三个后果：删掉记录那条键永远留着（键会单调堆积，没有任何一处会清），备份
/// 导不出它（换机后所有进度归零），以及它和它描述的那条内容分属两个存储，
/// 谁也保证不了一致。
///
/// 外键 `ON DELETE CASCADE`：记录真删时进度跟着走，不再需要任何清扫器。
public enum Migration023 {
  public static let schemaVersion = 23

  static func apply(to db: Database) throws {
    try db.execute(sql: "ALTER TABLE tasks ADD COLUMN deleted_at_ms INTEGER")
    try db.execute(sql: """
      CREATE INDEX idx_tasks_deleted_at ON tasks(deleted_at_ms)
      WHERE deleted_at_ms IS NOT NULL
      """)

    try db.execute(sql: """
      CREATE TABLE reading_progress (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        position REAL NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
      """)

    try db.execute(sql: "PRAGMA user_version = 23")
  }
}
