import CryptoKit
import Foundation

public protocol CaptureFingerprinting: Sendable {
  func bodySHA256(_ body: String) -> String
  func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV1) -> String
}

public struct SHA256CaptureFingerprinter: CaptureFingerprinting {
  public init() {}

  public func bodySHA256(_ body: String) -> String { digest(Data(body.utf8)) }

  public func semanticPayloadSHA256(_ envelope: CaptureEnvelopeV1) -> String {
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

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum CaptureDeliveryIdentity {
  public static func key(for envelope: CaptureEnvelopeV1) -> String {
    if let key = envelope.idempotencyKey { return "capture:v1:id:\(key)" }
    return "capture:v1:req:\(envelope.requestId)"
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
