import GRDB

/// Learning annotations: one free-form note per task plus selectable excerpts
/// (highlights) captured from the reading surface. Pure additive tables —
/// user thinking must never be coupled to machine-generated artifacts.
public enum Migration011 {
  public static let schemaVersion = 11

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_notes (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        body TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: """
      CREATE TABLE task_excerpts (
        id TEXT PRIMARY KEY CHECK (length(replace(id, '-', '')) = 32),
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        excerpt TEXT NOT NULL CHECK (length(excerpt) BETWEEN 1 AND 4000),
        created_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: "CREATE INDEX idx_task_excerpts_task ON task_excerpts(task_id)")
    try db.execute(sql: "PRAGMA user_version = 11")
  }
}
