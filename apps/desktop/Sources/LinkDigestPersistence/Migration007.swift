import GRDB

/// Optional security-scoped bookmark for media saved outside Application Support.
/// Existing internal media keeps NULL and resolves through `relative_path`.
public enum Migration007 {
  public static let schemaVersion = 7

  static func apply(to db: Database) throws {
    try db.execute(sql: "ALTER TABLE media_assets ADD COLUMN file_bookmark BLOB")
    try db.execute(sql: "PRAGMA user_version = 7")
  }
}
