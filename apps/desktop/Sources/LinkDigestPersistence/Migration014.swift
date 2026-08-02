import GRDB

/// 每日选题板。
///
/// 按天一批。被否决的**不删**——「这类角度他从来不选」这个结论只能从
/// 被否决的东西里得出来，删掉等于把唯一的负样本扔了。
public enum Migration014 {
  public static let schemaVersion = 14

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE topic_candidates (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        -- 当地日期的零点。用户说的「今天的选题」是他日历上的今天，
        -- 所以这个值在写入时就按当地时区算好，读的时候不再换算。
        day_start_ms INTEGER NOT NULL,
        title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
        -- 摘要必须短，读不完的选题等于没出。长度上限写进 CHECK：
        -- 模型偶尔会无视提示词里的字数要求，那时该被拦下的是数据不是界面。
        summary TEXT NOT NULL DEFAULT '' CHECK (length(summary) <= 400),
        -- 不受偏好约束的那一条。每天留一条，防止候选收敛成回音室。
        is_out_of_bounds INTEGER NOT NULL DEFAULT 0 CHECK (is_out_of_bounds IN (0, 1)),
        verdict TEXT NOT NULL DEFAULT 'pending'
          CHECK (verdict IN ('pending', 'taken', 'declined')),
        created_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """)
    // 选题板按天倒序翻。
    try db.execute(sql: """
      CREATE INDEX idx_topic_candidates_day
        ON topic_candidates(day_start_ms DESC, created_at_ms)
      """)

    try db.execute(sql: """
      CREATE TABLE topic_candidate_materials (
        candidate_id TEXT NOT NULL REFERENCES topic_candidates(id) ON DELETE CASCADE,
        -- 素材被删了，这条关联跟着走：候选还在，只是少了一份出处。
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        PRIMARY KEY (candidate_id, task_id)
      ) WITHOUT ROWID
      """)

    try db.execute(sql: "PRAGMA user_version = 14")
  }
}
