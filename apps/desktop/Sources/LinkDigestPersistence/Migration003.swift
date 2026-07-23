import GRDB

/// Media assets for video captures (Loop V). Additive only — never alters
/// Migration001/002 tables. Task deletion cascades here so rows do not orphan.
public enum Migration003 {
  public static let schemaVersion = 3

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE media_assets (
        id TEXT PRIMARY KEY NOT NULL CHECK (
          length(id) = 36
          AND id = lower(id)
          AND substr(id, 9, 1) = '-'
          AND substr(id, 14, 1) = '-'
          AND substr(id, 19, 1) = '-'
          AND substr(id, 24, 1) = '-'
          AND id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(id, '-', '')) = 32
          AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
        ),
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        snapshot_id TEXT,
        relative_path TEXT NOT NULL CHECK (length(relative_path) BETWEEN 1 AND 512),
        content_sha256 TEXT NOT NULL CHECK (
          length(content_sha256) = 64
          AND content_sha256 = lower(content_sha256)
          AND content_sha256 NOT GLOB '*[^0-9a-f]*'
        ),
        byte_size INTEGER NOT NULL CHECK (byte_size > 0),
        duration_seconds REAL CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
        platform TEXT NOT NULL CHECK (length(platform) BETWEEN 1 AND 64),
        author TEXT CHECK (author IS NULL OR length(author) BETWEEN 1 AND 256),
        transcription_status TEXT NOT NULL CHECK (
          transcription_status IN ('none', 'pending', 'running', 'completed', 'failed')
        ),
        created_at_ms INTEGER NOT NULL,
        UNIQUE (task_id, content_sha256)
      ) WITHOUT ROWID;
      CREATE INDEX media_assets_task ON media_assets(task_id, created_at_ms DESC, id DESC);
      """)
    try db.execute(sql: "PRAGMA user_version = 3")
  }
}
