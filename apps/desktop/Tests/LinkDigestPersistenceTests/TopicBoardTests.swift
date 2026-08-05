import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 取数层。
///
/// 方案里那条分界线：**取数是确定性的，加工才是模型的活**。
/// 这里钉的就是「确定性」那一半——窗口、条数、排除项。
final class TopicRecallQueryTests: XCTestCase {
  private let day: Int64 = 24 * 60 * 60 * 1000
  private let now: Int64 = 1_700_000_000_000

  @discardableResult
  private func capture(
    _ repository: GRDBHistoryRepository, title: String, at time: Int64
  ) throws -> TaskID {
    let record = try repository.acceptCapture(.init(
      document: try UserNoteDocument.make(title: title), receivedAtMilliseconds: time
    ))
    return record.taskID
  }

  func testRecentLaneTakesOnlyWhatIsInsideTheWindow() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try capture(repository, title: "三天前", at: now - 3 * day)
      try capture(repository, title: "十天前", at: now - 10 * day)

      let titles = try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 10), now: now
      ).map(\.title)
      XCTAssertEqual(titles, ["三天前"])
    }
  }

  /// 沉睡那一路只取够老的。
  func testDormantLaneTakesOnlyWhatIsOldEnough() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try capture(repository, title: "昨天", at: now - day)
      try capture(repository, title: "四十天前", at: now - 40 * day)

      let titles = try repository.recallMaterials(
        lane: .init(name: "沉睡", window: .dormant(sinceDays: 30), limit: 10), now: now
      ).map(\.title)
      XCTAssertEqual(titles, ["四十天前"])
    }
  }

  func testLimitIsRespected() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      for i in 1...6 { try capture(repository, title: "第\(i)条", at: now - Int64(i) * 1000) }
      let results = try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 3), now: now
      )
      XCTAssertEqual(results.count, 3)
      // 新的优先。
      XCTAssertEqual(results.first?.title, "第1条")
    }
  }

  /// 草稿不能当素材。
  ///
  /// 它是这套系统自己的产物。喂回去，模型只会越来越像它自己写的东西——
  /// 而用户按这个按钮是想看到自己想不到的组合。
  func testDraftsAreNeverRecalled() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try capture(repository, title: "真素材", at: now - day)
      _ = try repository.acceptCapture(.init(
        document: try PieceDraftDocument.make(title: "在写的稿子"),
        receivedAtMilliseconds: now - day
      ))

      let titles = try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 10), now: now
      ).map(\.title)
      XCTAssertEqual(titles, ["真素材"])
    }
  }

  /// 成品也不能当素材。
  ///
  /// `finishPiece` 是把稿子那条 task **原地**转成成品。只排除稿件的话，
  /// 同一条内容「做完」前后换个前缀就从排除变成召回——规则会自相矛盾，
  /// 而表现是选题板开始拿用户上周写完的东西给他出选题。
  func testFinishedWorksAreNeverRecalled() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try capture(repository, title: "真素材", at: now - day)
      let draft = try repository.acceptCapture(.init(
        document: try PieceDraftDocument.make(title: "写完的那篇"),
        receivedAtMilliseconds: now - day
      ))
      let piece = PieceID()
      try repository.createPiece(
        id: piece, spark: "写完的那篇",
        noteTaskID: draft.taskID, createdAtMilliseconds: now - day
      )
      _ = try repository.finishPiece(id: piece, finishedAtMilliseconds: now - day)

      let titles = try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 10), now: now
      ).map(\.title)
      XCTAssertEqual(titles, ["真素材"])
    }
  }

  func testTagFilterNarrowsTheLane() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let tagged = try capture(repository, title: "带标签的", at: now - day)
      try capture(repository, title: "没标签的", at: now - day)
      _ = try repository.addTags(["AI"], to: tagged)

      let titles = try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 10, tags: ["ai"]), now: now
      ).map(\.title)
      XCTAssertEqual(titles, ["带标签的"])
    }
  }

  func testEmptyLibraryReturnsNothingRatherThanFailing() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertTrue(try repository.recallMaterials(
        lane: .init(name: "近期", window: .recent(days: 7), limit: 10), now: now
      ).isEmpty)
    }
  }
}

/// 候选的读写。
final class TopicCandidateStoreTests: XCTestCase {
  private let today = TopicCandidate.dayStart(of: Date())

  private func candidate(
    _ title: String, day: Int64, verdict: TopicCandidate.Verdict = .pending,
    outOfBounds: Bool = false, materials: [TaskID] = [], createdAt: Int64 = 1
  ) -> TopicCandidate {
    .init(
      dayStartMilliseconds: day, title: title, summary: "一句话",
      materialTaskIDs: materials, isOutOfBounds: outOfBounds,
      verdict: verdict, createdAtMilliseconds: createdAt
    )
  }

  func testRoundTripsAndKeepsOrder() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try repository.insertTopicCandidates([
        candidate("第一条", day: today, createdAt: 1),
        candidate("第二条", day: today, createdAt: 2),
      ])
      let stored = try repository.topicCandidates(dayStartMilliseconds: today)
      XCTAssertEqual(stored.map(\.title), ["第一条", "第二条"])
    }
  }

  func testOutOfBoundsFlagSurvives() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try repository.insertTopicCandidates([candidate("越界的", day: today, outOfBounds: true)])
      XCTAssertEqual(
        try repository.topicCandidates(dayStartMilliseconds: today).first?.isOutOfBounds, true
      )
    }
  }

  /// 划掉的**不删**。
  ///
  /// 「这类角度他从来不选」这个结论只能从被否决的东西里得出来。
  /// 删掉等于把唯一的负样本扔了。
  func testDecliningKeepsTheRecord() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let one = candidate("不要的", day: today)
      try repository.insertTopicCandidates([one])
      try repository.setTopicVerdict(.declined, for: one.id)

      let stored = try repository.topicCandidates(dayStartMilliseconds: today)
      XCTAssertEqual(stored.count, 1, "划掉的候选被删了，负样本就没了")
      XCTAssertEqual(stored.first?.verdict, .declined)
    }
  }

  func testSettingVerdictOnAMissingCandidateFails() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertThrowsError(try repository.setTopicVerdict(.taken, for: UUID())) { error in
        XCTAssertEqual(error as? RepositoryFailure, .notFound)
      }
    }
  }

  /// 同一天可以再跑一次，追加不覆盖。
  ///
  /// 覆盖会把用户已经做过的判断一起抹掉——他上午划掉的三条，下午重跑之后
  /// 又回来了，而且看不出为什么。
  func testRerunningTheSameDayAppends() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let first = candidate("上午那条", day: today, createdAt: 1)
      try repository.insertTopicCandidates([first])
      try repository.setTopicVerdict(.declined, for: first.id)
      try repository.insertTopicCandidates([candidate("下午那条", day: today, createdAt: 2)])

      let stored = try repository.topicCandidates(dayStartMilliseconds: today)
      XCTAssertEqual(stored.count, 2)
      XCTAssertEqual(stored.first?.verdict, .declined, "已有判断被重跑抹掉了")
    }
  }

  func testRecentListsNewestDayFirst() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let yesterday = today - 24 * 60 * 60 * 1000
      try repository.insertTopicCandidates([
        candidate("昨天的", day: yesterday),
        candidate("今天的", day: today),
      ])
      XCTAssertEqual(
        try repository.recentTopicCandidates(limit: 10).map(\.title), ["今天的", "昨天的"]
      )
    }
  }

  /// 素材关联跟着候选走。
  func testMaterialLinksAreStored() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let record = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "出处"), receivedAtMilliseconds: 1
      ))
      try repository.insertTopicCandidates([
        candidate("有出处的", day: today, materials: [record.taskID]),
      ])
      XCTAssertEqual(
        try repository.topicCandidates(dayStartMilliseconds: today).first?.materialTaskIDs,
        [record.taskID]
      )
    }
  }

  /// 素材在生成过程中被删了 —— 候选本身还是有用的，不该整批失败。
  func testCandidateSurvivesAMissingMaterial() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let ghost = TaskID(UUID())
      try repository.insertTopicCandidates([
        candidate("出处已经没了", day: today, materials: [ghost]),
      ])
      let stored = try repository.topicCandidates(dayStartMilliseconds: today)
      XCTAssertEqual(stored.count, 1)
      XCTAssertTrue(stored.first?.materialTaskIDs.isEmpty ?? false)
    }
  }

  /// 模型无视字数要求写了长摘要 —— 截断，不是让整批失败。
  ///
  /// 用户看到「今天没出选题」时不会知道是因为一条摘要长了 20 个字。
  func testOverlongSummaryIsTruncatedRatherThanRejected() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try repository.insertTopicCandidates([.init(
        dayStartMilliseconds: today, title: "长摘要",
        summary: String(repeating: "字", count: 900), createdAtMilliseconds: 1
      )])
      let stored = try repository.topicCandidates(dayStartMilliseconds: today)
      XCTAssertEqual(stored.count, 1)
      XCTAssertLessThanOrEqual(stored.first?.summary.count ?? 0, 400)
    }
  }

  func testInsertingNothingIsANoop() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertNoThrow(try repository.insertTopicCandidates([]))
    }
  }
}
