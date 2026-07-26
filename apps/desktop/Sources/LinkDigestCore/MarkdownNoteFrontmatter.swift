import Foundation

/// Tolaria/Obsidian-style YAML frontmatter at the start of a capture body.
/// Intentionally small: only fields we surface in the reading properties strip.
public struct MarkdownNoteFrontmatter: Sendable, Equatable {
  public var accountName: String?
  public var author: String?
  public var published: String?
  public var coverImage: String?
  /// Parsed for backward compatibility with older captures; UI no longer surfaces it.
  public var description: String?
  /// Douyin/social engagement stats extracted from __INITIAL_STATE__ or DOM.
  public var likes: String?
  public var comments: String?
  public var shares: String?
  public var collects: String?
  /// YouTube 观看数等播放量口径。
  public var views: String?
  public var body: String

  public init(
    accountName: String? = nil,
    author: String? = nil,
    published: String? = nil,
    coverImage: String? = nil,
    description: String? = nil,
    likes: String? = nil,
    comments: String? = nil,
    shares: String? = nil,
    collects: String? = nil,
    views: String? = nil,
    body: String
  ) {
    self.accountName = accountName
    self.author = author
    self.published = published
    self.coverImage = coverImage
    self.description = description
    self.likes = likes
    self.comments = comments
    self.shares = shares
    self.collects = collects
    self.views = views
    self.body = body
  }

  public var hasProperties: Bool {
    // description is intentionally excluded from the reading strip (SEO blurbs).
    accountName != nil || author != nil || published != nil || coverImage != nil
  }

  public var hasEngagementStats: Bool {
    likes != nil || comments != nil || shares != nil || collects != nil || views != nil
  }

  /// Parses a leading `---` … `---` block. Invalid/incomplete frontmatter returns the original text as body.
  public static func parse(_ markdown: String) -> MarkdownNoteFrontmatter {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("---\n") || normalized == "---" else {
      return .init(body: markdown)
    }
    let rest = normalized.dropFirst(4)
    guard let endRange = rest.range(of: "\n---") else {
      return .init(body: markdown)
    }
    let yaml = String(rest[..<endRange.lowerBound])
    var body = String(rest[endRange.upperBound...])
    if body.hasPrefix("\n") { body = String(body.dropFirst()) }
    var accountName: String?
    var author: String?
    var published: String?
    var coverImage: String?
    var description: String?
    var likes: String?
    var views: String?
    var comments: String?
    var shares: String?
    var collects: String?
    for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
          .replacingOccurrences(of: "\\\"", with: "\"")
      }
      guard !value.isEmpty else { continue }
      switch key {
      case "account_name": accountName = value
      case "author": author = value
      case "published": published = value
      case "cover_image": coverImage = value
      case "description": description = value
      case "likes": likes = value
      case "comments": comments = value
      case "replies":
        // Older X captures used extractor-specific names. Keep them readable
        // while new captures serialize the shared social field names.
        if comments == nil { comments = value }
      case "shares": shares = value
      case "reposts":
        if shares == nil { shares = value }
      case "collects": collects = value
      case "views": views = value
      default: break
      }
    }
    return .init(
      accountName: accountName,
      author: author,
      published: published,
      coverImage: coverImage,
      description: description,
      likes: likes,
      comments: comments,
      shares: shares,
      collects: collects,
      views: views,
      body: body
    )
  }
}
