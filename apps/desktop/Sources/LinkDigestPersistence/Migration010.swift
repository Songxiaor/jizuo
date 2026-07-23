import GRDB

/// Per-task token ledger for LLM operations that are not Runs (transcript
/// tidy, mind-map extraction, …). Runs keep their own usage columns; the
/// task-level total is the sum of both sources.
public enum Migration010 {
  public static let schemaVersion = 10

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_token_usages (
        id TEXT PRIMARY KEY CHECK (length(replace(id, '-', '')) = 32),
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        operation TEXT NOT NULL CHECK (length(operation) BETWEEN 1 AND 64),
        prompt_tokens INTEGER,
        completion_tokens INTEGER,
        total_tokens INTEGER,
        created_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: "CREATE INDEX idx_task_token_usages_task ON task_token_usages(task_id)")
    try db.execute(sql: "PRAGMA user_version = 10")
  }
}
