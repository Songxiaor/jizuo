import GRDB

/// 工作台：一件创作从灵感到成品的容器。
///
/// 为什么不复用 `tasks`：一条 task 是「一份内容」，而一件创作是**一个跨越多天的过程**——
/// 它有阶段、会引用多份素材、正文一直在变。把过程塞进内容表，两者都会变形。
///
/// 但正文**不另存**：它就是一条笔记（`note_task_id`）。这样标签、搜索、双链、导出
/// 全部直接可用，成稿发出去以后收到的反馈也能顺着笔记回到素材库。
public enum Migration013 {
  public static let schemaVersion = 13

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE pieces (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        -- 灵感原句。写到第三天很容易偏离，这句话是锚，所以它独立于标题存着。
        spark TEXT NOT NULL CHECK (length(spark) BETWEEN 1 AND 2000),
        -- NULL 表示「跟着推断走」，有值才是用户手动覆盖过。
        -- 用可空列而不是空串：空串既要绕开 CHECK，读的时候也分不清
        -- 「没设过」和「设成了空」。
        stage TEXT CHECK (stage IS NULL OR stage IN ('spark', 'collect', 'draft', 'polish', 'done')),
        -- 正文所在的笔记。建创作时就建好那条笔记，于是「写」从第一秒起就是可用的。
        note_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        -- 完成时间。null 表示还在进行中，首页靠它把已发出的沉到下面。
        finished_at_ms INTEGER
      ) WITHOUT ROWID
      """)
    // 首页按「最近动过」排，进行中的在前。
    try db.execute(sql: "CREATE INDEX idx_pieces_updated ON pieces(finished_at_ms, updated_at_ms DESC)")
    // 一条笔记只当一件创作的正文，避免两件创作写到同一份稿子上。
    try db.execute(sql: "CREATE UNIQUE INDEX idx_pieces_note ON pieces(note_task_id)")

    try db.execute(sql: """
      CREATE TABLE piece_materials (
        piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
        -- 只引用，不拷贝正文：原素材改了这里看到的就是新的，
        -- 素材被删了这里显示「已不在」而不是留一份幽灵副本。
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        added_at_ms INTEGER NOT NULL,
        PRIMARY KEY (piece_id, task_id)
      ) WITHOUT ROWID
      """)
    try db.execute(sql: "CREATE INDEX idx_piece_materials_task ON piece_materials(task_id)")

    try db.execute(sql: """
      CREATE TABLE piece_events (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        piece_id TEXT NOT NULL REFERENCES pieces(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        detail TEXT NOT NULL DEFAULT '',
        created_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """)
    try db.execute(sql: "CREATE INDEX idx_piece_events_piece ON piece_events(piece_id, created_at_ms)")

    try db.execute(sql: "PRAGMA user_version = 13")
  }
}
