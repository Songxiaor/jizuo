import GRDB

/// 方法库。
///
/// 可复用的写法。启用的会进起草和改写的提示词——所以入库标准是硬的
/// （`MethodAdmission`）：放进去一条「要写得有深度」，它会污染每一次产出。
///
/// 停用不是删除：试过、发现不合适的方法本身也是信息。删掉之后，
/// 半年后同一条又会被重新提炼一次，而没人记得上次为什么不要它。
public enum Migration015 {
  public static let schemaVersion = 15

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE writing_methods (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        -- 入库自检在写入前做。这里的下限只挡明显的脏数据，
        -- 真正的门槛（品质词、重复）在 MethodAdmission 里，因为那需要
        -- 看整个库，SQL 的 CHECK 做不到。
        body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
        origin TEXT NOT NULL DEFAULT 'handwritten'
          CHECK (origin IN ('handwritten', 'distilled')),
        is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
        created_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """)
    // 起草时只取启用的那些，按加入顺序。
    try db.execute(sql: """
      CREATE INDEX idx_writing_methods_enabled
        ON writing_methods(is_enabled, created_at_ms)
      """)

    try db.execute(sql: "PRAGMA user_version = 15")
  }
}
