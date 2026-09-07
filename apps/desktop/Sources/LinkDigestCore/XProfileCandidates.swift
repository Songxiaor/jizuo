import Foundation

/// 浏览器扩展回传的 X 主页作品候选：只用于汲作选择页的内存预览。
///
/// 独立于 capture envelope 与 xBookmarks。收到本消息不得入库、不得自动总结，
/// ACK 只表示 App 已收下待展示的候选，不表示选择页已经出现在屏幕上。
public struct XProfileCandidatesRequest: Sendable, Equatable {
  public static let maximumItems = 100
  public static let schemaRelativePath = "contracts/x-profile-candidates-v1.schema.json"

  public struct Item: Sendable, Equatable {
    public let id: String
    public let url: String
    public let previewText: String?
    public let publishedText: String?

    public init(id: String, url: String, previewText: String? = nil, publishedText: String? = nil) {
      self.id = id
      self.url = url
      self.previewText = previewText
      self.publishedText = publishedText
    }
  }

  public let version: Int
  public let requestId: String
  public let profileURL: String
  public let authorID: String
  public let profileName: String?
  public let profileAvatarURL: String?
  public let items: [Item]

  public init(
    version: Int = 1,
    requestId: String,
    profileURL: String,
    authorID: String,
    profileName: String? = nil,
    profileAvatarURL: String? = nil,
    items: [Item]
  ) {
    self.version = version
    self.requestId = requestId
    self.profileURL = profileURL
    self.authorID = authorID
    self.profileName = profileName
    self.profileAvatarURL = profileAvatarURL
    self.items = items
  }

  /// 返回 nil 表示「不是主页候选消息」，调用方应继续按其它消息解析。
  /// 抛错表示「是这种消息但不合法」。
  public static func decode(_ data: Data) throws -> XProfileCandidatesRequest? {
    try decode(data, schemaLocator: nil)
  }

  static func decode(
    _ data: Data,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> XProfileCandidatesRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String
    else { return nil }
    guard kind == "xProfileCandidates" else { return nil }

    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }

    do {
      try CaptureWireContractSchema.xProfileCandidatesValidator(locator: schemaLocator).validate(object)
    } catch {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }

    guard let requestId = object["requestId"] as? String,
          let profileURL = object["profileURL"] as? String,
          let authorID = object["authorID"] as? String,
          let rawItems = object["items"] as? [[String: Any]]
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }

    let canonicalAuthor = authorID.lowercased()
    guard let canonicalProfile = canonicalProfileURL(profileURL),
          handle(fromProfileURL: canonicalProfile) == canonicalAuthor
    else { throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED }

    if let name = object["profileName"] as? String, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    if object["profileAvatarURL"] != nil, admittedAvatarURL(object["profileAvatarURL"] as? String) == nil {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }

    var seen = Set<String>()
    var items: [Item] = []
    for raw in rawItems {
      guard let id = raw["id"] as? String, XBookmarksSyncRequest.isValidTweetID(id) else {
        throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
      }
      guard let url = raw["url"] as? String, let canonicalURL = canonicalStatusURL(url) else {
        throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED
      }
      let handle = handle(fromStatusURL: canonicalURL)
      let statusID = XBookmarksSyncRequest.tweetID(fromCanonicalURL: canonicalURL)
      guard handle == canonicalAuthor, statusID == id else {
        throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED
      }
      if !seen.insert(id).inserted { continue }
      let preview = trimmedOptional(raw["previewText"], max: 200)
      let published = trimmedOptional(raw["publishedText"], max: 40)
      items.append(.init(id: id, url: canonicalURL, previewText: preview, publishedText: published))
    }
    guard !items.isEmpty else { throw CaptureValidationError.CAPTURE_CONTENT_EMPTY }
    guard items.count <= maximumItems else { throw CaptureValidationError.CAPTURE_PAYLOAD_TOO_LARGE }

    let profileName = trimmedOptional(object["profileName"], max: 80)
    return .init(
      version: 1,
      requestId: requestId,
      profileURL: canonicalProfile,
      authorID: canonicalAuthor,
      profileName: profileName,
      profileAvatarURL: admittedAvatarURL(object["profileAvatarURL"] as? String),
      items: items
    )
  }

  /// Public X profile photo only: https twimg `/profile_images/`. Tweet media and chrome avatars are not admitted.
  public static func admittedAvatarURL(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
    guard let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased(),
          host == "twimg.com" || host.hasSuffix(".twimg.com"),
          url.path.lowercased().contains("/profile_images/")
    else { return nil }
    return url.absoluteString
  }

  public static func canonicalProfileURL(_ raw: String) -> String? {
    guard let url = validatedHTTPSURL(raw) else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 1, isHandle(parts[0]) else { return nil }
    return "https://x.com/\(parts[0].lowercased())"
  }

  public static func canonicalStatusURL(_ raw: String) -> String? {
    guard let url = validatedHTTPSURL(raw),
          let id = XBookmarksSyncRequest.tweetID(fromCanonicalURL: url.absoluteString),
          let handle = handle(fromStatusURL: url.absoluteString)
    else { return nil }
    return "https://x.com/\(handle)/status/\(id)"
  }

  public static func isHandle(_ value: String) -> Bool {
    let handle = value.lowercased()
    guard handle.range(of: #"^[a-z0-9_]{1,15}$"#, options: .regularExpression) != nil else { return false }
    return !reservedHandles.contains(handle)
  }

  private static let reservedHandles: Set<String> = [
    "home", "explore", "search", "i", "settings", "login", "logout", "intent",
    "signup", "notifications", "messages", "compose", "tos", "privacy",
  ]

  private static func handle(fromProfileURL raw: String) -> String? {
    guard let url = URL(string: raw) else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 1 else { return nil }
    return parts[0].lowercased()
  }

  private static func handle(fromStatusURL raw: String) -> String? {
    guard let url = URL(string: raw) else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 3, parts[1].lowercased() == "status", isHandle(parts[0]) else { return nil }
    return parts[0].lowercased()
  }

  private static func validatedHTTPSURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return nil }
    let registered = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    guard registered == "x.com"
            || registered == "twitter.com"
            || registered == "mobile.twitter.com"
            || registered == "m.twitter.com"
    else { return nil }
    return url
  }

  private static func trimmedOptional(_ value: Any?, max: Int) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(max))
  }
}

public struct XProfileCandidatesPresented: Sendable, Equatable {
  public let version: Int
  public let requestId: String
  public let acceptedCount: Int

  public init(version: Int = 1, requestId: String, acceptedCount: Int) {
    self.version = version
    self.requestId = requestId
    self.acceptedCount = acceptedCount
  }

  public func encodedObject() -> [String: Any] {
    [
      "kind": "profileCandidatesPresented",
      "version": version,
      "requestId": requestId,
      "acceptedCount": acceptedCount,
    ]
  }

  public static func decode(_ value: Any) throws -> XProfileCandidatesPresented {
    try decode(value, schemaLocator: nil)
  }

  static func decode(
    _ value: Any,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> XProfileCandidatesPresented {
    guard let object = value as? [String: Any] else {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    do {
      try CaptureWireContractSchema.xProfileCandidatesValidator(locator: schemaLocator).validate(object)
    } catch {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    guard object["kind"] as? String == "profileCandidatesPresented" else {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    guard (object["version"] as? NSNumber)?.intValue == 1,
          let requestId = object["requestId"] as? String,
          let count = (object["acceptedCount"] as? NSNumber)?.intValue,
          (1...XProfileCandidatesRequest.maximumItems).contains(count)
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    return .init(version: 1, requestId: requestId, acceptedCount: count)
  }
}
