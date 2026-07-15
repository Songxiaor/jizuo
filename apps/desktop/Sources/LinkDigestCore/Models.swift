import Foundation

public struct CaptureEnvelopeV1: Codable, Sendable, Equatable {
  public let version: Int
  public let requestId: String
  public let createdAt: String
  public let idempotencyKey: String?
  public let source: Source
  public let capture: Capture
  public let evidence: Evidence
  public init(version: Int, requestId: String, createdAt: String, idempotencyKey: String? = nil, source: Source, capture: Capture, evidence: Evidence) { self.version = version; self.requestId = requestId; self.createdAt = createdAt; self.idempotencyKey = idempotencyKey; self.source = source; self.capture = capture; self.evidence = evidence }
  public struct Source: Codable, Sendable, Equatable { public let kind: String; public let url: String; public let title: String?; public let platform: String; public init(kind: String, url: String, title: String?, platform: String) { self.kind = kind; self.url = url; self.title = title; self.platform = platform } }
  public struct Capture: Codable, Sendable, Equatable { public let method: String; public let text: String; public let characterCount: Int; public let completeness: String; public let capturedAt: String; public init(method: String, text: String, characterCount: Int, completeness: String, capturedAt: String) { self.method = method; self.text = text; self.characterCount = characterCount; self.completeness = completeness; self.capturedAt = capturedAt } }
  public struct Evidence: Codable, Sendable, Equatable { public let sourceLabel: String; public let usedCookie: Bool; public init(sourceLabel: String, usedCookie: Bool) { self.sourceLabel = sourceLabel; self.usedCookie = usedCookie } }
}

public struct AppError: Codable, Sendable, Equatable { public let version: Int; public let requestId: String; public let createdAt: String; public let category: String; public let code: String; public let retryable: Bool; public let action: String; public let safeDetail: String?; public init(version: Int, requestId: String, createdAt: String, category: String, code: String, retryable: Bool, action: String, safeDetail: String?) { self.version = version; self.requestId = requestId; self.createdAt = createdAt; self.category = category; self.code = code; self.retryable = retryable; self.action = action; self.safeDetail = safeDetail } }
public enum NativeResponse: Codable, Sendable, Equatable { case taskAccepted(version: Int, requestId: String, characterCount: Int), error(AppError)
  enum CodingKeys: String, CodingKey { case kind, version, requestId, characterCount, error }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "taskAccepted":
      let version = try c.decode(Int.self, forKey: .version)
      guard version == 1 else {
        throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported NativeResponse version")
      }
      self = .taskAccepted(
        version: version,
        requestId: try c.decode(String.self, forKey: .requestId),
        characterCount: try c.decode(Int.self, forKey: .characterCount)
      )
    case "error":
      let error = try c.decode(AppError.self, forKey: .error)
      guard error.version == 1 else {
        throw DecodingError.dataCorruptedError(forKey: .error, in: c, debugDescription: "Unsupported AppError version")
      }
      self = .error(error)
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown NativeResponse kind")
    }
  }
  public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); switch self { case let .taskAccepted(v, r, n): try c.encode("taskAccepted", forKey: .kind); try c.encode(v, forKey: .version); try c.encode(r, forKey: .requestId); try c.encode(n, forKey: .characterCount); case let .error(e): try c.encode("error", forKey: .kind); try c.encode(e, forKey: .error) } }
}

public enum CaptureValidationError: String, Error, Codable, Sendable { case PROTOCOL_VERSION_UNSUPPORTED, CAPTURE_URL_UNSUPPORTED, CAPTURE_COUNT_MISMATCH, CAPTURE_CONTENT_EMPTY, CAPTURE_PAYLOAD_TOO_LARGE, CAPTURE_SCHEMA_INVALID }
public enum CaptureValidator {
  public static let maxTextScalars = 2_000_000
  public static func validate(_ value: CaptureEnvelopeV1) throws {
    let data = try JSONEncoder().encode(value)
    _ = try decode(data)
  }
  public static func decode(_ data: Data) throws -> CaptureEnvelopeV1 {
    do {
      let raw = try JSONSerialization.jsonObject(with: data)
      let value = try JSONDecoder().decode(CaptureEnvelopeV1.self, from: data)
      try validateSemanticRules(value)
      try CaptureWireContractSchema.validator().validate(raw)
      return value
    } catch let error as CaptureValidationError {
      throw error
    } catch {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
  }
  private static func validateSemanticRules(_ value: CaptureEnvelopeV1) throws { guard value.version == 1 else { throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED }; guard let url = URL(string: value.source.url), ["http", "https"].contains(url.scheme?.lowercased()) else { throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED }; let count = value.capture.text.unicodeScalars.count; guard count > 0 else { throw CaptureValidationError.CAPTURE_CONTENT_EMPTY }; guard count <= maxTextScalars else { throw CaptureValidationError.CAPTURE_PAYLOAD_TOO_LARGE }; guard value.capture.characterCount == count else { throw CaptureValidationError.CAPTURE_COUNT_MISMATCH } }
}

public actor CaptureInbox {
  private var seen = Set<String>()

  public init() {}

  public func accept(_ value: CaptureEnvelopeV1) -> Bool {
    seen.insert(value.idempotencyKey ?? value.requestId).inserted
  }

  public var acceptedCount: Int { seen.count }
}

public struct FixtureManifest: Codable { public let schema: String; public let fixtures: [Fixture]; public struct Fixture: Codable { public let name: String; public let file: String; public let expect: String; public let errorCode: String?; public let mutation: Mutation? }; public struct Mutation: Codable { public let field: String; public let repeatCount: Int?; public let unit: String; enum CodingKeys: String, CodingKey { case field, repeatCount = "repeat", unit } } }
