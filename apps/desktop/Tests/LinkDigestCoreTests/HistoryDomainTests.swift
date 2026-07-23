import XCTest
@testable import LinkDigestCore

final class HistoryDomainTests: XCTestCase {
  func testPlatformSynonymNormalizedNamesCoverLegacyAutomaticTags() {
    let names = HistoryTagNormalizer.platformSynonymNormalizedNames
    for legacy in ["公众号", "X", "GitHub", "抖音"] {
      let normalized = HistoryTagNormalizer.normalized(legacy)?.normalizedName
      XCTAssertNotNil(normalized)
      XCTAssertTrue(names.contains(normalized ?? ""))
    }
    XCTAssertFalse(names.contains("swift"))
  }

  func testTagNormalizationAndAutomaticFirstLineLimit() {
    XCTAssertNil(HistoryTag(rawValue: "   "))
    XCTAssertNil(HistoryTag(rawValue: String(repeating: "长", count: 21)))
    XCTAssertEqual(HistoryTag(rawValue: "  Swift ")?.normalizedName, "swift")
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "甲, 乙, 甲, 丙, 丁, 戊\n第 2 行不解析").map(\.name),
      ["甲", "乙", "丙", "丁", "戊"]
    )
    // Chinese comma / bullet formats that models often emit.
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "微信，验证，本地").map(\.name),
      ["微信", "验证", "本地"]
    )
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "- 产品\n- 设计\n- 工程").map(\.name),
      ["产品", "设计", "工程"]
    )
    XCTAssertEqual(
      HistoryTagNormalizer.fallbackTags(from: "该页面是微信公众平台的验证页面，提示环境异常。").map(\.name),
      ["微信", "需验证"]
    )
  }

  func testBrowserWireV1FingerprintGoldenHashAndManualNamespaceStaySeparate() {
    let envelope = fixture(requestID: "golden", idempotencyKey: "delivery-golden")
    let fingerprinter = SHA256CaptureFingerprinter()
    XCTAssertEqual(
      fingerprinter.semanticPayloadSHA256(envelope),
      "21cdaa40987a1f9cce2b26136a84ddd9583b29d15fd11f6f2ae16a9e497144c0"
    )
    let manual = CapturedDocument(
      requestID: envelope.requestId, createdAt: envelope.createdAt,
      idempotencyKey: envelope.idempotencyKey, origin: .manualLink,
      url: envelope.source.url, title: envelope.source.title, platform: "manual",
      method: "public_html", text: envelope.capture.text,
      completeness: "best_effort", capturedAt: envelope.capture.capturedAt,
      sourceLabel: "manual fixture"
    )
    XCTAssertTrue(CaptureDeliveryIdentity.key(for: envelope).hasPrefix("capture:v1:"))
    XCTAssertTrue(CaptureDeliveryIdentity.key(for: manual).hasPrefix("manual:v1:"))
    XCTAssertNotEqual(fingerprinter.semanticPayloadSHA256(envelope), fingerprinter.semanticPayloadSHA256(manual))
  }
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
    XCTAssertEqual(RunUsageCost(inputTokens: nil, outputTokens: 2, totalTokens: nil, costAmountMicros: 1234, costCurrencyCode: "USD").costAmountMicros, 1234)
    XCTAssertEqual(RunUsageCost(costAmountMicros: 1, costCurrencyCode: nil), .unknown)
    XCTAssertEqual(RunUsageCost(costAmountMicros: 1, costCurrencyCode: "usd"), .unknown)
    XCTAssertThrowsError(try RunUsageCost.validated(inputTokens: nil, outputTokens: 2, totalTokens: nil, costAmountMicros: 1, costCurrencyCode: nil))
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
