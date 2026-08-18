import XCTest
@testable import LinkDigestCore

final class OpenAppRequestTests: XCTestCase {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  func testNonOpenAppMessagesAreNotClaimed() throws {
    XCTAssertNil(try OpenAppRequest.decode(data(#"{"version":1,"kind":"xBookmarks"}"#)))
    XCTAssertNil(try OpenAppRequest.decode(data(#"{"version":1}"#)))
    XCTAssertNil(try OpenAppRequest.decode(data("not json")))
  }

  func testValidRequestKeepsRequestId() throws {
    let request = try OpenAppRequest.decode(data(
      #"{"kind":"openApp","version":1,"requestId":"req-open-1"}"#
    ))
    XCTAssertEqual(try XCTUnwrap(request).requestId, "req-open-1")
  }

  func testRejectsBadVersionAndEmptyRequestId() {
    XCTAssertThrowsError(try OpenAppRequest.decode(data(
      #"{"kind":"openApp","version":2,"requestId":"r"}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .PROTOCOL_VERSION_UNSUPPORTED) }

    XCTAssertThrowsError(try OpenAppRequest.decode(data(
      #"{"kind":"openApp","version":1,"requestId":""}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }
  }
}
