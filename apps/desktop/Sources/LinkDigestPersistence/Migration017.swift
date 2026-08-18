import GRDB

/// 「整理排版」产物的独立表：一条任务留最新一份。
///
/// 刻意不进 `runs`——那张表的 `kind` 上有 `CHECK (kind IN ('summarize','translate'))`，
/// SQLite 改不了 CHECK，加一种类型等于整表重建搬数据。整理排版和脑图一样是
/// 「任务的衍生产物」而不是一次总结运行，照 `task_mind_maps` 的加表模式做，
/// 既有数据一行都不用动，花费走 `task_token_usages` 台账。
///
/// `user_edited` 是给用户改稿留的位：产物可以再编辑，改过之后重新生成会先问。
public enum Migration017 {
  public static let schemaVersion = 17

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_reformats (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        body_text TEXT NOT NULL,
        user_edited INTEGER NOT NULL DEFAULT 0 CHECK (user_edited IN (0, 1)),
        is_partial INTEGER NOT NULL DEFAULT 0 CHECK (is_partial IN (0, 1)),
        provider TEXT,
        model TEXT,
        prompt_tokens INTEGER,
        completion_tokens INTEGER,
        total_tokens INTEGER,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: "PRAGMA user_version = 17")
  }
}
