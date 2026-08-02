import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 爆款实验室的存储。
///
/// 这里钉的核心只有一件事:**预测落定之后不可改**。整个校准循环靠它——
/// 一旦能改，人会不自觉地往结果的方向修，然后得出「我判断挺准的」
/// 这个毫无价值的结论。
final class HitPredictionStoreTests: XCTestCase {
  private func makePiece(_ repository: GRDBHistoryRepository) throws -> PieceID {
    let draft = try repository.acceptCapture(.init(
      document: try PieceDraftDocument.make(title: "稿子"), receivedAtMilliseconds: 1
    ))
    let id = PieceID()
    try repository.createPiece(
      id: id, spark: "灵感", noteTaskID: draft.taskID, createdAtMilliseconds: 1
    )
    return id
  }

  func testRoundTrips() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let piece = try makePiece(repository)

      try repository.insertHitPrediction(.init(
        pieceID: piece, predicted: .good, reasoning: "标题够反常",
        predictedAtMilliseconds: 10
      ))
      let stored = try XCTUnwrap(try repository.hitPrediction(of: piece))
      XCTAssertEqual(stored.predicted, .good)
      XCTAssertEqual(stored.reasoning, "标题够反常")
      XCTAssertFalse(stored.isSettled)
    }
  }

  /// 一件创作只能预测一次。
  ///
  /// 允许多次就等于允许重来:看到结果不理想再补一条，「盲」就没了。
  func testOnePredictionPerPiece() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let piece = try makePiece(repository)

      try repository.insertHitPrediction(.init(
        pieceID: piece, predicted: .good, reasoning: "", predictedAtMilliseconds: 10
      ))
      XCTAssertThrowsError(try repository.insertHitPrediction(.init(
        pieceID: piece, predicted: .hit, reasoning: "改主意了", predictedAtMilliseconds: 20
      )), "同一件创作被预测了第二次")
    }
  }

  /// 录入结果只写结果，预测本身碰都不碰。
  func testSettlingLeavesThePredictionUntouched() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let piece = try makePiece(repository)

      let one = HitPrediction(
        pieceID: piece, predicted: .hit, reasoning: "我以为这个话题正热",
        predictedAtMilliseconds: 10
      )
      try repository.insertHitPrediction(one)
      try repository.settleHitPrediction(
        id: one.id, actual: .quiet, review: "话题早过去了", settledAtMilliseconds: 20
      )

      let stored = try XCTUnwrap(try repository.hitPrediction(of: piece))
      XCTAssertEqual(stored.predicted, .hit, "预测被改动了")
      XCTAssertEqual(stored.reasoning, "我以为这个话题正热", "预测理由被改动了")
      XCTAssertEqual(stored.predictedAtMilliseconds, 10)
      XCTAssertEqual(stored.actual, .quiet)
      XCTAssertEqual(stored.review, "话题早过去了")
      XCTAssertEqual(stored.drift, -3)
    }
  }

  func testSettlingAMissingPredictionFails() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertThrowsError(try repository.settleHitPrediction(
        id: UUID(), actual: .good, review: "", settledAtMilliseconds: 1
      )) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
    }
  }

  func testListedNewestFirst() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let first = try makePiece(repository)
      let second = try makePiece(repository)

      try repository.insertHitPrediction(.init(
        pieceID: first, predicted: .quiet, reasoning: "早的", predictedAtMilliseconds: 10
      ))
      try repository.insertHitPrediction(.init(
        pieceID: second, predicted: .hit, reasoning: "晚的", predictedAtMilliseconds: 20
      ))
      XCTAssertEqual(try repository.hitPredictions().map(\.reasoning), ["晚的", "早的"])
    }
  }

  /// 删掉创作，它的预测跟着走。
  func testDeletingAPieceRemovesItsPrediction() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let piece = try makePiece(repository)

      try repository.insertHitPrediction(.init(
        pieceID: piece, predicted: .good, reasoning: "", predictedAtMilliseconds: 10
      ))
      try repository.deletePiece(id: piece)
      XCTAssertNil(try repository.hitPrediction(of: piece))
    }
  }
}
