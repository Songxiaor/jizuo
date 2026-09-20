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
