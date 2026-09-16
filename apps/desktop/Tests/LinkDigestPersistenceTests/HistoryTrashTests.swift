import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 回收站：删除从「立刻没了」改成「先放一边」。
///
/// 这一批测试钉的全是**看不见的失败**：某条被删的记录在某个筛选下又冒出来、
/// 搜索还能搜到、侧边栏数字和列表对不上。这几种都不报错、不崩溃，只有用户
/// 自己会撞上，所以只能靠测试守。
final class HistoryTrashTests: XCTestCase {
  private func capture(url: String, title: String, body: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-09-01T00:00:00Z",
      idempotencyKey: "trash-test-\(url)",
      origin: .manualLink,
      url: url,
      title: title,
      platform: "generic",
      method: "rendered_dom",
      text: body,
      completeness: "complete",
      capturedAt: "2026-09-01T00:00:00Z",
      sourceLabel: "浏览器扩展"
    )
  }

  private func withRepository(
    _ body: (GRDBHistoryRepository, LocalDatabaseLocation) throws -> Void
  ) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-trash-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = LocalDatabaseLocation(directoryURL: directory)
    let repository = try GRDBHistoryRepository.open(at: location, dependencies: .live)
    defer { try? repository.database.close() }
    try body(repository, location)
  }

  private func ids(
    _ repository: GRDBHistoryRepository,
    _ filter: HistoryListFilter = .none
  ) throws -> Set<String> {
    Set(try repository.historyPage(limit: 100, after: nil, filter: filter).rows.map(\.taskID.rawValue))
  }

  // MARK: - 移入 / 取回

  func testTrashedTaskLeavesEveryListButStaysInTrash() throws {
    try withRepository { repository, _ in
      let kept = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/kept", title: "留下的", body: "留下的正文，独一无二的词：留守。"),
        receivedAtMilliseconds: 1_000
      ))
      let removed = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/removed", title: "删掉的", body: "删掉的正文，独一无二的词：飞蓬。"),
        receivedAtMilliseconds: 2_000
      ))
      try repository.setFavorite(true, for: removed.taskID)
      _ = try repository.addTags(["共享标签"], to: removed.taskID)
      _ = try repository.addTags(["共享标签"], to: kept.taskID)

      XCTAssertEqual(try ids(repository), [kept.taskID.rawValue, removed.taskID.rawValue])

      try repository.moveToTrash(taskIDs: [removed.taskID])

      // 每一个作用域都要把它挡掉。少写一个 case 的表现就是「某个筛选下它又回来了」。
      for scope in HistoryListScope.allCases where scope != .trash {
        let visible = try ids(repository, .init(scope: scope))
        XCTAssertFalse(
          visible.contains(removed.taskID.rawValue),
          "作用域 \(scope.rawValue) 仍然能看到已删除的记录"
        )
      }
      // 平台筛选、标签筛选也一样。
      XCTAssertFalse(try ids(repository, .init(hosts: ["example.test"])).contains(removed.taskID.rawValue))
      XCTAssertFalse(try ids(repository, .init(tagNames: ["共享标签"])).contains(removed.taskID.rawValue))

      // 回收站里看得到，而且只有它。
      XCTAssertEqual(try ids(repository, .init(scope: .trash)), [removed.taskID.rawValue])

      // 取回之后原样回来。
      try repository.restoreFromTrash(taskIDs: [removed.taskID])
      XCTAssertEqual(try ids(repository), [kept.taskID.rawValue, removed.taskID.rawValue])
      XCTAssertEqual(try ids(repository, .init(scope: .trash)), [])
      XCTAssertEqual(try ids(repository, .init(scope: .favorite)), [removed.taskID.rawValue])
    }
  }

  func testSearchCannotFindTrashedTask() throws {
    try withRepository { repository, _ in
      let removed = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/x", title: "会被删的", body: "正文里有一个极罕见的词：龃龉难合。"),
        receivedAtMilliseconds: 1_000
      ))
      // 先确认这个词本来搜得到，否则后面的「搜不到」什么都证明不了。
      XCTAssertEqual(try ids(repository, .init(searchText: "龃龉难合")), [removed.taskID.rawValue])
      // 两个字的词走 LIKE 退回路径，三个字以上走 FTS；两条路径都要挡住。
      XCTAssertEqual(try ids(repository, .init(searchText: "龃龉")), [removed.taskID.rawValue])

      try repository.moveToTrash(taskIDs: [removed.taskID])

      XCTAssertEqual(try ids(repository, .init(searchText: "龃龉难合")), [])
      XCTAssertEqual(try ids(repository, .init(searchText: "龃龉")), [])
      XCTAssertEqual(try ids(repository, .init(searchText: "会被删的")), [])
    }
  }

  func testNavigationCountsExcludeTrashAndReportTrashCount() throws {
    try withRepository { repository, _ in
      let a = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/1", title: "一", body: "一"),
        receivedAtMilliseconds: 1_000
      ))
      _ = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/2", title: "二", body: "二"),
        receivedAtMilliseconds: 2_000
      ))
      _ = try repository.addTags(["计数标签"], to: a.taskID)

      let before = try repository.navigationCounts()
      XCTAssertEqual(before.all, 2)
      XCTAssertEqual(before.trash, 0)
      XCTAssertEqual(before.tags.first(where: { $0.tag.normalizedName == "计数标签" })?.count, 1)

      try repository.moveToTrash(taskIDs: [a.taskID])

      let after = try repository.navigationCounts()
      XCTAssertEqual(after.all, 1, "侧边栏「全部」必须和列表看到的条数一致")
      XCTAssertEqual(after.trash, 1)
      XCTAssertEqual(try repository.trashCount(), 1)
      // 标签计数也要跟着掉，否则点进标签只有 0 条却显示 1。
      XCTAssertNil(after.tags.first(where: { $0.tag.normalizedName == "计数标签" && $0.count > 0 }))
      // 平台格子同理。
      XCTAssertEqual(after.platforms.first(where: { $0.host == "example.test" })?.count, 1)
    }
  }

  func testRecallMaterialsSkipTrashedTasks() throws {
    try withRepository { repository, _ in
      let now = Int64(Date().timeIntervalSince1970 * 1_000)
      let removed = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/material", title: "素材", body: "素材正文"),
        receivedAtMilliseconds: now
      ))
      let lane = TopicRecall.Lane(name: "测试", window: .recent(days: 7), limit: 20)
      XCTAssertTrue(try repository.recallMaterials(lane: lane, now: now).contains { $0.id == removed.taskID })
      try repository.moveToTrash(taskIDs: [removed.taskID])
      XCTAssertFalse(try repository.recallMaterials(lane: lane, now: now).contains { $0.id == removed.taskID })
    }
  }

  // MARK: - 回收站里的链接再抓一次

  /// 同一条链接在回收站里又被抓一次 = 把它拿回来。
  ///
  /// `canonical_url` 上有唯一约束，所以只能复活那条、不能另建一行。真正的失败
  /// 模式不是「多了一行」，而是「抓了，但什么都没出现」——记录仍留在回收站里。
  func testRecapturingATrashedURLBringsThatRecordBack() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/again", title: "被删过的", body: "正文一"),
        receivedAtMilliseconds: 1_000
      ))
      try repository.moveToTrash(taskIDs: [first.taskID])
      XCTAssertEqual(try ids(repository), [])
      XCTAssertEqual(try repository.trashCount(), 1)

      // 第二次抓取必须带**新的**幂等键：扩展每次抓取都会生成新的，而沿用旧键
      // 会被 delivery 层按「同键不同内容」判成 CAPTURE_IDEMPOTENCY_CONFLICT，
      // 根本走不到按 canonical_url 查已有记录那一步。
      let second = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-09-01T00:00:00Z",
          idempotencyKey: "trash-test-again-second",
          origin: .manualLink,
          url: "https://example.test/again",
          title: "被删过的",
          platform: "generic",
          method: "rendered_dom",
          text: "正文二",
          completeness: "complete",
          capturedAt: "2026-09-01T00:00:00Z",
          sourceLabel: "浏览器扩展"
        ),
        receivedAtMilliseconds: 2_000
      ))

      XCTAssertEqual(second.taskID, first.taskID, "同一条链接必须还是原来那一条")
      XCTAssertEqual(try repository.trashCount(), 0, "重新抓取之后不该还留在回收站里")
      XCTAssertEqual(try ids(repository), [first.taskID.rawValue], "用户应该能在列表里看到它")
    }
  }

  /// 剪贴板重复检测必须把回收站里的当成「没捕获过」。
  func testContainsCanonicalURLIgnoresTrashedRecords() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/dedupe", title: "去重", body: "正文"),
        receivedAtMilliseconds: 1_000
      ))
      let canonical = try CanonicalURL("https://example.test/dedupe")
      XCTAssertTrue(try repository.containsCanonicalURL(canonical))

      try repository.moveToTrash(taskIDs: [task.taskID])
      XCTAssertFalse(
        try repository.containsCanonicalURL(canonical),
        "回收站里的链接算「已捕获」的话，重复检测会静默跳过，用户再抓什么都不会发生"
      )

      try repository.restoreFromTrash(taskIDs: [task.taskID])
      XCTAssertTrue(try repository.containsCanonicalURL(canonical))
    }
  }

  /// 返回值只报「真的改动过的」id。
  ///
  /// 以前调用方拿请求集当结果，于是点「恢复」一条已被清理掉的记录时，界面把
  /// 那一行移除、侧边栏计数却没变，切走再回来它又出现在回收站里。
  func testMoveAndRestoreReportOnlyActuallyChangedIDs() throws {
    try withRepository { repository, _ in
      let a = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/a", title: "甲", body: "甲"),
        receivedAtMilliseconds: 1_000
      ))
      let b = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/b", title: "乙", body: "乙"),
        receivedAtMilliseconds: 2_000
      ))
      // b 已经在回收站里，a 没有。
      try repository.moveToTrash(taskIDs: [b.taskID])

      XCTAssertEqual(
        try repository.moveToTrash(taskIDs: [a.taskID, b.taskID]),
        [a.taskID],
        "已经在回收站里的那条不该出现在「这次改动」里"
      )
      XCTAssertEqual(try repository.moveToTrash(taskIDs: [a.taskID]), [], "重复调用改不动任何行")

      XCTAssertEqual(
        try repository.restoreFromTrash(taskIDs: [a.taskID, b.taskID]),
        [a.taskID, b.taskID].sorted { $0.rawValue < $1.rawValue }
      )
      XCTAssertEqual(try repository.restoreFromTrash(taskIDs: [a.taskID]), [], "已经不在回收站里的改不动任何行")
    }
  }

  // MARK: - 自动清理

  func testPurgeTrashRemovesOnlyExpiredEntries() throws {
    try withRepository { repository, _ in
      let old = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/old", title: "很久前删的", body: "旧"),
        receivedAtMilliseconds: 1_000
      ))
      let fresh = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/fresh", title: "刚删的", body: "新"),
        receivedAtMilliseconds: 2_000
      ))
      let live = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/live", title: "没删的", body: "活"),
        receivedAtMilliseconds: 3_000
      ))
      try repository.moveToTrash(taskIDs: [old.taskID, fresh.taskID])

      // 把其中一条的删除时间拨回 31 天前。
      let longAgo = Int64(Date().timeIntervalSince1970 * 1_000) - 31 * 86_400_000
      try repository.database.write { db in
        try db.execute(
          sql: "UPDATE tasks SET deleted_at_ms = ? WHERE id = ?",
          arguments: [longAgo, old.taskID.rawValue]
        )
      }

      let purged = try repository.purgeTrash(olderThanDays: HistoryTrashPolicy.retentionDays)
      XCTAssertEqual(purged, 1)
      XCTAssertEqual(try repository.trashCount(), 1)
      XCTAssertEqual(try ids(repository, .init(scope: .trash)), [fresh.taskID.rawValue])
      XCTAssertEqual(try ids(repository), [live.taskID.rawValue])
      // 过期那条是**永久**删掉了，不是又藏起来。
      XCTAssertThrowsError(try repository.detail(taskID: old.taskID))
    }
  }

  /// 30 天清理走真删，阅读进度必须跟着走（FK CASCADE）。
  ///
  /// 这条同时回答一个审计问题：`PRAGMA foreign_keys` 只在连接配置里（`prepareDatabase`）
  /// 开过，删除路径本身没有显式开——如果哪个连接的 pragma 没生效，progress 行就会
  /// 变成谁也不认识的孤儿，而没有任何报错。
  func testPurgeDropsReadingProgressWithTheTask() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/progress", title: "带进度的", body: "正文"),
        receivedAtMilliseconds: 1_000
      ))
      try repository.saveReadingPosition(0.5, taskID: task.taskID, updatedAtMilliseconds: 10)
      try repository.moveToTrash(taskIDs: [task.taskID])
      let longAgo = Int64(Date().timeIntervalSince1970 * 1_000) - 31 * 86_400_000
      try repository.database.write { db in
        try db.execute(
          sql: "UPDATE tasks SET deleted_at_ms = ? WHERE id = ?",
          arguments: [longAgo, task.taskID.rawValue]
        )
      }

      XCTAssertEqual(try repository.purgeTrash(olderThanDays: HistoryTrashPolicy.retentionDays), 1)
      let orphans = try repository.database.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM reading_progress WHERE task_id = ?",
          arguments: [task.taskID.rawValue]
        ) ?? -1
      }
      XCTAssertEqual(orphans, 0, "任务被永久删除后，阅读进度行必须跟着消失")
      XCTAssertNil(try repository.readingPosition(taskID: task.taskID))
    }
  }

  func testPurgeTrashIsNoOpWhenNothingExpired() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/keep", title: "刚删的", body: "新"),
        receivedAtMilliseconds: 1_000
      ))
      try repository.moveToTrash(taskIDs: [task.taskID])
      XCTAssertEqual(try repository.purgeTrash(olderThanDays: HistoryTrashPolicy.retentionDays), 0)
      XCTAssertEqual(try repository.trashCount(), 1)
    }
  }

  /// 重复移入不该把「删除时间」一路推到现在——否则 30 天自动清理可以被无限推迟。
  func testMoveToTrashTwiceKeepsTheOriginalDeletionTime() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/twice", title: "删两次", body: "x"),
        receivedAtMilliseconds: 1_000
      ))
      try repository.moveToTrash(taskIDs: [task.taskID])
      let first: Int64? = try repository.database.read { db in
        try Int64.fetchOne(db, sql: "SELECT deleted_at_ms FROM tasks WHERE id = ?", arguments: [task.taskID.rawValue])
      }
      try repository.moveToTrash(taskIDs: [task.taskID])
      let second: Int64? = try repository.database.read { db in
        try Int64.fetchOne(db, sql: "SELECT deleted_at_ms FROM tasks WHERE id = ?", arguments: [task.taskID.rawValue])
      }
      XCTAssertEqual(first, second)
    }
  }

  // MARK: - 「待总结」与「最近」的口径

  /// 翻译过一次的条目**仍然是待总结**。
  ///
  /// 旧实现问的是「有没有任何一次成功运行带产物」，翻译也是一次运行，于是翻译过
  /// 的条目从「待总结」里静静消失——而它一句总结都没有。这是这一批里最贵的一条。
  func testTranslatedTaskStaysUnsummarized() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/translated", title: "翻译过的", body: "原文"),
        receivedAtMilliseconds: 1_000
      ))
      let translate = try repository.createRun(.init(
        taskID: task.taskID,
        snapshotID: task.snapshotID,
        idempotencyKey: "translate-1",
        kind: .translate,
        targetLanguage: "简体中文",
        createdAtMilliseconds: 2_000
      ))
      try repository.markRunRunning(.init(runID: translate.runID, startedAtMilliseconds: 2_100, provider: .init()))
      try repository.finishRun(.init(
        runID: translate.runID,
        status: .completed,
        finishedAtMilliseconds: 2_200,
        artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "译文")
      ))

      XCTAssertEqual(try ids(repository, .init(scope: .unsummarized)), [task.taskID.rawValue])
      XCTAssertEqual(try repository.navigationCounts().unsummarized, 1)

      let row = try XCTUnwrap(
        repository.historyPage(limit: 10, after: nil, filter: .none).rows.first
      )
      XCTAssertEqual(row.hasSummary, false, "翻译不是总结，徽标不能亮")

      // 真的总结一次之后才离开「待总结」。
      let summarize = try repository.createRun(.init(
        taskID: task.taskID,
        snapshotID: task.snapshotID,
        idempotencyKey: "summarize-1",
        kind: .summarize,
        createdAtMilliseconds: 3_000
      ))
      try repository.markRunRunning(.init(runID: summarize.runID, startedAtMilliseconds: 3_100, provider: .init()))
      try repository.finishRun(.init(
        runID: summarize.runID,
        status: .completed,
        finishedAtMilliseconds: 3_200,
        artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "总结")
      ))
      XCTAssertEqual(try ids(repository, .init(scope: .unsummarized)), [])
      XCTAssertEqual(try repository.navigationCounts().unsummarized, 0)
      let after = try XCTUnwrap(
        repository.historyPage(limit: 10, after: nil, filter: .none).rows.first
      )
      XCTAssertEqual(after.hasSummary, true)
    }
  }

  /// 跑完但没落下产物的总结不算数：徽标和「待总结」口径必须一致。
  func testSummarizeWithoutArtifactStaysUnsummarized() throws {
    try withRepository { repository, _ in
      let task = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/empty", title: "空产物", body: "原文"),
        receivedAtMilliseconds: 1_000
      ))
      let run = try repository.createRun(.init(
        taskID: task.taskID,
        snapshotID: task.snapshotID,
        idempotencyKey: "summarize-empty",
        kind: .summarize,
        createdAtMilliseconds: 2_000
      ))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 2_100, provider: .init()))
      try repository.finishRun(.init(runID: run.runID, status: .stopped, finishedAtMilliseconds: 2_200))

      XCTAssertEqual(try ids(repository, .init(scope: .unsummarized)), [task.taskID.rawValue])
      let row = try XCTUnwrap(repository.historyPage(limit: 10, after: nil, filter: .none).rows.first)
      XCTAssertEqual(row.hasSummary, false)
    }
  }

  /// 「最近」= 最近 7 天**存进来的**，不是最近改过的。
  ///
  /// 旧实现按 `updated_at_ms`，而那个值会被总结、改标题、加标签推到当下：
  /// 去年存的一篇今天总结一下就跑进「最近」，而用户心里的「最近」只有一个意思。
  func testRecentUsesCreatedAtNotUpdatedAt() throws {
    try withRepository { repository, _ in
      let now = Int64(Date().timeIntervalSince1970 * 1_000)
      let fresh = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/new", title: "刚存的", body: "新"),
        receivedAtMilliseconds: now
      ))
      let ancient = try repository.acceptCapture(.init(
        document: capture(url: "https://example.test/ancient", title: "很久前存的", body: "旧"),
        receivedAtMilliseconds: now
      ))
      // 一年前存进来，但刚刚改过。
      try repository.database.write { db in
        try db.execute(
          sql: "UPDATE tasks SET created_at_ms = ?, updated_at_ms = ? WHERE id = ?",
          arguments: [now - 365 * 86_400_000, now, ancient.taskID.rawValue]
        )
      }

      XCTAssertEqual(try ids(repository, .init(scope: .recent)), [fresh.taskID.rawValue])
      XCTAssertEqual(try repository.navigationCounts().recent, 1)
    }
  }
}
