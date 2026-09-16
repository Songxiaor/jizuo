import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 从每个还在野外的旧版本升到最新版，数据一条不少。
///
/// 迁移最危险的失败方式不是崩溃，是**悄悄少了点东西**：某张表的行在重建时掉了、
/// 中文正文的编码在某一步被弄坏、FTS 索引没跟着回填于是搜索突然搜不到旧内容。
/// 这几种都不报错，用户只会觉得「东西不见了」。
///
/// 所以这里不看「新列长得对不对」，而是造一个带样本行的旧库，跑完整条迁移链，
/// 然后逐表对账：行数、关键字段、搜索、计数，全部和升级前一致。
final class MigrationMatrixTests: XCTestCase {
  /// 还在野外、需要能升上来的版本。
  ///
  /// v20 是这条矩阵的下界：再往前的库在 Migration021 之前就已经没有已知安装了，
  /// 而每加一个版本都要多跑一整条链。
  private static let originVersions = [20, 21, 22, 23]

  private struct Fixture {
    let taskIDs: [String]
    let noteTaskID: String
    let transcriptBody: String
    let summaryBody: String
  }

  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-migration-matrix-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  /// 每张主要表至少两行，正文是中文，并且带一份转写快照。
  private func seed(at location: LocalDatabaseLocation, version: Int) throws -> Fixture {
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    let transcriptBody = "视频里他说：把复杂的事情讲清楚，比把简单的事情讲漂亮难得多。"
    let summaryBody = "总结：作者主张先把链路跑通，再去优化其中最慢的一段。"
    var taskIDs: [String] = []
    var noteTaskID = ""

    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try MigrationFixture.apply(upTo: version, in: db)

      let urls = [
        "https://example.test/文章一",
        "https://www.zhihu.com/p/12345",
        "\(HistoryPlatformDisplay.noteURLPrefix)44444444-4444-4444-8444-444444444444",
      ]
      let base = Int64(1_760_000_000_000)
      for (offset, url) in urls.enumerated() {
        let taskID = UUID().uuidString.lowercased()
        taskIDs.append(taskID)
        if url.hasPrefix(HistoryPlatformDisplay.noteURLPrefix) { noteTaskID = taskID }
        let timestamp = base - Int64(offset) * 1_000
        try db.execute(
          sql: """
            INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite)
            VALUES (?, ?, 1, ?, ?, ?)
            """,
          arguments: [taskID, url, timestamp, timestamp, offset == 0 ? 1 : 0]
        )
        try Self.insertSnapshot(
          db,
          taskID: taskID,
          sequence: 1,
          sourceKind: "page",
          url: url,
          title: "标题 \(offset) · 中文",
          body: "正文 \(offset)：这段文字专门用来验证中文在迁移之后一个字都不少。",
          timestamp: timestamp,
          shaSeed: offset * 10
        )
        // 第一条再带一份转写快照：它属于「派生层」，最容易在重建索引时被漏掉。
        if offset == 0 {
          try Self.insertSnapshot(
            db,
            taskID: taskID,
            sequence: 2,
            sourceKind: "local_transcription",
            url: url,
            title: "标题 \(offset) · 转写",
            body: transcriptBody,
            timestamp: timestamp + 1,
            shaSeed: offset * 10 + 1
          )
        }
      }

      // 两条 run + 两份 artifact（一条总结、一条翻译）。
      for (offset, kind) in ["summarize", "translate"].enumerated() {
        let runID = UUID().uuidString.lowercased()
        let snapshotID: String = try String.fetchOne(
          db,
          sql: "SELECT id FROM content_snapshots WHERE task_id = ? AND sequence = 1",
          arguments: [taskIDs[offset]]
        ) ?? ""
        try db.execute(
          sql: """
            INSERT INTO runs (id, task_id, snapshot_id, idempotency_key, kind, status, created_at_ms, started_at_ms, finished_at_ms)
            VALUES (?, ?, ?, ?, ?, 'completed', ?, ?, ?)
            """,
          arguments: [runID, taskIDs[offset], snapshotID, "matrix-\(kind)", kind, base, base + 1, base + 2]
        )
        try db.execute(
          sql: """
            INSERT INTO artifacts (id, run_id, content_format, completeness, body_text, created_at_ms, updated_at_ms)
            VALUES (?, ?, 'markdown', 'complete', ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString.lowercased(), runID,
            kind == "summarize" ? summaryBody : "译文：把复杂的事情讲清楚。",
            base + 2, base + 2,
          ]
        )
      }

      // 两个标签，各挂一条。
      for (index, name) in ["写作", "工程"].enumerated() {
        try db.execute(
          sql: "INSERT INTO tags (normalized_name, display_name, created_at_ms) VALUES (?, ?, ?)",
          arguments: [name, name, base]
        )
        let tagID = db.lastInsertedRowID
        try db.execute(
          sql: "INSERT INTO task_tags (task_id, tag_id, created_at_ms) VALUES (?, ?, ?)",
          arguments: [taskIDs[index], tagID, base]
        )
      }

      // v21 起 `content_kind` 默认是 capture。生产写入会立刻 refreshClassification；
      // 夹具是裸 INSERT，不回填的话笔记会永远停在 capture 上，v21/v22/v23
      // 又不再跑 Migration021，侧边栏笔记计数就会是 0。v20 还没有这两列，
      // 交给升级时的 Migration021 回填。
      if version >= Migration021.schemaVersion {
        try TaskClassificationSQL.backfillAll(db)
      }

      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), version)
    }
    try queue.close()
    return Fixture(
      taskIDs: taskIDs,
      noteTaskID: noteTaskID,
      transcriptBody: transcriptBody,
      summaryBody: summaryBody
    )
  }

  private static func insertSnapshot(
    _ db: Database,
    taskID: String,
    sequence: Int,
    sourceKind: String,
    url: String,
    title: String,
    body: String,
    timestamp: Int64,
    shaSeed: Int
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO content_snapshots (
          id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
          title, platform, capture_method, completeness, body_text, character_count, body_sha256,
          source_label, used_cookie
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'generic', 'rendered_dom', 'complete', ?, ?, ?, '浏览器扩展', 0)
        """,
      arguments: [
        UUID().uuidString.lowercased(), taskID, sequence, timestamp, timestamp, sourceKind, url,
        title, body, body.count, String(format: "%064x", shaSeed + 1),
      ]
    )
  }

  private static func tableCounts(_ db: Database) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for table in ["tasks", "content_snapshots", "runs", "artifacts", "tags", "task_tags"] {
      counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
    return counts
  }

  func testEveryLiveSchemaVersionUpgradesWithoutLosingData() throws {
    for version in Self.originVersions {
      try withTemporaryLocation { location in
        let fixture = try seed(at: location, version: version)

        // 升级前的账。
        var readOnly = Configuration()
        readOnly.readonly = true
        let before = try DatabaseQueue(path: location.databaseURL.path, configuration: readOnly)
        let expectedCounts = try before.read(Self.tableCounts)
        let expectedURLs = try before.read { db in
          try String.fetchAll(db, sql: "SELECT canonical_url FROM tasks ORDER BY id")
        }
        let expectedBodies = try before.read { db in
          try String.fetchAll(db, sql: "SELECT body_text FROM content_snapshots ORDER BY id")
        }
        try before.close()

        let repository = try GRDBHistoryRepository.open(at: location)
        defer { try? repository.database.close() }

        // 1. 版本真的升到最新。
        let upgraded = try repository.database.read { db in
          try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(upgraded, LocalDatabase.latestSchemaVersion, "v\(version) 没有升到最新版")

        // 2. 逐表行数不变。
        let actualCounts = try repository.database.read(Self.tableCounts)
        XCTAssertEqual(actualCounts, expectedCounts, "v\(version) 升级后行数变了")

        // 3. 关键字段逐条相同（含中文正文）。
        let actualURLs = try repository.database.read { db in
          try String.fetchAll(db, sql: "SELECT canonical_url FROM tasks ORDER BY id")
        }
        XCTAssertEqual(actualURLs, expectedURLs, "v\(version) 升级后链接变了")
        let actualBodies = try repository.database.read { db in
          try String.fetchAll(db, sql: "SELECT body_text FROM content_snapshots ORDER BY id")
        }
        XCTAssertEqual(actualBodies, expectedBodies, "v\(version) 升级后正文变了")

        // 4. 完整性检查过关，外键没有悬空。
        let maintenance = DatabaseMaintenance(database: repository.database)
        XCTAssertEqual(try maintenance.integrityCheck(), "ok")
        let danglingForeignKeys = try repository.database.read { db in
          try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        XCTAssertEqual(danglingForeignKeys, 0, "v\(version) 升级后出现悬空外键")

        // 5. 搜索能搜到旧内容——正文、转写稿和总结三层都要能搜到。
        func search(_ text: String) throws -> Int {
          try repository.historyPage(limit: 50, after: nil, filter: .init(searchText: text)).rows.count
        }
        XCTAssertGreaterThan(try search("一个字都不少"), 0, "v\(version) 升级后正文搜不到")
        XCTAssertGreaterThan(try search("讲漂亮"), 0, "v\(version) 升级后转写稿搜不到")
        XCTAssertGreaterThan(try search("先把链路跑通"), 0, "v\(version) 升级后总结搜不到")

        // 6. 侧边栏计数和列表一致。
        let counts = try repository.navigationCounts()
        let listed = try repository.historyPage(limit: 50, after: nil, filter: .none).rows.count
        XCTAssertEqual(counts.all, listed, "v\(version) 升级后计数和列表对不上")
        XCTAssertEqual(counts.notes, 1, "v\(version) 升级后笔记归类错了")
        XCTAssertEqual(counts.trash, 0)
        XCTAssertEqual(counts.favorite, 1)
        XCTAssertEqual(counts.tags.count, 2)

        // 7. 新增能力在每条升级路径上都可用。
        let anyTask = try XCTUnwrap(TaskID(fixture.taskIDs[0]))
        try repository.moveToTrash(taskIDs: [anyTask])
        XCTAssertEqual(try repository.trashCount(), 1)
        try repository.restoreFromTrash(taskIDs: [anyTask])
        try repository.saveReadingPosition(0.42, taskID: anyTask, updatedAtMilliseconds: 1)
        XCTAssertEqual(try repository.readingPosition(taskID: anyTask), 0.42)
      }
    }
  }

  /// 造旧库的夹具本身必须跟得上迁移链：加了迁移却忘了在这里补一行，
  /// 表现是「矩阵测试悄悄停在更早的版本上」，看着照样绿。
  func testFixtureCanBuildEveryVersionUpToLatest() throws {
    XCTAssertEqual(MigrationFixture.supportedVersions.last, LocalDatabase.latestSchemaVersion)
    try withTemporaryLocation { location in
      let queue = try DatabaseQueue(path: location.databaseURL.path)
      defer { try? queue.close() }
      try queue.write { db in
        try MigrationFixture.apply(upTo: LocalDatabase.latestSchemaVersion, in: db)
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), LocalDatabase.latestSchemaVersion)
      }
    }
  }
}
