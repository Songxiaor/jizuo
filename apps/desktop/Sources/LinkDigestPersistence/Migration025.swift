import GRDB

/// 素材卡（2026-11 第二批）：每条内容至多一张，单独一张表，和脑图（Migration009）同一个思路。
///
/// - 删内容时 `ON DELETE CASCADE` 带走素材卡；
/// - 记录用过的模型和 token；
/// - `live_speaker_tag_applied / suppressed` 记「真人口播」标签的来龙去脉：用户手动摘掉后，
///   重新生成不再自动挂回去。
///
/// 只建一张空表，不碰已有行；升级前由 `LocalDatabase.open` 先做整库备份。
public enum Migration025 {
  public static let schemaVersion = 25

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE task_material_cards (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        card_json TEXT NOT NULL,
        live_speaker INTEGER NOT NULL DEFAULT 0 CHECK (live_speaker IN (0, 1)),
        live_speaker_tag_applied INTEGER NOT NULL DEFAULT 0 CHECK (live_speaker_tag_applied IN (0, 1)),
        live_speaker_tag_suppressed INTEGER NOT NULL DEFAULT 0 CHECK (live_speaker_tag_suppressed IN (0, 1)),
        provider TEXT,
        model TEXT,
        prompt_tokens INTEGER,
        completion_tokens INTEGER,
        total_tokens INTEGER,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
      """)
    try db.execute(sql: "PRAGMA user_version = 25")
  }
}
