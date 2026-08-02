import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 阶段推断。
///
/// 阶段如果全靠手动推进，它就成了填表——每件创作都要记得去点一下，
/// 而人只会在意「东西写完没有」。所以这里钉的是推断规则本身。
final class PieceStageInferenceTests: XCTestCase {
  func testStageFollowsWhatActuallyExists() {
    XCTAssertEqual(
      PieceStage.inferred(materialCount: 0, bodyLength: 0, isFinished: false), .spark,
      "只有一句话时就是灵感阶段"
    )
    XCTAssertEqual(
      PieceStage.inferred(materialCount: 2, bodyLength: 0, isFinished: false), .collect
    )
    XCTAssertEqual(
      PieceStage.inferred(materialCount: 2, bodyLength: 500, isFinished: false), .draft
    )
  }

  /// 把灵感那句话抄进正文不算开始写——否则新建完就直接跳到起草。
  func testAShortBodyIsNotYetDrafting() {
    XCTAssertEqual(
      PieceStage.inferred(materialCount: 1, bodyLength: 20, isFinished: false), .collect
    )
  }

  /// 完成压过一切：已发出的不该因为素材少又被算回收集。
  func testFinishedWins() {
    XCTAssertEqual(
      PieceStage.inferred(materialCount: 0, bodyLength: 0, isFinished: true), .done
    )
  }

  /// 进度条只有四格，`done` 是终点不是第五步。
  func testDoneIsNotOnTheTrack() {
    XCTAssertEqual(PieceStage.track.count, 4)
    XCTAssertNil(PieceStage.done.trackIndex)
    XCTAssertEqual(PieceStage.spark.trackIndex, 0)
    XCTAssertEqual(PieceStage.polish.trackIndex, 3)
  }
}

/// 工作台的持久化。
final class PiecePersistenceTests: XCTestCase {
  /// 建一件创作，连带它的正文笔记。返回 (pieceID, noteTaskID)。
  private func makePiece(
    _ repository: GRDBHistoryRepository,
    spark: String,
    body: String? = nil,
    at ms: Int64 = 1_000
  ) throws -> (PieceID, TaskID) {
    let accepted = try repository.acceptCapture(.init(
      document: try UserNoteDocument.make(
        title: PieceDocument.noteTitle(forSpark: spark), body: body
      ),
      receivedAtMilliseconds: ms
    ))
    let id = PieceID()
    try repository.createPiece(
      id: id, spark: spark, noteTaskID: accepted.taskID, createdAtMilliseconds: ms
    )
    return (id, accepted.taskID)
  }

  func testCreatingAPieceStartsAtSpark() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, noteID) = try makePiece(repository, spark: "AI 时代的创作可以偷懒")
      let piece = try XCTUnwrap(try repository.piece(id: id))
      XCTAssertEqual(piece.stage, .spark)
      XCTAssertEqual(piece.spark, "AI 时代的创作可以偷懒")
      XCTAssertEqual(piece.noteTaskID, noteID)
      XCTAssertEqual(piece.materialCount, 0)
      XCTAssertNil(piece.finishedAtMilliseconds)
    }
  }

  func testEmptySparkIsRejected() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let accepted = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(body: "x"), receivedAtMilliseconds: 1
      ))
      XCTAssertThrowsError(
        try repository.createPiece(
          id: PieceID(), spark: "   ", noteTaskID: accepted.taskID, createdAtMilliseconds: 1
        )
      ) { XCTAssertEqual($0 as? RepositoryFailure, .invalidInput) }
    }
  }

  /// 加了素材，阶段自己就该往前走一格——不需要用户去点。
  func testAddingMaterialMovesTheStageOnItsOwn() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(repository, spark: "灵感")
      let material = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-08-01T00:00:00Z", origin: .manualLink,
          url: "https://example.test/a", title: "一篇素材",
          platform: "web", method: "fixture", text: "正文",
          completeness: "complete", capturedAt: "2026-08-01T00:00:00Z", sourceLabel: "网页"
        ),
        receivedAtMilliseconds: 2
      ))

      try repository.addMaterial(taskID: material.taskID, to: id, addedAtMilliseconds: 3)
      let piece = try XCTUnwrap(try repository.piece(id: id))
      XCTAssertEqual(piece.stage, .collect)
      XCTAssertEqual(piece.materialCount, 1)
    }
  }

  /// 重复加入不该报错也不该变成两条——用户从两个地方各点一次是常事。
  func testAddingTheSameMaterialTwiceKeepsOne() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(repository, spark: "灵感")
      let material = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "素材笔记", body: "内容"),
        receivedAtMilliseconds: 2
      ))
      try repository.addMaterial(taskID: material.taskID, to: id, addedAtMilliseconds: 3)
      XCTAssertNoThrow(try repository.addMaterial(taskID: material.taskID, to: id, addedAtMilliseconds: 4))
      XCTAssertEqual(try repository.materials(of: id).count, 1)
    }
  }

  /// 正文写长了就是起草中，同样不需要手动切。
  func testWritingBodyMovesToDrafting() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(
        repository, spark: "灵感", body: String(repeating: "写", count: 200)
      )
      XCTAssertEqual(try repository.piece(id: id)?.stage, .draft)
    }
  }

  /// 占位符不算字数。
  ///
  /// 它是「从这里开始写…」这种提示,不是用户写的内容。算进去的话,
  /// 一个字都没写的稿子会显示「7 字」,而阶段推断也会跟着偏。
  func testPlaceholderBodyCountsAsZeroWords() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      // 不传 body,PieceDraftDocument 会填占位符。
      let accepted = try repository.acceptCapture(.init(
        document: try PieceDraftDocument.make(title: "灵感"), receivedAtMilliseconds: 1
      ))
      let id = PieceID()
      try repository.createPiece(
        id: id, spark: "灵感", noteTaskID: accepted.taskID, createdAtMilliseconds: 1
      )

      let piece = try XCTUnwrap(try repository.piece(id: id))
      XCTAssertEqual(piece.bodyLength, 0, "占位符不该被当成写过的字")
      XCTAssertEqual(piece.stage, .spark, "只有占位符时仍在灵感阶段")
    }
  }

  /// 手动覆盖压过推断；传 nil 回到自动。
  func testManualStageOverridesInferenceAndCanBeReleased() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(
        repository, spark: "灵感", body: String(repeating: "写", count: 200)
      )
      XCTAssertEqual(try repository.piece(id: id)?.stage, .draft)

      // 写到一半发现素材不够，退回收集——这是正常的，不是失败。
      try repository.setPieceStage(.collect, for: id, updatedAtMilliseconds: 10)
      XCTAssertEqual(try repository.piece(id: id)?.stage, .collect)

      try repository.setPieceStage(nil, for: id, updatedAtMilliseconds: 11)
      XCTAssertEqual(try repository.piece(id: id)?.stage, .draft, "放开覆盖后应回到推断值")
    }
  }

  func testFinishingRecordsATimeAndSinksItInTheList() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (older, _) = try makePiece(repository, spark: "先建的", at: 1_000)
      let (newer, _) = try makePiece(repository, spark: "后建的", at: 2_000)

      // 把「后建的」标记为已发出，它就该沉到未完成的下面。
      try repository.setPieceStage(.done, for: newer, updatedAtMilliseconds: 3_000)
      let list = try repository.pieces()
      XCTAssertEqual(list.map(\.id), [older, newer])
      XCTAssertEqual(list.last?.stage, .done)
      XCTAssertNotNil(list.last?.finishedAtMilliseconds)
    }
  }

  /// 删掉一件创作不该连带删掉稿子——「不做这篇了」不等于「把写的东西扔了」。
  func testDeletingAPieceKeepsTheWrittenNote() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, noteID) = try makePiece(repository, spark: "灵感", body: "已经写了一些东西")
      try repository.deletePiece(id: id)

      XCTAssertNil(try repository.piece(id: id))
      XCTAssertNoThrow(try repository.detail(taskID: noteID), "正文笔记必须还在")
    }
  }

  /// 素材被删掉时，创作里的引用要跟着消失，而不是留一行对不上的空白。
  func testDeletingAMaterialRemovesTheReference() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(repository, spark: "灵感")
      let material = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "会被删的素材", body: "内容"),
        receivedAtMilliseconds: 2
      ))
      try repository.addMaterial(taskID: material.taskID, to: id, addedAtMilliseconds: 3)
      XCTAssertEqual(try repository.materials(of: id).count, 1)

      _ = try repository.deleteTasks(taskIDs: [material.taskID])
      XCTAssertTrue(try repository.materials(of: id).isEmpty)
      XCTAssertEqual(try repository.piece(id: id)?.materialCount, 0)
    }
  }

  func testMaterialsCarryTitleAndSource() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let (id, _) = try makePiece(repository, spark: "灵感")
      let note = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "我的笔记素材", body: "内容"),
        receivedAtMilliseconds: 2
      ))
      try repository.addMaterial(taskID: note.taskID, to: id, addedAtMilliseconds: 3)

      let material = try XCTUnwrap(try repository.materials(of: id).first)
      XCTAssertEqual(material.title, "我的笔记素材")
      XCTAssertEqual(material.host, HistoryPlatformDisplay.noteHost)
      XCTAssertTrue(material.isAvailable)
    }
  }
}
