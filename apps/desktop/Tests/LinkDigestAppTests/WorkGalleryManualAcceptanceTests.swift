import Foundation
import XCTest
@testable import LinkDigestApp

/// The interactive fixture is hosted by the opt-in, isolated App, not xctest:
/// the desktop tooling cannot activate the unbundled xctest executable.
@MainActor
final class WorkGalleryManualAcceptanceTests: XCTestCase {
  func testFixtureExercisesAllSortOrdersWithoutReorderingCandidatesOrChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-gallery-fixture-\(UUID())")
    let model = WorkGalleryAcceptanceFixture.makeModel(root: root)
    let ids = WorkGalleryAcceptanceFixture.ids
    model.toggleSelection(ids[0]); model.toggleSelection(ids[1])
    let expected: [WorkSortOrder: [String]] = [
      .original: ids,
      .mostLiked: [ids[2], ids[3], ids[1], ids[0]],
      .leastLiked: [ids[1], ids[3], ids[2], ids[0]],
      .newest: [ids[3], ids[1], ids[2], ids[0]],
      .oldest: [ids[2], ids[1], ids[3], ids[0]]
    ]
    for order in WorkSortOrder.allCases {
      let sorted = order.sorted(model.candidates, likes: { $0.likes }, published: { $0.publishedText })
      XCTAssertEqual(sorted.map(\.workID), expected[order])
      XCTAssertEqual(model.candidates.map(\.workID), ids)
      XCTAssertEqual(model.selectedIDs, [ids[0], ids[1]])
    }
  }
}
