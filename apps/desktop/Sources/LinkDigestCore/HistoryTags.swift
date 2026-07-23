import Foundation

/// A small, local-only label attached to a history task. `name` preserves the
/// first accepted spelling for display; `normalizedName` is the stable
/// case-insensitive key used by persistence and SQL filtering.
public struct HistoryTag: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let name: String
  public let normalizedName: String

  public var id: String { normalizedName }

  public init?(rawValue: String) {
    guard let value = HistoryTagNormalizer.normalized(rawValue) else { return nil }
    name = value.name
    normalizedName = value.normalizedName
  }

  public init(name: String, normalizedName: String) {
    self.name = name
    self.normalizedName = normalizedName
  }
}

/// One query value for the history board. Tags and free-text search are
/// deliberately independent so both are evaluated in SQLite, never by
/// filtering an already-loaded in-memory page.
public enum HistoryListScope: String, Sendable, Equatable, CaseIterable {
  case all
  case recent
  case unsummarized
}

/// The small navigation rail is fed by database aggregation, not by a loaded
/// list page. A platform is its normalized host because that is the stable
/// cross-language value used by both the Swift UI and SQLite filters.
public struct HistoryNavigationPlatform: Sendable, Equatable, Identifiable {
  public let host: String
  public let count: Int
  public var id: String { host }
  public init(host: String, count: Int) { self.host = host; self.count = count }
}

public struct HistoryNavigationTag: Sendable, Equatable, Identifiable {
  public let tag: HistoryTag
  public let count: Int
  public var id: String { tag.normalizedName }
  public init(tag: HistoryTag, count: Int) { self.tag = tag; self.count = count }
}

public struct HistoryNavigationCounts: Sendable, Equatable {
  public let all: Int
  public let recent: Int
  public let unsummarized: Int
  public let platforms: [HistoryNavigationPlatform]
  public let tags: [HistoryNavigationTag]
  public init(
    all: Int = 0,
    recent: Int = 0,
    unsummarized: Int = 0,
    platforms: [HistoryNavigationPlatform] = [],
    tags: [HistoryNavigationTag] = []
  ) {
    self.all = all
    self.recent = recent
    self.unsummarized = unsummarized
    self.platforms = platforms
    self.tags = tags
  }
}

/// 平台是"内容从哪来"的系统维度：侧边栏显示人类可读的中文平台名，
/// 未收录的 host 回退为去 www 的域名本身。
public enum HistoryPlatformDisplay {
  public static func name(forHost rawHost: String) -> String {
    let host = HistoryHostNormalizer.normalized(rawHost)
    switch host {
    case "douyin.com", "iesdouyin.com", "v.douyin.com": return "抖音"
    case "mp.weixin.qq.com", "weixin.qq.com": return "微信公众号"
    case "github.com": return "GitHub"
    case "x.com", "twitter.com": return "X"
    case "youtube.com", "youtu.be": return "YouTube"
    case "bilibili.com", "b23.tv": return "哔哩哔哩"
    case "xiaohongshu.com", "xhslink.com": return "小红书"
    case "zhihu.com", "zhuanlan.zhihu.com": return "知乎"
    case "weibo.com": return "微博"
    case "medium.com": return "Medium"
    case "reddit.com": return "Reddit"
    default: return host.isEmpty ? rawHost : host
    }
  }

  /// 命中品牌映射的算公共平台；其余杂项来源在侧边栏聚合为"待分类"。
  public static func isWellKnown(host rawHost: String) -> Bool {
    let normalized = HistoryHostNormalizer.normalized(rawHost)
    guard !normalized.isEmpty else { return false }
    return name(forHost: rawHost) != normalized
  }
}

public enum HistoryHostNormalizer {
  public static func normalized(_ rawHost: String) -> String {
    var value = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
    if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
    for prefix in ["www.", "www2.", "m.", "mobile.", "amp."] where value.hasPrefix(prefix) {
      value.removeFirst(prefix.count)
      break
    }
    return value
  }
}

public struct HistoryListFilter: Sendable, Equatable {
  public let tagNormalizedNames: [String]
  public let hosts: [String]
  public let scope: HistoryListScope
  public let searchText: String

  public init(
    tagNames: [String] = [],
    hosts: [String] = [],
    scope: HistoryListScope = .all,
    searchText: String = ""
  ) {
    var seen = Set<String>()
    tagNormalizedNames = tagNames.compactMap { HistoryTagNormalizer.normalized($0)?.normalizedName }
      .filter { seen.insert($0).inserted }
    var seenHosts = Set<String>()
    self.hosts = hosts.map(HistoryHostNormalizer.normalized)
      .filter { !$0.isEmpty && seenHosts.insert($0).inserted }
    self.scope = scope
    self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static let none = HistoryListFilter()
}

public enum HistoryTagNormalizer {
  public static let maximumCharacterCount = 20
  public static let maximumTagsPerTask = 10
  public static let maximumAutomaticTags = 5

  public static func normalized(_ rawValue: String) -> HistoryTag? {
    let display = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !display.isEmpty,
      display.count <= maximumCharacterCount,
      !display.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      // Reject punctuation-only noise from empty model lines such as "," or "、".
      display.contains(where: { $0.isLetter || $0.isNumber })
    else {
      return nil
    }
    let normalized = display.precomposedStringWithCanonicalMapping.lowercased()
    guard !normalized.isEmpty else { return nil }
    return HistoryTag(name: display, normalizedName: normalized)
  }

  /// Parses the tag model's constrained response. Prefers the first line of
  /// comma-separated labels, then falls back to multi-line / bullet lists and
  /// common Chinese separators so slight format drift does not empty the UI.
  public static func automaticTags(from response: String) -> [HistoryTag] {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let rawLines = trimmed.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    let strippedLines = rawLines.map(stripListMarker).filter { !$0.isEmpty }

    // When the whole response is a bullet/numbered list, treat each line as a tag.
    if rawLines.count >= 2, rawLines.allSatisfy(looksLikeListItem) {
      let fromBullets = normalizedTags(strippedLines, limit: maximumAutomaticTags)
      if !fromBullets.isEmpty { return fromBullets }
    }

    let firstLine = stripListMarker(rawLines.first ?? trimmed)
    let fromFirstLine = normalizedTags(splitTagCandidates(firstLine), limit: maximumAutomaticTags)
    if !fromFirstLine.isEmpty { return fromFirstLine }

    let fromWhole = normalizedTags(splitTagCandidates(trimmed), limit: maximumAutomaticTags)
    if !fromWhole.isEmpty { return fromWhole }

    return normalizedTags(strippedLines, limit: maximumAutomaticTags)
  }

  /// Platform names that used to be attached as automatic tags. The sidebar
  /// already lists platforms first-class, so navigation hides these legacy
  /// duplicates instead of showing them beside the 平台 section.
  public static let platformSynonymNormalizedNames: Set<String> = Set(
    ["公众号", "X", "GitHub", "抖音"].compactMap { normalized($0)?.normalizedName }
  )

  /// Local, deterministic labels used when the model tag call fails open or
  /// returns nothing parseable. Only attaches strong platform / gate signals
  /// already visible in the summary — never a generic “总结” filler.
  public static func fallbackTags(from summary: String, limit: Int = 3) -> [HistoryTag] {
    guard limit > 0 else { return [] }
    let text = summary
    var raw: [String] = []
    if text.contains("微信") || text.contains("公众号") || text.contains("公众平台") {
      raw.append("微信")
    }
    if text.contains("环境异常") || text.contains("完成验证") || text.contains("验证页面") || text.contains("人机验证") {
      raw.append("需验证")
    }
    if text.range(of: #"GitHub|github\.com"#, options: .regularExpression) != nil {
      raw.append("GitHub")
    }
    if text.contains("知乎") { raw.append("知乎") }
    if text.range(of: #"\bX\b|Twitter|twitter\.com|x\.com"#, options: .regularExpression) != nil {
      raw.append("X")
    }
    if text.contains("YouTube") || text.contains("youtube") { raw.append("YouTube") }
    return normalizedTags(raw, limit: limit)
  }

  public static func normalizedTags(_ rawValues: [String], limit: Int = maximumTagsPerTask) -> [HistoryTag] {
    guard limit > 0 else { return [] }
    var seen = Set<String>()
    var result: [HistoryTag] = []
    for rawValue in rawValues {
      guard let tag = normalized(rawValue), seen.insert(tag.normalizedName).inserted else { continue }
      result.append(tag)
      if result.count == limit { break }
    }
    return result
  }

  private static func splitTagCandidates(_ value: String) -> [String] {
    value
      .replacingOccurrences(of: "、", with: ",")
      .replacingOccurrences(of: "，", with: ",")
      .replacingOccurrences(of: ";", with: ",")
      .replacingOccurrences(of: "；", with: ",")
      .replacingOccurrences(of: "|", with: ",")
      .replacingOccurrences(of: "｜", with: ",")
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .map { candidate in
        var value = stripListMarker(candidate)
        // Strip wrapping quotes the model sometimes adds: `"标签"` / 「标签」
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
          value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("「") && value.hasSuffix("」") {
          value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
  }

  private static func looksLikeListItem(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let expression = try? NSRegularExpression(pattern: #"^([-*•]|\d+[\.、\)])\s+\S"#) else {
      return false
    }
    return expression.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
  }

  private static func stripListMarker(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let expression = try? NSRegularExpression(pattern: #"^([-*•]|\d+[\.、\)])\s+"#) else {
      return result
    }
    result = expression.stringByReplacingMatches(
      in: result,
      range: NSRange(result.startIndex..., in: result),
      withTemplate: ""
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
