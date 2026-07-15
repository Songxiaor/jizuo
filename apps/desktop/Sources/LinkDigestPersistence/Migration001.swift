import GRDB
import LinkDigestCore

public enum Migration001 {
  public static let schemaVersion = 1

  static func apply(to db: Database, beforeCommit: () throws -> Void) throws {
    try db.execute(sql: """
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id) AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND id NOT GLOB '*[^0-9a-f-]*' AND length(replace(id, '-', '')) = 32 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
        canonical_url TEXT NOT NULL,
        canonicalization_version INTEGER NOT NULL CHECK (canonicalization_version = 1),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        UNIQUE (canonicalization_version, canonical_url)
      ) WITHOUT ROWID;
      CREATE INDEX tasks_history_order ON tasks(updated_at_ms DESC, id DESC);

      CREATE TABLE content_snapshots (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id) AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND id NOT GLOB '*[^0-9a-f-]*' AND length(replace(id, '-', '')) = 32 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL CHECK (sequence >= 1),
        envelope_created_at_ms INTEGER NOT NULL,
        captured_at_ms INTEGER NOT NULL,
        source_kind TEXT NOT NULL,
        source_url TEXT NOT NULL,
        title TEXT,
        platform TEXT NOT NULL,
        capture_method TEXT NOT NULL,
        completeness TEXT NOT NULL,
        body_text TEXT NOT NULL,
        character_count INTEGER NOT NULL CHECK (character_count BETWEEN 1 AND 2000000),
        body_sha256 TEXT NOT NULL CHECK (length(body_sha256) = 64 AND body_sha256 = lower(body_sha256) AND body_sha256 NOT GLOB '*[^0-9a-f]*'),
        source_label TEXT NOT NULL,
        used_cookie INTEGER NOT NULL CHECK (used_cookie = 0),
        UNIQUE (task_id, sequence),
        UNIQUE (task_id, body_sha256),
        UNIQUE (task_id, id)
      ) WITHOUT ROWID;

      CREATE TABLE capture_deliveries (
        delivery_key TEXT PRIMARY KEY NOT NULL,
        capture_contract_version INTEGER NOT NULL CHECK (capture_contract_version = 1),
        request_id TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64 AND payload_sha256 = lower(payload_sha256) AND payload_sha256 NOT GLOB '*[^0-9a-f]*'),
        task_id TEXT NOT NULL,
        snapshot_id TEXT NOT NULL,
        received_at_ms INTEGER NOT NULL,
        FOREIGN KEY (task_id, snapshot_id) REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE INDEX capture_deliveries_task_recent ON capture_deliveries(task_id, received_at_ms DESC, delivery_key DESC);
      CREATE INDEX capture_deliveries_snapshot_recent ON capture_deliveries(snapshot_id, received_at_ms DESC, delivery_key DESC);

      CREATE TABLE runs (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id) AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND id NOT GLOB '*[^0-9a-f-]*' AND length(replace(id, '-', '')) = 32 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
        task_id TEXT NOT NULL,
        snapshot_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        rerun_of_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        kind TEXT NOT NULL CHECK (kind IN ('summarize', 'translate')),
        target_language TEXT,
        status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'stopped', 'failed', 'interrupted')),
        provider_profile_id TEXT,
        provider_kind TEXT,
        provider_base_url TEXT,
        provider_api_mode TEXT,
        model TEXT,
        created_at_ms INTEGER NOT NULL,
        started_at_ms INTEGER,
        finished_at_ms INTEGER,
        failure_code TEXT,
        failure_retryable INTEGER CHECK (failure_retryable IN (0, 1)),
        input_tokens INTEGER CHECK (input_tokens >= 0),
        output_tokens INTEGER CHECK (output_tokens >= 0),
        total_tokens INTEGER CHECK (total_tokens >= 0),
        cost_amount_micros INTEGER CHECK (cost_amount_micros >= 0),
        cost_currency_code TEXT CHECK (length(cost_currency_code) = 3 AND cost_currency_code = upper(cost_currency_code) AND cost_currency_code NOT GLOB '*[^A-Z]*'),
        CHECK ((cost_amount_micros IS NULL) = (cost_currency_code IS NULL)),
        FOREIGN KEY (task_id, snapshot_id) REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE INDEX runs_task_recent ON runs(task_id, created_at_ms DESC, id DESC);
      CREATE INDEX runs_snapshot_recent ON runs(snapshot_id, created_at_ms DESC, id DESC);
      CREATE INDEX runs_rerun_parent ON runs(rerun_of_run_id) WHERE rerun_of_run_id IS NOT NULL;
      CREATE INDEX runs_nonterminal ON runs(status, created_at_ms) WHERE status IN ('queued', 'running');

      CREATE TABLE artifacts (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id) AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-' AND substr(id, 19, 1) = '-' AND substr(id, 24, 1) = '-' AND id NOT GLOB '*[^0-9a-f-]*' AND length(replace(id, '-', '')) = 32 AND replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'),
        run_id TEXT NOT NULL UNIQUE REFERENCES runs(id) ON DELETE CASCADE,
        content_format TEXT NOT NULL CHECK (content_format IN ('plain_text', 'markdown')),
        completeness TEXT NOT NULL CHECK (completeness IN ('complete', 'partial')),
        body_text TEXT NOT NULL CHECK (length(CAST(body_text AS BLOB)) > 0),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID;
      """)
    try beforeCommit()
    try db.execute(sql: "PRAGMA user_version = 1")
  }
}
