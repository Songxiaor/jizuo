import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 合集（Migration024）：有顺序的一组内容。
///
/// 这里钉的是用户看得见的几件事：顺序不乱、同一条不重复、删进回收站就不显示、
/// 恢复后回到原位、删合集不删内容、同一个文件夹再导入时找回同一个合集。
final class CollectionPersistenceTests: XCTestCase {
  // MARK: - 夹具

  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    try withTemporaryDirectory { directory in
      let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory), dependencies: .live)
      defer { try? repository.database.close() }
      try body(repository)
    }
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-collection-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(directory)
  }

  @discardableResult
  private func capture(_ repository: GRDBHistoryRepository, _ slug: String, body: String? = nil, at milliseconds: Int64 = 1_000) throws -> TaskID {
    let document = CapturedDocument(
      createdAt: "2026-09-01T00:00:00Z",
      idempotencyKey: "collection-test-\(slug)",
      origin: .manualLink,
      url: "https://example.test/\(slug)",
      title: "标题 \(slug)",
      platform: "generic",
      method: "rendered_dom",
      text: body ?? "正文 \(slug)：用来验证合集的顺序和可见性。",
      completeness: "complete",
      capturedAt: "2026-09-01T00:00:00Z",
      sourceLabel: "浏览器扩展"
    )
    return try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: milliseconds)).taskID
  }

  private func order(_ repository: GRDBHistoryRepository, _ id: CollectionID) throws -> [TaskID] {
    try repository.collectionItems(id: id).map(\.taskID)
  }

  private func listed(_ repository: GRDBHistoryRepository, _ filter: HistoryListFilter, pageSize: Int = 50) throws -> [TaskID] {
    var result: [TaskID] = []
    var cursor: HistoryPageCursor?
    repeat {
      let page = try repository.historyPage(limit: pageSize, after: cursor, filter: filter)
      result += page.rows.map(\.taskID)
      cursor = page.nextCursor
    } while cursor != nil
    return result
  }

  // MARK: - 迁移

  /// 从 v23 升到 v24：两张新表建好，旧数据一个字节不变，规模按真实库（约 1,400 条）来。
  func testMigrationFrom023To024KeepsRealScaleDataIntact() throws {
    try withTemporaryDirectory { directory in
      let location = LocalDatabaseLocation(directoryURL: directory)
      let queue = try DatabaseQueue(path: location.databaseURL.path)
      let taskCount = 1_400
      let base = Int64(1_760_000_000_000)
      var trashedID = ""
      try queue.write { db in
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try MigrationFixture.apply(upTo: 23, in: db)
        for index in 0..<taskCount {
          let taskID = UUID().uuidString.lowercased()
          let url = index % 50 == 0
            ? "\(HistoryPlatformDisplay.noteURLPrefix)\(UUID().uuidString.lowercased())"
            : "https://example.test/文章-\(index)"
          let timestamp = base + Int64(index) * 1_000
          try db.execute(
            sql: """
              INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms, is_favorite, deleted_at_ms)
              VALUES (?, ?, 1, ?, ?, ?, ?)
              """,
            arguments: [taskID, url, timestamp, timestamp, index % 7 == 0 ? 1 : 0, index == 3 ? timestamp : nil]
          )
          if index == 3 { trashedID = taskID }
          let body = "正文 \(index)：中文内容在迁移之后必须一个字都不少。"
          try db.execute(
            sql: """
              INSERT INTO content_snapshots (
                id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url,
                title, platform, capture_method, completeness, body_text, character_count, body_sha256,
                source_label, used_cookie
              ) VALUES (?, ?, 1, ?, ?, 'page', ?, ?, 'generic', 'rendered_dom', 'complete', ?, ?, ?, '浏览器扩展', 0)
              """,
            arguments: [
              UUID().uuidString.lowercased(), taskID, timestamp, timestamp, url,
              "标题 \(index)", body, body.count, String(format: "%064x", index + 1),
            ]
          )
          if index % 10 == 0 {
            try db.execute(
              sql: "INSERT INTO reading_progress (task_id, position, updated_at_ms) VALUES (?, 0.5, ?)",
              arguments: [taskID, timestamp]
            )
          }
        }
        try TaskClassificationSQL.backfillAll(db)
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 23)
      }
      let before = try queue.read(Self.fingerprint)
      try queue.close()

      let started = Date()
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let elapsed = Date().timeIntervalSince(started)

      try repository.database.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 24)
        let tables = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        XCTAssertTrue(tables.isSuperset(of: ["collections", "collection_items"]))
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collections"), 0)
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_items"), 0)
        XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
      }
      XCTAssertEqual(try repository.database.read(Self.fingerprint), before, "升级到 v24 后旧数据变了")
      XCTAssertEqual(try DatabaseMaintenance(database: repository.database).integrityCheck(), "ok")
      // 只建空表和索引；真实规模下也应该是瞬间的事（含升级前整库备份）。
      XCTAssertLessThan(elapsed, 10, "迁移耗时 \(elapsed) 秒，异常地慢")

      // 升级后的旧数据马上能进合集，回收站里那条照样不显示。
      let firstTwo = try repository.historyPage(limit: 2, after: nil, filter: .none).rows.map(\.taskID)
      let trashed = try XCTUnwrap(TaskID(trashedID))
      let collection = try repository.createCollection(name: "迁移后的合集")
      XCTAssertEqual(try repository.addTasks(firstTwo + [trashed], toCollection: collection.id), 3)
      XCTAssertEqual(try repository.collection(id: collection.id)?.itemCount, 2)
    }
  }

  /// 升级前后逐表对账用的指纹：每张已有表的全部行，按主键排序后拼成字符串。
  private static func fingerprint(_ db: Database) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    let tables: [(String, String)] = [
      ("tasks", "SELECT id, canonical_url, created_at_ms, updated_at_ms, is_favorite, deleted_at_ms, content_kind, normalized_host FROM tasks ORDER BY id"),
      ("content_snapshots", "SELECT id, task_id, body_text, title FROM content_snapshots ORDER BY id"),
      ("reading_progress", "SELECT task_id, position FROM reading_progress ORDER BY task_id"),
      ("task_search_map", "SELECT rowid_value, kind, source_id, task_id FROM task_search_map ORDER BY rowid_value"),
    ]
    for (name, sql) in tables {
      result[name] = try Row.fetchAll(db, sql: sql).map { row in
        row.databaseValues.map { $0.description }.joined(separator: "|")
      }
    }
    return result
  }

  // MARK: - 仓储

  func testCreateRenameListAndDeleteKeepsContent() throws {
    try withRepository { repository in
      let a = try capture(repository, "a")
      XCTAssertThrowsError(try repository.createCollection(name: "   \n ")) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidInput)
      }
      let first = try repository.createCollection(name: "  Claude Code 教程\n12 讲  ")
      XCTAssertEqual(first.name, "Claude Code 教程 12 讲")
      XCTAssertEqual(first.origin, .manual)
      XCTAssertNil(first.folderPath)
      XCTAssertEqual(first.itemCount, 0)
      let second = try repository.createCollection(name: String(repeating: "长", count: 100))
      XCTAssertEqual(second.name.count, HistoryCollectionNaming.maximumCharacterCount)

      try repository.addTasks([a], toCollection: first.id)
      let renamed = try repository.renameCollection(id: first.id, to: "教程")
      XCTAssertEqual(renamed.name, "教程")
      XCTAssertEqual(renamed.itemCount, 1)
      XCTAssertEqual(try repository.collections().map(\.id), [first.id, second.id], "侧栏按创建先后排")

      try repository.deleteCollection(id: first.id)
      XCTAssertEqual(try repository.collections().map(\.id), [second.id])
      XCTAssertThrowsError(try repository.deleteCollection(id: first.id)) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }
      XCTAssertThrowsError(try repository.renameCollection(id: first.id, to: "x")) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }
      // 合集删了，内容还在。
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil, filter: .none).rows.map(\.taskID), [a])
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_items") }, 0)
    }
  }

  func testAddDedupesAndAppendsInGivenOrder() throws {
    try withRepository { repository in
      let a = try capture(repository, "a"), b = try capture(repository, "b"), c = try capture(repository, "c")
      let collection = try repository.createCollection(name: "顺序")
      XCTAssertEqual(try repository.addTasks([b, a, b], toCollection: collection.id), 2)
      XCTAssertEqual(try repository.addTasks([a, c, TaskID()], toCollection: collection.id), 1, "已在合集里的和不存在的都跳过")
      XCTAssertEqual(try order(repository, collection.id), [b, a, c])
      XCTAssertEqual(try repository.collection(id: collection.id)?.itemCount, 3)
      XCTAssertThrowsError(try repository.addTasks([a], toCollection: CollectionID(UUID()))) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }

      XCTAssertEqual(try repository.removeTasks([a, a], fromCollection: collection.id), 1)
      XCTAssertEqual(try repository.removeTasks([a], fromCollection: collection.id), 0)
      XCTAssertEqual(try order(repository, collection.id), [b, c])
      // 移出后再加入，排到最后。
      try repository.addTasks([a], toCollection: collection.id)
      XCTAssertEqual(try order(repository, collection.id), [b, c, a])
    }
  }

  func testMoveTasksAfterAnchor() throws {
    try withRepository { repository in
      let a = try capture(repository, "a"), b = try capture(repository, "b")
      let c = try capture(repository, "c"), d = try capture(repository, "d")
      let collection = try repository.createCollection(name: "排序")
      try repository.addTasks([a, b, c, d], toCollection: collection.id)

      try repository.moveTasks([d], inCollection: collection.id, after: a)
      XCTAssertEqual(try order(repository, collection.id), [a, d, b, c])
      try repository.moveTasks([b, c], inCollection: collection.id, after: nil)
      XCTAssertEqual(try order(repository, collection.id), [b, c, a, d])
      try repository.moveTasks([b], inCollection: collection.id, after: d)
      XCTAssertEqual(try order(repository, collection.id), [c, a, d, b])
      // 不是合集成员的被忽略；锚点在被挪的里面、或锚点不在合集里，都拒绝。
      let outsider = try capture(repository, "outsider")
      try repository.moveTasks([outsider], inCollection: collection.id, after: nil)
      XCTAssertEqual(try order(repository, collection.id), [c, a, d, b])
      XCTAssertThrowsError(try repository.moveTasks([a], inCollection: collection.id, after: a)) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidInput)
      }
      XCTAssertThrowsError(try repository.moveTasks([a], inCollection: collection.id, after: outsider)) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }
    }
  }

  func testTrashHidesItemAndRestoreReturnsItToItsPlace() throws {
    try withRepository { repository in
      let a = try capture(repository, "a"), b = try capture(repository, "b"), c = try capture(repository, "c")
      let collection = try repository.createCollection(name: "回收站")
      try repository.addTasks([a, b, c], toCollection: collection.id)
      let filter = HistoryListFilter(includesNotes: true, collectionID: collection.id)

      try repository.moveToTrash(taskIDs: [b])
      XCTAssertEqual(try order(repository, collection.id), [a, c])
      XCTAssertEqual(try repository.collection(id: collection.id)?.itemCount, 2)
      XCTAssertEqual(try listed(repository, filter), [a, c])
      // 在「b 不可见」时重排，b 恢复后仍在 a 和 c 之间。
      try repository.moveTasks([c], inCollection: collection.id, after: nil)
      try repository.restoreFromTrash(taskIDs: [b])
      XCTAssertEqual(try order(repository, collection.id), [c, a, b])

      // 彻底删除：条目关系跟着消失，不留悬空行。
      _ = try repository.deleteTasks(taskIDs: [a])
      XCTAssertEqual(try order(repository, collection.id), [c, b])
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_items WHERE task_id = ?", arguments: [a.rawValue])
      }, 0)
    }
  }

  func testHistoryPageFollowsCollectionOrderAcrossPages() throws {
    try withRepository { repository in
      var ids: [TaskID] = []
      for (index, slug) in ["a", "b", "c", "d", "e"].enumerated() {
        ids.append(try capture(repository, slug, at: Int64(1_000 + index * 1_000)))
      }
      let note = try repository.acceptCapture(AcceptCaptureCommand(
        document: UserNoteDocument.make(title: "笔记也能进合集", body: "合集里的笔记"),
        receivedAtMilliseconds: 9_000
      )).taskID
      let outsider = try capture(repository, "outsider", body: "合集外的：同样的独特词 藏青", at: 10_000)
      let collection = try repository.createCollection(name: "分页")
      let expected = [ids[2], ids[0], note, ids[4], ids[1], ids[3]]
      try repository.addTasks(expected, toCollection: collection.id)

      // 默认列表按存入时间；在合集里一律按合集顺序，分页也不乱。
      let filter = HistoryListFilter(ordersBySavedTime: true, includesNotes: true, collectionID: collection.id)
      XCTAssertEqual(try listed(repository, filter, pageSize: 2), expected)
      let firstPage = try repository.historyPage(limit: 2, after: nil, filter: filter)
      XCTAssertNotNil(firstPage.nextCursor?.collectionPosition)

      // 拿别的列表的游标来翻合集：位置对不上，按无效输入拒绝，而不是悄悄从头来。
      let foreignCursor = HistoryPageCursor(updatedAtMilliseconds: 1, taskID: ids[0])
      XCTAssertThrowsError(try repository.historyPage(limit: 2, after: foreignCursor, filter: filter)) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidInput)
      }

      // 合集里搜索：只在合集内找，结果仍按合集顺序。
      try repository.addTasks([ids[1]], toCollection: collection.id)
      _ = outsider
      let searched = HistoryListFilter(searchText: "正文", includesNotes: true, collectionID: collection.id)
      XCTAssertEqual(try listed(repository, searched), [ids[2], ids[0], ids[4], ids[1], ids[3]])
      // 搜索第一页带命中总数（列表头「搜索 · N 条」），翻页和浏览时不数。
      XCTAssertEqual(try repository.historyPage(limit: 2, after: nil, filter: searched).totalCount, 5)
      XCTAssertNil(try repository.historyPage(limit: 2, after: nil, filter: filter).totalCount)
      let noMatch = HistoryListFilter(searchText: "藏青", includesNotes: true, collectionID: collection.id)
      XCTAssertEqual(try listed(repository, noMatch), [])
      XCTAssertEqual(try repository.historyPage(limit: 2, after: nil, filter: noMatch).totalCount, 0)

      // 「意思相近」套用当前筛选时也不能跑出合集。
      XCTAssertEqual(try listed(repository, filter.restricted(to: [outsider, ids[4]])), [ids[4]])
    }
  }

  func testCollectionsContainingTask() throws {
    try withRepository { repository in
      let a = try capture(repository, "a"), b = try capture(repository, "b")
      let first = try repository.createCollection(name: "一")
      let second = try repository.createCollection(name: "二")
      try repository.addTasks([a], toCollection: first.id)
      try repository.addTasks([a, b], toCollection: second.id)
      XCTAssertEqual(try repository.collections(containing: a).map(\.id), [first.id, second.id])
      XCTAssertEqual(try repository.collections(containing: b).map(\.id), [second.id])
      XCTAssertEqual(try repository.collections(containing: TaskID()), [])
    }
  }

  func testImportedFolderCollectionIsFoundAgainAndAppended() throws {
    try withRepository { repository in
      let a = try capture(repository, "a"), b = try capture(repository, "b"), c = try capture(repository, "c")
      // 全部导入失败时不建空合集。
      XCTAssertNil(try repository.createOrUpdateImportedFolderCollection(name: "教程", folderPath: "/Users/x/教程", orderedTaskIDs: [TaskID()]))
      XCTAssertEqual(try repository.collections(), [])

      let created = try XCTUnwrap(repository.createOrUpdateImportedFolderCollection(
        name: "教程", folderPath: "/Users/x/教程", orderedTaskIDs: [b, a]
      ))
      XCTAssertEqual(created.origin, .importedFolder)
      XCTAssertEqual(created.folderPath, "/Users/x/教程")
      XCTAssertEqual(try order(repository, created.id), [b, a])

      // 用户改过名；同一文件夹再导入：同一个合集，旧顺序不动，新的追加在后，名字不被改回去。
      _ = try repository.renameCollection(id: created.id, to: "我的教程")
      let updated = try XCTUnwrap(repository.createOrUpdateImportedFolderCollection(
        name: "教程", folderPath: "/Users/x/教程", orderedTaskIDs: [a, c, b]
      ))
      XCTAssertEqual(updated.id, created.id)
      XCTAssertEqual(updated.name, "我的教程")
      XCTAssertEqual(try order(repository, created.id), [b, a, c])
      XCTAssertEqual(updated.itemCount, 3)

      // 同名但不同文件夹：另一个合集。
      let other = try XCTUnwrap(repository.createOrUpdateImportedFolderCollection(
        name: "教程", folderPath: "/Users/y/教程", orderedTaskIDs: [c]
      ))
      XCTAssertNotEqual(other.id, created.id)
      XCTAssertEqual(try repository.collections().count, 2)

      // 已有合集、这次一条新内容都没有：原样返回，不报错。
      let unchanged = try repository.createOrUpdateImportedFolderCollection(
        name: "教程", folderPath: "/Users/x/教程", orderedTaskIDs: []
      )
      XCTAssertEqual(unchanged?.id, created.id)
      XCTAssertEqual(unchanged?.itemCount, 3)
      XCTAssertThrowsError(try repository.createOrUpdateImportedFolderCollection(name: "x", folderPath: "  ", orderedTaskIDs: [a]))
    }
  }

  func testFolderKeyTreatsEquivalentPathsAsSameFolder() {
    XCTAssertEqual(
      HistoryCollectionNaming.folderKey(URL(fileURLWithPath: "/tmp/合集测试/子目录/../")),
      HistoryCollectionNaming.folderKey(URL(fileURLWithPath: "/tmp/合集测试", isDirectory: true))
    )
  }
}
