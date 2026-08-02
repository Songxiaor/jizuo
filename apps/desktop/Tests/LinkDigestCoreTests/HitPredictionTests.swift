import XCTest
@testable import LinkDigestCore

/// 盲预测的算术。
final class HitPredictionTests: XCTestCase {
  private func prediction(
    _ predicted: HitPrediction.Tier, actual: HitPrediction.Tier? = nil
  ) -> HitPrediction {
    .init(
      pieceID: PieceID(), predicted: predicted, reasoning: "因为标题够反常",
      predictedAtMilliseconds: 1, actual: actual
    )
  }

  func testUnsettledHasNoDrift() {
    let one = prediction(.good)
    XCTAssertFalse(one.isSettled)
    XCTAssertNil(one.drift)
    XCTAssertFalse(one.isAccurate)
  }

  func testDriftSignSaysWhichWayYouWereWrong() {
    XCTAssertEqual(prediction(.hit, actual: .quiet).drift, -3, "高估该是负的")
    XCTAssertEqual(prediction(.quiet, actual: .hit).drift, 3, "低估该是正的")
    XCTAssertEqual(prediction(.good, actual: .good).drift, 0)
  }

  func testAccurateMeansExactTier() {
    XCTAssertTrue(prediction(.good, actual: .good).isAccurate)
    XCTAssertFalse(prediction(.good, actual: .hit).isAccurate)
  }

  func testTiersAreOrdered() {
    XCTAssertLessThan(HitPrediction.Tier.quiet, .modest)
    XCTAssertLessThan(HitPrediction.Tier.modest, .good)
    XCTAssertLessThan(HitPrediction.Tier.good, .hit)
  }
}

/// 校准。这是实验室真正的产出。
final class HitCalibrationTests: XCTestCase {
  private func settled(
    _ predicted: HitPrediction.Tier, _ actual: HitPrediction.Tier
  ) -> HitPrediction {
    .init(
      pieceID: PieceID(), predicted: predicted, reasoning: "",
      predictedAtMilliseconds: 1, actual: actual
    )
  }

  private func pending(_ predicted: HitPrediction.Tier) -> HitPrediction {
    .init(pieceID: PieceID(), predicted: predicted, reasoning: "", predictedAtMilliseconds: 1)
  }

  func testOnlySettledPredictionsCount() {
    let calibration = HitCalibration(predictions: [
      settled(.good, .good), pending(.hit), pending(.quiet),
    ])
    XCTAssertEqual(calibration.settledCount, 1)
    XCTAssertEqual(calibration.accurateCount, 1)
  }

  func testCountsBothDirections() {
    let calibration = HitCalibration(predictions: [
      settled(.hit, .quiet), settled(.hit, .modest), settled(.quiet, .hit),
    ])
    XCTAssertEqual(calibration.overestimatedCount, 2)
    XCTAssertEqual(calibration.underestimatedCount, 1)
  }

  /// 数据不够时不给结论。
  ///
  /// 少于门槛看到的「规律」多半是运气。直接显示「3/5 准」会让人立刻
  /// 据此调整，而那是在拿噪声当信号。
  func testDoesNotConcludeFromTooFewSamples() {
    let calibration = HitCalibration(predictions: [
      settled(.hit, .quiet), settled(.hit, .quiet), settled(.hit, .quiet),
    ])
    XCTAssertFalse(calibration.hasEnoughData)
    XCTAssertTrue(calibration.summary.contains("攒够"), "样本不够却给了倾向结论")
  }

  func testCallsOutASystematicOverestimate() {
    let calibration = HitCalibration(
      predictions: Array(repeating: settled(.hit, .quiet), count: 8)
    )
    XCTAssertTrue(calibration.hasEnoughData)
    XCTAssertTrue(calibration.summary.contains("高估"), calibration.summary)
  }

  func testCallsOutASystematicUnderestimate() {
    let calibration = HitCalibration(
      predictions: Array(repeating: settled(.quiet, .good), count: 8)
    )
    XCTAssertTrue(calibration.summary.contains("低估"), calibration.summary)
  }

  func testNoBiasWhenMostlyAccurate() {
    var predictions = Array(repeating: settled(.good, .good), count: 7)
    predictions.append(settled(.hit, .quiet))
    let summary = HitCalibration(predictions: predictions).summary
    XCTAssertTrue(summary.contains("没有明显"), summary)
  }

  func testEmptyIsStatedPlainly() {
    XCTAssertTrue(HitCalibration(predictions: []).summary.contains("还没有"))
  }

  /// 一次预测什么都说明不了 —— 门槛必须明显大于 1。
  func testThresholdIsNotTrivial() {
    XCTAssertGreaterThanOrEqual(HitCalibration.minimumForConclusion, 5)
  }
}
