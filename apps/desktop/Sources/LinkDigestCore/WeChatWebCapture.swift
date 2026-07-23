import Foundation

/// The narrow app boundary for the one supported rendered-page capture path.
/// Implementations may load the page, but only this validated document crosses
/// back into the existing ingest service.
@MainActor
public protocol WeChatWebCapturing: Sendable {
  func capture(url: URL) async throws -> CapturedDocument
}

public struct WeChatExtractedPage: Sendable, Equatable {
  public let title: String
  public let text: String
  public let images: [String]
  public let coverImage: String?
  public let accountName: String?
  public let author: String?
  public let publishedAt: String?

  public init(
    title: String,
    text: String,
    images: [String] = [],
    coverImage: String? = nil,
    accountName: String? = nil,
    author: String? = nil,
    publishedAt: String? = nil
  ) {
    self.title = title
    self.text = text
    self.images = images
    self.coverImage = coverImage
    self.accountName = accountName
    self.author = author
    self.publishedAt = publishedAt
  }
}

/// Pure checks shared by the WebKit adapter and its no-network unit tests.
public enum WeChatWebCapturePolicy {
  public static let allowedHost = "mp.weixin.qq.com"
  public static let maximumResultScalars = CaptureValidator.maxTextScalars
  public static let maximumTitleScalars = 4_096
  public static let maximumImageCount = 60
  public static let maximumImageURLScalars = 2_048
  public static let maximumMetadataScalars = 4_096

  /// Converts the documented WeChat `ct` seconds field without trusting a
  /// locale-formatted date string. Non-timestamps intentionally return nil.
  public static func iso8601FromCT(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: "^[0-9]{9,12}$", options: .regularExpression) != nil,
          let seconds = TimeInterval(value), seconds.isFinite
    else { return nil }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
  }

  /// Host-only routing is deliberate: an HTTP WeChat URL still enters this
  /// backend so it can fail with the explicit HTTPS-only policy instead of
  /// falling through to the generic network fetcher.
  public static func isCandidate(_ url: URL) -> Bool {
    url.host?.lowercased() == allowedHost
  }

  /// Applied to the initial request and every navigation/response URL.
  public static func validateNavigationURL(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https",
          url.host?.lowercased() == allowedHost,
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443
    else { throw ManualLinkError.webHostNotAllowed }
  }

  /// 导航裁决：主框架离开 mp.weixin.qq.com 是策略违规，终止捕获；
  /// 子框架/新窗口的站外内容（广告、视频 iframe）只静默拦截——
  /// 它们不是用户提交的目标页面，不应把整页捕获判死。
  public enum NavigationDecision: Sendable, Equatable {
    case allow
    case blockSilently
    case failCapture
  }

  public static func navigationDecision(url: URL?, isMainFrame: Bool) -> NavigationDecision {
    guard let url, (try? validateNavigationURL(url)) != nil else {
      return isMainFrame ? .failCapture : .blockSilently
    }
    return .allow
  }

  /// JavaScript values are untrusted. Only the declared scalar fields and image
  /// strings are copied into a new value; additional keys are intentionally ignored.
  public static func validateJavaScriptResult(
    _ value: Any,
    allowEmptyText: Bool = false
  ) throws -> WeChatExtractedPage {
    guard let dictionary = value as? [String: Any],
          let rawTitle = dictionary["title"] as? String,
          let rawText = dictionary["text"] as? String,
          let rawImages = dictionary["images"] as? [Any],
          rawImages.count <= maximumImageCount
    else { throw ManualLinkError.invalidPageResult }

    func optionalString(_ key: String, maximumScalars: Int = maximumMetadataScalars) throws -> String? {
      guard let value = dictionary[key] else { return nil }
      guard let raw = value as? String else { throw ManualLinkError.invalidPageResult }
      let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.unicodeScalars.count <= maximumScalars else { throw ManualLinkError.responseTooLarge }
      return result.isEmpty ? nil : result
    }

    var images: [String] = []
    var seen = Set<String>()
    for rawValue in rawImages {
      guard let raw = rawValue as? String else { throw ManualLinkError.invalidPageResult }
      let image = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard image.unicodeScalars.count <= maximumImageURLScalars else { throw ManualLinkError.responseTooLarge }
      if !image.isEmpty, seen.insert(image).inserted { images.append(image) }
    }

    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleCount = title.unicodeScalars.count
    let textCount = text.unicodeScalars.count
    guard titleCount <= maximumTitleScalars,
          titleCount <= maximumResultScalars - min(textCount, maximumResultScalars)
    else { throw ManualLinkError.responseTooLarge }
    guard textCount <= maximumResultScalars,
          titleCount + textCount <= maximumResultScalars
    else { throw ManualLinkError.responseTooLarge }
    guard allowEmptyText || !text.isEmpty else { throw ManualLinkError.emptyContent }
    let coverImage = try optionalString("coverImage", maximumScalars: maximumImageURLScalars)
    let accountName = try optionalString("accountName")
    let author = try optionalString("author")
    let publishedAt = try optionalString("publishedAt")
    let supplementalScalars = images.reduce(0) { $0 + $1.unicodeScalars.count }
      + [coverImage, accountName, author, publishedAt].compactMap { $0?.unicodeScalars.count }.reduce(0, +)
    guard supplementalScalars <= maximumResultScalars,
          titleCount + textCount + supplementalScalars <= maximumResultScalars
    else { throw ManualLinkError.responseTooLarge }

    return .init(
      title: title,
      text: text,
      images: images,
      coverImage: coverImage,
      accountName: accountName,
      author: author,
      publishedAt: publishedAt.flatMap { iso8601FromCT($0) ?? $0 }
    )
  }

  /// At the hard deadline a completed, valid empty-body check is reported as
  /// empty content. A page that never became inspectable is a true timeout.
  public static func deadlineFailure(
    pageDidFinish: Bool,
    completedEmptyReadinessCheck: Bool
  ) -> ManualLinkError {
    pageDidFinish && completedEmptyReadinessCheck ? .emptyContent : .timedOut
  }
}
