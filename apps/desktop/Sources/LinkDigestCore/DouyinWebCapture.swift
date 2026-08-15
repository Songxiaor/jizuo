import Foundation

/// Narrow boundary for the rendered Douyin fallback used by manual-link
/// capture. Only a validated `CapturedDocument` may cross back into ingest.
@MainActor
public protocol DouyinWebCapturing: Sendable {
  func capture(url: URL) async throws -> CapturedDocument
}

/// 抓取等待循环。从 WebKit 服务里抽出来只为一件事：让「视频地址比标题晚出现」
/// 这条真实时序能被测试驱动，而不是只能靠碰上一条慢视频才发现。
///
/// 原始缺陷是标题就绪后只再轮询 8 × 250ms ≈ 2 秒，超时就把「只有标题作者、
/// 没有视频地址」的结果当成抓取成功。这里刻意不设尝试次数上限——何时放弃
/// 只由外部截止时间决定，慢视频和快视频因此走同一条路径。
@MainActor
public enum DouyinCaptureWait {
  public enum PollOutcome: Sendable, Equatable {
    /// 页面还没渲染出可解析的作品信息。
    case notReady
    /// 页面已就绪；`videoURL` 仍可能为空，代表元数据先到、视频地址未到。
    case ready(DouyinRenderedPage)
  }

  /// 轮询到出现可播放视频地址或图集为止。
  ///
  /// 返回 `nil` 表示外部已取消（含截止时间到达），由调用方决定如何收尾。
  /// 元数据先到不构成完成条件。
  public static func waitForPlayableMedia(
    pollInterval: Duration,
    isCancelled: () -> Bool,
    sleep: (Duration) async throws -> Void,
    poll: () async throws -> PollOutcome
  ) async throws -> DouyinRenderedPage? {
    while !isCancelled() {
      switch try await poll() {
      case .notReady:
        try await sleep(pollInterval)
      case .ready(let page):
        guard DouyinWebCapturePolicy.completionDecision(for: page)
          == .completeWithPlayableMedia
        else {
          try await sleep(pollInterval)
          continue
        }
        return page
      }
    }
    return nil
  }
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
  public let imageURLs: [URL]

  public init(
    awemeID: String,
    canonicalURL: URL,
    title: String,
    description: String? = nil,
    author: String? = nil,
    publishedAt: String? = nil,
    videoURL: URL? = nil,
    coverURL: URL? = nil,
    durationSeconds: Double? = nil,
    imageURLs: [URL] = []
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
    self.imageURLs = imageURLs
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

  public static let maximumGalleryImages = 35

  /// 登录 WebView 会经过这些域完成扫码 / SSO，再回到 douyin.com。
  /// 抓取主框必须放行，否则已登录会话会被写成「请用扩展」。
  /// 不放进 `isDouyinHost`：用户提交的起始地址仍然只能是抖音内容域。
  public static func isSessionNavigationURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          let host = normalizedHost(url.host),
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443
    else { return false }
    return host == "snssdk.com" || host.hasSuffix(".snssdk.com")
      || host == "bytedance.com" || host.hasSuffix(".bytedance.com")
  }

  /// Accept a single gallery URL, or `nil` when it is not a Douyin note image.
  public static func galleryImageURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 8_192 else { return nil }
    guard let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          isDouyinPicHost(url.host),
          isGalleryImage(url)
    else { return nil }
    return url
  }

  /// 标题、作者等元数据先出现并不代表内容已经可用。视频要等签名地址，
  /// 图文要等至少一张正片图；在此之前不能把抓取判成成功。
  public static func completionDecision(
    for page: DouyinRenderedPage
  ) -> CompletionDecision {
    if page.videoURL != nil || !page.imageURLs.isEmpty {
      return .completeWithPlayableMedia
    }
    return .waitForPlayableMedia
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
    guard let url else {
      return isMainFrame ? .failCapture : .blockSilently
    }
    if (try? validateNavigationURL(url)) != nil { return .allow }
    if isSessionNavigationURL(url) { return .allow }
    return isMainFrame ? .failCapture : .blockSilently
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
            || canonicalURL.path == "/note/\(awemeID)"
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
    let imageURLs = try validatedGalleryImageURLs(dictionary["imageURLs"])

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
      durationSeconds: durationSeconds,
      imageURLs: imageURLs
    )
  }

  private static func validatedGalleryImageURLs(_ raw: Any?) throws -> [URL] {
    guard let raw else { return [] }
    guard let values = raw as? [String] else {
      throw ManualLinkError.invalidPageResult
    }
    guard values.count <= maximumGalleryImages else {
      throw ManualLinkError.responseTooLarge
    }
    var urls: [URL] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.unicodeScalars.count <= 8_192 else {
        throw ManualLinkError.responseTooLarge
      }
      guard let url = galleryImageURL(from: trimmed) else {
        throw ManualLinkError.invalidPageResult
      }
      if !urls.contains(url) { urls.append(url) }
    }
    return urls
  }

  private static func isDouyinPicHost(_ raw: String?) -> Bool {
    guard let host = normalizedHost(raw) else { return false }
    return host == "douyinpic.com" || host.hasSuffix(".douyinpic.com")
  }

  /// 与扩展同一条规则：只收正片图，不要评论配图和头像。
  private static func isGalleryImage(_ url: URL) -> Bool {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    if items?.contains(where: { $0.name == "biz_tag" && $0.value == "aweme_images" }) == true {
      return true
    }
    return url.path.contains("tplv-dy-aweme-images")
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
    if value.range(
      of: #"(?:粉丝|获赞)\s*[\d.,]+\s*[万千亿]?"#,
      options: .regularExpression
    ) != nil {
      value = value.replacingOccurrences(
        of: #"(?:已(?:关注)?|关注)\s*$"#,
        with: "",
        options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
