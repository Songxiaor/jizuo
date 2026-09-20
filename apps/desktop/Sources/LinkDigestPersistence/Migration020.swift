import GRDB

/// Followed creators and the saved works that belong to them.
///
/// Identity is UNIQUE(platform, author_id). Nickname is not a key. Work links
/// cascade when a task is deleted so sidebar counts stay honest.
public enum Migration020 {
  public static let schemaVersion = 20

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE creators (
        id TEXT PRIMARY KEY NOT NULL CHECK (
          length(id) = 36 AND id = lower(id)
          AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
          AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-'
          AND id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(id, '-', '')) = 32
          AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
        ),
        platform TEXT NOT NULL CHECK (length(platform) BETWEEN 1 AND 253),
        author_id TEXT NOT NULL CHECK (length(author_id) BETWEEN 1 AND 256),
        profile_url TEXT NOT NULL CHECK (length(profile_url) BETWEEN 1 AND 2048),
        display_name TEXT CHECK (display_name IS NULL OR length(display_name) BETWEEN 1 AND 80),
        avatar_url TEXT CHECK (avatar_url IS NULL OR length(avatar_url) BETWEEN 1 AND 2048),
        pinned_rank INTEGER CHECK (pinned_rank IS NULL OR (pinned_rank BETWEEN 1 AND 5)),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        UNIQUE (platform, author_id)
      ) WITHOUT ROWID
      """)
    try db.execute(sql: """
      CREATE UNIQUE INDEX idx_creators_pinned_rank
      ON creators(pinned_rank)
      WHERE pinned_rank IS NOT NULL
      """)
    try db.execute(sql: "CREATE INDEX idx_creators_updated ON creators(updated_at_ms DESC, id DESC)")

    try db.execute(sql: """
      CREATE TABLE creator_works (
        creator_id TEXT NOT NULL REFERENCES creators(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        PRIMARY KEY (creator_id, task_id),
        UNIQUE (task_id)
      ) WITHOUT ROWID
      """)
    try db.execute(sql: "CREATE INDEX idx_creator_works_creator ON creator_works(creator_id)")
    try db.execute(sql: "PRAGMA user_version = 20")
  }
}
