import XCTest
@testable import LinkDigestApp

final class CaptureOutcomeStoreTests: XCTestCase {
  func testRoundTripsSuccessAndFailureCountsWithoutWritingSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureOutcomeStore(applicationSupportRoot: root)

    store.recordSuccess(platform: "x")
    store.recordSuccess(platform: "x")
    store.recordFailure(platform: "x", code: "CAPTURE_CONTENT_EMPTY")
    store.recordFailure(platform: "https://example.com/item?token=abcd", code: "CAPTURE_SCHEMA_INVALID")

    let snap = store.snapshot()
    XCTAssertEqual(snap.platforms["x"]?.succeeded, 2)
    XCTAssertEqual(snap.platforms["x"]?.failed["CAPTURE_CONTENT_EMPTY"], 1)
    XCTAssertNil(snap.platforms["https://example.com/item?token=abcd"])

    let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
    XCTAssertFalse(text.contains("https://"))
    XCTAssertFalse(text.contains("token=abcd"))
    XCTAssertTrue(text.contains("CAPTURE_CONTENT_EMPTY"))
  }

  func testSharedStoreIsDisabledUnderXCTest() {
    XCTAssertNil(CaptureOutcomeStore.shared)
  }
}
