import GRDB

/// 转写稿的分段时间。
///
/// 挂在 **snapshot** 上而不是 task 上：一条任务可以有原始转写稿、模型整理稿、
/// 用户手改稿好几份正文，而只有识别器直接产出的那一份的文字和时间是对齐的。
/// 整理稿的每个字都可能被模型改过，把原稿的时间套上去，点一下就跳错地方——
/// 一个看起来能用、实际总是差几十秒的功能，比没有这个功能更糟。
///
/// 同理，用户编辑正文之后这份分段即作废，由写入方负责删除（见
/// `deleteTranscriptParagraphs`）。宁可退回没有锚点的普通转写稿。
///
/// `ordinal` 是段落在正文里的顺序，用来和渲染出来的段落一一对上；不靠时间排序，
/// 因为识别结果偶尔会给出时间相同的相邻段。
public enum Migration018 {
  public static let schemaVersion = 18

  static func apply(to db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE transcript_paragraphs (
        snapshot_id TEXT NOT NULL REFERENCES content_snapshots(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text TEXT NOT NULL,
        PRIMARY KEY (snapshot_id, ordinal)
      )
      """)
    try db.execute(sql: "PRAGMA user_version = 18")
  }
}
