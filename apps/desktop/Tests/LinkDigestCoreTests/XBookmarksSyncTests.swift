import XCTest
@testable import LinkDigestCore

final class XBookmarksSyncTests: XCTestCase {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  func testNonBookmarkMessagesAreNotClaimed() throws {
    // capture envelope 与其它消息返回 nil，让调用方继续按原路解析。
    XCTAssertNil(try XBookmarksSyncRequest.decode(data(#"{"version":1,"kind":"capture"}"#)))
    XCTAssertNil(try XBookmarksSyncRequest.decode(data(#"{"version":1}"#)))
    XCTAssertNil(try XBookmarksSyncRequest.decode(data("not json".debugDescription)))
  }

  func testValidRequestDeduplicatesWhileKeepingOrder() throws {
    let request = try XBookmarksSyncRequest.decode(data(#"""
    {"kind":"xBookmarks","version":1,"requestId":"req-1",
     "tweetIDs":["2080312096865271866","1234567890123","2080312096865271866"]}
    """#))
    let unwrapped = try XCTUnwrap(request)
    XCTAssertEqual(unwrapped.requestId, "req-1")
    // 滚动时同一条会被重复采到；去重但保持首次出现的顺序。
    XCTAssertEqual(unwrapped.tweetIDs, ["2080312096865271866", "1234567890123"])
  }

  func testRejectsBadVersionEmptyAndOversizedAndNonNumericIDs() {
    // 是这种消息但不合法 → 抛错（区别于 nil）。
    XCTAssertThrowsError(try XBookmarksSyncRequest.decode(data(
      #"{"kind":"xBookmarks","version":2,"requestId":"r","tweetIDs":["1234567890123"]}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .PROTOCOL_VERSION_UNSUPPORTED) }

    XCTAssertThrowsError(try XBookmarksSyncRequest.decode(data(
      #"{"kind":"xBookmarks","version":1,"requestId":"r","tweetIDs":[]}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_CONTENT_EMPTY) }

    XCTAssertThrowsError(try XBookmarksSyncRequest.decode(data(
      #"{"kind":"xBookmarks","version":1,"requestId":"r","tweetIDs":["not-a-number"]}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }

    let flood = (0..<(XBookmarksSyncRequest.maximumIDs + 1)).map { "\(1_000_000_000 + $0)" }
    let floodJSON = "{\"kind\":\"xBookmarks\",\"version\":1,\"requestId\":\"r\",\"tweetIDs\":[\(flood.map { "\"\($0)\"" }.joined(separator: ","))]}"
    XCTAssertThrowsError(try XBookmarksSyncRequest.decode(data(floodJSON))) {
      XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_PAYLOAD_TOO_LARGE)
    }
  }

  func testLookupAllowsEmptyAndDeduplicates() throws {
    XCTAssertNil(try XBookmarksLookupRequest.decode(data(#"{"version":1,"kind":"xBookmarks"}"#)))

    let empty = try XCTUnwrap(try XBookmarksLookupRequest.decode(data(
      #"{"kind":"xBookmarksLookup","version":1,"requestId":"look-1","tweetIDs":[]}"#
    )))
    XCTAssertEqual(empty.requestId, "look-1")
    XCTAssertEqual(empty.tweetIDs, [])

    let request = try XCTUnwrap(try XBookmarksLookupRequest.decode(data(#"""
    {"kind":"xBookmarksLookup","version":1,"requestId":"look-2",
     "tweetIDs":["2080312096865271866","1234567890123","2080312096865271866"]}
    """#)))
    XCTAssertEqual(request.tweetIDs, ["2080312096865271866", "1234567890123"])
  }

  func testLookupRejectsBadPayload() {
    XCTAssertThrowsError(try XBookmarksLookupRequest.decode(data(
      #"{"kind":"xBookmarksLookup","version":2,"requestId":"r","tweetIDs":[]}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .PROTOCOL_VERSION_UNSUPPORTED) }

    XCTAssertThrowsError(try XBookmarksLookupRequest.decode(data(
      #"{"kind":"xBookmarksLookup","version":1,"requestId":"r","tweetIDs":["abc"]}"#
    ))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }
  }

  func testNativeResponseRoundTripsBookmarksLookup() throws {
    let response = NativeResponse.bookmarksLookup(
      version: 1,
      requestId: "look-1",
      existingIDs: ["1234567890123", "2080312096865271866"]
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(NativeResponse.self, from: encoded)
    XCTAssertEqual(decoded, response)
  }
}
