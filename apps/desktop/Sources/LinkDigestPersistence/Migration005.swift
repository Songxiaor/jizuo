import GRDB

/// Widens only capture-delivery provenance from frozen V1 to the explicit V1/V2
/// set. No media descriptor or playback URL is added to durable storage.
public enum Migration005 {
  public static let schemaVersion = 5

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      ALTER TABLE capture_deliveries RENAME TO capture_deliveries_v004;

      CREATE TABLE capture_deliveries (
        delivery_key TEXT PRIMARY KEY NOT NULL,
        capture_contract_version INTEGER NOT NULL CHECK (capture_contract_version IN (1, 2)),
        request_id TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64 AND payload_sha256 = lower(payload_sha256) AND payload_sha256 NOT GLOB '*[^0-9a-f]*'),
        task_id TEXT NOT NULL,
        snapshot_id TEXT NOT NULL,
        received_at_ms INTEGER NOT NULL,
        FOREIGN KEY (task_id, snapshot_id) REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE
      ) WITHOUT ROWID;

      INSERT INTO capture_deliveries (
        delivery_key, capture_contract_version, request_id, payload_sha256,
        task_id, snapshot_id, received_at_ms
      )
      SELECT delivery_key, capture_contract_version, request_id, payload_sha256,
        task_id, snapshot_id, received_at_ms
      FROM capture_deliveries_v004;

      DROP TABLE capture_deliveries_v004;
      CREATE INDEX capture_deliveries_task_recent ON capture_deliveries(task_id, received_at_ms DESC, delivery_key DESC);
      CREATE INDEX capture_deliveries_snapshot_recent ON capture_deliveries(snapshot_id, received_at_ms DESC, delivery_key DESC);
      PRAGMA user_version = 5;
      """)
  }
}
