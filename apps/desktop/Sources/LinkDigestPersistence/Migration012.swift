import GRDB

/// 文章级收藏：给 `tasks` 加一个布尔标记。纯加列、带默认值，存量数据一律视为未收藏。
///
/// 和「收藏视频到本地」是两回事——那个走 `media_assets`，是把临时视频落盘；
/// 这个只是用户对条目的「稍后回看」标记，不碰任何媒体。
public enum Migration012 {
  public static let schemaVersion = 12

  static func apply(to db: Database) throws {
    try db.execute(sql: "ALTER TABLE tasks ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0")
    // 收藏筛选和侧栏计数都按这一列过滤，建个索引免得条目一多就全表扫。
    try db.execute(sql: "CREATE INDEX idx_tasks_is_favorite ON tasks(is_favorite) WHERE is_favorite = 1")
    try db.execute(sql: "PRAGMA user_version = 12")
  }
}
