import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

final class CreatorPersistenceTests: XCTestCase {
  func testEmptyDatabaseCreatesCreatorTablesAtLatestSchema() throws {
    try withCreatorRepository { repository in
      XCTAssertEqual(
        try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") },
        LocalDatabase.latestSchemaVersion
      )
      let names = try repository.database.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_schema WHERE type = 'table' AND name IN ('creators','creator_works') ORDER BY name"
        )
      }
      XCTAssertEqual(names, ["creator_works", "creators"])
      let uniqueSQL = try repository.database.read { db -> String in
        try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE name = 'creators'") ?? ""
      }
      XCTAssertTrue(uniqueSQL.contains("UNIQUE (platform, author_id)"))
      XCTAssertFalse(uniqueSQL.contains("UNIQUE (author_id)"))
      XCTAssertTrue(uniqueSQL.contains("avatar_url"))
    }
  }

  func testVersion19UpgradeKeepsOldTasksAndDoesNotInventCreators() throws {
    try withTemporaryLocation { location in
      let legacy = try DatabaseQueue(path: location.databaseURL.path)
      try legacy.write { db in
        try applyThrough019(db)
        try db.execute(
          sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, 1, 1)",
          arguments: ["11111111-1111-1111-1111-111111111111", "https://www.douyin.com/video/7000000000000000001"]
        )
      }
      try legacy.close()

      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(
        try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") },
        20
      )
      XCTAssertEqual(
        try repository.historyPage(limit: 10, after: nil).rows.map(\.canonicalURL),
        ["https://www.douyin.com/video/7000000000000000001"]
      )
      XCTAssertEqual(try repository.navigationCounts().creatorCount, 0)
      XCTAssertEqual(try repository.creatorPage(limit: 10, after: nil, searchText: "").rows.count, 0)
    }
  }

  func testSameDisplayNameDifferentIdentitiesStaySeparate() throws {
    try withCreatorRepository { repository in
      let one = try repository.upsertCreator(creatorCommand(
        platform: "douyin.com",
        authorID: "MS4wLjABAAAA-one",
        name: "同名博主",
        now: 1
      ))
      let two = try repository.upsertCreator(creatorCommand(
        platform: "douyin.com",
        authorID: "MS4wLjABAAAA-two",
        name: "同名博主",
        now: 2
      ))
      XCTAssertNotEqual(one.id, two.id)
      let xTwin = try repository.upsertCreator(creatorCommand(
        platform: "x.com",
        authorID: "MS4wLjABAAAA-one",
        name: "同名博主",
        now: 3
      ))
      XCTAssertNotEqual(xTwin.id, one.id)

      let firstWork = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "c-one", key: "c-one",
          url: "https://www.douyin.com/video/7000000000000000001",
          body: "one body"
        ),
        receivedAtMilliseconds: 10
      ))
      let secondWork = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "c-two", key: "c-two",
          url: "https://www.douyin.com/video/7000000000000000002",
          body: "two body"
        ),
        receivedAtMilliseconds: 11
      ))
      try repository.attachCreatorWork(creatorID: one.id, taskID: firstWork.taskID)
      try repository.attachCreatorWork(creatorID: two.id, taskID: secondWork.taskID)

      let filtered = try repository.historyPage(
        limit: 20, after: nil, filter: .init(creatorID: one.id)
      )
      XCTAssertEqual(filtered.rows.map(\.taskID), [firstWork.taskID])
      XCTAssertEqual(try repository.creator(id: one.id)?.savedWorkCount, 1)
      XCTAssertEqual(try repository.creator(id: two.id)?.savedWorkCount, 1)
    }
  }

  func testCreatorFilterPaginatesOnlyAttachedSavedTasks() throws {
    try withCreatorRepository { repository in
      let creator = try repository.upsertCreator(creatorCommand(
        authorID: "MS4wLjABAAAA-page",
        now: 1
      ))
      var attached: [TaskID] = []
      for index in 1...55 {
        let accepted = try repository.acceptCapture(.init(
          envelope: capture(
            requestID: "page-\(index)", key: "page-\(index)",
            url: "https://www.douyin.com/video/\(7_000_000_000_000_000_000 + index)",
            body: "work \(index)"
          ),
          receivedAtMilliseconds: Int64(index)
        ))
        try repository.attachCreatorWork(creatorID: creator.id, taskID: accepted.taskID)
        attached.append(accepted.taskID)
      }
      _ = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "other", key: "other",
          url: "https://www.douyin.com/video/7999999999999999999",
          body: "unrelated"
        ),
        receivedAtMilliseconds: 100
      ))

      let first = try repository.historyPage(limit: 50, after: nil, filter: .init(creatorID: creator.id))
      XCTAssertEqual(first.rows.count, 50)
      XCTAssertNotNil(first.nextCursor)
      XCTAssertTrue(Set(first.rows.map(\.taskID)).isSubset(of: Set(attached)))
      let rest = try repository.historyPage(
        limit: 50, after: first.nextCursor, filter: .init(creatorID: creator.id)
      )
      XCTAssertEqual(rest.rows.count, 5)
      XCTAssertNil(rest.nextCursor)
      XCTAssertEqual(Set(first.rows.map(\.taskID)).union(rest.rows.map(\.taskID)).count, 55)
      XCTAssertEqual(try repository.creator(id: creator.id)?.savedWorkCount, 55)
    }
  }

  func testDuplicateImportRefreshesNameKeepsIdentityAndDoesNotDoubleCount() throws {
    try withCreatorRepository { repository in
      let first = try repository.upsertCreator(creatorCommand(
        authorID: "MS4wLjABAAAA-dup",
        name: nil,
        now: 1
      ))
      XCTAssertNil(first.displayName)
      let again = try repository.upsertCreator(creatorCommand(
        authorID: "MS4wLjABAAAA-dup",
        name: "青山言",
        now: 2
      ))
      XCTAssertEqual(again.id, first.id)
      XCTAssertEqual(again.displayName, "青山言")
      XCTAssertEqual(again.identity.authorID, "MS4wLjABAAAA-dup")

      let work = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "dup-work", key: "dup-work",
          url: "https://www.douyin.com/video/7000000000000000100",
          body: "dup body"
        ),
        receivedAtMilliseconds: 3
      ))
      try repository.attachCreatorWork(creatorID: first.id, taskID: work.taskID)
      try repository.attachCreatorWork(creatorID: first.id, taskID: work.taskID)
      XCTAssertEqual(try repository.creator(id: first.id)?.savedWorkCount, 1)
    }
  }

  func testAttachExistingCanonicalURLsIgnoresUnsavedAndPinLimitIsTransactional() throws {
    try withCreatorRepository { repository in
      let creator = try repository.upsertCreator(creatorCommand(authorID: "MS4wLjABAAAA-pin", now: 1))
      let saved = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "pin-work", key: "pin-work",
          url: "https://www.douyin.com/video/7000000000000000200",
          body: "saved body"
        ),
        receivedAtMilliseconds: 2
      ))
      let result = try repository.attachCreatorWorks(
        creatorID: creator.id,
        canonicalURLs: [
          "https://www.douyin.com/video/7000000000000000200",
          "https://www.douyin.com/video/7000000000000000201",
        ]
      )
      XCTAssertEqual(result.attachedTaskIDs, [saved.taskID])
      XCTAssertEqual(result.unmatchedCanonicalURLs, ["https://www.douyin.com/video/7000000000000000201"])
      XCTAssertEqual(try repository.creator(id: creator.id)?.savedWorkCount, 1)

      var pinned: [CreatorID] = []
      for index in 1...5 {
        let item = try repository.upsertCreator(creatorCommand(
          authorID: "MS4wLjABAAAA-pin-\(index)",
          now: Int64(10 + index)
        ))
        try repository.setCreatorPinned(creatorID: item.id, pinned: true)
        pinned.append(item.id)
      }
      XCTAssertEqual(try repository.navigationCounts().pinnedCreators.count, 5)
      XCTAssertThrowsError(try repository.setCreatorPinned(creatorID: creator.id, pinned: true)) { error in
        XCTAssertEqual(error as? RepositoryFailure, .invalidInput)
      }
      XCTAssertEqual(try repository.navigationCounts().pinnedCreators.map(\.id), pinned)
      XCTAssertNil(try repository.creator(id: creator.id)?.pinnedRank)
    }
  }

  func testDeletingTaskCascadesAssociationAndUpdatesCount() throws {
    try withCreatorRepository { repository in
      let creator = try repository.upsertCreator(creatorCommand(authorID: "MS4wLjABAAAA-del", now: 1))
      let keep = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "keep", key: "keep",
          url: "https://www.douyin.com/video/7000000000000000301",
          body: "keep body"
        ),
        receivedAtMilliseconds: 2
      ))
      let gone = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "gone", key: "gone",
          url: "https://www.douyin.com/video/7000000000000000302",
          body: "gone body"
        ),
        receivedAtMilliseconds: 3
      ))
      try repository.attachCreatorWork(creatorID: creator.id, taskID: keep.taskID)
      try repository.attachCreatorWork(creatorID: creator.id, taskID: gone.taskID)
      XCTAssertEqual(try repository.creator(id: creator.id)?.savedWorkCount, 2)
      try repository.deleteTask(taskID: gone.taskID)
      XCTAssertEqual(try repository.creator(id: creator.id)?.savedWorkCount, 1)
      XCTAssertEqual(
        try repository.historyPage(limit: 10, after: nil, filter: .init(creatorID: creator.id)).rows.map(\.taskID),
        [keep.taskID]
      )
      XCTAssertEqual(try repository.creator(id: creator.id)?.savedWorkCount, 1)
    }
  }

  func testAttachConflictKeepsOriginalOwnerForSingleAndBatch() throws {
    try withCreatorRepository { repository in
      let first = try repository.upsertCreator(creatorCommand(authorID: "MS4wLjABAAAA-owner", now: 1))
      let second = try repository.upsertCreator(creatorCommand(authorID: "MS4wLjABAAAA-other", now: 2))
      let work = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "owned", key: "owned",
          url: "https://www.douyin.com/video/7000000000000000401",
          body: "owned body"
        ),
        receivedAtMilliseconds: 3
      ))
      try repository.attachCreatorWork(creatorID: first.id, taskID: work.taskID)
      try repository.attachCreatorWork(creatorID: first.id, taskID: work.taskID)
      XCTAssertThrowsError(try repository.attachCreatorWork(creatorID: second.id, taskID: work.taskID)) { error in
        XCTAssertEqual(error as? RepositoryFailure, .invalidInput)
      }
      XCTAssertEqual(try repository.creator(id: first.id)?.savedWorkCount, 1)
      XCTAssertEqual(try repository.creator(id: second.id)?.savedWorkCount, 0)

      XCTAssertThrowsError(try repository.attachCreatorWorks(
        creatorID: second.id,
        canonicalURLs: ["https://www.douyin.com/video/7000000000000000401"]
      )) { error in
        XCTAssertEqual(error as? RepositoryFailure, .invalidInput)
      }
      let again = try repository.attachCreatorWorks(
        creatorID: first.id,
        canonicalURLs: ["https://www.douyin.com/video/7000000000000000401"]
      )
      XCTAssertEqual(again.attachedTaskIDs, [work.taskID])
      XCTAssertEqual(try repository.creator(id: first.id)?.savedWorkCount, 1)
    }
  }

  func testCreatorPageCursorIncludesPinStateAndRefreshAfterUnpin() throws {
    try withCreatorRepository { repository in
      var created: [CreatorSummary] = []
      for index in 1...8 {
        created.append(try repository.upsertCreator(creatorCommand(
          authorID: "MS4wLjABAAAA-page-\(index)",
          now: Int64(index)
        )))
      }
      try repository.setCreatorPinned(creatorID: created[0].id, pinned: true)
      try repository.setCreatorPinned(creatorID: created[1].id, pinned: true)

      func ids(_ page: CreatorPage) -> [CreatorID] { page.rows.map(\.id) }
      let first = try repository.creatorPage(limit: 3, after: nil, searchText: "")
      XCTAssertEqual(ids(first), [created[0].id, created[1].id, created[7].id])
      XCTAssertEqual(first.rows.map(\.pinnedRank), [1, 2, nil])
      XCTAssertNil(first.nextCursor?.pinnedRank, "第一页最后一条已是未置顶，游标必须带上未置顶状态")
      let second = try repository.creatorPage(limit: 3, after: first.nextCursor, searchText: "")
      XCTAssertEqual(ids(second), [created[6].id, created[5].id, created[4].id])
      XCTAssertFalse(Set(ids(second)).contains(created[0].id))
      XCTAssertFalse(Set(ids(second)).contains(created[1].id), "只按时间翻页会把更早的置顶人再捞回来")
      XCTAssertNil(second.nextCursor?.pinnedRank)
      let third = try repository.creatorPage(limit: 3, after: second.nextCursor, searchText: "")
      XCTAssertEqual(ids(third), [created[3].id, created[2].id])
      let all = ids(first) + ids(second) + ids(third)
      XCTAssertEqual(all.count, Set(all).count, "跨页不能重复")
      XCTAssertEqual(Set(all), Set(created.map(\.id)))

      try repository.setCreatorPinned(creatorID: created[0].id, pinned: false)
      let refreshed = try repository.creatorPage(limit: 3, after: nil, searchText: "")
      XCTAssertEqual(ids(refreshed).first, created[1].id)
      XCTAssertFalse(ids(refreshed).contains(created[0].id), "取消置顶后应按未置顶时间重排，不能还停在第一页置顶位")
      let rest = try repository.creatorPage(limit: 10, after: refreshed.nextCursor, searchText: "")
      let refreshedAll = ids(refreshed) + ids(rest)
      XCTAssertEqual(refreshedAll.count, Set(refreshedAll).count)
      XCTAssertEqual(Set(refreshedAll), Set(created.map(\.id)))
    }
  }

  func testAvatarURLPersistsOnUpsertAndStaysWhenNameRefreshes() throws {
    try withCreatorRepository { repository in
      let first = try repository.upsertCreator(creatorCommand(
        authorID: "MS4wLjABAAAA-avatar",
        avatarURL: "https://p3.douyinpic.com/aweme/100x100/fixture-avatar.jpeg",
        now: 1
      ))
      XCTAssertEqual(first.avatarURL, "https://p3.douyinpic.com/aweme/100x100/fixture-avatar.jpeg")
      let renamed = try repository.upsertCreator(creatorCommand(
        authorID: "MS4wLjABAAAA-avatar",
        name: "有头像的博主",
        now: 2
      ))
      XCTAssertEqual(renamed.id, first.id)
      XCTAssertEqual(renamed.displayName, "有头像的博主")
      XCTAssertEqual(renamed.avatarURL, first.avatarURL)
    }
  }
}

private func withCreatorRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
  try withTemporaryLocation { location in
    let repository = try GRDBHistoryRepository.open(at: location)
    defer { try? repository.database.close() }
    try body(repository)
  }
}

private func capture(
  requestID: String,
  key: String,
  url: String,
  body: String
) -> CaptureEnvelopeV1 {
  CaptureEnvelopeV1(
    version: 1,
    requestId: requestID,
    createdAt: "2026-07-15T04:00:00Z",
    idempotencyKey: key,
    source: .init(kind: "browser_capture", url: url, title: "Fixture", platform: "generic"),
    capture: .init(
      method: "rendered_dom",
      text: body,
      characterCount: body.unicodeScalars.count,
      completeness: "full_article",
      capturedAt: "2026-07-15T04:00:00Z"
    ),
    evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
  )
}

private func creatorCommand(
  platform: String = "douyin.com",
  authorID: String,
  name: String? = nil,
  profileURL: String? = nil,
  avatarURL: String? = nil,
  now: Int64
) -> UpsertCreatorCommand {
  let identity = CreatorIdentity(platform: platform, authorID: authorID)!
  return UpsertCreatorCommand(
    identity: identity,
    profileURL: profileURL ?? "https://www.douyin.com/user/\(authorID)",
    displayName: name,
    avatarURL: avatarURL,
    nowMilliseconds: now
  )!
}

private func applyThrough019(_ db: Database) throws {
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
}
