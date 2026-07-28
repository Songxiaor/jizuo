import Foundation

/// Narrow boundary for the rendered Douyin fallback used by manual-link
/// capture. Only a validated `CapturedDocument` may cross back into ingest.
@MainActor
public protocol DouyinWebCapturing: Sendable {
  func capture(url: URL) async throws -> CapturedDocument
}

public struct DouyinRenderedPage: Sendable, Equatable {
  public let awemeID: String
  public let canonicalURL: URL
  public let title: String
  public let description: String?
  public let author: String?
  public let publishedAt: String?
  public let videoURL: URL?
  public let coverURL: URL?
  public let durationSeconds: Double?

  public init(
    awemeID: String,
    canonicalURL: URL,
    title: String,
    description: String? = nil,
    author: String? = nil,
    publishedAt: String? = nil,
    videoURL: URL? = nil,
    coverURL: URL? = nil,
    durationSeconds: Double? = nil
  ) {
    self.awemeID = awemeID
    self.canonicalURL = canonicalURL
    self.title = title
    self.description = description
    self.author = author
    self.publishedAt = publishedAt
    self.videoURL = videoURL
    self.coverURL = coverURL
    self.durationSeconds = durationSeconds
  }
}

/// Pure validation for values returned by the hidden WebKit page.
///
/// JavaScript output is untrusted. The capture service does not pass raw DOM,
/// cookies, or arbitrary dictionary values into history.
public enum DouyinWebCapturePolicy {
  public static let maximumTitleScalars = 4_096
  public static let maximumMetadataScalars = 4_096
  public static let maximumDescriptionScalars = CaptureValidator.maxTextScalars

  public enum NavigationDecision: Sendable, Equatable {
    case allow
    case blockSilently
    case failCapture
  }

  public enum CompletionDecision: Sendable, Equatable {
    case completeWithPlayableMedia
    case waitForPlayableMedia
  }

  /// 标题、作者等元数据先出现并不代表视频已经可用。抖音播放器会在稍后才把
  /// 当前作品的签名 HTTPS 地址写入 video/state；在此之前不能把抓取判成成功。
  public static func completionDecision(
    for page: DouyinRenderedPage
  ) -> CompletionDecision {
    page.videoURL == nil ? .waitForPlayableMedia : .completeWithPlayableMedia
  }

  public static func isCandidate(_ url: URL) -> Bool {
    guard let host = normalizedHost(url.host) else { return false }
    return isDouyinHost(host)
  }

  public static func validateNavigationURL(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https",
          let host = normalizedHost(url.host),
          isDouyinHost(host),
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443
    else { throw ManualLinkError.webHostNotAllowed }
  }

  public static func navigationDecision(url: URL?, isMainFrame: Bool) -> NavigationDecision {
    guard let url, (try? validateNavigationURL(url)) != nil else {
      return isMainFrame ? .failCapture : .blockSilently
    }
    return .allow
  }

  public static func validateJavaScriptResult(_ value: Any) throws -> DouyinRenderedPage {
    guard let dictionary = value as? [String: Any] else {
      throw ManualLinkError.invalidPageResult
    }

    func requiredString(_ key: String, maximum: Int) throws -> String {
      guard let raw = dictionary[key] as? String else {
        throw ManualLinkError.invalidPageResult
      }
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { throw ManualLinkError.emptyContent }
      guard value.unicodeScalars.count <= maximum else {
        throw ManualLinkError.responseTooLarge
      }
      return value
    }

    func optionalString(_ key: String, maximum: Int = maximumMetadataScalars) throws -> String? {
      guard let rawValue = dictionary[key] else { return nil }
      guard let raw = rawValue as? String else {
        throw ManualLinkError.invalidPageResult
      }
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard value.unicodeScalars.count <= maximum else {
        throw ManualLinkError.responseTooLarge
      }
      return value.isEmpty ? nil : value
    }

    let awemeID = try requiredString("awemeID", maximum: 25)
    guard awemeID.range(of: #"^\d{8,25}$"#, options: .regularExpression) != nil else {
      throw ManualLinkError.invalidPageResult
    }
    let canonicalString = try requiredString("canonicalURL", maximum: 2_048)
    guard let canonicalURL = URL(string: canonicalString),
          canonicalURL.scheme?.lowercased() == "https",
          normalizedHost(canonicalURL.host).map(isDouyinHost) == true,
          canonicalURL.path == "/video/\(awemeID)"
    else { throw ManualLinkError.invalidPageResult }

    let title = try requiredString("title", maximum: maximumTitleScalars)
    let description = try optionalString(
      "description",
      maximum: maximumDescriptionScalars
    )
    let author = try optionalString("author").flatMap(cleanAuthor)
    let publishedAt = try optionalString("publishedAt").flatMap(cleanPublishedAt)
    let videoURL = try optionalHTTPSURL("videoURL", in: dictionary)
    let coverURL = try optionalHTTPSURL("coverURL", in: dictionary)

    let durationSeconds: Double?
    if let raw = dictionary["durationSeconds"] {
      guard let number = raw as? NSNumber else {
        throw ManualLinkError.invalidPageResult
      }
      let value = number.doubleValue
      guard value.isFinite, value > 0, value <= 86_400 else {
        throw ManualLinkError.invalidPageResult
      }
      durationSeconds = value
    } else {
      durationSeconds = nil
    }

    return DouyinRenderedPage(
      awemeID: awemeID,
      canonicalURL: canonicalURL,
      title: title,
      description: description,
      author: author,
      publishedAt: publishedAt,
      videoURL: videoURL,
      coverURL: coverURL,
      durationSeconds: durationSeconds
    )
  }

  private static func optionalHTTPSURL(
    _ key: String,
    in dictionary: [String: Any]
  ) throws -> URL? {
    guard let rawValue = dictionary[key] else { return nil }
    guard let raw = rawValue as? String else {
      throw ManualLinkError.invalidPageResult
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.unicodeScalars.count <= 8_192 else {
      throw ManualLinkError.responseTooLarge
    }
    guard !value.isEmpty else { return nil }
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          url.host?.isEmpty == false,
          url.user == nil,
          url.password == nil
    else { throw ManualLinkError.invalidPageResult }
    return url
  }

  private static func cleanAuthor(_ raw: String) -> String? {
    var value = raw
      .replacingOccurrences(
        of: #"(?:官方|企业|个人|机构)?认证(?:徽章|信息|标识)?"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(of: "已认证", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var previous = ""
    while !value.isEmpty, value != previous {
      previous = value
      value = value.replacingOccurrences(
        of: #"(?:粉丝|获赞|关注|作品|喜欢|朋友)\s*[\d.,]*\s*[万千亿]?\s*$"#,
        with: "",
        options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.isEmpty ? nil : value
  }

  private static func cleanPublishedAt(_ raw: String) -> String? {
    let value = raw.replacingOccurrences(
      of: #"^发布时间\s*[:：]\s*"#,
      with: "",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func normalizedHost(_ raw: String?) -> String? {
    guard var host = raw?.lowercased(), !host.isEmpty else { return nil }
    while host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : host
  }

  private static func isDouyinHost(_ host: String) -> Bool {
    host == "douyin.com" || host.hasSuffix(".douyin.com")
      || host == "iesdouyin.com" || host.hasSuffix(".iesdouyin.com")
  }
}
