import XCTest
@testable import LinkDigestCore

final class HistoryDomainTests: XCTestCase {
  func testCanonicalURLV1IsConservativeAndDeterministic() throws {
    XCTAssertEqual(try CanonicalURL("HTTPS://Example.COM:443").value, "https://example.com/")
    XCTAssertEqual(try CanonicalURL("http://EXAMPLE.com:80/path?q=2&q=1#fragment").value, "http://example.com/path?q=2&q=1")
    XCTAssertEqual(try CanonicalURL("https://example.com/a?utm_source=x&b=2").value, "https://example.com/a?utm_source=x&b=2")
    XCTAssertNotEqual(try CanonicalURL("https://example.com/a?b=2&a=1").value, try CanonicalURL("https://example.com/a?a=1&b=2").value)
    XCTAssertEqual(try CanonicalURL("https://example.com:444/path").value, "https://example.com:444/path")
    XCTAssertThrowsError(try CanonicalURL("file:///tmp/private"))
  }

  func testCaptureFingerprintsIncludeNULAndExcludeTransportIdentity() {
    let fingerprinter = SHA256CaptureFingerprinter()
    XCTAssertEqual(fingerprinter.bodySHA256("a\0b"), "59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138")
    let first = fixture(requestID: "request-one", idempotencyKey: "delivery-one")
    let retry = fixture(requestID: "request-two", idempotencyKey: "delivery-two")
    XCTAssertEqual(fingerprinter.semanticPayloadSHA256(first), fingerprinter.semanticPayloadSHA256(retry))
    let changed = CaptureEnvelopeV1(version: 1, requestId: "request-two", createdAt: first.createdAt, idempotencyKey: "delivery-two", source: first.source, capture: .init(method: first.capture.method, text: "a\0c", characterCount: 3, completeness: first.capture.completeness, capturedAt: first.capture.capturedAt), evidence: first.evidence)
    let titleChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: .init(kind: first.source.kind, url: first.source.url, title: "Changed title", platform: first.source.platform), capture: first.capture, evidence: first.evidence)
    let sourceChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: .init(kind: first.source.kind, url: "https://example.test/other", title: first.source.title, platform: first.source.platform), capture: first.capture, evidence: first.evidence)
    let capturedAtChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: first.source, capture: .init(method: first.capture.method, text: first.capture.text, characterCount: first.capture.characterCount, completeness: first.capture.completeness, capturedAt: "2026-07-15T04:00:01Z"), evidence: first.evidence)
    for semanticChange in [changed, titleChanged, sourceChanged, capturedAtChanged] {
      XCTAssertNotEqual(fingerprinter.semanticPayloadSHA256(first), fingerprinter.semanticPayloadSHA256(semanticChange))
    }
  }

  func testRunStateMachineAndUsageCostExactness() throws {
    XCTAssertTrue(RunStatus.queued.canTransition(to: .running))
    XCTAssertTrue(RunStatus.queued.canTransition(to: .stopped))
    XCTAssertTrue(RunStatus.running.canTransition(to: .completed))
    XCTAssertFalse(RunStatus.completed.canTransition(to: .running))
    XCTAssertEqual(try RunUsageCost(inputTokens: nil, outputTokens: 2, totalTokens: nil, costAmountMicros: 1234, costCurrencyCode: "USD").costAmountMicros, 1234)
    XCTAssertThrowsError(try RunUsageCost(costAmountMicros: 1, costCurrencyCode: nil))
    XCTAssertThrowsError(try RunUsageCost(costAmountMicros: 1, costCurrencyCode: "usd"))
  }

  func testTypedIDsRequireLowercaseCanonicalUUID() {
    let id = TaskID()
    XCTAssertEqual(TaskID(id.rawValue), id)
    XCTAssertNil(TaskID(id.rawValue.uppercased()))
    XCTAssertNil(TaskID("not-a-uuid"))
  }

  private func fixture(requestID: String, idempotencyKey: String?) -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(version: 1, requestId: requestID, createdAt: "2026-07-15T04:00:00Z", idempotencyKey: idempotencyKey, source: .init(kind: "browser_capture", url: "https://example.test/path?b=2&a=1", title: "Fixture", platform: "generic"), capture: .init(method: "rendered_dom", text: "a\0b", characterCount: 3, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"), evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false))
  }
}
