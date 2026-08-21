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
  case favorite
  /// 用户自己写的笔记。
  ///
  /// 它是**独立区域**，不是一个筛选条件：除了 `.notes` 自己，其余所有作用域都把笔记
  /// 排除在外。抓来的资料和自己写的东西混在一张列表里，找素材时会被自己的草稿打断，
  /// 写东西时又要在一堆网页里翻——两件事的心智完全不同。
  ///
  /// 底层仍与抓取记录共用同一张表，所以标签、搜索、导出、翻译一概照常可用。
  case notes

  /// 工作台里的稿件。它属于「过程」,不该出现在任何浏览列表里——
  /// 稿子是从某件创作里打开的,不是从列表里翻出来的。
  case drafts

  /// 输出:已完成的作品。这是三个模块里的第三个,装的是「我做出来的东西」。
  case works

  /// 该作用域是否只看笔记。
  public var isNotesOnly: Bool { self == .notes }
  /// 该作用域是否只看稿件。
  public var isDraftsOnly: Bool { self == .drafts }
  /// 该作用域是否只看成品。
  public var isWorksOnly: Bool { self == .works }
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
  public let favorite: Int
  /// 用户自己写的笔记条数。默认 0，让既有构造点无需改动。
  public let notes: Int
  /// 已完成的作品数。
  public let works: Int
  public let platforms: [HistoryNavigationPlatform]
  /// 可变，好让调用方就地筛掉不想展示的标签。
  ///
  /// 原先 UI 层要过滤标签只能整个重建一遍这个结构体，而 `init` 的每个参数都有
  /// 默认值——漏写一个字段不会报错，只会悄悄变成 0。侧边栏「我的笔记」长期显示
  /// 0 就是这么来的。留一个可变字段，过滤就不再需要重建。
  public var tags: [HistoryNavigationTag]
  public init(
    all: Int = 0,
    recent: Int = 0,
    unsummarized: Int = 0,
    favorite: Int = 0,
    notes: Int = 0,
    works: Int = 0,
    platforms: [HistoryNavigationPlatform] = [],
    tags: [HistoryNavigationTag] = []
  ) {
    self.all = all
    self.recent = recent
    self.unsummarized = unsummarized
    self.favorite = favorite
    self.notes = notes
    self.works = works
    self.platforms = platforms
    self.tags = tags
  }
}

/// One source of truth for platform identity across navigation, filtering and
/// bundled icon lookup. `canonicalHost` is a stable platform key; it is usually
/// a domain, but may represent a family such as Discourse whose installations
/// live on different domains.
public struct HistoryPlatformDescriptor: Sendable, Equatable {
  public let canonicalHost: String
  public let displayName: String
  public let exactHosts: [String]
  public let suffixHosts: [String]
  public let bundledAssetName: String?

  public init(
    canonicalHost: String,
    displayName: String,
    exactHosts: [String],
    suffixHosts: [String] = [],
    bundledAssetName: String? = nil
  ) {
    self.canonicalHost = canonicalHost
    self.displayName = displayName
    self.exactHosts = exactHosts
    self.suffixHosts = suffixHosts
    self.bundledAssetName = bundledAssetName
  }
}

public enum HistoryPlatformRegistry {
  /// Keep aliases, display names and bundled assets together. Adding a source
  /// in multiple switches made the sidebar name, filter and icon drift apart.
  public static let platforms: [HistoryPlatformDescriptor] = [
    .init(canonicalHost: "douyin.com", displayName: "抖音", exactHosts: ["douyin.com", "iesdouyin.com", "v.douyin.com"], bundledAssetName: "douyin"),
    .init(canonicalHost: "mp.weixin.qq.com", displayName: "微信公众号", exactHosts: ["mp.weixin.qq.com", "weixin.qq.com"], bundledAssetName: "wechat"),
    .init(canonicalHost: "github.com", displayName: "GitHub", exactHosts: ["github.com"], bundledAssetName: "github"),
    .init(canonicalHost: "x.com", displayName: "X", exactHosts: ["x.com", "twitter.com"], bundledAssetName: "x.com"),
    .init(canonicalHost: "youtube.com", displayName: "YouTube", exactHosts: ["youtube.com", "youtu.be"], bundledAssetName: "youtube"),
    .init(canonicalHost: "bilibili.com", displayName: "哔哩哔哩", exactHosts: ["bilibili.com", "b23.tv"], bundledAssetName: "bilibili"),
    .init(canonicalHost: "xiaohongshu.com", displayName: "小红书", exactHosts: ["xiaohongshu.com", "xhslink.com"], bundledAssetName: "xiaohongshu"),
    .init(canonicalHost: "zhihu.com", displayName: "知乎", exactHosts: ["zhihu.com", "zhuanlan.zhihu.com"], bundledAssetName: "zhihu"),
    .init(canonicalHost: "weibo.com", displayName: "微博", exactHosts: ["weibo.com", "weibo.cn"], bundledAssetName: "weibo"),
    .init(canonicalHost: "medium.com", displayName: "Medium", exactHosts: ["medium.com"], bundledAssetName: "medium"),
    .init(canonicalHost: "reddit.com", displayName: "Reddit", exactHosts: ["reddit.com"], bundledAssetName: "reddit"),
    .init(canonicalHost: "toutiao.com", displayName: "今日头条", exactHosts: ["toutiao.com"], bundledAssetName: "toutiao"),
    .init(canonicalHost: "douban.com", displayName: "豆瓣", exactHosts: ["douban.com"], bundledAssetName: "douban"),
    .init(canonicalHost: "juejin.cn", displayName: "掘金", exactHosts: ["juejin.cn"], bundledAssetName: "juejin"),
    .init(canonicalHost: "substack.com", displayName: "Substack", exactHosts: ["substack.com"], suffixHosts: ["substack.com"]),
    .init(canonicalHost: "news.ycombinator.com", displayName: "Hacker News", exactHosts: ["news.ycombinator.com"]),
    .init(canonicalHost: "v2ex.com", displayName: "V2EX", exactHosts: ["v2ex.com"]),
    .init(canonicalHost: "stackoverflow.com", displayName: "Stack Overflow", exactHosts: ["stackoverflow.com"]),
    .init(canonicalHost: "dev.to", displayName: "dev.to", exactHosts: ["dev.to"]),
    .init(canonicalHost: "discourse", displayName: "Discourse", exactHosts: ["linux.do", "uscardforum.com"]),
    .init(canonicalHost: "lemmy.world", displayName: "Lemmy", exactHosts: ["lemmy.world"]),
    .init(canonicalHost: "mastodon.social", displayName: "Mastodon", exactHosts: ["mastodon.social"]),
  ]

  public static func descriptor(forHost rawHost: String) -> HistoryPlatformDescriptor? {
    let host = HistoryHostNormalizer.normalized(rawHost)
    guard !host.isEmpty else { return nil }
    if let exact = platforms.first(where: { $0.canonicalHost == host || $0.exactHosts.contains(host) }) { return exact }
    return platforms.first { platform in
      platform.suffixHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
  }

  public static func canonicalHost(for rawHost: String) -> String {
    let normalized = HistoryHostNormalizer.normalized(rawHost)
    return descriptor(forHost: normalized)?.canonicalHost ?? normalized
  }

  public static func displayName(forHost rawHost: String) -> String? {
    descriptor(forHost: rawHost)?.displayName
  }

  public static func bundledAssetName(forHost rawHost: String) -> String? {
    descriptor(forHost: rawHost)?.bundledAssetName
  }
}

/// 平台是"内容从哪来"的系统维度：侧边栏显示人类可读的中文平台名，
/// 未收录的 host 回退为去 www 的域名本身。
public enum HistoryPlatformDisplay {
  /// 用户自建笔记在侧边栏的归属。
  ///
  /// 笔记的 canonical URL 是 `linkdigest-note:<uuid>`，**没有 `://`**，而 host 是靠
  /// `instr(url, '://')` 从 URL 里切出来的——不特殊处理的话会切出一段乱码，笔记会以
  /// 一个无意义的"域名"落进侧边栏的「待分类」。
  ///
  /// 给它一个稳定的合成 host，既让筛选、计数复用现有那一套（零新增导航代码），也让
  /// 它以「我的笔记」出现在平台列表里。
  public static let noteHost = "note"
  /// 与 `CanonicalURL.noteScheme` 对应的 URL 前缀，SQL 侧靠它识别笔记。
  public static let noteURLPrefix = "linkdigest-note:"

  /// 工作台稿件的合成 host 与 URL 前缀,理由同上。
  public static let draftHost = "draft"
  public static let draftURLPrefix = "linkdigest-draft:"

  /// 成品所在的输出区。
  public static let workHost = "work"

  /// 杂项来源在侧栏网格里的那一格。
  ///
  /// 不是真实域名——它代表「所有不常见来源」的聚合，点它等于同时选中一批
  /// host。用下划线包起来是为了和真实域名区分开：域名不会以下划线开头。
  public static let miscHost = "__misc__"
  public static let workURLPrefix = "linkdigest-work:"

  public static func name(forHost rawHost: String) -> String {
    if rawHost == miscHost { return "待分类" }
    if rawHost == noteHost { return "我的笔记" }
    if rawHost == draftHost { return "工作台稿件" }
    if rawHost == workHost { return "我的作品" }
    let host = HistoryHostNormalizer.normalized(rawHost)
    return HistoryPlatformRegistry.displayName(forHost: host) ?? (host.isEmpty ? rawHost : host)
  }

  /// 命中品牌映射的算公共平台；其余杂项来源在侧边栏聚合为"待分类"。
  public static func isWellKnown(host rawHost: String) -> Bool {
    let normalized = HistoryHostNormalizer.normalized(rawHost)
    guard !normalized.isEmpty else { return false }
    if [noteHost, draftHost, workHost].contains(normalized) { return true }
    return HistoryPlatformRegistry.descriptor(forHost: normalized) != nil
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
    self.hosts = hosts.map(HistoryPlatformRegistry.canonicalHost)
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

/// 总结末行的标签尾标：跟摘要同一次生成，不再另打一趟请求。
///
/// 模型按提示在最后一行写 `TAGS: a, b`。展示和落库都剥掉这一行，避免标签混进正文。
public enum SummaryTagTrailer {
  public static let marker = "TAGS:"

  public static func split(_ text: String) -> (body: String, tags: [HistoryTag]) {
    let visible = visibleBody(text)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let lastBreak = trimmed.lastIndex(where: \.isNewline) else { return (text, []) }
    let lastLine = trimmed[trimmed.index(after: lastBreak)...]
      .trimmingCharacters(in: .whitespaces)
    guard lastLine.hasPrefix(marker) else { return (text, []) }
    let raw = String(lastLine.dropFirst(marker.count))
    return (visible, HistoryTagNormalizer.automaticTags(from: raw))
  }

  /// 流式过程中，最后一行一旦开始像尾标就先藏起来，避免 `TAGS` 几个字母闪进正文。
  public static func visibleBody(_ text: String) -> String {
    guard let lastBreak = text.lastIndex(where: \.isNewline) else { return text }
    let lastLine = text[text.index(after: lastBreak)...]
      .trimmingCharacters(in: .whitespaces)
    guard !lastLine.isEmpty else { return text }
    let isComplete = lastLine.hasPrefix(marker)
    let isPrefix = marker.hasPrefix(lastLine)
    guard isComplete || isPrefix else { return text }
    return String(text[..<lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
