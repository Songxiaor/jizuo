import Foundation

public enum LiveRecordingPlatform: String, Codable, Sendable, CaseIterable {
  case douyin
  case xiaohongshu

  public var displayName: String {
    switch self {
    case .douyin: return "抖音"
    case .xiaohongshu: return "小红书"
    }
  }
}

/// 录制清晰度档。名字沿用抖音页面里的 sdk_key，跨语言不翻译。
public enum LiveQuality: String, Codable, Sendable, CaseIterable {
  case origin
  case hd
  case sd
  case ld

  public var displayName: String {
    switch self {
    case .origin: return "原画"
    case .hd: return "高清"
    case .sd: return "标清"
    case .ld: return "流畅"
    }
  }
}

public enum LiveStreamContainer: String, Codable, Sendable {
  case flv
  case hls
}

/// 一档清晰度的一个可拉流地址。地址是限时签名的，只在进程内存里用。
public struct LiveStreamVariant: Sendable, Equatable {
  public let quality: LiveQuality
  public let container: LiveStreamContainer
  public let url: String
  public let resolution: String?
  public let label: String?

  public init(
    quality: LiveQuality,
    container: LiveStreamContainer,
    url: String,
    resolution: String? = nil,
    label: String? = nil
  ) {
    self.quality = quality
    self.container = container
    self.url = url
    self.resolution = resolution
    self.label = label
  }
}

/// 浏览器扩展交来的「开始录制」消息（`live-recording-v1.schema.json`）。
public struct LiveRecordingRequest: Sendable, Equatable {
  public static let schemaRelativePath = "contracts/live-recording-v1.schema.json"
  public static let maximumVariants = 8
  public static let defaultReferer = "https://live.douyin.com/"

  /// 与扩展 `LIVE_BROWSER_USER_AGENT` 一致：只声明身份，不做轮换。
  public static let defaultUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

  public let version: Int
  public let requestId: String
  public let createdAt: String
  public let platform: LiveRecordingPlatform
  public let pageURL: String
  public let roomID: String?
  public let anchorName: String?
  /// 平台的主播 id（抖音 sec_uid / 小红书 hostId）。只在能对上已有博主时使用。
  public let anchorID: String?
  public let anchorAvatarURL: String?
  public let anchorProfileURL: String?
  public let title: String?
  public let quality: LiveQuality
  public let variants: [LiveStreamVariant]
  public let referer: String
  public let userAgent: String

  public init(
    version: Int = 1,
    requestId: String,
    createdAt: String,
    platform: LiveRecordingPlatform,
    pageURL: String,
    roomID: String? = nil,
    anchorName: String? = nil,
    anchorID: String? = nil,
    anchorAvatarURL: String? = nil,
    anchorProfileURL: String? = nil,
    title: String? = nil,
    quality: LiveQuality,
    variants: [LiveStreamVariant],
    referer: String = LiveRecordingRequest.defaultReferer,
    userAgent: String = LiveRecordingRequest.defaultUserAgent
  ) {
    self.version = version
    self.requestId = requestId
    self.createdAt = createdAt
    self.platform = platform
    self.pageURL = pageURL
    self.roomID = roomID
    self.anchorName = anchorName
    self.anchorID = anchorID
    self.anchorAvatarURL = anchorAvatarURL
    self.anchorProfileURL = anchorProfileURL
    self.title = title
    self.quality = quality
    self.variants = variants
    self.referer = referer
    self.userAgent = userAgent
  }

  /// nil = 不是这类消息；抛错 = 是这类消息但不合法。
  public static func decode(_ data: Data) throws -> LiveRecordingRequest? {
    try decode(data, schemaLocator: nil)
  }

  static func decode(
    _ data: Data,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> LiveRecordingRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String
    else { return nil }
    guard kind == "liveRecording" else { return nil }
    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    do {
      try CaptureWireContractSchema.liveRecordingValidator(locator: schemaLocator).validate(object)
    } catch {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }

    guard
      let requestId = object["requestId"] as? String,
      let createdAt = object["createdAt"] as? String,
      let platformRaw = object["platform"] as? String,
      let platform = LiveRecordingPlatform(rawValue: platformRaw),
      let pageURL = object["pageURL"] as? String,
      let qualityRaw = object["quality"] as? String,
      let quality = LiveQuality(rawValue: qualityRaw),
      let rawVariants = object["variants"] as? [[String: Any]]
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }

    guard let page = URL(string: pageURL),
          page.scheme?.lowercased() == "https",
          admittedPageHost(page, platform: platform)
    else { throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED }

    var variants: [LiveStreamVariant] = []
    var seen = Set<String>()
    for raw in rawVariants {
      guard
        let qualityRaw = raw["quality"] as? String,
        let variantQuality = LiveQuality(rawValue: qualityRaw),
        let containerRaw = raw["container"] as? String,
        let container = LiveStreamContainer(rawValue: containerRaw),
        let url = raw["url"] as? String,
        admittedStreamURL(url, container: container)
      else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
      let identity = "\(variantQuality.rawValue):\(container.rawValue)"
      guard seen.insert(identity).inserted else { continue }
      variants.append(
        LiveStreamVariant(
          quality: variantQuality,
          container: container,
          url: url,
          resolution: trimmed(raw["resolution"] as? String, max: 32),
          label: trimmed(raw["label"] as? String, max: 32)
        )
      )
    }
    guard !variants.isEmpty, variants.count <= maximumVariants else {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    // 原画只认 HLS：原画 FLV 是抖音私有 H.265 封装，ffmpeg 只能读到音频。
    if platform == .douyin,
       quality == .origin,
       !variants.contains(where: { $0.quality == .origin && $0.container == .hls }) {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }

    let headers = object["requestHeaders"] as? [String: Any]
    let referer = trimmed(headers?["referer"] as? String, max: 2_048) ?? defaultReferer
    let userAgent = trimmed(headers?["userAgent"] as? String, max: 512) ?? defaultUserAgent

    return LiveRecordingRequest(
      version: 1,
      requestId: requestId,
      createdAt: createdAt,
      platform: platform,
      pageURL: pageURL,
      roomID: trimmed(object["roomID"] as? String, max: 64),
      anchorName: trimmed(object["anchorName"] as? String, max: 80),
      anchorID: trimmed(object["anchorID"] as? String, max: 256),
      anchorAvatarURL: admittedHTTPSURL(object["anchorAvatarURL"] as? String, max: 2_048),
      anchorProfileURL: admittedProfileURL(
        object["anchorProfileURL"] as? String,
        platform: platform
      ),
      title: trimmed(object["title"] as? String, max: 200),
      quality: quality,
      variants: variants,
      referer: referer,
      userAgent: userAgent
    )
  }

  /// 录制时真正用的那一档。原画要 HLS，其他档优先 FLV；缺档就往下退。
  public func selectedVariant() -> LiveStreamVariant? {
    Self.select(variants: variants, requested: quality, platform: platform)
  }

  public static func select(
    variants: [LiveStreamVariant],
    requested: LiveQuality,
    platform: LiveRecordingPlatform = .douyin
  ) -> LiveStreamVariant? {
    let all = LiveQuality.allCases
    guard let index = all.firstIndex(of: requested) else { return nil }
    let order = Array(all[index...]) + Array(all[..<index].reversed())
    for quality in order {
      let matching = variants.filter { $0.quality == quality }
      guard !matching.isEmpty else { continue }
      if quality == .origin {
        // 小红书原画是 H.264 FLV，可直接录；抖音原画必须 HLS。
        if platform == .xiaohongshu {
          if let flv = matching.first(where: { $0.container == .flv }) { return flv }
          if let hls = matching.first(where: { $0.container == .hls }) { return hls }
          continue
        }
        if let hls = matching.first(where: { $0.container == .hls }) { return hls }
        continue
      }
      if let flv = matching.first(where: { $0.container == .flv }) { return flv }
      if let hls = matching.first(where: { $0.container == .hls }) { return hls }
    }
    return nil
  }

  public static func admittedPageHost(_ url: URL, platform: LiveRecordingPlatform) -> Bool {
    let host = url.host?.lowercased() ?? ""
    switch platform {
    case .douyin:
      return host == "live.douyin.com"
    case .xiaohongshu:
      return host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com")
    }
  }

  public static func admittedStreamURL(_ raw: String, container: LiveStreamContainer) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= 8_192, let url = URL(string: value) else { return false }
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
    let path = url.path.lowercased()
    switch container {
    case .hls: return path.hasSuffix(".m3u8")
    case .flv: return path.hasSuffix(".flv")
    }
  }

  private static func trimmed(_ value: String?, max: Int) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(max))
  }

  private static func admittedHTTPSURL(_ value: String?, max: Int) -> String? {
    guard let cleaned = trimmed(value, max: max),
          let url = URL(string: cleaned),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          url.host?.isEmpty == false
    else { return nil }
    return cleaned
  }

  private static func admittedProfileURL(
    _ value: String?,
    platform: LiveRecordingPlatform
  ) -> String? {
    guard let cleaned = admittedHTTPSURL(value, max: 2_048),
          let host = URL(string: cleaned)?.host?.lowercased()
    else { return nil }
    switch platform {
    case .douyin:
      return host == "douyin.com" || host.hasSuffix(".douyin.com") ? cleaned : nil
    case .xiaohongshu:
      return host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") ? cleaned : nil
    }
  }
}
