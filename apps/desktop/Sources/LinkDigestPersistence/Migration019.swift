import GRDB

/// content_series 表。产品入口已去掉，schema 保留以免 live DB 降级。
///
/// 只加两张独立表，既有历史一行都不改。删系列只删关系，不删原文。
/// 条目被删时关系跟着 CASCADE 走，系列里不会留下幽灵课。
public enum Migration019 {
  public static let schemaVersion = 19

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE content_series (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 80),
        hub_url TEXT,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """)
    try db.execute(sql: "CREATE INDEX idx_content_series_updated ON content_series(updated_at_ms DESC, id)")

    try db.execute(sql: """
      CREATE TABLE content_series_items (
        series_id TEXT NOT NULL REFERENCES content_series(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        position INTEGER NOT NULL CHECK (position >= 0),
        PRIMARY KEY (series_id, task_id)
      ) WITHOUT ROWID
      """)
    try db.execute(sql: "CREATE INDEX idx_content_series_items_task ON content_series_items(task_id)")
    try db.execute(sql: "CREATE INDEX idx_content_series_items_order ON content_series_items(series_id, position, task_id)")
    try db.execute(sql: "PRAGMA user_version = 19")
  }
}
