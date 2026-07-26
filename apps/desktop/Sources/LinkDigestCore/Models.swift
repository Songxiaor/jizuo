import Foundation

public struct CaptureEnvelopeV1: Codable, Sendable, Equatable {
  public let version: Int
  public let requestId: String
  public let createdAt: String
  public let idempotencyKey: String?
  public let source: Source
  public let capture: Capture
  public let evidence: Evidence
  /// Optional legacy video media block. Browser `videoURL` values remain
  /// process-only and are downloaded only after explicit user save.
  public let media: Media?
  public init(
    version: Int,
    requestId: String,
    createdAt: String,
    idempotencyKey: String? = nil,
    source: Source,
    capture: Capture,
    evidence: Evidence,
    media: Media? = nil
  ) {
    self.version = version
    self.requestId = requestId
    self.createdAt = createdAt
    self.idempotencyKey = idempotencyKey
    self.source = source
    self.capture = capture
    self.evidence = evidence
    self.media = media
  }
  public struct Source: Codable, Sendable, Equatable { public let kind: String; public let url: String; public let title: String?; public let platform: String; public init(kind: String, url: String, title: String?, platform: String) { self.kind = kind; self.url = url; self.title = title; self.platform = platform } }
  public struct Capture: Codable, Sendable, Equatable { public let method: String; public let text: String; public let characterCount: Int; public let completeness: String; public let capturedAt: String; public init(method: String, text: String, characterCount: Int, completeness: String, capturedAt: String) { self.method = method; self.text = text; self.characterCount = characterCount; self.completeness = completeness; self.capturedAt = capturedAt } }
  public struct Evidence: Codable, Sendable, Equatable { public let sourceLabel: String; public let usedCookie: Bool; public init(sourceLabel: String, usedCookie: Bool) { self.sourceLabel = sourceLabel; self.usedCookie = usedCookie } }
  public struct Media: Codable, Sendable, Equatable {
    public let platform: String
    public let videoURL: String
    public let coverURL: String?
    public let durationSeconds: Double?
    public let author: String?
    public init(
      platform: String,
      videoURL: String,
      coverURL: String? = nil,
      durationSeconds: Double? = nil,
      author: String? = nil
    ) {
      self.platform = platform
      self.videoURL = videoURL
      self.coverURL = coverURL
      self.durationSeconds = durationSeconds
      self.author = author
    }
  }
}

public enum MediaKind: String, Codable, Sendable, Equatable {
  case directFile, hls, embed, browserSessionOnly, unsupported
}

public enum TranscriptionCapability: String, Codable, Sendable, Equatable {
  case supported, conditional, unavailable
}

public enum MediaFailureReason: String, Codable, Sendable, Equatable {
  case blobOrMSE = "blob_or_mse"
  case multipleCandidates = "multiple_candidates"
  case videoNotLoaded = "video_not_loaded"
  case noTransferableSource = "no_transferable_source"
  case drmOrEncrypted = "drm_or_encrypted"
  case browserSessionRequired = "browser_session_required"
  case unsupportedMediaType = "unsupported_media_type"
  case unknown
}

public enum MediaSelectionReason: String, Codable, Sendable, Equatable {
  case singleCandidate, playing, recentInteraction, largestVisibleArea, nearestViewportCenter, ambiguous
}

public enum MediaPlaybackState: String, Codable, Sendable, Equatable {
  case playing, paused, ended, notLoaded, unknown
}

public struct MediaDescriptor: Codable, Sendable, Equatable {
  public let kind: MediaKind
  public let pageURL: String
  public let canonicalURL: String
  public let platform: String
  public let ephemeralPlaybackURL: String?
  /// 画面与声音分成两条流的来源（B 站 DASH）：`ephemeralPlaybackURL` 是画面，
  /// 这一条是配套音轨，下载后在本机合成一个带声音的文件。与主地址同一有效期。
  public let companionAudioURL: String?
  public let mimeType: String?
  public let posterURL: String?
  public let durationSeconds: Double?
  public let author: String?
  public let expiresAt: String?
  public let transcriptionCapability: TranscriptionCapability
  public let failureReason: MediaFailureReason?
  public let candidateCount: Int?
  public let selectionReason: MediaSelectionReason?
  public let playbackState: MediaPlaybackState?

  public init(
    kind: MediaKind,
    pageURL: String,
    canonicalURL: String,
    platform: String,
    ephemeralPlaybackURL: String? = nil,
    companionAudioURL: String? = nil,
    mimeType: String? = nil,
    posterURL: String? = nil,
    durationSeconds: Double? = nil,
    author: String? = nil,
    expiresAt: String? = nil,
    transcriptionCapability: TranscriptionCapability,
    failureReason: MediaFailureReason? = nil,
    candidateCount: Int? = nil,
    selectionReason: MediaSelectionReason? = nil,
    playbackState: MediaPlaybackState? = nil
  ) {
    self.kind = kind
    self.pageURL = pageURL
    self.canonicalURL = canonicalURL
    self.platform = platform
    self.ephemeralPlaybackURL = ephemeralPlaybackURL
    self.companionAudioURL = companionAudioURL
    self.mimeType = mimeType
    self.posterURL = posterURL
    self.durationSeconds = durationSeconds
    self.author = author
    self.expiresAt = expiresAt
    self.transcriptionCapability = transcriptionCapability
    self.failureReason = failureReason
    self.candidateCount = candidateCount
    self.selectionReason = selectionReason
    self.playbackState = playbackState
  }
}

public struct CaptureEnvelopeV2: Codable, Sendable, Equatable {
  public let version: Int
  public let requestId: String
  public let createdAt: String
  public let idempotencyKey: String?
  public let source: CaptureEnvelopeV1.Source
  public let capture: CaptureEnvelopeV1.Capture
  public let evidence: CaptureEnvelopeV1.Evidence
  public let media: MediaDescriptor

  public init(
    version: Int = 2,
    requestId: String,
    createdAt: String,
    idempotencyKey: String? = nil,
    source: CaptureEnvelopeV1.Source,
    capture: CaptureEnvelopeV1.Capture,
    evidence: CaptureEnvelopeV1.Evidence,
    media: MediaDescriptor
  ) {
    self.version = version
    self.requestId = requestId
    self.createdAt = createdAt
    self.idempotencyKey = idempotencyKey
    self.source = source
    self.capture = capture
    self.evidence = evidence
    self.media = media
  }
}

public enum CaptureWireEnvelope: Sendable, Equatable {
  case v1(CaptureEnvelopeV1)
  case v2(CaptureEnvelopeV2)

  public var requestId: String {
    switch self { case let .v1(value): value.requestId; case let .v2(value): value.requestId }
  }
  public var characterCount: Int {
    switch self { case let .v1(value): value.capture.characterCount; case let .v2(value): value.capture.characterCount }
  }

  public static func decode(_ data: Data) throws -> CaptureWireEnvelope {
    try decode(data, schemaLocator: nil)
  }

  static func decode(
    _ data: Data,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> CaptureWireEnvelope {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = (object["version"] as? NSNumber)?.intValue
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    switch version {
    case 1:
      return .v1(try CaptureValidator.decode(data, schemaLocator: schemaLocator))
    case 2:
      guard object["media"] != nil else {
        // V2 envelope arrived without the media discriminator. Two valid cases:
        //   (a) the field is genuinely absent — fall back to a V1 decode so
        //       the page text is not lost (frozen pre-V2 probe behaviour).
        //   (b) the field exists but its value is a JSON null, which
        //       JSONSerialization surfaces as NSNull — same fallback applies.
        // We rewrite the top-level version to 1 so the V1 validator's strict
        // `version == 1` guard accepts the downgraded payload.
        if let downgraded = rewriteVersionToV1(data),
           let v1 = try? CaptureValidator.decode(downgraded, schemaLocator: schemaLocator) {
          return .v1(v1)
        }
        throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
      }
      // Try strict V2 decode. If the V2 envelope is malformed in any way
      // (missing field, wrong kind, URL scheme not allowed, schema
      // mismatch, etc.), fall back to V1 so the user can still see the
      // captured text. The media block is silently dropped — better to
      // lose the video than to fail the entire capture. We catch *any*
      // error here because the V2 validator can throw both
      // CaptureValidationError and JSONSchemaValidationError; the latter
      // is a private type the outer switch does not know about.
      do {
        return .v2(try CaptureEnvelopeV2Validator.decode(data, schemaLocator: schemaLocator))
      } catch {
        if let downgraded = rewriteVersionToV1(data),
           let v1 = try? CaptureValidator.decode(downgraded, schemaLocator: schemaLocator) {
          return .v1(v1)
        }
        throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
      }
    default:
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
  }

  /// 把顶层 `version` 改成 1，**并丢掉 media 块**，其余原样保留。
  ///
  /// 丢 media 是这条回退路径的全部意义：调用方的注释一直写着「The media block is
  /// silently dropped — better to lose the video than to fail the entire capture」，
  /// 但这个函数原来只改 version、把 V2 形状的 media 留在原地。V1 的
  /// `media.videoURL` 是非可选 String，而 V2 的 media 形状不同，于是 V1 解码必然
  /// 失败——整条回退是死代码，catch 分支永远只能抛 CAPTURE_SCHEMA_INVALID。
  ///
  /// 用户看到的后果：author 超长、时长越界、pageURL scheme 不合法这类**只影响
  /// 媒体块**的问题，会让整条抓取被拒，连完好的正文一起丢掉。
  ///
  /// 注意 V1 仍然要求 `evidence.usedCookie == false`。带 Cookie 的抓取降不到 V1
  /// 是语义正确的——V1 这个字段的含义就是「没用登录态」，不该被绕过。
  private static func rewriteVersionToV1(_ data: Data) -> Data? {
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    object["version"] = NSNumber(value: 1)
    object.removeValue(forKey: "media")
    return try? JSONSerialization.data(withJSONObject: object, options: [])
  }
}

public enum CaptureEnvelopeV2Validator {
  public static func validate(_ value: CaptureEnvelopeV2) throws {
    try validate(value, schemaLocator: nil)
  }
  static func validate(
    _ value: CaptureEnvelopeV2,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws {
    _ = try decode(try JSONEncoder().encode(value), schemaLocator: schemaLocator)
  }
  public static func decode(_ data: Data) throws -> CaptureEnvelopeV2 {
    try decode(data, schemaLocator: nil)
  }
  static func decode(
    _ data: Data,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> CaptureEnvelopeV2 {
    do {
      let raw = try JSONSerialization.jsonObject(with: data)
      let value = try JSONDecoder().decode(CaptureEnvelopeV2.self, from: data)
      guard value.version == 2 else { throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED }
      guard let sourceURL = URL(string: value.source.url), ["http", "https"].contains(sourceURL.scheme?.lowercased()) else {
        throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED
      }
      let count = value.capture.text.unicodeScalars.count
      guard count > 0 else { throw CaptureValidationError.CAPTURE_CONTENT_EMPTY }
      guard count <= CaptureValidator.maxTextScalars else { throw CaptureValidationError.CAPTURE_PAYLOAD_TOO_LARGE }
      guard count == value.capture.characterCount else { throw CaptureValidationError.CAPTURE_COUNT_MISMATCH }
      try CaptureWireContractSchema.validator(version: 2, locator: schemaLocator).validate(raw)
      return value
    } catch let error as CaptureValidationError {
      throw error
    } catch {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
  }
}

public struct AppError: Codable, Sendable, Equatable { public let version: Int; public let requestId: String; public let createdAt: String; public let category: String; public let code: String; public let retryable: Bool; public let action: String; public let safeDetail: String?; public init(version: Int, requestId: String, createdAt: String, category: String, code: String, retryable: Bool, action: String, safeDetail: String?) { self.version = version; self.requestId = requestId; self.createdAt = createdAt; self.category = category; self.code = code; self.retryable = retryable; self.action = action; self.safeDetail = safeDetail } }
public enum NativeResponse: Codable, Sendable, Equatable {
  case taskAccepted(version: Int, requestId: String, characterCount: Int)
  /// 收藏夹同步：受理了一批推文 id，逐条抓取在 App 的队列里进行。
  case bookmarksAccepted(version: Int, requestId: String, queuedCount: Int, skippedCount: Int)
  case error(AppError)

  enum CodingKeys: String, CodingKey { case kind, version, requestId, characterCount, queuedCount, skippedCount, error }
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
    case "bookmarksAccepted":
      let version = try c.decode(Int.self, forKey: .version)
      guard version == 1 else {
        throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported NativeResponse version")
      }
      self = .bookmarksAccepted(
        version: version,
        requestId: try c.decode(String.self, forKey: .requestId),
        queuedCount: try c.decode(Int.self, forKey: .queuedCount),
        skippedCount: try c.decode(Int.self, forKey: .skippedCount)
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
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .taskAccepted(v, r, n):
      try c.encode("taskAccepted", forKey: .kind); try c.encode(v, forKey: .version)
      try c.encode(r, forKey: .requestId); try c.encode(n, forKey: .characterCount)
    case let .bookmarksAccepted(v, r, queued, skipped):
      try c.encode("bookmarksAccepted", forKey: .kind); try c.encode(v, forKey: .version)
      try c.encode(r, forKey: .requestId)
      try c.encode(queued, forKey: .queuedCount); try c.encode(skipped, forKey: .skippedCount)
    case let .error(e):
      try c.encode("error", forKey: .kind); try c.encode(e, forKey: .error)
    }
  }
}

public enum CaptureValidationError: String, Error, Codable, Sendable { case PROTOCOL_VERSION_UNSUPPORTED, CAPTURE_URL_UNSUPPORTED, CAPTURE_COUNT_MISMATCH, CAPTURE_CONTENT_EMPTY, CAPTURE_PAYLOAD_TOO_LARGE, CAPTURE_SCHEMA_INVALID }
public enum CaptureValidator {
  public static let maxTextScalars = 2_000_000
  public static func validate(_ value: CaptureEnvelopeV1) throws {
    try validate(value, schemaLocator: nil)
  }
  static func validate(
    _ value: CaptureEnvelopeV1,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws {
    let data = try JSONEncoder().encode(value)
    _ = try decode(data, schemaLocator: schemaLocator)
  }
  public static func decode(_ data: Data) throws -> CaptureEnvelopeV1 {
    try decode(data, schemaLocator: nil)
  }
  static func decode(
    _ data: Data,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> CaptureEnvelopeV1 {
    do {
      let raw = try JSONSerialization.jsonObject(with: data)
      let value = try JSONDecoder().decode(CaptureEnvelopeV1.self, from: data)
      try validateSemanticRules(value)
      try CaptureWireContractSchema.validator(locator: schemaLocator).validate(raw)
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

public struct FixtureManifest: Codable { public let schema: String; public let fixtures: [Fixture]; public struct Fixture: Codable { public let name: String; public let file: String; public let schema: String?; public let expect: String; public let errorCode: String?; public let mutation: Mutation? }; public struct Mutation: Codable { public let field: String; public let repeatCount: Int?; public let unit: String; enum CodingKeys: String, CodingKey { case field, repeatCount = "repeat", unit } } }
