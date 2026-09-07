import XCTest
@testable import LinkDigestCore

final class XProfileCandidatesTests: XCTestCase {
  private func data(_ json: String) -> Data { Data(json.utf8) }

  private func validRequestJSON(
    author: String = "sample_author",
    items: String = #"[{"id":"1234567890123","url":"https://x.com/sample_author/status/1234567890123","previewText":"Hello"}]"#
  ) -> String {
    """
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://x.com/\(author)","authorID":"\(author)","items":\(items)}
    """
  }

  func testVersionRejectsBooleanFractionAndString() {
    for version in ["true", "1.5", "\"1\""] {
      XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data(
        validRequestJSON().replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)"))))
    }
  }

  func testNonProfileMessagesAreNotClaimed() throws {
    XCTAssertNil(try XProfileCandidatesRequest.decode(data(#"{"version":1,"kind":"xBookmarks"}"#)))
    XCTAssertNil(try XProfileCandidatesRequest.decode(data(#"{"version":1,"kind":"capture"}"#)))
    XCTAssertNil(try XProfileCandidatesRequest.decode(data(#"{"version":1}"#)))
  }

  func testValidRequestCanonicalizesTwitterHostAndKeepsAuthorPosts() throws {
    let request = try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://twitter.com/Sample_Author",
     "authorID":"Sample_Author",
     "profileName":"Sample",
     "items":[{"id":"1234567890123","url":"https://twitter.com/Sample_Author/status/1234567890123","previewText":"Hello"}]}
    """))
    let unwrapped = try XCTUnwrap(request)
    XCTAssertEqual(unwrapped.profileURL, "https://x.com/sample_author")
    XCTAssertEqual(unwrapped.authorID, "sample_author")
    XCTAssertEqual(unwrapped.items.map(\.url), ["https://x.com/sample_author/status/1234567890123"])
    XCTAssertNil(unwrapped.profileAvatarURL)
  }

  func testOptionalAvatarURLAdmitsPublicTwimgProfileAndRejectsMediaOrChrome() throws {
    let avatar = "https://pbs.twimg.com/profile_images/1/owner.jpg"
    let request = try XCTUnwrap(try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://x.com/sample_author","authorID":"sample_author",
     "profileName":"夹具作者","profileAvatarURL":"\(avatar)",
     "items":[{"id":"1234567890123","url":"https://x.com/sample_author/status/1234567890123"}]}
    """)))
    XCTAssertEqual(request.profileAvatarURL, avatar)
    XCTAssertEqual(XProfileCandidatesRequest.admittedAvatarURL(avatar), avatar)
    XCTAssertNil(try XProfileCandidatesRequest.decode(data(validRequestJSON()))?.profileAvatarURL)

    XCTAssertNil(XProfileCandidatesRequest.admittedAvatarURL("https://pbs.twimg.com/media/tweet.jpg"))
    XCTAssertNil(XProfileCandidatesRequest.admittedAvatarURL("https://abs.twimg.com/sticky/default_profile.png"))
    XCTAssertNil(XProfileCandidatesRequest.admittedAvatarURL("https://example.test/profile_images/x.jpg"))
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://x.com/sample_author","authorID":"sample_author",
     "profileAvatarURL":"https://pbs.twimg.com/media/tweet.jpg",
     "items":[{"id":"1234567890123","url":"https://x.com/sample_author/status/1234567890123"}]}
    """))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }
  }

  func testRejectsCookieTokenAndDOMFields() {
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://x.com/sample_author","authorID":"sample_author",
     "cookie":"auth_token=secret",
     "items":[{"id":"1234567890123","url":"https://x.com/sample_author/status/1234567890123"}]}
    """))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }
  }

  func testRejectsMismatchedAuthorQuotedPostAndReservedHome() {
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://x.com/sample_author","authorID":"sample_author",
     "items":[{"id":"1234567890123","url":"https://x.com/other/status/1234567890123"}]}
    """))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_URL_UNSUPPORTED) }

    XCTAssertNil(XProfileCandidatesRequest.canonicalProfileURL("https://x.com/home"))
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data(validRequestJSON(author: "home")))) {
      XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID)
    }
  }

  func testRejectsCredentialedURLPortAndOversize() {
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data("""
    {"kind":"xProfileCandidates","version":1,"requestId":"req-1",
     "profileURL":"https://name:pass@x.com/sample_author","authorID":"sample_author",
     "items":[{"id":"1234567890123","url":"https://x.com/sample_author/status/1234567890123"}]}
    """))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID) }

    let flood = (0..<101).map { #"{"id":"\#(1_000_000_000 + $0)","url":"https://x.com/sample_author/status/\#(1_000_000_000 + $0)"}"# }.joined(separator: ",")
    XCTAssertThrowsError(try XProfileCandidatesRequest.decode(data(validRequestJSON(items: "[\(flood)]")))) {
      XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID)
    }
  }

  func testAckDecodesPresentedAndRejectsBookmarksAccepted() throws {
    let ack = try XProfileCandidatesPresented.decode([
      "kind": "profileCandidatesPresented",
      "version": 1,
      "requestId": "req-1",
      "acceptedCount": 2,
    ] as [String: Any])
    XCTAssertEqual(ack.acceptedCount, 2)

    XCTAssertThrowsError(try XProfileCandidatesPresented.decode([
      "kind": "bookmarksAccepted",
      "version": 1,
      "requestId": "req-1",
      "queuedCount": 2,
      "skippedCount": 0,
    ] as [String: Any]))
  }

  func testPresentedAckIsSuccessfulDeliveryAndErrorIsNot() throws {
    XCTAssertEqual(
      NativeResponse.profileCandidatesPresented(version: 1, requestId: "req-1", acceptedCount: 2).isSuccessfulBrowserDelivery,
      true
    )
    XCTAssertEqual(
      NativeResponse.error(
        AppError(
          version: 1,
          requestId: "req-1",
          createdAt: "2026-09-07T00:00:00Z",
          category: "protocol",
          code: "CAPTURE_SCHEMA_INVALID",
          retryable: false,
          action: "upgrade_app",
          safeDetail: nil
        )
      ).isSuccessfulBrowserDelivery,
      false
    )
  }

  func testNativeResponseRoundTripDoesNotPretendBookmarksSuccess() throws {
    let encoded = try JSONEncoder().encode(
      NativeResponse.profileCandidatesPresented(version: 1, requestId: "req-1", acceptedCount: 3)
    )
    let decoded = try JSONDecoder().decode(NativeResponse.self, from: encoded)
    XCTAssertEqual(decoded, .profileCandidatesPresented(version: 1, requestId: "req-1", acceptedCount: 3))
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    XCTAssertEqual(object?["kind"] as? String, "profileCandidatesPresented")
    XCTAssertNil(object?["queuedCount"])
  }
}
