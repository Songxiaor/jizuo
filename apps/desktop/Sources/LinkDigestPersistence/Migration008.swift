import GRDB

/// V1 keeps its frozen `used_cookie = 0` column constraint. V2 session-detail
/// evidence is additive so existing snapshot foreign keys and WITHOUT ROWID
/// identities never need a risky table rebuild.
public enum Migration008 {
  public static let schemaVersion = 8

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      ALTER TABLE content_snapshots
      ADD COLUMN used_cookie_v2 INTEGER NOT NULL DEFAULT 0
      CHECK (used_cookie_v2 IN (0, 1))
      """)
    try db.execute(sql: "PRAGMA user_version = 8")
  }
}
