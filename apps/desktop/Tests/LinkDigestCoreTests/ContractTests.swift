import XCTest
@testable import LinkDigestCore

final class ContractTests: XCTestCase {
  func testSemanticValidator() throws {
    let value = CaptureEnvelopeV1(version: 1, requestId: "fixture", createdAt: "2026-07-13T20:00:00Z", source: .init(kind: "browser_capture", url: "https://example.test", title: "Fixture", platform: "generic"), capture: .init(method: "rendered_dom", text: "😀ok", characterCount: 3, completeness: "full_article", capturedAt: "2026-07-13T20:00:00Z"), evidence: .init(sourceLabel: "test", usedCookie: false))
    XCTAssertNoThrow(try CaptureValidator.validate(value))
    XCTAssertThrowsError(try CaptureValidator.validate(.init(version: 1, requestId: "bad", createdAt: value.createdAt, source: .init(kind: "browser_capture", url: "file:///tmp/x", title: nil, platform: "generic"), capture: value.capture, evidence: value.evidence))) { XCTAssertEqual($0 as? CaptureValidationError, .CAPTURE_URL_UNSUPPORTED) }
  }
  func testSharedFixtures() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/fixtures")
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-manifest.json").path) else { throw XCTSkip("build-dev.sh copies contracts before test") }
    let schema = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent("capture-envelope-v1.schema.json"), encoding: .utf8)
    XCTAssertTrue(schema.contains("https://json-schema.org/draft/2020-12/schema"))
    let results = try FixtureRunner.run(directory: root); XCTAssertTrue(results.allSatisfy { $0.1 })
  }

  func testSwiftExecutesSchemaRulesBeyondSemanticInvariants() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/fixtures/valid.json")
    let valid = try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as! [String: Any]
    var invalidValues: [[String: Any]] = []

    var cookie = valid
    var cookieEvidence = cookie["evidence"] as! [String: Any]
    cookieEvidence["usedCookie"] = true
    cookie["evidence"] = cookieEvidence
    invalidValues.append(cookie)

    var kind = valid
    var kindSource = kind["source"] as! [String: Any]
    kindSource["kind"] = "unknown_capture"
    kind["source"] = kindSource
    invalidValues.append(kind)

    var date = valid
    date["createdAt"] = "not-a-date"
    invalidValues.append(date)

    var request = valid
    request["requestId"] = ""
    invalidValues.append(request)

    for invalid in invalidValues {
      let data = try JSONSerialization.data(withJSONObject: invalid)
      XCTAssertThrowsError(try CaptureValidator.decode(data)) { error in
        XCTAssertEqual(error as? CaptureValidationError, .CAPTURE_SCHEMA_INVALID)
      }
    }
  }

  func testTwentyUniqueMessagesAndDuplicateAreIdempotent() async {
    let inbox = CaptureInbox()
    for index in 0..<20 {
      let value = CaptureEnvelopeV1(version: 1, requestId: "request-\(index)", createdAt: "2026-07-13T20:00:00Z", idempotencyKey: "capture-\(index)", source: .init(kind: "browser_capture", url: "https://example.test/article", title: "Fixture", platform: "generic"), capture: .init(method: "rendered_dom", text: "x", characterCount: 1, completeness: "full_article", capturedAt: "2026-07-13T20:00:00Z"), evidence: .init(sourceLabel: "test", usedCookie: false))
      let accepted = await inbox.accept(value)
      XCTAssertTrue(accepted)
    }
    let duplicate = CaptureEnvelopeV1(version: 1, requestId: "request-retry", createdAt: "2026-07-13T20:00:00Z", idempotencyKey: "capture-0", source: .init(kind: "browser_capture", url: "https://example.test/article", title: "Fixture", platform: "generic"), capture: .init(method: "rendered_dom", text: "x", characterCount: 1, completeness: "full_article", capturedAt: "2026-07-13T20:00:00Z"), evidence: .init(sourceLabel: "test", usedCookie: false))
    let duplicateAccepted = await inbox.accept(duplicate)
    let acceptedCount = await inbox.acceptedCount
    XCTAssertFalse(duplicateAccepted)
    XCTAssertEqual(acceptedCount, 20)
  }
}
