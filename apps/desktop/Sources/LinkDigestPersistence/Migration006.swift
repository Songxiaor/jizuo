import GRDB

/// Task-scoped ownership and completion evidence for V2 direct-file
/// transcription. No remote URL or temporary filesystem path is durable.
public enum Migration006 {
  public static let schemaVersion = 6

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_transcription_attempts (
        id TEXT PRIMARY KEY NOT NULL CHECK (
          length(id) = 36 AND id = lower(id)
          AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
          AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-'
          AND id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(id, '-', '')) = 32
          AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
        ),
        task_id TEXT NOT NULL,
        generation INTEGER NOT NULL CHECK (generation > 0),
        status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'cancelled', 'failed')),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        completed_at_ms INTEGER,
        UNIQUE (task_id, generation),
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE INDEX task_transcription_attempts_owner
        ON task_transcription_attempts(task_id, generation DESC, id DESC);

      CREATE TABLE task_transcription_evidence (
        id TEXT PRIMARY KEY NOT NULL CHECK (
          length(id) = 36 AND id = lower(id)
          AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
          AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-'
          AND id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(id, '-', '')) = 32
          AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'
        ),
        attempt_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        attempt_generation INTEGER NOT NULL CHECK (attempt_generation > 0),
        snapshot_id TEXT NOT NULL,
        source TEXT NOT NULL CHECK (length(trim(source)) BETWEEN 1 AND 64),
        engine TEXT NOT NULL CHECK (length(trim(engine)) BETWEEN 1 AND 128),
        provider TEXT CHECK (provider IS NULL OR length(trim(provider)) BETWEEN 1 AND 128),
        model TEXT CHECK (model IS NULL OR length(trim(model)) BETWEEN 1 AND 256),
        locale_identifier TEXT CHECK (locale_identifier IS NULL OR length(trim(locale_identifier)) BETWEEN 2 AND 64),
        language TEXT CHECK (language IS NULL OR length(trim(language)) BETWEEN 2 AND 32),
        completed_at_ms INTEGER NOT NULL,
        UNIQUE (attempt_id),
        UNIQUE (task_id, attempt_generation),
        FOREIGN KEY (attempt_id) REFERENCES task_transcription_attempts(id) ON DELETE CASCADE,
        FOREIGN KEY (task_id, snapshot_id) REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE INDEX task_transcription_evidence_task
        ON task_transcription_evidence(task_id, attempt_generation DESC, id DESC);
      PRAGMA user_version = 6;
      """)
  }
}
