import CryptoKit
import Foundation

public protocol CaptureFingerprinting: Sendable {
  func bodySHA256(_ body: String) -> String
  func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV1) -> String
  func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV2) -> String
  func semanticPayloadSHA256(_ document: CapturedDocument) -> String
}

public struct SHA256CaptureFingerprinter: CaptureFingerprinting {
  public init() {}

  public func bodySHA256(_ body: String) -> String { digest(Data(body.utf8)) }

  public func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV1) -> String {
    // Frozen browser-wire v1 algorithm. Existing capture_deliveries rows were
    // written with this exact namespace and field order; do not route browser
    // replay through the internal domain representation.
    var encoder = LengthPrefixedUTF8Encoder()
    encoder.append("linkdigest:capture-payload:v1")
    encoder.append(Int64(envelope.version))
    encoder.append(envelope.createdAt)
    encoder.append(envelope.source.kind)
    encoder.append(envelope.source.url)
    encoder.appendOptional(envelope.source.title)
    encoder.append(envelope.source.platform)
    encoder.append(envelope.capture.method)
    encoder.append(envelope.capture.text)
    encoder.append(Int64(envelope.capture.characterCount))
    encoder.append(envelope.capture.completeness)
    encoder.append(envelope.capture.capturedAt)
    encoder.append(envelope.evidence.sourceLabel)
    encoder.append(envelope.evidence.usedCookie)
    return digest(encoder.data)
  }

  public func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV2) -> String {
    var encoder = LengthPrefixedUTF8Encoder()
    appendV2PersistentFields(envelope, to: &encoder)
    return digest(encoder.data)
  }

  public func semanticPayloadSHA256(_ document: CapturedDocument) -> String {
    var encoder = LengthPrefixedUTF8Encoder()
    encoder.append("linkdigest:manual-document:v1")
    encoder.append(document.createdAt)
    encoder.append(document.origin.rawValue)
    encoder.append(document.url)
    encoder.appendOptional(document.title)
    encoder.append(document.platform)
    encoder.append(document.method)
    encoder.append(document.text)
    encoder.append(Int64(document.characterCount))
    encoder.append(document.completeness)
    encoder.append(document.capturedAt)
    encoder.append(document.sourceLabel)
    return digest(encoder.data)
  }

  private func appendV2PersistentFields(
    _ envelope: CaptureEnvelopeV2,
    to encoder: inout LengthPrefixedUTF8Encoder
  ) {
    encoder.append("linkdigest:capture-payload:v2")
    encoder.append(Int64(envelope.version))
    encoder.append(envelope.createdAt)
    encoder.append(envelope.source.kind)
    encoder.append(envelope.source.url)
    encoder.appendOptional(envelope.source.title)
    encoder.append(envelope.source.platform)
    encoder.append(envelope.capture.method)
    encoder.append(envelope.capture.text)
    encoder.append(Int64(envelope.capture.characterCount))
    encoder.append(envelope.capture.completeness)
    encoder.append(envelope.capture.capturedAt)
    encoder.append(envelope.evidence.sourceLabel)
    encoder.append(envelope.evidence.usedCookie)
    appendPersistentMediaDescriptor(envelope.media, to: &encoder)
  }

  private func appendPersistentMediaDescriptor(
    _ media: MediaDescriptor,
    to encoder: inout LengthPrefixedUTF8Encoder
  ) {
    // Explicitly exclude ephemeralPlaybackURL and expiresAt. Neither may enter
    // a durable replay fingerprint or conflict diagnostic.
    encoder.append(media.kind.rawValue)
    encoder.append(media.pageURL)
    encoder.append(media.canonicalURL)
    encoder.append(media.platform)
    encoder.appendOptional(media.mimeType)
    encoder.appendOptional(media.posterURL)
    encoder.appendOptional(media.durationSeconds.map { String($0) })
    encoder.appendOptional(media.author)
    encoder.append(media.transcriptionCapability.rawValue)
    encoder.appendOptional(media.failureReason?.rawValue)
    encoder.appendOptional(media.candidateCount.map { String($0) })
    encoder.appendOptional(media.selectionReason?.rawValue)
    encoder.appendOptional(media.playbackState?.rawValue)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Closed, irreversible delivery facts handed to persistence. Browser wire
/// values are reduced here; Repository never receives a V1/V2 envelope or a
/// MediaDescriptor and cannot reconstruct transient media URLs.
public struct CaptureDeliveryProvenance: Sendable, Equatable {
  public let deliveryKey: String
  public let captureContractVersion: Int
  public let semanticPayloadSHA256: String

  init(deliveryKey: String, captureContractVersion: Int, semanticPayloadSHA256: String) {
    self.deliveryKey = deliveryKey
    self.captureContractVersion = captureContractVersion
    self.semanticPayloadSHA256 = semanticPayloadSHA256
  }

  static func browserV1(_ envelope: CaptureEnvelopeV1) throws -> Self {
    try CaptureValidator.validate(envelope)
    let fingerprinter = SHA256CaptureFingerprinter()
    return .init(
      deliveryKey: CaptureDeliveryIdentity.key(for: envelope),
      captureContractVersion: 1,
      semanticPayloadSHA256: fingerprinter.semanticPayloadSHA256(envelope)
    )
  }

  static func browserV2(_ envelope: CaptureEnvelopeV2) throws -> Self {
    try CaptureEnvelopeV2Validator.validate(envelope)
    let fingerprinter = SHA256CaptureFingerprinter()
    return .init(
      deliveryKey: CaptureDeliveryIdentity.key(for: envelope),
      captureContractVersion: 2,
      semanticPayloadSHA256: fingerprinter.semanticPayloadSHA256(envelope)
    )
  }

  static func localDocument(_ document: CapturedDocument) throws -> Self {
    guard document.origin != .browserCapture,
          document.idempotencyKey?.isEmpty != true
    else { throw RepositoryFailure.invalidInput }
    try CapturedDocumentValidator.validate(document)
    let fingerprinter = SHA256CaptureFingerprinter()
    return .init(
      deliveryKey: CaptureDeliveryIdentity.key(for: document),
      captureContractVersion: 1,
      semanticPayloadSHA256: fingerprinter.semanticPayloadSHA256(document)
    )
  }
}

public enum CaptureDeliveryIdentity {
  public static func key(for envelope: CaptureEnvelopeV1) -> String {
    if let key = envelope.idempotencyKey { return "capture:v1:id:\(key)" }
    return "capture:v1:req:\(envelope.requestId)"
  }
  public static func key(for envelope: CaptureEnvelopeV2) -> String {
    if let key = envelope.idempotencyKey { return "capture:v2:id:\(key)" }
    return "capture:v2:req:\(envelope.requestId)"
  }
  public static func key(for document: CapturedDocument) -> String {
    if let key = document.idempotencyKey { return "manual:v1:id:\(key)" }
    return "manual:v1:req:\(document.requestID)"
  }
}

private struct LengthPrefixedUTF8Encoder {
  private(set) var data = Data()

  mutating func append(_ value: String) {
    let bytes = Data(value.utf8)
    appendLength(UInt64(bytes.count))
    data.append(bytes)
  }

  mutating func append(_ value: Int64) { append(String(value)) }
  mutating func append(_ value: Bool) { append(value ? "1" : "0") }

  mutating func appendOptional(_ value: String?) {
    if let value { data.append(1); append(value) } else { data.append(0) }
  }

  private mutating func appendLength(_ value: UInt64) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}
