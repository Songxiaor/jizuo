import Foundation

/// A local document is the application's domain input.  It is intentionally
/// not the browser's `CaptureEnvelopeV1`: only the socket boundary decodes the
/// latter, then maps it here before persistence or model work begins.
public struct CapturedDocument: Sendable, Equatable {
  public enum Origin: String, Sendable, Equatable {
    case browserCapture = "browser_capture"
    case manualLink = "manual_link"
    case localTranscription = "local_transcription"
  }

  public let requestID: String
  public let createdAt: String
  public let idempotencyKey: String?
  public let origin: Origin
  public let url: String
  public let title: String?
  public let platform: String
  public let method: String
  public let text: String
  public let characterCount: Int
  public let completeness: String
  public let capturedAt: String
  public let sourceLabel: String
  /// True only when an explicit browser capture reused the current page's
  /// same-origin session. It is local evidence, never a cookie value.
  public let usedCookie: Bool
  /// Optional legacy media metadata carried from the wire or a source adapter.
  /// Browser URLs stay process-only until an explicit save; persistence stores
  /// only local file metadata in `media_assets`, never the remote URL.
  public let media: CaptureMedia?

  public init(
    requestID: String = UUID().uuidString.lowercased(),
    createdAt: String,
    idempotencyKey: String? = nil,
    origin: Origin,
    url: String,
    title: String?,
    platform: String,
    method: String,
    text: String,
    characterCount: Int? = nil,
    completeness: String,
    capturedAt: String,
    sourceLabel: String,
    usedCookie: Bool = false,
    media: CaptureMedia? = nil
  ) {
    self.requestID = requestID
    self.createdAt = createdAt
    self.idempotencyKey = idempotencyKey
    self.origin = origin
    self.url = url
    self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? title?.trimmingCharacters(in: .whitespacesAndNewlines)
      : CapturedDocumentTitle.fallback(for: url)
    self.platform = platform
    self.method = method
    self.text = text
    self.characterCount = characterCount ?? text.unicodeScalars.count
    self.completeness = completeness
    self.capturedAt = capturedAt
    self.sourceLabel = sourceLabel
    self.usedCookie = usedCookie
    self.media = media
  }

  public init(wire envelope: CaptureEnvelopeV1) {
    self.init(
      requestID: envelope.requestId,
      createdAt: envelope.createdAt,
      idempotencyKey: envelope.idempotencyKey,
      origin: .browserCapture,
      url: envelope.source.url,
      title: envelope.source.title,
      platform: envelope.source.platform,
      method: envelope.capture.method,
      text: envelope.capture.text,
      characterCount: envelope.capture.characterCount,
      completeness: envelope.capture.completeness,
      capturedAt: envelope.capture.capturedAt,
      sourceLabel: envelope.evidence.sourceLabel,
      usedCookie: envelope.evidence.usedCookie,
      media: envelope.media.map {
        CaptureMedia(
          platform: $0.platform,
          videoURL: $0.videoURL,
          coverURL: $0.coverURL,
          durationSeconds: $0.durationSeconds,
          author: $0.author
        )
      }
    )
  }

  public init(wire envelope: CaptureEnvelopeV2) {
    self.init(
      requestID: envelope.requestId,
      createdAt: envelope.createdAt,
      idempotencyKey: envelope.idempotencyKey,
      origin: .browserCapture,
      url: envelope.source.url,
      title: envelope.source.title,
      platform: envelope.source.platform,
      method: envelope.capture.method,
      text: envelope.capture.text,
      characterCount: envelope.capture.characterCount,
      completeness: envelope.capture.completeness,
      capturedAt: envelope.capture.capturedAt,
      sourceLabel: envelope.evidence.sourceLabel,
      usedCookie: envelope.evidence.usedCookie,
      media: envelope.media.ephemeralPlaybackURL.map { playbackURL in
        CaptureMedia(
          platform: envelope.media.platform,
          videoURL: playbackURL,
          coverURL: envelope.media.posterURL,
          durationSeconds: envelope.media.durationSeconds,
          author: envelope.media.author
        )
      }
    )
  }
}

/// Domain-side media handoff. Mirrors the optional wire `media` block without
/// becoming a second cross-language truth source.
public struct CaptureMedia: Sendable, Equatable {
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

/// Stable local title helpers. Applied at the document boundary so list,
/// detail, generation and export agree without UI-only special cases.
///
/// Product rule: titles are the original page title only — never a URL, path
/// fragment, or generated summary. Missing titles display as `无标题`.
public enum CapturedDocumentTitle {
  public static let missing = "无标题"

  /// Stored when capture did not supply a usable page title.
  public static func fallback(for rawURL: String) -> String {
    _ = rawURL
    return missing
  }

  /// List / detail / export display. Maps empty values and the legacy
  /// `host · /path` fallback shape to `无标题` so old rows stop looking like links.
  public static func display(_ title: String?, for rawURL: String = "") -> String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty { return missing }
    if isLegacyURLShapedTitle(trimmed, rawURL: rawURL) { return missing }
    return trimmed
  }

  /// Old builds stored `example.com · /long/path` when the page title was empty.
  public static func isLegacyURLShapedTitle(_ title: String, rawURL: String = "") -> Bool {
    if title.contains(" · /") { return true }
    if title == missing { return false }
    guard let host = URLComponents(string: rawURL)?.host?.lowercased(), !host.isEmpty else {
      return false
    }
    // Exact host-only legacy fallback (root path).
    return title.lowercased() == host
  }
}

public enum CapturedDocumentValidationError: Error, Sendable, Equatable {
  case invalidURL, emptyContent, contentTooLarge, countMismatch, invalidTimestamp
}

public enum CapturedDocumentValidator {
  public static func validate(_ document: CapturedDocument) throws {
    guard !document.requestID.isEmpty,
          URL(string: document.url) != nil,
          ["http", "https"].contains(URL(string: document.url)?.scheme?.lowercased())
    else { throw CapturedDocumentValidationError.invalidURL }
    let count = document.text.unicodeScalars.count
    guard count > 0 else { throw CapturedDocumentValidationError.emptyContent }
    guard count <= CaptureValidator.maxTextScalars else { throw CapturedDocumentValidationError.contentTooLarge }
    guard count == document.characterCount else { throw CapturedDocumentValidationError.countMismatch }
    guard validTimestamp(document.createdAt), validTimestamp(document.capturedAt) else {
      throw CapturedDocumentValidationError.invalidTimestamp
    }
  }

  private static func validTimestamp(_ value: String) -> Bool {
    let standard = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions.insert(.withFractionalSeconds)
    return standard.date(from: value) != nil || fractional.date(from: value) != nil
  }
}
