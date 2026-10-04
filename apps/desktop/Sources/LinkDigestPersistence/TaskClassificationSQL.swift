import GRDB
import LinkDigestCore

/// `tasks.content_kind` 与 `tasks.normalized_host` 的**唯一**计算来源。
///
/// 这两列是 Migration021 引入的物化判定。以前每条查询都现算：内容类型靠
/// `canonical_url LIKE 'linkdigest-note:%'` 这种前缀 LIKE（SQLite 的 LIKE 不是
/// 索引可用的前缀查找，EXPLAIN QUERY PLAN 确认是覆盖索引全扫），平台分组靠一个
/// 几百字符、把 `instr/substr` 嵌四层的巨型 CASE，对每行求值几十次。
///
/// 物化之后最大的风险是「列里存的」和「代码算的」漂移。这里把回填、写入维护、
/// 以及等价性测试全部指向同一份表达式字符串，从构造上消除第二个来源：
/// 迁移回填用它，写入路径 `refreshClassification` 用它，测试拿它跟列对账。
public enum TaskClassificationSQL {
  public static let captureKind = "capture"
  public static let noteKind = "note"
  public static let draftKind = "draft"
  public static let workKind = "work"

  /// 内容类型判定。与平台注册表无关，因此永远不会随版本漂移。
  ///
  /// 顺序即语义：笔记、稿件、成品各有互不重叠的 URL scheme，其余一律是抓来的资料。
  public static func contentKind(tableAlias: String) -> String {
    """
    CASE
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%' THEN '\(noteKind)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%' THEN '\(draftKind)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%' THEN '\(workKind)'
      ELSE '\(captureKind)'
    END
    """
  }

  /// SQLite has no URL-host function. URLs stored in `tasks` have already passed
  /// the public-web admission policy, so this expression only extracts and
  /// normalizes that durable canonical host for grouping/filtering; it never
  /// admits a URL or changes network policy.
  ///
  /// 和 `contentKind` 不同，这段是从 `HistoryPlatformRegistry` 生成的——注册表加一个
  /// 平台，同一条旧 URL 的归属就会变。物化列因此需要 `hostExpressionSignature`
  /// 配合 `reconcileHostClassification` 在注册表变更后重算，否则旧记录会永远停在
  /// 加平台之前的那个 host 上，而且不报错、只是分组少了一类。
  public static func normalizedHost(tableAlias: String) -> String {
    let raw = "lower(substr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3), 1, instr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3) || '/', '/') - 1))"
    let normalized = """
      CASE
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.noteHost)'
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.draftHost)'
        WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'
          THEN '\(HistoryPlatformDisplay.workHost)'
        WHEN \(raw) LIKE 'www.%' THEN substr(\(raw), 5)
        WHEN \(raw) LIKE 'www2.%' THEN substr(\(raw), 6)
        WHEN \(raw) LIKE 'm.%' THEN substr(\(raw), 3)
        WHEN \(raw) LIKE 'mobile.%' THEN substr(\(raw), 8)
        WHEN \(raw) LIKE 'amp.%' THEN substr(\(raw), 5)
        ELSE \(raw)
      END
      """
    let cases = HistoryPlatformRegistry.platforms.flatMap { platform -> [String] in
      var result: [String] = []
      if !platform.exactHosts.isEmpty {
        let hosts = platform.exactHosts
          .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
          .joined(separator: ", ")
        result.append("WHEN \(normalized) IN (\(hosts)) THEN '\(platform.canonicalHost)'")
      }
      for suffix in platform.suffixHosts {
        let safe = suffix.replacingOccurrences(of: "'", with: "''")
        result.append("WHEN \(normalized) = '\(safe)' OR \(normalized) LIKE '%.\(safe)' THEN '\(platform.canonicalHost)'")
      }
      return result
    }.joined(separator: "\n")
    return "CASE\n\(cases)\nELSE \(normalized)\nEND"
  }

  /// 条目是否「自有」（2026-09-24）。手动标签优先，其次按默认规则：
  /// 笔记 / 稿件 / 作品，以及备忘录、语音备忘录算自有。与 `ContentOwnership` 同一口径。
  public static func ownSQL(tableAlias t: String) -> String {
    let own = ContentOwnership.ownTagNormalizedName.replacingOccurrences(of: "'", with: "''")
    let external = ContentOwnership.externalTagNormalizedName.replacingOccurrences(of: "'", with: "''")
    let hosts = ContentOwnership.ownLocalHosts.map { "'\($0)'" }.joined(separator: ", ")
    return """
      (
        EXISTS (
          SELECT 1 FROM task_tags own_tt INNER JOIN tags own_tag ON own_tag.id = own_tt.tag_id
          WHERE own_tt.task_id = \(t).id AND own_tag.normalized_name = '\(own)'
        )
        OR (
          NOT EXISTS (
            SELECT 1 FROM task_tags ext_tt INNER JOIN tags ext_tag ON ext_tag.id = ext_tt.tag_id
            WHERE ext_tt.task_id = \(t).id AND ext_tag.normalized_name = '\(external)'
          )
          AND (
            \(t).content_kind IN ('\(noteKind)', '\(draftKind)', '\(workKind)')
            OR \(t).normalized_host IN (\(hosts))
          )
        )
      )
      """
  }

  /// 条目的形式（`ContentForm.rawValue`）。按抓取时已有的信息判定，顺序即优先级：
  /// 作品 → 笔记（含备忘录）→ 录音 → 视频 → 图片 → 文档（其余本地文件）→ 图文（其余网页）。
  ///
  /// 本地文件的音频 / 视频 / 图片靠最新一份本机导入快照的开头区分（`LocalImportDocument`
  /// 固定写「从本机导入的音频/视频：」，图片正文以 `![` 开头）。取最新而不是第一份：
  /// 同一文件重新导入会写入新格式的快照（旧版图片导入第一份是纯识别文字）。
  /// 转写稿是另一种快照（`local_transcription`），不影响判定。网页视频沿用列表行
  /// `has_media` 的同一信号；视频站的视频页再按网址认（YouTube 嵌入播放，既没有本机文件
  /// 也没有扩展传来的视频信息，原来落进「图文」还排第一，2026-10-04 走查）。
  public static func formSQL(tableAlias t: String) -> String {
    let local = LocalImportSource.files.rawValue
    // 本地文件只查一次最新快照的开头（原来音频 / 视频 / 图片三个分支各查一遍）。
    let localForm = """
      (SELECT CASE
          WHEN fcs.head LIKE '从本机导入的音频%' THEN '\(ContentForm.audio.rawValue)'
          WHEN fcs.head LIKE '从本机导入的视频%' THEN '\(ContentForm.video.rawValue)'
          WHEN fcs.head LIKE '![%' THEN '\(ContentForm.image.rawValue)'
          ELSE '\(ContentForm.document.rawValue)'
        END
        FROM (SELECT substr(cs.body_text, 1, 12) AS head FROM content_snapshots cs
          WHERE cs.task_id = \(t).id AND cs.source_kind = 'local_import'
          ORDER BY cs.sequence DESC LIMIT 1) fcs)
      """
    return """
      CASE
        WHEN \(t).content_kind = '\(workKind)' THEN '\(ContentForm.work.rawValue)'
        WHEN \(t).content_kind IN ('\(noteKind)', '\(draftKind)') OR \(t).normalized_host = '\(LocalImportSource.appleNotes.rawValue)'
          THEN '\(ContentForm.note.rawValue)'
        WHEN \(t).normalized_host = '\(LocalImportSource.voiceMemos.rawValue)' THEN '\(ContentForm.audio.rawValue)'
        WHEN \(t).normalized_host = '\(local)' THEN COALESCE(\(localForm), '\(ContentForm.document.rawValue)')
        WHEN EXISTS(SELECT 1 FROM capture_deliveries fcd WHERE fcd.task_id = \(t).id AND fcd.capture_contract_version = 2)
          OR EXISTS(SELECT 1 FROM media_assets fma WHERE fma.task_id = \(t).id)
          OR \(t).canonical_url LIKE '%youtube.com/watch%'
          OR \(t).canonical_url LIKE '%youtu.be/%'
          OR \(t).canonical_url LIKE '%bilibili.com/video/%'
          OR \(t).canonical_url LIKE '%douyin.com/video/%'
          THEN '\(ContentForm.video.rawValue)'
        ELSE '\(ContentForm.article.rawValue)'
      END
      """
  }


  /// 注册表指纹。存的是「用哪段表达式算出来的」，不是版本号——版本号要人记得改，
  /// 表达式自己就会变。
  public static var hostExpressionSignature: String { normalizedHost(tableAlias: "t") }

  /// 回填/重算全表。迁移和注册表漂移修复共用。
  public static func backfillAll(_ db: Database) throws {
    try db.execute(sql: """
      UPDATE tasks SET
        content_kind = \(contentKind(tableAlias: "tasks")),
        normalized_host = \(normalizedHost(tableAlias: "tasks"))
      """)
  }

  /// 单条写入后的维护。`canonical_url` 一变就必须跟着调用——目前只有两个写入点：
  /// `acceptCapture` 建条目，和 `finishPiece` 把稿件原地换成成品。
  public static func refreshClassification(_ db: Database, taskID: String) throws {
    try db.execute(
      sql: """
        UPDATE tasks SET
          content_kind = \(contentKind(tableAlias: "tasks")),
          normalized_host = \(normalizedHost(tableAlias: "tasks"))
        WHERE id = ?
        """,
      arguments: [taskID]
    )
  }

  /// 存下来的指纹跟当前表达式是不是同一份。启动时先读这一行，相同就什么都不做。
  public static func hostClassificationIsCurrent(_ db: Database) throws -> Bool {
    let stored = try String.fetchOne(db, sql: "SELECT expression FROM task_host_classification WHERE id = 1")
    return stored == hostExpressionSignature
  }

  /// 注册表变了就重算一次，并把新指纹存回去。
  public static func reconcileHostClassification(_ db: Database) throws {
    try backfillAll(db)
    try db.execute(
      sql: """
        INSERT INTO task_host_classification (id, expression) VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET expression = excluded.expression
        """,
      arguments: [hostExpressionSignature]
    )
  }
}
