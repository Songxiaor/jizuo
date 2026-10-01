import Foundation

/// Stable identity for a followed creator. Nickname is display-only and must
/// never appear here: two people can share a name, and names change.
public struct CreatorID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) {
    guard let value = CreatorID.canonicalUUID(rawValue) else { return nil }
    self.rawValue = value
  }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }

  private static func canonicalUUID(_ value: String) -> String? {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
    return value
  }
}

/// Platform + author ID. The pair is the unique key; `authorID` is never unique
/// on its own because the same string can exist on another site.
public struct CreatorIdentity: Sendable, Equatable, Hashable {
  public let platform: String
  public let authorID: String

  public init?(platform rawPlatform: String, authorID rawAuthorID: String) {
    let platform = HistoryPlatformRegistry.canonicalHost(for: rawPlatform)
    let authorID = rawAuthorID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !platform.isEmpty, !authorID.isEmpty, authorID.count <= 256 else { return nil }
    self.platform = platform
    self.authorID = authorID
  }
}

public struct CreatorSummary: Sendable, Equatable, Identifiable {
  public let id: CreatorID
  public let identity: CreatorIdentity
  public let profileURL: String
  public let displayName: String?
  public let avatarURL: String?
  public let pinnedRank: Int?
  public let savedWorkCount: Int
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64

  public init(
    id: CreatorID,
    identity: CreatorIdentity,
    profileURL: String,
    displayName: String?,
    avatarURL: String? = nil,
    pinnedRank: Int?,
    savedWorkCount: Int,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64
  ) {
    self.id = id
    self.identity = identity
    self.profileURL = profileURL
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.pinnedRank = pinnedRank
    self.savedWorkCount = savedWorkCount
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }

  public var listingTitle: String {
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? CreatorDisplay.placeholderName(platform: identity.platform) : name
  }

  public var hasResolvedDisplayName: Bool {
    CreatorDisplay.isResolvedDisplayName(displayName, authorID: identity.authorID)
  }

  /// Directory copy: a real display name, or 平台名 + 主页地址. Never a bare @handle.
  ///
  /// 2026-10-01 走查：没名字的博主卡原来写「待获取」，一排卡片全是同一个词，分不出谁是谁，
  /// 也不知道要等什么。改成「抖音 · douyin.com/user/MS4w…」：认得出是哪个平台、哪个主页。
  public var directoryDisplayName: String {
    hasResolvedDisplayName
      ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
      : CreatorDisplay.unnamedDirectoryTitle(platform: identity.platform, profileURL: profileURL)
  }

  public var isPinned: Bool { pinnedRank != nil }
}

public enum CreatorDisplay {
  public static let maximumPinnedCount = 5

  public static func placeholderName(platform: String) -> String {
    switch HistoryPlatformRegistry.canonicalHost(for: platform) {
    case "douyin.com": return "未命名抖音博主"
    default: return "未命名博主"
    }
  }

  /// 没有真名时的目录标题。
  ///
  /// 原来是「平台名 · 主页地址」，卡片里只放得下「哔哩哔哩 · space.bi…」，截掉的
  /// 正好是能认出这个人的那一段（2026-10-01 走查）。现在只取主页地址最后一段：
  /// 短的当账号显示（X 写成 @账号，其它平台写「平台博主 账号」）；抖音那种几十位的
  /// 加密 ID、B 站的纯数字 UID 人认不出来，直接说「未命名…博主」。
  public static func unnamedDirectoryTitle(platform: String, profileURL: String, maxAccountLength: Int = 12) -> String {
    let platformName = HistoryPlatformDisplay.shortName(forHost: platform)
    let host = HistoryPlatformRegistry.canonicalHost(for: platform)
    if host == "douyin.com" { return placeholderName(platform: platform) }
    // 中英文之间空一格：「未命名 B 站博主」「Reddit 博主 spez」。
    let creatorLabel = platformName.unicodeScalars.last?.isASCII == true ? "\(platformName) 博主" : "\(platformName)博主"
    let fallback = platformName.unicodeScalars.first?.isASCII == true ? "未命名 \(creatorLabel)" : "未命名\(creatorLabel)"
    guard let components = URLComponents(string: profileURL.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return fallback }
    // 取第一段像账号的：B 站主页常是 space.bilibili.com/12345/video，取最后一段会得到
    // 「video」；YouTube 是 /@name/videos。前缀段（user、channel…）跳过。
    let generic: Set<String> = ["user", "u", "space", "profile", "people", "channel", "c", "home"]
    let account = components.path.split(separator: "/").map(String.init)
      .first { !generic.contains($0.lowercased()) } ?? ""
    let readable = account.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "_-.@".unicodeScalars.contains($0)
    }
    // 纯数字的 UID（B 站常见）人认不出，卡片里还会被截断，不如直说没拿到名字。
    let isNumericID = account.allSatisfy(\.isNumber)
    guard !account.isEmpty, account.count <= maxAccountLength, readable, !isNumericID else { return fallback }
    if host == "x.com", !account.hasPrefix("@") { return "@\(account)" }
    if account.hasPrefix("@") { return account }
    return "\(creatorLabel) \(account)"
  }

  public static func isResolvedDisplayName(_ raw: String?, authorID: String) -> Bool {
    let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !name.isEmpty else { return false }
    let stripped = name.hasPrefix("@") ? String(name.dropFirst()) : name
    let author = authorID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !author.isEmpty else { return true }
    return stripped.caseInsensitiveCompare(author) != .orderedSame
  }
}

public struct UpsertCreatorCommand: Sendable, Equatable {
  public let identity: CreatorIdentity
  public let profileURL: String
  public let displayName: String?
  public let avatarURL: String?
  public let nowMilliseconds: Int64

  public init?(
    identity: CreatorIdentity,
    profileURL: String,
    displayName: String?,
    avatarURL: String? = nil,
    nowMilliseconds: Int64
  ) {
    let url = profileURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty, url.count <= 2048 else { return nil }
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name, name.count > 80 { return nil }
    let avatar = Self.normalizedAvatarURL(avatarURL)
    if avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, avatar == nil {
      return nil
    }
    self.identity = identity
    self.profileURL = url
    self.displayName = (name?.isEmpty == false) ? name : nil
    self.avatarURL = avatar
    self.nowMilliseconds = nowMilliseconds
  }

  private static func normalizedAvatarURL(_ raw: String?) -> String? {
    let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty, value.count <= 2048, let url = URL(string: value) else { return nil }
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
    return value
  }
}

public struct AttachCreatorWorksResult: Sendable, Equatable {
  public let attachedTaskIDs: [TaskID]
  public let unmatchedCanonicalURLs: [String]

  public init(attachedTaskIDs: [TaskID] = [], unmatchedCanonicalURLs: [String] = []) {
    self.attachedTaskIDs = attachedTaskIDs
    self.unmatchedCanonicalURLs = unmatchedCanonicalURLs
  }
}

public struct CreatorPageCursor: Sendable, Equatable {
  /// Nil means the unpinned group. The page is ordered pinned-first by rank,
  /// then unpinned by recency, so the cursor must carry pin state.
  public let pinnedRank: Int?
  public let updatedAtMilliseconds: Int64
  public let creatorID: CreatorID
  public init(pinnedRank: Int?, updatedAtMilliseconds: Int64, creatorID: CreatorID) {
    self.pinnedRank = pinnedRank
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.creatorID = creatorID
  }
}

public struct CreatorPage: Sendable, Equatable {
  public let rows: [CreatorSummary]
  public let nextCursor: CreatorPageCursor?
  public init(rows: [CreatorSummary], nextCursor: CreatorPageCursor?) {
    self.rows = rows
    self.nextCursor = nextCursor
  }
}
