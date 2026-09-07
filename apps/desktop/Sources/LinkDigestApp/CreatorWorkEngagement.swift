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
    case .views: return platform == "bilibili.com" ? "播放" : "浏览"
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
    case "bilibili.com":
      return [.views, .likes, .comments, .collects, .shares]
    case "xiaohongshu.com":
      return [.likes, .comments, .collects, .shares]
    default:
      return [.likes, .comments, .collects]
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
    ["x.com", "douyin.com", "xiaohongshu.com", "bilibili.com"].contains(HistoryPlatformRegistry.canonicalHost(for: host))
  }

  /// Card and reader use the same platform order; compact cards keep one row.
  static func rows(forHost host: String) -> [[CreatorWorkMetricKind]] {
    let slots = slots(forHost: host)
    if usesAdaptiveWorkGrid(host) { return [slots] }
    if slots.count <= 3 { return [slots] }
    let mid = (slots.count + 1) / 2
    return [Array(slots.prefix(mid)), Array(slots.dropFirst(mid))]
  }

  static func displayValue(_ raw: String?) -> (visible: String, accessibility: String) {
    guard let raw else {
      return ("—", "尚未读取")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return ("—", "尚未读取")
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
    case "bilibili.com": return "稿件"
    default: return "文字"
    }
  }

  static func headline(capturedTitle: String, preview: String, host: String, hasCover: Bool) -> String {
    let trimmed = capturedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let missing = trimmed.isEmpty || trimmed == CapturedDocumentTitle.missing
    if hasCover {
      return missing ? contentKind(host: host) : capturedTitle
    }
    if isIndependentTitle(capturedTitle, preview: preview) { return capturedTitle }
    return contentKind(host: host)
  }
}
