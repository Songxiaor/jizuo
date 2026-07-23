import XCTest
@testable import LinkDigestCore

final class CaptureMediaContractTests: XCTestCase {
  func testV2DirectMediaRequiresHTTPSPlaybackURLAndMapsOnlyToTransientDescriptor() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("contracts/fixtures")
    let valid = try Data(contentsOf: root.appendingPathComponent("v2-direct-file.json"))
    let invalid = try Data(contentsOf: root.appendingPathComponent("v2-invalid-direct-without-url.json"))
    let envelope = try CaptureEnvelopeV2Validator.decode(valid, schemaLocator: CaptureWireContractSchema.testLocator())
    XCTAssertEqual(envelope.media.kind, .directFile)
    XCTAssertNoThrow(try CaptureEnvelopeV2Validator.validate(envelope, schemaLocator: CaptureWireContractSchema.testLocator()))
    XCTAssertThrowsError(try CaptureEnvelopeV2Validator.decode(invalid, schemaLocator: CaptureWireContractSchema.testLocator()))

    let document = CapturedDocument(wire: envelope)
    XCTAssertNil(document.media, "V2 must never enter the legacy permanent-download seam")
    XCTAssertFalse(String(reflecting: document).contains("fixture=redacted"))

    var directWithFailure = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    var directMedia = directWithFailure["media"] as! [String: Any]
    directMedia["failureReason"] = "unknown"
    directWithFailure["media"] = directMedia
    XCTAssertThrowsError(try CaptureEnvelopeV2Validator.decode(
      JSONSerialization.data(withJSONObject: directWithFailure),
      schemaLocator: CaptureWireContractSchema.testLocator()
    ))

    var browserOnlyWithURL = try JSONSerialization.jsonObject(with: Data(
      contentsOf: root.appendingPathComponent("v2-blob-mse.json")
    )) as! [String: Any]
    var browserOnlyMedia = browserOnlyWithURL["media"] as! [String: Any]
    browserOnlyMedia["ephemeralPlaybackURL"] = "https://media.example.test/forbidden.mp4"
    browserOnlyWithURL["media"] = browserOnlyMedia
    XCTAssertThrowsError(try CaptureEnvelopeV2Validator.decode(
      JSONSerialization.data(withJSONObject: browserOnlyWithURL),
      schemaLocator: CaptureWireContractSchema.testLocator()
    ))
  }

  func testV2BlobAndAmbiguousFixturesCarryStableFailureReasonsWithoutPlaybackURL() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("contracts/fixtures")
    for (file, reason) in [
      ("v2-blob-mse.json", MediaFailureReason.blobOrMSE),
      ("v2-multi-video-ambiguous.json", MediaFailureReason.multipleCandidates),
    ] {
      let envelope = try CaptureEnvelopeV2Validator.decode(
        Data(contentsOf: root.appendingPathComponent(file)),
        schemaLocator: CaptureWireContractSchema.testLocator()
      )
      XCTAssertNil(envelope.media.ephemeralPlaybackURL)
      XCTAssertEqual(envelope.media.failureReason, reason)
    }
  }

  func testV2ProvenanceUsesSafeDigestAndExcludesTransientMediaFields() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("contracts/fixtures/v2-direct-file.json")
    let first = try CaptureEnvelopeV2Validator.decode(
      Data(contentsOf: root),
      schemaLocator: CaptureWireContractSchema.testLocator()
    )
    let second = CaptureEnvelopeV2(
      requestId: "transport-retry-request",
      createdAt: first.createdAt,
      idempotencyKey: "transport-retry-delivery",
      source: first.source,
      capture: first.capture,
      evidence: first.evidence,
      media: .init(
        kind: first.media.kind,
        pageURL: first.media.pageURL,
        canonicalURL: first.media.canonicalURL,
        platform: first.media.platform,
        ephemeralPlaybackURL: "https://different.example.test/secret-signed-url.mp4",
        mimeType: first.media.mimeType,
        posterURL: first.media.posterURL,
        durationSeconds: first.media.durationSeconds,
        author: first.media.author,
        expiresAt: "2026-07-20T00:01:00Z",
        transcriptionCapability: first.media.transcriptionCapability,
        failureReason: first.media.failureReason,
        candidateCount: first.media.candidateCount,
        selectionReason: first.media.selectionReason,
        playbackState: first.media.playbackState
      )
    )
    let firstCommand = try AcceptCaptureCommand(envelope: first, receivedAtMilliseconds: 1)
    let secondCommand = try AcceptCaptureCommand(envelope: second, receivedAtMilliseconds: 2)
    XCTAssertEqual(firstCommand.provenance.semanticPayloadSHA256, secondCommand.provenance.semanticPayloadSHA256)
    XCTAssertEqual(firstCommand.provenance.semanticPayloadSHA256, "3d57b6ee5ac224a68d6cb964d9face860f31dde33ae6536af898e26d8a2474cd")
    XCTAssertEqual(firstCommand.provenance.captureContractVersion, 2)
    XCTAssertTrue(firstCommand.provenance.deliveryKey.hasPrefix("capture:v2:"))
    XCTAssertEqual(CaptureDeliveryIdentity.key(for: first), firstCommand.provenance.deliveryKey)
    XCTAssertFalse(String(reflecting: firstCommand).contains(first.media.ephemeralPlaybackURL ?? "missing"))
    XCTAssertFalse(String(reflecting: firstCommand).contains(first.media.posterURL ?? "missing"))
    XCTAssertFalse(String(reflecting: firstCommand).contains(first.media.expiresAt ?? "missing"))
    XCTAssertFalse(String(reflecting: firstCommand).contains("MediaDescriptor"))

    let sessionEvidence = CaptureEnvelopeV2(
      requestId: "session-evidence",
      createdAt: first.createdAt,
      source: first.source,
      capture: first.capture,
      evidence: .init(
        sourceLabel: "Current page DOM + same-origin session detail",
        usedCookie: true
      ),
      media: second.media
    )
    let sessionURLVariant = CaptureEnvelopeV2(
      requestId: "session-evidence-url-variant",
      createdAt: first.createdAt,
      source: first.source,
      capture: first.capture,
      evidence: sessionEvidence.evidence,
      media: .init(
        kind: second.media.kind,
        pageURL: second.media.pageURL,
        canonicalURL: second.media.canonicalURL,
        platform: second.media.platform,
        ephemeralPlaybackURL: "https://another.example.test/temporary.mp4",
        mimeType: second.media.mimeType,
        posterURL: second.media.posterURL,
        durationSeconds: second.media.durationSeconds,
        author: second.media.author,
        transcriptionCapability: second.media.transcriptionCapability,
        candidateCount: second.media.candidateCount,
        selectionReason: second.media.selectionReason,
        playbackState: second.media.playbackState
      )
    )
    let fingerprinter = SHA256CaptureFingerprinter()
    XCTAssertNotEqual(
      fingerprinter.semanticPayloadSHA256(first),
      fingerprinter.semanticPayloadSHA256(sessionEvidence)
    )
    XCTAssertEqual(
      fingerprinter.semanticPayloadSHA256(sessionEvidence),
      fingerprinter.semanticPayloadSHA256(sessionURLVariant)
    )
  }

  func testEnvelopeWithoutMediaStillValidates() throws {
    let value = CaptureEnvelopeV1(
      version: 1,
      requestId: "no-media",
      createdAt: "2026-07-19T12:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test/a", title: "A", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "plain text body", characterCount: 15, completeness: "full_article", capturedAt: "2026-07-19T12:00:00Z"),
      evidence: .init(sourceLabel: "test", usedCookie: false),
      media: nil
    )
    XCTAssertNoThrow(try CaptureValidator.validate(value, schemaLocator: CaptureWireContractSchema.testLocator()))
  }

  func testEnvelopeWithMediaValidatesAndMapsToDocument() throws {
    let value = CaptureEnvelopeV1(
      version: 1,
      requestId: "with-media",
      createdAt: "2026-07-19T12:00:00Z",
      source: .init(kind: "browser_capture", url: "https://www.douyin.com/video/1", title: "Clip", platform: "douyin"),
      capture: .init(method: "rendered_dom", text: "douyin body text", characterCount: 16, completeness: "full_article", capturedAt: "2026-07-19T12:00:00Z"),
      evidence: .init(sourceLabel: "Current page DOM", usedCookie: false),
      media: .init(
        platform: "douyin",
        videoURL: "https://cdn.example.test/v.mp4",
        coverURL: "https://cdn.example.test/c.jpg",
        durationSeconds: 9,
        author: "author"
      )
    )
    XCTAssertNoThrow(try CaptureValidator.validate(value, schemaLocator: CaptureWireContractSchema.testLocator()))
    let document = CapturedDocument(wire: value)
    XCTAssertEqual(document.media?.platform, "douyin")
    XCTAssertEqual(document.media?.videoURL, "https://cdn.example.test/v.mp4")
    XCTAssertEqual(document.media?.author, "author")
  }

  func testSharedMediaFixtureIsValid() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("contracts/fixtures")
    let fixtureURL = root.appendingPathComponent("valid-with-media.json")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
      throw XCTSkip("contracts fixtures unavailable in this layout")
    }
    let data = try Data(contentsOf: fixtureURL)
    XCTAssertNoThrow(try CaptureValidator.decode(data, schemaLocator: CaptureWireContractSchema.testLocator()))
  }

  func testWireFingerprintIgnoresMediaForFrozenAlgorithm() throws {
    let base = CaptureEnvelopeV1(
      version: 1,
      requestId: "fp",
      createdAt: "2026-07-19T12:00:00Z",
      source: .init(kind: "browser_capture", url: "https://example.test", title: "t", platform: "generic"),
      capture: .init(method: "rendered_dom", text: "body", characterCount: 4, completeness: "full_article", capturedAt: "2026-07-19T12:00:00Z"),
      evidence: .init(sourceLabel: "test", usedCookie: false)
    )
    let withMedia = CaptureEnvelopeV1(
      version: base.version,
      requestId: base.requestId,
      createdAt: base.createdAt,
      source: base.source,
      capture: base.capture,
      evidence: base.evidence,
      media: .init(platform: "douyin", videoURL: "https://cdn.example.test/a.mp4")
    )
    let fingerprinter = SHA256CaptureFingerprinter()
    // Frozen browser-wire v1 algorithm must not change when optional media is present.
    XCTAssertEqual(
      fingerprinter.semanticPayloadSHA256(base),
      fingerprinter.semanticPayloadSHA256(withMedia)
    )
  }
}
