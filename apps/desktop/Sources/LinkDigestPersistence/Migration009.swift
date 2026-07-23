import GRDB

/// Mind-map outlines live in their own additive table: one latest map per
/// task, stored as contract JSON so themes re-render locally for free and
/// user edits persist without ever re-spending tokens.
public enum Migration009 {
  public static let schemaVersion = 9

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_mind_maps (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        outline_json TEXT NOT NULL,
        theme_id TEXT NOT NULL,
        user_edited INTEGER NOT NULL DEFAULT 0 CHECK (user_edited IN (0, 1)),
        provider TEXT,
        model TEXT,
        prompt_tokens INTEGER,
        completion_tokens INTEGER,
        total_tokens INTEGER,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: "PRAGMA user_version = 9")
  }
}
