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
  /// 标题本地化后保留的原文标题；UI 副行优先读它。
  public var originalTitle: String?
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
    originalTitle: String? = nil,
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
    self.originalTitle = originalTitle
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
    // 详情页会反复读取没有属性头的正文，先避开整篇 Unicode 归一化，
    // 才不会让这个冷门格式的兼容成本落在每一次正文渲染上。
    guard markdown.hasPrefix("---") else {
      return .init(body: markdown)
    }
    // CRLF 只存在于少数旧记录；没有 CR 时复用原串，避免为解析分隔符复制整篇正文。
    let normalized = markdown.utf8.contains(13)
      ? markdown.replacingOccurrences(of: "\r\n", with: "\n")
      : markdown
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
    var originalTitle: String?
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
      case "original_title": originalTitle = value
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
      originalTitle: originalTitle,
      body: body
    )
  }

  /// 把当前字段写回 `---` 头 + 正文。键顺序固定，便于 diff 与测试。
  public func render() -> String {
    func append(_ key: String, _ value: String?, to lines: inout [String]) {
      guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
      lines.append("\(key): \(Self.yamlQuoted(value))")
    }
    var lines: [String] = []
    append("account_name", accountName, to: &lines)
    append("author", author, to: &lines)
    append("published", published, to: &lines)
    append("cover_image", coverImage, to: &lines)
    append("description", description, to: &lines)
    append("original_title", originalTitle, to: &lines)
    append("likes", likes, to: &lines)
    append("comments", comments, to: &lines)
    append("shares", shares, to: &lines)
    append("collects", collects, to: &lines)
    append("views", views, to: &lines)
    guard !lines.isEmpty else { return body }
    return "---\n\(lines.joined(separator: "\n"))\n---\n\n\(body)"
  }

  private static func yamlQuoted(_ value: String) -> String {
    "\"" + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ") + "\""
  }

  /// 元数据块里会出现的键。回显判定用白名单而不是「长得像 YAML」：
  /// 正文里合法的水平分隔线之间夹着 `key: value` 样式文字并不罕见。
  private static let knownKeys: Set<String> = [
    "account_name", "author", "published", "cover_image", "description", "original_title",
    "likes", "comments", "replies", "shares", "reposts", "collects", "views"
  ]

  /// 清除模型回显在生成结果里的元数据块。
  ///
  /// 修掉「翻译把元数据块也翻一遍」之前生成的旧译文，正文中段还留着一块
  /// `---` 包裹的 author/likes 残渣——它不在文档开头（前面是翻译后的标题），
  /// `parse` 剥不掉，于是原样渲染成一段乱码。这里做显示层清理。
  ///
  /// 回显是**模型的输出**，不是我们自己序列化的干净格式，实物长这样：
  /// 冒号被翻成全角（`author："aiko`）、值折成两行（`"aiko` ↵ `(@aikonect_)"`）、
  /// 收尾的 `---` 有时黏在最后一个值后面。所以判定规则是：块须在文档前几行内
  /// 出现、`---` 起头；块内至少两行以白名单键开头（半角/全角冒号都算），
  /// 见过已知键之后允许值的折行；`---` 单独一行或黏在行尾都算闭合。
  /// 正常的水平分隔线之间是普通正文，凑不齐两个白名单键，不受影响。
  /// 翻译模型有时把 `Captured title` / `捕获的标题` 包装行也译出来。
  public static func strippingCapturedEnvelope(from markdown: String) -> String {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    let dropped = lines.filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "<<<" || trimmed == ">>>" { return false }
      if trimmed == "Loading" || trimmed == "加载中" { return false }
      let lower = trimmed.lowercased()
      if lower.hasPrefix("captured title") || lower.hasPrefix("captured content") { return false }
      if trimmed.hasPrefix("捕获的标题") || trimmed.hasPrefix("捕获的内容") { return false }
      return true
    }
    var result: [String] = []
    for line in dropped {
      let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if isBlank, result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
      result.append(line)
    }
    while result.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeFirst() }
    return result.joined(separator: "\n")
  }

  public static func strippingEchoedMetadataBlock(from markdown: String) -> String {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")

    // 开头的块 `parse` 已能处理；这里容忍块前最多 4 个非空行（标题可能被
    // 模型拆成多行），再往后的 `---` 当作正文分隔线，不碰。
    var nonBlankBeforeBlock = 0
    var openIndex: Int?
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "---" { openIndex = index; break }
      if !trimmed.isEmpty {
        nonBlankBeforeBlock += 1
        if nonBlankBeforeBlock > 4 { return markdown }
      }
    }
    guard let open = openIndex else { return markdown }

    var knownKeyLines = 0
    var closeIndex: Int?
    var index = open + 1
    // 块不该没完没了：16 行内没闭合就不是元数据回显。
    while index < lines.count, index - open <= 16 {
      var trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed == "---" { closeIndex = index; break }
      if trimmed.isEmpty { index += 1; continue }

      var closesOnThisLine = false
      if trimmed.hasSuffix("---") {
        trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespaces)
        closesOnThisLine = true
      }
      if let key = leadingMetadataKey(of: trimmed), knownKeys.contains(key) {
        knownKeyLines += 1
      } else if knownKeyLines == 0 {
        // 块的第一个非空行就不是元数据键——这是正文分隔线，不碰。
        return markdown
      }
      // 已见过已知键之后，允许没有冒号的行：那是被折行的值。
      if closesOnThisLine { closeIndex = index; break }
      index += 1
    }
    // 单独一个 author 行也可能出现在真实引文里；至少两个已知键才敢删。
    guard let close = closeIndex, knownKeyLines >= 2 else { return markdown }

    var kept = Array(lines[..<open]) + Array(lines[(close + 1)...])
    // 折叠删除位留下的连续空行，避免标题和正文之间空出一大截。
    while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
    var result: [String] = []
    for line in kept {
      let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if isBlank, result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
      result.append(line)
    }
    return result.joined(separator: "\n")
  }

  /// 取行首到第一个冒号（半角或全角，取更靠前的那个）之间的键名。
  private static func leadingMetadataKey(of line: String) -> String? {
    let ascii = line.firstIndex(of: ":")
    let fullwidth = line.firstIndex(of: "：")
    let separator: String.Index
    switch (ascii, fullwidth) {
    case let (a?, f?): separator = min(a, f)
    case let (a?, nil): separator = a
    case let (nil, f?): separator = f
    case (nil, nil): return nil
    }
    return line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
