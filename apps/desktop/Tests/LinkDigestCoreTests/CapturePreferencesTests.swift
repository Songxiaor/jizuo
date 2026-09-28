import XCTest
@testable import LinkDigestCore

final class CapturePreferencesTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/private/tmp/linkdigest-capture-prefs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testMissingFileFallsBackToDefault() {
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 20)
  }

  func testSavedLimitIsReadBackAndClamped() throws {
    let store = CapturePreferencesStore(root: root)
    try store.setCommentLimit(60)
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 60)
    try store.setCommentLimit(500)
    XCTAssertEqual(store.commentLimit, 100)
    try store.setCommentLimit(1)
    XCTAssertEqual(store.commentLimit, 10)
  }

  func testCorruptFileFallsBackToDefault() throws {
    let url = root.appendingPathComponent("Library/Application Support/LinkDigest/capture-preferences-v1.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("oops".utf8).write(to: url)
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 20)
  }

  func testRequestDecodingClaimsOnlyItsOwnKind() throws {
    XCTAssertNil(try CapturePreferencesRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r"}"#.utf8)))
    XCTAssertNil(try CapturePreferencesRequest.decode(Data("not json".utf8)))
    let request = try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":1,"requestId":"r-1"}"#.utf8))
    XCTAssertEqual(request?.requestId, "r-1")
    XCTAssertThrowsError(try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":2,"requestId":"r"}"#.utf8)))
    XCTAssertThrowsError(try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":1}"#.utf8)))
  }

  func testResponseRoundTripsAndIsNotADelivery() throws {
    let response = NativeResponse.capturePreferences(version: 1, requestId: "r-1", commentLimit: 30)
    let encoded = try JSONEncoder().encode(response)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "capturePreferences")
    XCTAssertEqual(object["commentLimit"] as? Int, 30)
    XCTAssertEqual(try JSONDecoder().decode(NativeResponse.self, from: encoded), response)
    XCTAssertFalse(response.isSuccessfulBrowserDelivery)
  }
}
