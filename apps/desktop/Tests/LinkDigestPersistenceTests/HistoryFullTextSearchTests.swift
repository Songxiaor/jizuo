import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 搜索改走 FTS5 trigram 索引（Migration022）之后，语义必须和旧的 `LIKE '%x%'` 一样：
/// **包含子串就算命中**。
///
/// 另外补一个旧实现的正确性缺陷：旧查询只搜「有效快照」，而有效快照的定义排除了
/// `local_transcription` 和 `burned_in_subtitles`，于是视频转写稿的正文永远搜不到——
/// 用户最想找回的「他在视频里说过的那句话」正好落在被排除的那一层。
final class HistoryFullTextSearchTests: XCTestCase {
  private func capture(url: String, title: String, body: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-07-28T00:00:00Z",
      idempotencyKey: "fts-\(url)",
      origin: .manualLink,
      url: url,
      title: title,
      platform: "generic",
      method: "rendered_dom",
      text: body,
      completeness: "complete",
      capturedAt: "2026-07-28T00:00:00Z",
      sourceLabel: "浏览器扩展"
    )
  }

  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-fts-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    try body(repository)
  }

  private func search(_ repository: GRDBHistoryRepository, _ text: String) throws -> [String] {
    try repository.historyPage(limit: 50, after: nil, filter: .init(searchText: text))
      .rows.map(\.taskID.rawValue)
  }

  /// 直接写 `content_snapshots` —— 触发器挂在表上，生产里的转写落库走的是同一条路。
  @discardableResult
  private func appendSnapshot(
    _ repository: GRDBHistoryRepository,
    taskID: String,
    sourceKind: String,
    title: String?,
    body: String,
    sourceLabel: String = "本机转写"
  ) throws -> String {
    let id = UUID().uuidString.lowercased()
    try repository.database.write { db in
      let sequence = (try Int.fetchOne(
        db, sql: "SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?", arguments: [taskID]
      ) ?? 0) + 1
      try db.execute(
        sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
            title, platform, capture_method, completeness, body_text, character_count, body_sha256,
            source_label, used_cookie
          ) VALUES (?, ?, ?, 1, 1, ?, 'https://example.test/x', ?, 'generic', 'rendered_dom', 'complete', ?, ?, ?, ?, 0)
          """,
        arguments: [
          id, taskID, sequence, sourceKind, title, body, max(1, body.unicodeScalars.count),
          String(format: "%064x", abs(body.hashValue) % Int(UInt32.max)), sourceLabel,
        ]
      )
    }
    return id
  }

  // MARK: - 四类命中

  func testChineseSubstringMatchesLikeTheOldLikeQueryDid() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/cn",
        title: "完全无关的标题",
        body: "咱们来讲讲命局中的格局配置情况，先说说盲派命理对格局的概念。"
      ), receivedAtMilliseconds: 1))
      _ = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/other",
        title: "另一条",
        body: "毫不相干的内容。"
      ), receivedAtMilliseconds: 1))

      // 词中间切一刀也要命中：trigram 是子串匹配，不是分词匹配。
      XCTAssertEqual(try search(repository, "盲派命理"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "局中的格局"), [target.taskID.rawValue])
      XCTAssertTrue(try search(repository, "这句话哪都没有").isEmpty)
    }
  }

  func testEnglishIsCaseInsensitiveJustLikeLike() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/en",
        title: "Untitled",
        body: "Retrieval Augmented Generation changes how agents search."
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "augmented"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "AUGMENTED GENERATION"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "how agents"), [target.taskID.rawValue])
    }
  }

  func testMixedChineseAndEnglishMatches() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/mix",
        title: "混合标题",
        body: "我们用 RAG 检索增强来解决 Agent 找不到东西的问题。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "RAG 检索"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "检索增强"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "Agent 找不到"), [target.taskID.rawValue])
    }
  }

  /// 1-2 个字建不起三元组，FTS 命不中，所以这段退回 LIKE。
  /// 退回路径和 FTS 路径的覆盖面必须一致，否则「搜两个字」和「搜三个字」会
  /// 给出口径不同的结果。
  func testShortQueriesFallBackToLikeAndStillMatch() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/short",
        title: "无关标题",
        body: "盲派命理讲的是格局。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "盲"), [target.taskID.rawValue], "一个字也要能搜到")
      XCTAssertEqual(try search(repository, "盲派"), [target.taskID.rawValue], "两个字也要能搜到")
      XCTAssertTrue(try search(repository, "禅").isEmpty)

      // 短词路径同样要覆盖转写稿。
      try appendSnapshot(
        repository, taskID: target.taskID.rawValue, sourceKind: "local_transcription",
        title: nil, body: "他在视频里说：禅定是另一回事。"
      )
      XCTAssertEqual(try search(repository, "禅"), [target.taskID.rawValue])
    }
  }

  func testTranscriptBodyIsSearchable() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/video",
        title: "某个视频",
        // 视频条目的"正文"往往只是 og:description，真内容在转写稿里。
        body: "这是一条视频，站点描述里什么都没说。"
      ), receivedAtMilliseconds: 1))
      try appendSnapshot(
        repository, taskID: target.taskID.rawValue, sourceKind: "local_transcription",
        title: "转写稿", body: "他说：做产品最难的是承认这一版方向错了。"
      )
      try appendSnapshot(
        repository, taskID: target.taskID.rawValue, sourceKind: "burned_in_subtitles",
        title: "画面字幕", body: "字幕里出现的独有词：靛青。"
      )

      XCTAssertEqual(try search(repository, "承认这一版"), [target.taskID.rawValue], "转写稿正文要能搜到")
      XCTAssertEqual(try search(repository, "独有词：靛青"), [target.taskID.rawValue], "画面字幕也要能搜到")
    }
  }

  func testArtifactBodyIsSearchable() throws {
    try withRepository { repository in
      let accepted = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/artifact",
        title: "标题里没有关键词",
        body: "正文里也没有。"
      ), receivedAtMilliseconds: 1))
      let run = try repository.createRun(.init(
        taskID: accepted.taskID, snapshotID: accepted.snapshotID,
        idempotencyKey: "fts:sum", kind: .summarize, targetLanguage: nil, createdAtMilliseconds: 10
      ))
      try repository.markRunRunning(.init(
        runID: run.runID, startedAtMilliseconds: 11,
        provider: .init(
          profileID: "p", providerKind: "openai-compatible",
          baseURL: "https://provider.example/v1", apiMode: "chat_completions", model: "m"
        )
      ))
      try repository.finishRun(.init(
        runID: run.runID, status: .completed, finishedAtMilliseconds: 12,
        artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "要点：日主有无财官决定格局高低。")
      ))
      XCTAssertEqual(try search(repository, "财官决定"), [accepted.taskID.rawValue])
    }
  }

  func testTitleAndSourceLabelStayReachable() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/title",
        title: "提升 Agent 的信息搜索能力",
        body: "无关正文。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "信息搜索能力"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "example.test/title"), [target.taskID.rawValue], "链接还要能搜")
    }
  }

  // MARK: - 索引维护

  func testDeletingATaskRemovesItFromSearch() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/delete",
        title: "待删条目",
        body: "这条里有一个独特词：鹧鸪天。"
      ), receivedAtMilliseconds: 1))
      try appendSnapshot(
        repository, taskID: target.taskID.rawValue, sourceKind: "local_transcription",
        title: nil, body: "转写稿里另一个独特词：菩萨蛮。"
      )
      XCTAssertEqual(try search(repository, "鹧鸪天"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "菩萨蛮"), [target.taskID.rawValue])

      try repository.deleteTask(taskID: target.taskID)

      XCTAssertTrue(try search(repository, "鹧鸪天").isEmpty, "删掉的记录不能还能搜出来")
      XCTAssertTrue(try search(repository, "菩萨蛮").isEmpty)
      // 索引里也不该留孤儿：留着的话下次 rowid 复用会把两条内容串在一起。
      let leftovers = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_search_map WHERE task_id = ?", arguments: [target.taskID.rawValue]) ?? -1
      }
      XCTAssertEqual(leftovers, 0)
      let indexRows = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_search") ?? -1
      }
      XCTAssertEqual(indexRows, 0)
    }
  }

  func testUpdatingSnapshotBodyReindexes() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/update",
        title: "会被改写的条目",
        body: "第一版里写的是：鹧鸪天。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "鹧鸪天"), [target.taskID.rawValue])
      try repository.updateSnapshotBodyText(
        taskID: target.taskID, snapshotID: target.snapshotID,
        bodyText: "改写之后写的是：菩萨蛮。", updatedAtMilliseconds: 2
      )
      XCTAssertTrue(try search(repository, "鹧鸪天").isEmpty, "改完还能搜到旧内容说明索引没跟着更新")
      XCTAssertEqual(try search(repository, "菩萨蛮"), [target.taskID.rawValue])
    }
  }

  /// 存量库升级过来的记录也要进索引，否则「改版之后旧东西全搜不到」。
  func testExistingRowsAreBackfilledOnMigration() throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-fts-backfill-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = LocalDatabaseLocation(directoryURL: directory)

    let taskID = UUID().uuidString.lowercased()
    let queue = try DatabaseQueue(path: location.databaseURL.path)
    try queue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try Migration001.apply(to: db, beforeCommit: {})
      try Migration002.apply(to: db); try Migration003.apply(to: db); try Migration004.apply(to: db)
      try Migration005.apply(to: db); try Migration006.apply(to: db); try Migration007.apply(to: db)
      try Migration008.apply(to: db); try Migration009.apply(to: db); try Migration010.apply(to: db)
      try Migration011.apply(to: db); try Migration012.apply(to: db); try Migration013.apply(to: db)
      try Migration014.apply(to: db); try Migration015.apply(to: db); try Migration016.apply(to: db)
      try Migration017.apply(to: db); try Migration018.apply(to: db); try Migration019.apply(to: db)
      try Migration020.apply(to: db)
      try db.execute(
        sql: """
          INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms)
          VALUES (?, 'https://example.test/legacy', 1, 1, 1)
          """,
        arguments: [taskID]
      )
      try db.execute(
        sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
            title, platform, capture_method, completeness, body_text, character_count, body_sha256,
            source_label, used_cookie
          ) VALUES (?, ?, 1, 1, 1, 'page', 'https://example.test/legacy', '旧条目', 'generic',
            'rendered_dom', 'complete', '老库里写着：鹧鸪天。', 10, ?, '浏览器扩展', 0)
          """,
        arguments: [UUID().uuidString.lowercased(), taskID, String(repeating: "a", count: 64)]
      )
    }
    try queue.close()

    let repository = try GRDBHistoryRepository.open(at: location)
    defer { try? repository.database.close() }
    XCTAssertEqual(try search(repository, "鹧鸪天"), [taskID], "存量正文必须在迁移时回填进索引")
  }

  /// FTS 的查询串是拼给 MATCH 的，用户输入里的引号和 `-` `*` `:` 不能被当成语法。
  func testQuerySyntaxCharactersAreTreatedAsLiteralText() throws {
    try withRepository { repository in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/syntax",
        title: "无关标题",
        body: "命令行写法是 --verbose，配置写成 key: value 就行。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "--verbose"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "key: value"), [target.taskID.rawValue])
      XCTAssertTrue(try search(repository, "\"根本没有的词\"").isEmpty, "引号不能让查询炸掉")
    }
  }

  /// 走的确实是索引，不是又退回全表扫。
  func testSearchUsesTheFullTextIndex() throws {
    try withRepository { repository in
      _ = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/plan", title: "标题", body: "正文内容若干。"
      ), receivedAtMilliseconds: 1))
      let plan = try repository.database.read { db in
        try Row.fetchAll(db, sql: """
          EXPLAIN QUERY PLAN
          SELECT m.task_id FROM task_search
          INNER JOIN task_search_map m ON m.rowid_value = task_search.rowid
          WHERE task_search MATCH '"正文内容"'
          """).map { ($0["detail"] as String?) ?? "" }.joined(separator: " | ")
      }
      XCTAssertTrue(
        plan.lowercased().contains("virtual table index"),
        "搜索没走 FTS 索引：\(plan)"
      )
    }
  }
}
