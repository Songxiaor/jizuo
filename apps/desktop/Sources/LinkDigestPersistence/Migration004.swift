import GRDB

/// Additive attempt ownership and append-only completion evidence. The row
/// deliberately excludes transcript text, media paths, source URLs, credentials,
/// and provider payloads; the associated content snapshot remains the body truth.
public enum Migration004 {
  public static let schemaVersion = 4

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      ALTER TABLE media_assets ADD COLUMN transcription_attempt_id TEXT CHECK (
        transcription_attempt_id IS NULL OR (
          length(transcription_attempt_id) = 36
          AND transcription_attempt_id = lower(transcription_attempt_id)
          AND substr(transcription_attempt_id, 9, 1) = '-'
          AND substr(transcription_attempt_id, 14, 1) = '-'
          AND substr(transcription_attempt_id, 19, 1) = '-'
          AND substr(transcription_attempt_id, 24, 1) = '-'
          AND transcription_attempt_id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(transcription_attempt_id, '-', '')) = 32
          AND replace(transcription_attempt_id, '-', '') NOT GLOB '*[^0-9a-f]*'
        )
      );
      ALTER TABLE media_assets ADD COLUMN transcription_attempt_generation INTEGER CHECK (
        transcription_attempt_generation IS NULL OR transcription_attempt_generation > 0
      );
      CREATE UNIQUE INDEX media_assets_id_task ON media_assets(id, task_id);
      CREATE UNIQUE INDEX media_assets_task_transcription_generation
        ON media_assets(task_id, transcription_attempt_generation)
        WHERE transcription_attempt_generation IS NOT NULL;

      CREATE TABLE media_transcription_evidence (
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
        media_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        snapshot_id TEXT NOT NULL,
        attempt_id TEXT NOT NULL CHECK (
          length(attempt_id) = 36
          AND attempt_id = lower(attempt_id)
          AND substr(attempt_id, 9, 1) = '-'
          AND substr(attempt_id, 14, 1) = '-'
          AND substr(attempt_id, 19, 1) = '-'
          AND substr(attempt_id, 24, 1) = '-'
          AND attempt_id NOT GLOB '*[^0-9a-f-]*'
          AND length(replace(attempt_id, '-', '')) = 32
          AND replace(attempt_id, '-', '') NOT GLOB '*[^0-9a-f]*'
        ),
        attempt_generation INTEGER NOT NULL CHECK (attempt_generation > 0),
        source TEXT NOT NULL CHECK (length(trim(source)) BETWEEN 1 AND 64),
        engine TEXT NOT NULL CHECK (length(trim(engine)) BETWEEN 1 AND 128),
        provider TEXT CHECK (provider IS NULL OR length(trim(provider)) BETWEEN 1 AND 128),
        model TEXT CHECK (model IS NULL OR length(trim(model)) BETWEEN 1 AND 256),
        locale_identifier TEXT CHECK (locale_identifier IS NULL OR length(trim(locale_identifier)) BETWEEN 2 AND 64),
        language TEXT CHECK (language IS NULL OR length(trim(language)) BETWEEN 2 AND 32),
        completed_at_ms INTEGER NOT NULL,
        UNIQUE (media_id, attempt_id),
        UNIQUE (task_id, attempt_generation),
        FOREIGN KEY (media_id, task_id) REFERENCES media_assets(id, task_id) ON DELETE CASCADE,
        FOREIGN KEY (task_id, snapshot_id) REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE INDEX media_transcription_evidence_task
        ON media_transcription_evidence(task_id, attempt_generation DESC, id DESC);
      CREATE INDEX media_transcription_evidence_media
        ON media_transcription_evidence(media_id, attempt_generation DESC, id DESC);
      """)
    try db.execute(sql: "PRAGMA user_version = 4")
  }
}
