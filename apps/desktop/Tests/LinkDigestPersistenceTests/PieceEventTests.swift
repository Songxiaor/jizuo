import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 判断沉淀。
///
/// 这张表是整个系统里唯一带着用户个人信息的东西——素材是别人写的,
/// AI 的产出是模型给的,只有「你把它改成了什么」是你的。
final class PieceEventTests: XCTestCase {
  private func makePiece(_ repository: GRDBHistoryRepository, spark: String = "灵感") throws -> PieceID {
    let draft = try repository.acceptCapture(.init(
      document: try PieceDraftDocument.make(title: spark), receivedAtMilliseconds: 1
    ))
    let id = PieceID()
    try repository.createPiece(
      id: id, spark: spark, noteTaskID: draft.taskID, createdAtMilliseconds: 1
    )
    return id
  }

  func testEventsAreRecordedInOrder() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let id = try makePiece(repository)

      try repository.recordPieceEvent(.init(pieceID: id, kind: .materialAdded, detail: "素材A", createdAtMilliseconds: 10))
      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "AI 写的", createdAtMilliseconds: 20))
      try repository.recordPieceEvent(.init(pieceID: id, kind: .revised, detail: "我改的", createdAtMilliseconds: 30))

      let events = try repository.pieceEvents(of: id)
      XCTAssertEqual(events.map(\.kind), [.materialAdded, .drafted, .revised])
      XCTAssertEqual(events.map(\.detail), ["素材A", "AI 写的", "我改的"])
    }
  }

  /// 配对是这张表真正的产出:AI 写成这样、我改成了那样。
  func testPairsGeneratedWithWhatYouChangedItInto() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let id = try makePiece(repository)

      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "AI 的版本", createdAtMilliseconds: 10))
      try repository.recordPieceEvent(.init(pieceID: id, kind: .revised, detail: "我的版本", createdAtMilliseconds: 20))

      let pairs = try repository.draftRevisionPairs(limit: 10)
      XCTAssertEqual(pairs.count, 1)
      XCTAssertEqual(pairs.first?.generated, "AI 的版本")
      XCTAssertEqual(pairs.first?.revised, "我的版本")
    }
  }

  /// AI 写完你还没动过 —— 不成对。
  ///
  /// 得不出任何偏好的记录不该混进来,它只会稀释真正有信号的那些。
  func testDraftWithoutRevisionIsNotAPair() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let id = try makePiece(repository)

      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "AI 的版本", createdAtMilliseconds: 10))
      XCTAssertTrue(try repository.draftRevisionPairs(limit: 10).isEmpty)
    }
  }

  /// 修订必须发生在**那次**起草之后。
  ///
  /// 重跑起草时,上一轮的修订不能被算成新一版的反馈——那会把
  /// 「你对旧版本的意见」错记成「你对新版本的意见」。
  func testOnlyRevisionsAfterTheLatestDraftCount() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let id = try makePiece(repository)

      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "第一版", createdAtMilliseconds: 10))
      try repository.recordPieceEvent(.init(pieceID: id, kind: .revised, detail: "对第一版的修改", createdAtMilliseconds: 20))
      // 重跑起草。
      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "第二版", createdAtMilliseconds: 30))

      // 第二版还没改过,所以整体无可配对——不能把「对第一版的修改」配给第二版。
      XCTAssertTrue(
        try repository.draftRevisionPairs(limit: 10).isEmpty,
        "旧修订不能被算成新一版的反馈"
      )

      try repository.recordPieceEvent(.init(pieceID: id, kind: .revised, detail: "对第二版的修改", createdAtMilliseconds: 40))
      let pairs = try repository.draftRevisionPairs(limit: 10)
      XCTAssertEqual(pairs.first?.generated, "第二版")
      XCTAssertEqual(pairs.first?.revised, "对第二版的修改")
    }
  }

  /// 删掉创作,它的痕迹跟着走。
  func testDeletingAPieceRemovesItsEvents() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let id = try makePiece(repository)

      try repository.recordPieceEvent(.init(pieceID: id, kind: .drafted, detail: "x", createdAtMilliseconds: 10))
      try repository.deletePiece(id: id)
      XCTAssertTrue(try repository.pieceEvents(of: id).isEmpty)
    }
  }
}

/// 改动幅度。
///
/// 这个数字的用途是「筛出值得细看的那几篇」——几乎没改的不用看,
/// 大改的才说明 AI 那版偏得远。所以要的是量级,不是逐字精确。
final class DraftRevisionRatioTests: XCTestCase {
  private func pair(_ a: String, _ b: String) -> DraftRevisionPair {
    .init(generated: a, revised: b, generatedAtMilliseconds: 1, revisedAtMilliseconds: 2)
  }

  func testUntouchedIsZero() {
    let same = pair("完全一样的一段文字", "完全一样的一段文字")
    XCTAssertEqual(same.changeRatio, 0)
    XCTAssertTrue(same.isNearlyUntouched)
  }

  func testSmallEditStaysSmall() {
    let p = pair(
      String(repeating: "原", count: 200),
      String(repeating: "原", count: 199) + "改"
    )
    XCTAssertLessThan(p.changeRatio, 0.05)
    XCTAssertTrue(p.isNearlyUntouched, "只动一个字不该被当成大改")
  }

  func testRewriteIsLarge() {
    let p = pair(String(repeating: "甲", count: 100), String(repeating: "乙", count: 100))
    XCTAssertGreaterThan(p.changeRatio, 0.9)
    XCTAssertFalse(p.isNearlyUntouched)
  }

  /// 中间插一段:两端相同的部分要被正确吃掉,只算中间那块。
  func testInsertionCountsOnlyTheInsertedPart() {
    let head = String(repeating: "头", count: 100)
    let tail = String(repeating: "尾", count: 100)
    let p = pair(head + tail, head + String(repeating: "新", count: 20) + tail)
    XCTAssertLessThan(p.changeRatio, 0.15)
    XCTAssertGreaterThan(p.changeRatio, 0)
  }

  func testEmptyGeneratedIsHandled() {
    XCTAssertEqual(pair("", "").changeRatio, 0)
    XCTAssertEqual(pair("", "写了东西").changeRatio, 1)
  }
}
