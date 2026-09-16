import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// Migration021 把「这条是什么内容」「它来自哪个平台」从每次查询现算改成两列。
///
/// 这类改动最危险的失败方式不是崩溃，是**语义悄悄变了一点点**：某种 URL 形态
/// 分错组，侧边栏少一格、某条记录从此搜不到，用户只会觉得「东西不见了」。
/// 所以这里不测「新列看起来对不对」，测的是「老 SQL 判定」和「新列判定」在一组
/// 覆盖各种 URL 形态的夹具上**逐条相同**。
final class TaskClassificationMigrationTests: XCTestCase {
  // MARK: - 老实现的判定，原样抄在这里当对照组

  private static let legacyIsNote = "canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'"
  private static let legacyIsDraft = "canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'"
  private static let legacyIsWork = "canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'"
  private static let legacyIsCaptured =
    "NOT (\(legacyIsNote)) AND NOT (\(legacyIsDraft)) AND NOT (\(legacyIsWork))"

  /// 老的平台表达式。`TaskClassificationSQL.normalizedHost` 是它原样搬家的结果，
  /// 对照的意义在于：列里存的值必须等于**此刻**现算的值——写入路径漏调用一次
  /// 刷新，这条就红。
  private static func legacyHost(_ alias: String) -> String {
    TaskClassificationSQL.normalizedHost(tableAlias: alias)
  }

  /// 覆盖各种 URL 形态：三种自建内容、www/www2/m/mobile/amp 前缀、带端口、
  /// 大小写、无路径、子域、以及注册表里有品牌映射的几个平台。
  private static let fixtureURLs: [String] = [
    "https://www.example.com/a",
    "https://www2.example.org/b",
    "https://m.bilibili.com/video/BV1",
    "https://mobile.twitter.com/someone/status/1",
    "https://amp.cnn.com/news/x",
    "https://x.com/someone/status/2",
    "https://zhihu.com/p/1",
    "https://zhuanlan.zhihu.com/p/2",
    "https://mp.weixin.qq.com/s/abc",
    "https://www.xiaohongshu.com/explore/1",
    "https://www.douyin.com/video/1",
    "https://youtu.be/xyz",
    "https://www.youtube.com/watch?v=1",
    "http://example.test:8080/c",
    "https://EXAMPLE.COM/UPPER",
    "https://example.com",
    "https://sub.deep.example.net/d/e/f",
    "\(HistoryPlatformDisplay.noteURLPrefix)11111111-1111-4111-8111-111111111111",
    "\(HistoryPlatformDisplay.draftURLPrefix)22222222-2222-4222-8222-222222222222",
    "\(HistoryPlatformDisplay.workURLPrefix)33333333-3333-4333-8333-333333333333",
  ]

  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-classification-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  /// 造一个停在 v20 的库，灌进夹具，然后交给 `LocalDatabase.open` 去升级。
  private func makeVersion20Database(at location: LocalDatabaseLocation) throws -> [String: String] {
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    var idsByURL: [String: String] = [:]
    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try Migration001.apply(to: db, beforeCommit: {})
      try Migration002.apply(to: db)
      try Migration003.apply(to: db)
      try Migration004.apply(to: db)
      try Migration005.apply(to: db)
      try Migration006.apply(to: db)
      try Migration007.apply(to: db)
      try Migration008.apply(to: db)
      try Migration009.apply(to: db)
      try Migration010.apply(to: db)
      try Migration011.apply(to: db)
      try Migration012.apply(to: db)
      try Migration013.apply(to: db)
      try Migration014.apply(to: db)
      try Migration015.apply(to: db)
      try Migration016.apply(to: db)
      try Migration017.apply(to: db)
      try Migration018.apply(to: db)
      try Migration019.apply(to: db)
      try Migration020.apply(to: db)

      let now = Int64(1_760_000_000_000)
      for (offset, url) in Self.fixtureURLs.enumerated() {
        let id = UUID().uuidString.lowercased()
        idsByURL[url] = id
        // 更新时间拉开，分页顺序才有可比性；隔一条收藏一次，收藏计数才不是 0。
        let updated = now - Int64(offset) * 1_000
        try db.execute(
          sql: """
            INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite)
            VALUES (?, ?, 1, ?, ?, ?)
            """,
          arguments: [id, url, updated, updated, offset % 2 == 0 ? 1 : 0]
        )
        try db.execute(
          sql: """
            INSERT INTO content_snapshots (
              id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
              title, platform, capture_method, completeness, body_text, character_count, body_sha256,
              source_label, used_cookie
            ) VALUES (?, ?, 1, ?, ?, 'page', ?, ?, 'generic', 'rendered_dom', 'complete', ?, ?, ?, '浏览器扩展', 0)
            """,
          arguments: [
            UUID().uuidString.lowercased(), id, updated, updated, url,
            "标题 \(offset)", "正文 \(offset)", 5,
            String(format: "%064x", offset + 1),
          ]
        )
      }
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 20)
    }
    try queue.close()
    return idsByURL
  }

  // MARK: - 等价性

  func testMigratedColumnsMatchTheLegacyPredicatesRowByRow() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }

      let mismatches = try database.read { db in
        try String.fetchAll(db, sql: """
          SELECT t.canonical_url
          FROM tasks t
          WHERE t.content_kind <> (
            CASE
              WHEN t.\(Self.legacyIsNote) THEN 'note'
              WHEN t.\(Self.legacyIsDraft) THEN 'draft'
              WHEN t.\(Self.legacyIsWork) THEN 'work'
              ELSE 'capture'
            END
          )
          OR t.normalized_host IS NOT (\(Self.legacyHost("t")))
          """)
      }
      XCTAssertEqual(mismatches, [], "新列与老 SQL 判定不一致的 URL")
    }
  }

  func testEveryFixtureRowGotClassified() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let unclassified = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE normalized_host IS NULL") ?? -1
      }
      XCTAssertEqual(unclassified, 0)
      let kinds = try database.read { db in
        try String.fetchAll(db, sql: "SELECT DISTINCT content_kind FROM tasks ORDER BY content_kind")
      }
      XCTAssertEqual(kinds, ["capture", "draft", "note", "work"])
    }
  }

  // MARK: - 计数、分页、平台分组结果不变

  func testNavigationCountsMatchLegacySQLAfterMigration() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let counts = try repository.navigationCounts()

      let legacy = try repository.database.read { db -> (Int, Int, Int, Int, Int, [String: Int]) in
        let notes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(Self.legacyIsNote)") ?? -1
        let works = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(Self.legacyIsWork)") ?? -1
        let all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(Self.legacyIsCaptured)") ?? -1
        let favorite = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM tasks WHERE \(Self.legacyIsCaptured) AND is_favorite = 1"
        ) ?? -1
        let unsummarized = try Int.fetchOne(db, sql: """
          SELECT COUNT(*) FROM tasks t
          WHERE NOT (t.\(Self.legacyIsNote)) AND NOT (t.\(Self.legacyIsDraft)) AND NOT (t.\(Self.legacyIsWork))
            AND NOT EXISTS (
              SELECT 1 FROM runs sr
              INNER JOIN artifacts sa ON sa.run_id = sr.id
              WHERE sr.task_id = t.id AND sr.status = 'completed'
            )
          """) ?? -1
        var platforms: [String: Int] = [:]
        let host = Self.legacyHost("t")
        for row in try Row.fetchAll(db, sql: """
          SELECT \(host) AS host, COUNT(*) AS count
          FROM tasks t
          WHERE \(host) <> ''
            AND NOT (t.\(Self.legacyIsNote)) AND NOT (t.\(Self.legacyIsDraft)) AND NOT (t.\(Self.legacyIsWork))
          GROUP BY \(host)
          """) {
          platforms[row["host"]] = row["count"]
        }
        return (notes, works, all, favorite, unsummarized, platforms)
      }

      XCTAssertEqual(counts.notes, legacy.0)
      XCTAssertEqual(counts.works, legacy.1)
      XCTAssertEqual(counts.all, legacy.2)
      XCTAssertEqual(counts.favorite, legacy.3)
      XCTAssertEqual(counts.unsummarized, legacy.4)
      XCTAssertEqual(
        Dictionary(uniqueKeysWithValues: counts.platforms.map { ($0.host, $0.count) }),
        legacy.5
      )
      XCTAssertFalse(counts.platforms.isEmpty)
    }
  }

  func testHistoryPageScopesMatchLegacySQLAfterMigration() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      func legacyIDs(_ predicate: String) throws -> [String] {
        try repository.database.read { db in
          try String.fetchAll(db, sql: """
            SELECT t.id FROM tasks t WHERE \(predicate)
            ORDER BY t.updated_at_ms DESC, t.id DESC
            """)
        }
      }
      func pageIDs(_ scope: HistoryListScope) throws -> [String] {
        try repository.historyPage(limit: 200, after: nil, filter: .init(scope: scope))
          .rows.map(\.taskID.rawValue)
      }

      XCTAssertEqual(
        try pageIDs(.all),
        try legacyIDs("NOT (t.\(Self.legacyIsDraft)) AND NOT (t.\(Self.legacyIsNote)) AND NOT (t.\(Self.legacyIsWork))")
      )
      XCTAssertEqual(try pageIDs(.notes), try legacyIDs("t.\(Self.legacyIsNote) AND NOT (t.\(Self.legacyIsDraft))"))
      XCTAssertEqual(try pageIDs(.drafts), try legacyIDs("t.\(Self.legacyIsDraft)"))
      XCTAssertEqual(try pageIDs(.works), try legacyIDs("t.\(Self.legacyIsWork)"))
      XCTAssertFalse(try pageIDs(.all).isEmpty)
      XCTAssertEqual(try pageIDs(.notes).count, 1)
      XCTAssertEqual(try pageIDs(.drafts).count, 1)
      XCTAssertEqual(try pageIDs(.works).count, 1)
    }
  }

  func testHostFilterMatchesLegacyHostExpression() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let hosts = try repository.navigationCounts().platforms.map(\.host)
      XCTAssertFalse(hosts.isEmpty)
      for host in hosts {
        let filtered = try repository.historyPage(limit: 200, after: nil, filter: .init(hosts: [host]))
          .rows.map(\.taskID.rawValue).sorted()
        // 参数要和 `HistoryListFilter` 一样先过一遍规范化：它会把 `:8080` 这类端口
        // 去掉，老实现拿到的也是规范化之后的值。不跟着做的话比的就不是同一个输入。
        let legacy = try repository.database.read { db in
          try String.fetchAll(
            db,
            sql: """
              SELECT t.id FROM tasks t
              WHERE \(Self.legacyHost("t")) = ?
                AND NOT (t.\(Self.legacyIsDraft))
                AND NOT (t.\(Self.legacyIsNote))
                AND NOT (t.\(Self.legacyIsWork))
              """,
            arguments: [HistoryPlatformRegistry.canonicalHost(for: host)]
          )
        }.sorted()
        XCTAssertEqual(filtered, legacy, "host=\(host) 的筛选结果与老表达式不一致")
      }
    }
  }

  // MARK: - 写入路径

  func testWritePathKeepsColumnsInSyncWithTheLiveExpression() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      for (offset, url) in ["https://www.example.com/x", "https://m.bilibili.com/video/BV2"].enumerated() {
        _ = try repository.acceptCapture(.init(
          document: CapturedDocument(
            createdAt: "2026-07-28T00:00:00Z",
            idempotencyKey: "classification-\(offset)",
            origin: .manualLink,
            url: url,
            title: "标题",
            platform: "generic",
            method: "rendered_dom",
            text: "正文正文正文",
            completeness: "complete",
            capturedAt: "2026-07-28T00:00:00Z",
            sourceLabel: "浏览器扩展"
          ),
          receivedAtMilliseconds: 1_760_000_000_000
        ))
      }

      let mismatches = try repository.database.read { db in
        try String.fetchAll(db, sql: """
          SELECT t.canonical_url FROM tasks t
          WHERE t.normalized_host IS NOT (\(Self.legacyHost("t")))
            OR t.content_kind <> (\(TaskClassificationSQL.contentKind(tableAlias: "t")))
          """)
      }
      XCTAssertEqual(mismatches, [], "acceptCapture 之后派生列必须已经写好")
      let hosts = try repository.navigationCounts().platforms.map(\.host).sorted()
      XCTAssertEqual(hosts.count, 2, "两条不同平台的记录应当在侧边栏分成两格：\(hosts)")
    }
  }

  /// 平台注册表是编译期常量，加一个平台时旧记录的归属要跟着变，而 schema 版本不动。
  /// 这条把「指纹变了就重算」钉住：手工把指纹改脏 + 把列写乱，重开一次必须自愈。
  func testStaleHostSignatureTriggersRebackfillOnOpen() throws {
    try withTemporaryLocation { location in
      _ = try makeVersion20Database(at: location)
      do {
        let database = try LocalDatabase.open(at: location)
        try database.write { db in
          try db.execute(sql: "UPDATE task_host_classification SET expression = 'stale' WHERE id = 1")
          try db.execute(sql: "UPDATE tasks SET normalized_host = 'wrong'")
        }
        try database.close()
      }
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let wrong = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE normalized_host = 'wrong'") ?? -1
      }
      XCTAssertEqual(wrong, 0, "指纹变了就应当整表重算")
      let signature = try database.read { db in
        try String.fetchOne(db, sql: "SELECT expression FROM task_host_classification WHERE id = 1")
      }
      XCTAssertEqual(signature, TaskClassificationSQL.hostExpressionSignature)
    }
  }

  func testTopicCandidateMaterialsHasTaskIndex() throws {
    try withTemporaryLocation { location in
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let plan = try database.read { db in
        try Row.fetchAll(
          db,
          sql: "EXPLAIN QUERY PLAN SELECT 1 FROM topic_candidate_materials WHERE task_id = 'x'"
        ).map { ($0["detail"] as String?) ?? "" }.joined(separator: " ")
      }
      XCTAssertTrue(plan.contains("idx_topic_candidate_materials_task"), "删记录时按 task_id 找行不该全表扫：\(plan)")
    }
  }
}
