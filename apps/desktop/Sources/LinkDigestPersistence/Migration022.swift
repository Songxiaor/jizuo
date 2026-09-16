import GRDB

/// 全文搜索从 6 处 `LIKE '%x%'` 全扫换成 FTS5 trigram 索引。
///
/// 旧实现的代码注释写着「本机全部正文合计 185 KB，扫一遍是毫秒级」。那个前提已经
/// 过期 28 倍：`content_snapshots.body_text` 现在 3.8MB，`artifacts.body_text` 1.5MB，
/// 每敲一个字就把这 5.3MB 连同 UTF-8 解码全过一遍。
///
/// 顺带修一个正确性缺陷：旧查询搜的是「有效快照」`es`，而 `es` 的定义**排除**了
/// `local_transcription` 和 `burned_in_subtitles`，所以视频转写稿的正文永远搜不到——
/// 用户最想找回的「他在视频里说的那句话」正好落在被排除的那一层里。这里按快照
/// 逐条入索引，转写稿自然进来。
///
/// ## 为什么是独立 FTS 表 + 映射表，而不是 `content=` 外部内容表
///
/// `content_snapshots` 和 `artifacts` 都是 `WITHOUT ROWID`，没有可供 FTS5
/// `content_rowid=` 关联的整型 rowid，外部内容表方案直接不成立。
///
/// 独立 FTS 表只有隐式整型 rowid，而源表主键是 UUID 文本，所以需要一张映射表把
/// 「UUID → FTS rowid」钉住，删除和更新才能定位到具体那一行。新 rowid 用
/// `MAX(rowid_value)+1` 现取，不用 `last_insert_rowid()`——后者在触发器里的语义
/// 依赖上下文，是那种平时对、偶尔错的写法。
///
/// 正文不在映射表里再存一份：FTS 表自己存一份已经够了，源表 5.3MB 再复制一遍
/// 只是白白让库翻倍。
public enum Migration022 {
  public static let schemaVersion = 22

  /// 短于 3 个字符的查询词 trigram 索引命不中（三元组建不起来），退回 LIKE。
  /// 一两个字的搜索本来命中面就极广，全扫一次也是可接受的代价。
  public static let minimumTrigramLength = 3

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE VIRTUAL TABLE task_search USING fts5(body, tokenize='trigram')
      """)
    try db.execute(sql: """
      CREATE TABLE task_search_map (
        rowid_value INTEGER PRIMARY KEY,
        kind TEXT NOT NULL CHECK (kind IN ('snapshot', 'artifact')),
        source_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        UNIQUE (kind, source_id)
      )
      """)
    try db.execute(sql: "CREATE INDEX idx_task_search_map_task ON task_search_map(task_id)")

    // 存量回填。标题、来源标签和正文拼进同一列：旧实现对这三者分别 LIKE，
    // 合成一列的命中集合与「三者任一包含子串」完全相同，而索引只建一份。
    try db.execute(sql: """
      INSERT INTO task_search_map (rowid_value, kind, source_id, task_id)
      SELECT ROW_NUMBER() OVER (ORDER BY s.task_id, s.sequence), 'snapshot', s.id, s.task_id
      FROM content_snapshots s
      """)
    try db.execute(sql: """
      INSERT INTO task_search_map (rowid_value, kind, source_id, task_id)
      SELECT
        (SELECT IFNULL(MAX(rowid_value), 0) FROM task_search_map)
          + ROW_NUMBER() OVER (ORDER BY a.id),
        'artifact', a.id, r.task_id
      FROM artifacts a
      INNER JOIN runs r ON r.id = a.run_id
      """)
    try db.execute(sql: """
      INSERT INTO task_search (rowid, body)
      SELECT m.rowid_value,
        COALESCE(s.title, '') || ' ' || s.source_label || ' ' || s.body_text
      FROM task_search_map m
      INNER JOIN content_snapshots s ON s.id = m.source_id
      WHERE m.kind = 'snapshot'
      """)
    try db.execute(sql: """
      INSERT INTO task_search (rowid, body)
      SELECT m.rowid_value, a.body_text
      FROM task_search_map m
      INNER JOIN artifacts a ON a.id = m.source_id
      WHERE m.kind = 'artifact'
      """)

    for statement in triggerStatements { try db.execute(sql: statement) }

    try db.execute(sql: "PRAGMA user_version = 22")
  }

  /// 触发器单独拎出来，迁移和「重建索引」共用一份定义。
  static let triggerStatements: [String] = [
    """
    CREATE TRIGGER task_search_snapshot_insert AFTER INSERT ON content_snapshots BEGIN
      INSERT INTO task_search_map (rowid_value, kind, source_id, task_id)
      VALUES (
        (SELECT IFNULL(MAX(rowid_value), 0) + 1 FROM task_search_map),
        'snapshot', new.id, new.task_id
      );
      INSERT INTO task_search (rowid, body)
      VALUES (
        (SELECT rowid_value FROM task_search_map WHERE kind = 'snapshot' AND source_id = new.id),
        COALESCE(new.title, '') || ' ' || new.source_label || ' ' || new.body_text
      );
    END
    """,
    // 正文改写（转写稿回填、字幕层编辑）走 UPDATE，索引必须跟着变，
    // 否则搜到的是上一版的字。
    """
    CREATE TRIGGER task_search_snapshot_update
    AFTER UPDATE OF title, source_label, body_text ON content_snapshots BEGIN
      UPDATE task_search
      SET body = COALESCE(new.title, '') || ' ' || new.source_label || ' ' || new.body_text
      WHERE rowid = (SELECT rowid_value FROM task_search_map WHERE kind = 'snapshot' AND source_id = new.id);
    END
    """,
    """
    CREATE TRIGGER task_search_snapshot_delete AFTER DELETE ON content_snapshots BEGIN
      DELETE FROM task_search
      WHERE rowid = (SELECT rowid_value FROM task_search_map WHERE kind = 'snapshot' AND source_id = old.id);
      DELETE FROM task_search_map WHERE kind = 'snapshot' AND source_id = old.id;
    END
    """,
    """
    CREATE TRIGGER task_search_artifact_insert AFTER INSERT ON artifacts BEGIN
      INSERT INTO task_search_map (rowid_value, kind, source_id, task_id)
      VALUES (
        (SELECT IFNULL(MAX(rowid_value), 0) + 1 FROM task_search_map),
        'artifact', new.id, (SELECT task_id FROM runs WHERE id = new.run_id)
      );
      INSERT INTO task_search (rowid, body)
      VALUES (
        (SELECT rowid_value FROM task_search_map WHERE kind = 'artifact' AND source_id = new.id),
        new.body_text
      );
    END
    """,
    """
    CREATE TRIGGER task_search_artifact_update
    AFTER UPDATE OF body_text ON artifacts BEGIN
      UPDATE task_search SET body = new.body_text
      WHERE rowid = (SELECT rowid_value FROM task_search_map WHERE kind = 'artifact' AND source_id = new.id);
    END
    """,
    """
    CREATE TRIGGER task_search_artifact_delete AFTER DELETE ON artifacts BEGIN
      DELETE FROM task_search
      WHERE rowid = (SELECT rowid_value FROM task_search_map WHERE kind = 'artifact' AND source_id = old.id);
      DELETE FROM task_search_map WHERE kind = 'artifact' AND source_id = old.id;
    END
    """,
    // 兜底：删条目时按 task_id 扫一遍。
    //
    // 外键 CASCADE 删子表是不是会触发子表上的 DELETE 触发器，取决于连接的
    // `recursive_triggers` 设置——这是那种「本机对、换台机器错」的依赖。删记录后
    // 还能搜到是最难发现的一类脏数据（没有报错，只是结果里多一条打不开的东西），
    // 所以不赌这个行为，直接在 tasks 上再挂一道。重复删是幂等的。
    """
    CREATE TRIGGER task_search_task_delete AFTER DELETE ON tasks BEGIN
      DELETE FROM task_search
      WHERE rowid IN (SELECT rowid_value FROM task_search_map WHERE task_id = old.id);
      DELETE FROM task_search_map WHERE task_id = old.id;
    END
    """,
  ]
}
