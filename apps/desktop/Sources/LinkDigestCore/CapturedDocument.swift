import Foundation

/// A local document is the application's domain input.  It is intentionally
/// not the browser's `CaptureEnvelopeV1`: only the socket boundary decodes the
/// latter, then maps it here before persistence or model work begins.
public struct CapturedDocument: Sendable, Equatable {
  public enum Origin: String, Sendable, Equatable {
    case browserCapture = "browser_capture"
    case manualLink = "manual_link"
    case localTranscription = "local_transcription"
    /// 用户在 App 内自建的笔记。它没有来源网页，是唯一允许使用
    /// `CanonicalURL.noteScheme` 的来源——见 `CapturedDocumentValidator`。
    case userNote = "user_note"
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
  /// Optional legacy media metadata carried from V1 or a local source adapter.
  /// V2 browser media stays on the application-layer session descriptor; it
  /// must not enter the repository-facing document. Persistence stores only
  /// local file metadata in `media_assets`, never the remote URL.
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
      media: nil
    )
  }
}

/// Domain-side media handoff. Mirrors the optional wire `media` block without
/// becoming a second cross-language truth source.
public struct CaptureMedia: Sendable, Equatable {
  public let platform: String
  public let videoURL: String
  /// 只有画面的流（B 站 DASH）配套的音轨地址。下载时两条一起取，在本机合成。
  public let companionAudioURL: String?
  public let coverURL: String?
  public let durationSeconds: Double?
  public let author: String?

  public init(
    platform: String,
    videoURL: String,
    companionAudioURL: String? = nil,
    coverURL: String? = nil,
    durationSeconds: Double? = nil,
    author: String? = nil
  ) {
    self.platform = platform
    self.videoURL = videoURL
    self.companionAudioURL = companionAudioURL
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
    guard !document.requestID.isEmpty else { throw CapturedDocumentValidationError.invalidURL }
    // 笔记没有来源网页，用独立 scheme；**只有 `userNote` 能这么做**。
    //
    // 这道 guard 是抓取内容的安全边界：浏览器扩展或任何其它来源若能用非 http(s)
    // 的 URL 进来，就等于绕过了这里的全部限制。所以放宽必须绑定到具体 origin，
    // 而不是放宽 scheme 白名单本身。
    if document.origin == .userNote {
      guard (try? CanonicalURL(document.url))?.isNote == true else {
        throw CapturedDocumentValidationError.invalidURL
      }
    } else {
      guard URL(string: document.url) != nil,
            ["http", "https"].contains(URL(string: document.url)?.scheme?.lowercased())
      else { throw CapturedDocumentValidationError.invalidURL }
    }
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
