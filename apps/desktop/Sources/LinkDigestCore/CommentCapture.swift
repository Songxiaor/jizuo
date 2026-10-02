import Foundation

/// App 内「抓取评论」：在隐藏网页里运行扩展同一份 `extract-comments.js`，
/// 把结果解析成结构化评论，勾选后按与扩展**逐字相同**的格式写进正文末尾。
///
/// 格式契约：扩展 `src/content/comments.ts` 的 `commentsMarkdown` /
/// `stripEmbeddedCommentSection`。两边的单测用同一段期望文本钉住。
public struct CapturedComment: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let author: String
  public let body: String
  public let depth: Int
  public let likes: String?
  public let score: String?
  public let published: String?
  public let permalink: String?

  public init(
    id: String, author: String, body: String, depth: Int,
    likes: String? = nil, score: String? = nil, published: String? = nil, permalink: String? = nil
  ) {
    self.id = id
    self.author = author
    self.body = body
    self.depth = depth
    self.likes = likes
    self.score = score
    self.published = published
    self.permalink = permalink
  }
}

public struct CommentCollection: Codable, Equatable, Sendable {
  public let platform: String
  public let comments: [CapturedComment]
  public let expectedCount: Int?
  public let limit: Int
  /// 页面有登录墙，读到的只是未登录可见部分。
  public let loginRequired: Bool?

  public init(platform: String, comments: [CapturedComment], expectedCount: Int?, limit: Int, loginRequired: Bool? = nil) {
    self.platform = platform
    self.comments = comments
    self.expectedCount = expectedCount
    self.limit = limit
    self.loginRequired = loginRequired
  }
}

public enum CommentCapture {
  /// 与扩展 `commentPlatformForURL` 同一份判定：哪些链接有评论读取器。
  public static func platform(for url: URL) -> String? {
    guard let host = url.host?.lowercased() else { return nil }
    let path = url.path
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
    func has(_ name: String) -> Bool { query.contains { $0.name == name } }
    if on("reddit.com"), path.contains("/comments/") { return "reddit" }
    if on("news.ycombinator.com") || on("v2ex.com") || on("stackoverflow.com") || on("dev.to")
      || on("linux.do") || on("uscardforum.com") { return "community" }
    if on("x.com") || on("twitter.com"), path.range(of: #"/status/\d+"#, options: .regularExpression) != nil { return "x" }
    if on("youtube.com"), path == "/watch", has("v") { return "youtube" }
    if on("bilibili.com"), path.contains("/video/") { return "bilibili" }
    if on("zhihu.com"),
       path.range(of: #"/answer/\d+"#, options: .regularExpression) != nil
        || (host == "zhuanlan.zhihu.com" && path.range(of: #"^/p/\d+"#, options: .regularExpression) != nil) {
      return "zhihu"
    }
    if on("douyin.com"),
       path.range(of: #"/(video|note)/\d+"#, options: .regularExpression) != nil || has("modal_id") {
      return "douyin"
    }
    if on("xiaohongshu.com"),
       path.range(of: #"/(explore|discovery/item)/[0-9a-fA-F]+"#, options: .regularExpression) != nil {
      return "xiaohongshu"
    }
    return nil
  }

  /// 随 App 打包的收集脚本（扩展构建产物的副本，见 scripts/sync-contracts.sh）。
  public static func collectorScript() -> String? {
    guard let url = CoreResourceBundle.resolved()?
      .url(forResource: "extract-comments", withExtension: "js", subdirectory: "browser-scripts")
    else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// 在网页里执行的函数体（给 `callAsyncJavaScript`）：先写条数，再跑收集脚本，
  /// 返回 JSON 字符串，避免 WebKit 把嵌套对象转成难解析的桥接类型。
  public static func collectorFunctionBody(script: String, limit: Int) -> String {
    """
    globalThis.__linkdigestCommentLimit = \(CapturePreferencesStore.clampedCommentLimit(limit));
    const result = await (0, eval)(\(javaScriptStringLiteral(script)));
    return JSON.stringify(result ?? null);
    """
  }

  public static func decodeCollection(json: String) -> CommentCollection? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(CommentCollection.self, from: data)
  }

  // MARK: - 写进正文

  public static func markdown(expectedCount: Int?, comments: [CapturedComment]) -> String {
    guard !comments.isEmpty else { return "" }
    let count = comments.count
    let coverage: String
    if let expectedCount, expectedCount > count {
      coverage = "已保存 \(count) 条 / 页面显示 \(expectedCount)"
    } else {
      coverage = "已保存 \(count) 条"
    }
    var lines = ["## 评论（\(coverage)）", ""]
    for comment in comments {
      let depth = max(0, comment.depth)
      let indent = String(repeating: "  ", count: min(depth, 6))
      let details = [
        comment.score.map { "score \($0)" },
        comment.likes.map { "赞 \($0)" },
        comment.published.map { $0.replacingOccurrences(of: #"\s*·\s*"#, with: " ", options: .regularExpression) },
        comment.permalink.map { "[原评论](\($0))" },
        "回复层级 \(depth)",
      ].compactMap { $0 }.joined(separator: " · ")
      lines.append("\(indent)- **\(sanitizedAuthor(comment.author))** · \(details)")
      for line in comment.body.components(separatedBy: "\n") {
        lines.append(trimTrailing("\(indent)  \(line)"))
      }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 去掉正文里已有的评论段（最后一个 `## 评论（…）` / `## 评论与回复（…）` 起到结尾）。
  public static func strippingCommentSection(from text: String) -> String {
    let pattern = #"\n## 评论(?:与回复)?（[^\n]*）\s*\n"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    guard let last = regex.matches(in: text, range: range).last,
          let cut = Range(last.range, in: text)
    else { return text }
    return trimTrailing(String(text[..<cut.lowerBound]))
  }

  /// 用勾选的评论替换正文里的评论段；一条都不勾就是去掉评论段。
  public static func replacingComments(
    in text: String,
    expectedCount: Int?,
    selected: [CapturedComment]
  ) -> String {
    let base = strippingCommentSection(from: text)
    let section = markdown(expectedCount: expectedCount, comments: selected)
    return section.isEmpty ? base : "\(base)\n\n\(section)"
  }

  private static func sanitizedAuthor(_ raw: String) -> String {
    let cleaned = raw.replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "未知用户" : cleaned
  }

  private static func trimTrailing(_ value: String) -> String {
    var result = value
    while let last = result.last, last.isWhitespace { result.removeLast() }
    return result
  }

  static func javaScriptStringLiteral(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }
}
