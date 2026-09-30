import GRDB

/// 合集（2026-09-29 第一期）：一组要放在一起看、**有顺序**的内容。
///
/// ## 为什么不复用标签
///
/// 标签回答「这条内容是什么」，一条内容挂几个标签都没有先后；合集像歌单，
/// 「第 3 讲在第 4 讲前面」本身就是数据。标签表没有地方放这个顺序，硬塞进去
/// 就得给每个「标签 × 内容」加一个只有一部分标签才用的位置列。
///
/// ## 两张表
///
/// - `collections`：合集本身。`origin` 记它是手动建的还是导入文件夹时建的；导入的
///   记下文件夹路径（部分唯一索引：同一个文件夹只对应一个合集，再导入一次时找回它）。
/// - `collection_items`：谁在哪个合集里、排第几。主键 (合集, 内容) 保证同一合集里
///   一条内容只出现一次；`position` 不设唯一约束——调整顺序时整段重写位置，唯一约束
///   会让「先挪 A 再挪 B」的中间状态撞键，而分页已经用 (position, task_id) 兜住并列。
///
/// ## 删除语义
///
/// - 删合集：`ON DELETE CASCADE` 只带走条目关系，内容一条不动。
/// - 内容进回收站：行还在，读的时候按 `tasks.deleted_at_ms IS NULL` 过滤掉——
///   从回收站恢复后它回到原来的位置，不用另存一份「删之前排第几」。
/// - 内容被彻底删除：`task_id` 外键 CASCADE，关系跟着消失，不留悬空行。
///
/// ## 在现有库上执行的代价
///
/// 只建两张空表和三条索引，不碰任何已有行；1,400 条的真实库和空库耗时一样。
public enum Migration024 {
  public static let schemaVersion = 24

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE collections (
        id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36 AND id = lower(id)),
        name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
        origin TEXT NOT NULL CHECK (origin IN ('manual', 'imported_folder')),
        -- 只有导入文件夹建的合集才有；手动合集必须为空。
        folder_path TEXT CHECK ((origin = 'imported_folder') = (folder_path IS NOT NULL)),
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      ) WITHOUT ROWID
      """)
    try db.execute(sql: """
      CREATE UNIQUE INDEX idx_collections_folder_path ON collections(folder_path)
      WHERE folder_path IS NOT NULL
      """)

    try db.execute(sql: """
      CREATE TABLE collection_items (
        collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        added_at_ms INTEGER NOT NULL,
        PRIMARY KEY (collection_id, task_id)
      ) WITHOUT ROWID
      """)
    // 按合集取条目、分页都按 (合集, 位置) 走。
    try db.execute(sql: "CREATE INDEX idx_collection_items_order ON collection_items(collection_id, position, task_id)")
    // 「这条内容在哪些合集里」，以及内容被彻底删除时 CASCADE 按 task_id 找行。
    try db.execute(sql: "CREATE INDEX idx_collection_items_task ON collection_items(task_id)")

    try db.execute(sql: "PRAGMA user_version = 24")
  }
}
