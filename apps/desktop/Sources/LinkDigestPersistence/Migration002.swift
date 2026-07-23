import GRDB

/// Local labels were added after the initial history schema. They are kept in
/// their own relation so a tag can be reused while task deletion still cleans
/// its associations through SQLite foreign keys.
public enum Migration002 {
  public static let schemaVersion = 2

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE tags (
        id INTEGER PRIMARY KEY,
        normalized_name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK (length(normalized_name) BETWEEN 1 AND 20),
        display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 20),
        created_at_ms INTEGER NOT NULL
      );

      CREATE TABLE task_tags (
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        created_at_ms INTEGER NOT NULL,
        PRIMARY KEY (task_id, tag_id)
      ) WITHOUT ROWID;
      CREATE INDEX task_tags_tag_task ON task_tags(tag_id, task_id);
      """)
    try db.execute(sql: "PRAGMA user_version = 2")
  }
}
