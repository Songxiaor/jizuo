import Foundation
import LinkDigestCore

enum CreatorWorkMetricKind: String, CaseIterable, Equatable {
  case likes
  case comments
  case shares
  case collects
  case views

  func title(forHost host: String) -> String {
    let platform = HistoryPlatformRegistry.canonicalHost(for: host)
    switch self {
    case .likes: return "点赞"
    case .comments: return platform == "x.com" ? "回复" : "评论"
    case .shares:
      if platform == "x.com" { return "转帖" }
      if platform == "douyin.com" { return "转发" }
      return "分享"
    case .collects: return platform == "x.com" ? "书签" : "收藏"
    case .views:
      if platform == "bilibili.com" { return "播放" }
      if platform == "mp.weixin.qq.com" { return "阅读" }
      return "浏览"
    }
  }

  var systemImage: String {
    switch self {
    case .likes: return "heart"
    case .comments: return "bubble.right"
    case .shares: return "arrowshape.turn.up.right"
    case .collects: return "bookmark"
    case .views: return "eye"
    }
  }

  func value(from row: HistoryRowProjection) -> String? {
    switch self {
    case .likes: return row.likes
    case .comments: return row.comments
    case .shares: return row.shares
    case .collects: return row.collects
    case .views: return row.views
    }
  }
  func value(from note: MarkdownNoteFrontmatter) -> String? {
    switch self {
    case .likes: return note.likes
    case .comments: return note.comments
    case .shares: return note.shares
    case .collects: return note.collects
    case .views: return note.views
    }
  }

}

enum CreatorWorkMetricLayout {
  static func slots(forHost host: String) -> [CreatorWorkMetricKind] {
    switch HistoryPlatformRegistry.canonicalHost(for: host) {
    case "douyin.com":
      return [.likes, .comments, .collects, .shares]
    case "x.com":
      return [.likes, .comments, .shares, .collects, .views]
    case "bilibili.com", "youtube.com":
      return [.views, .likes, .comments, .collects, .shares]
    case "xiaohongshu.com":
      return [.likes, .comments, .collects, .shares]
    case "mp.weixin.qq.com":
      return []
    default:
      return []
    }
  }

  static func isX(_ host: String) -> Bool {
    HistoryPlatformRegistry.canonicalHost(for: host) == "x.com"
  }

  static func isDouyin(_ host: String) -> Bool {
    HistoryPlatformRegistry.canonicalHost(for: host) == "douyin.com"
  }

  /// Social works share a responsive 2–4 column grid.
  static func usesAdaptiveWorkGrid(_ host: String) -> Bool {
    // All source-platform galleries share the same responsive column math.
    true
  }

  /// Card and reader use the same platform order; compact cards keep one row.
  static func rows(forHost host: String) -> [[CreatorWorkMetricKind]] {
    let slots = slots(forHost: host)
    if usesAdaptiveWorkGrid(host) { return [slots] }
    if slots.count <= 3 { return [slots] }
    let mid = (slots.count + 1) / 2
    return [Array(slots.prefix(mid)), Array(slots.dropFirst(mid))]
  }

  /// Card and reader use the same platform order; compact cards keep one row.
  /// Missing metrics stay hidden (no "—" filler). Real zero remains visible.
  /// WeChat and non-social sites do not force like/collect rows.
  static func visibleSlots(
    forHost host: String,
    values: (CreatorWorkMetricKind) -> String?
  ) -> [CreatorWorkMetricKind] {
    let platform = HistoryPlatformRegistry.canonicalHost(for: host)
    if platform == "mp.weixin.qq.com" { return [] }
    if !showsEngagementMetrics(forHost: platform) { return [] }
    return slots(forHost: host).filter { slot in
      guard let raw = values(slot) else { return false }
      return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// Social / video platforms may show engagement; articles and generic sites do not.
  static func showsEngagementMetrics(forHost host: String) -> Bool {
    switch HistoryPlatformRegistry.canonicalHost(for: host) {
    case "x.com", "douyin.com", "xiaohongshu.com", "bilibili.com", "youtube.com":
      return true
    default:
      return false
    }
  }

  static func displayValue(_ raw: String?) -> (visible: String, accessibility: String) {
    guard let raw else {
      return ("—", "未获取")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return ("—", "未获取")
    }
    return (HistoryEngagementCount.compact(trimmed), trimmed)
  }
}

enum CreatorDirectoryChrome {
  static let listColumnMin: CGFloat = 260
  static let listColumnIdeal: CGFloat = 270
  static let listColumnMax: CGFloat = 270
  static let xCardMinimumWidth: CGFloat = 230
  static let xGridSpacing: CGFloat = 10
  static let xGridHorizontalPadding: CGFloat = 24

  /// Works-pane width in, column count out. Padding 24 and gap 10 are deducted first.
  /// 2–4 columns in normal widths; one column when the pane is too narrow for two cards.
  static func xColumnCount(availableWidth: CGFloat) -> Int {
    let inner = max(0, availableWidth - xGridHorizontalPadding) + xGridSpacing
    let raw = Int(floor(inner / (xCardMinimumWidth + xGridSpacing)))
    return min(4, max(1, raw))
  }
}

enum CreatorDirectorySurfaceState: Equatable {
  case catalog
  case works
  case reader

  static func resolve(
    showsCatalog: Bool,
    hasSelectedCreator: Bool,
    isReading: Bool
  ) -> Self {
    if isReading { return .reader }
    if showsCatalog || !hasSelectedCreator { return .catalog }
    return .works
  }
}

enum CreatorDirectoryCardCopy {
  static func normalizeForCompare(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let suffixes = ["……", "...", "…"]
    var stripped = true
    while stripped {
      stripped = false
      for suffix in suffixes where text.hasSuffix(suffix) {
        text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        stripped = true
      }
    }
    return text
  }

  /// True only when the stored title is not the body (or a truncated/prefix slice of it).
  static func isIndependentTitle(_ title: String, preview: String) -> Bool {
    let headline = normalizeForCompare(title)
    let body = normalizeForCompare(preview)
    if headline.isEmpty || headline == CapturedDocumentTitle.missing { return false }
    if body.isEmpty { return true }
    if headline == body { return false }
    if body.hasPrefix(headline) || headline.hasPrefix(body) { return false }
    return true
  }

  static func contentKind(host: String) -> String {
    switch HistoryPlatformRegistry.canonicalHost(for: host) {
    case "x.com": return "帖子"
    case "douyin.com": return "作品"
    case "xiaohongshu.com": return "笔记"
    case "bilibili.com", "youtube.com": return "视频"
    case "mp.weixin.qq.com", "substack.com": return "文章"
    case "github.com": return "仓库"
    case "reddit.com", "discourse": return "讨论"
    default: return "内容"
    }
  }

  /// Author / site identity line. Never invent; never use platform name as author.
  static func authorLine(row: HistoryRowProjection) -> String? {
    if let author = row.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
      return author
    }
    let host = HistoryPlatformRegistry.canonicalHost(for: row.host)
    switch host {
    case "mp.weixin.qq.com":
      return "作者未获取"
    case "github.com":
      return siteIdentity(row) ?? "GitHub"
    case "substack.com":
      return siteIdentity(row) ?? "刊物未获取"
    case "discourse", "reddit.com":
      return siteIdentity(row) ?? "社区未获取"
    default:
      if HistoryPlatformDisplay.isWellKnown(host: host) {
        return nil
      }
      return siteIdentity(row)
    }
  }

  /// Site / host identity for cards. Never use `sourceLabel` — that is the capture
  /// channel (e.g. "GitHub 公开仓库 README"), not author or publication name.
  static func siteIdentity(_ row: HistoryRowProjection) -> String? {
    if let host = URLComponents(string: row.canonicalURL)?.host {
      let normalized = HistoryHostNormalizer.normalized(host)
      if !normalized.isEmpty { return normalized }
    }
    let host = row.host.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty { return nil }
    let normalized = HistoryHostNormalizer.normalized(host)
    return normalized.isEmpty ? nil : normalized
  }

  /// Card title line. `nil` means omit — used when the cover slot already shows the same body preview.
  static func headline(
    capturedTitle: String,
    preview: String,
    host: String,
    hasCover: Bool,
    showsBodyPreview: Bool = false
  ) -> String? {
    let trimmed = capturedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let missing = trimmed.isEmpty || trimmed == CapturedDocumentTitle.missing
    if hasCover {
      return missing ? contentKind(host: host) : capturedTitle
    }
    if isIndependentTitle(capturedTitle, preview: preview) { return capturedTitle }
    // No independent title: body preview already carries the text — don't repeat a truncated copy.
    if showsBodyPreview { return nil }
    // Cover slot is a status placeholder, not body text — keep a kind label so the card isn't empty.
    return contentKind(host: host)
  }
}
