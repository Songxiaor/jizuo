import GRDB

/// 爆款实验室:盲预测与校准。
///
/// 关闭这个实验性功能时，模块从界面消失，但**数据保留不删**——
/// 攒了三个月的预测记录，因为手滑关了一次开关就没了，是不可接受的。
public enum Migration016 {
  public static let schemaVersion = 16

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE hit_predictions (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
        predicted TEXT NOT NULL CHECK (predicted IN ('quiet', 'modest', 'good', 'hit')),
        -- 为什么这么预测。这一栏比预测本身值钱：三天后回头看，
        -- 「我以为标题够反常」和「我以为这个话题正热」是两种完全不同的
        -- 误判，而只看档位分不出来。
        reasoning TEXT NOT NULL DEFAULT '' CHECK (length(reasoning) <= 2000),
        predicted_at_ms INTEGER NOT NULL,
        -- 实际结果。null 表示还没出。
        actual TEXT CHECK (actual IS NULL OR actual IN ('quiet', 'modest', 'good', 'hit')),
        actual_at_ms INTEGER,
        review TEXT NOT NULL DEFAULT '' CHECK (length(review) <= 2000)
      ) WITHOUT ROWID
      """);
    // 一件创作只预测一次。
    //
    // 允许多次就等于允许重来：看到结果不理想再补一条，
    // 「盲」就没了，而整个校准循环靠的就是这个「盲」。
    try db.execute(sql: """
      CREATE UNIQUE INDEX idx_hit_predictions_piece ON hit_predictions(piece_id)
      """)
    try db.execute(sql: """
      CREATE INDEX idx_hit_predictions_time ON hit_predictions(predicted_at_ms DESC)
      """)

    try db.execute(sql: "PRAGMA user_version = 16")
  }
}
