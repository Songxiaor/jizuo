import AppKit
import CryptoKit
import Foundation
import SwiftUI
import LinkDigestCore

/// Resolves Markdown destinations before the shared public-web syntax policy
/// decides whether the default browser may open them. Resolution never grants
/// extra schemes, credentials, or ports: the final absolute URL still passes
/// through `PublicWebURLPolicy.validateSyntax`.
enum MarkdownLinkResolver {
  static func resolve(_ destination: URL, sourceURL: URL?) throws -> URL {
    let raw = destination.relativeString
    guard let destinationComponents = URLComponents(string: raw) else {
      throw ManualLinkError.unsafeURL
    }

    let resolved: URL
    if destinationComponents.scheme != nil {
      resolved = destination
    } else {
      guard destinationComponents.host == nil,
            destinationComponents.user == nil,
            destinationComponents.password == nil,
            let sourceURL
      else { throw ManualLinkError.unsafeURL }

      if let github = githubRepository(sourceURL),
         !destinationComponents.percentEncodedPath.isEmpty,
         !destinationComponents.percentEncodedPath.hasPrefix("/") {
        resolved = try resolveGitHubRepositoryLink(
          raw,
          destination: destinationComponents,
          owner: github.owner,
          repository: github.repository
        )
      } else {
        guard let absolute = URL(string: raw, relativeTo: sourceURL)?.absoluteURL else {
          throw ManualLinkError.unsafeURL
        }
        resolved = absolute
      }
    }

    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    try policy.validateSyntax(resolved)
    return resolved
  }

  private static func githubRepository(_ sourceURL: URL) -> (owner: String, repository: String)? {
    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          PublicWebURLPolicy.normalizedHost(components.host ?? "") == "github.com",
          components.user == nil, components.password == nil,
          components.port == nil || components.port == 443
    else { return nil }
    let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard path.count == 2 else { return nil }
    return (String(path[0]), String(path[1]))
  }

  private static func resolveGitHubRepositoryLink(
    _ raw: String,
    destination: URLComponents,
    owner: String,
    repository: String
  ) throws -> URL {
    let mode = destination.percentEncodedPath.hasSuffix("/") ? "tree" : "blob"
    guard let base = URL(string: "https://github.com/\(owner)/\(repository)/\(mode)/HEAD/"),
          let absolute = URL(string: raw, relativeTo: base)?.absoluteURL
    else { throw ManualLinkError.unsafeURL }

    // A relative README link may use `.` segments, but it must not climb out
    // of this repository's HEAD namespace.
    let expectedPrefix = "/\(owner)/\(repository)/\(mode)/HEAD/"
    guard absolute.scheme?.lowercased() == "https",
          PublicWebURLPolicy.normalizedHost(absolute.host ?? "") == "github.com",
          absolute.path.hasPrefix(expectedPrefix)
    else { throw ManualLinkError.unsafeURL }
    return absolute
  }
}

/// Splits README-style markdown so local cached images render at their marker
/// positions instead of only as a trailing gallery.
enum LocalMarkdownImageLayout {
  /// 仿 X 原生引用卡的内容：被引作者、正文、卡内图片、原推链接。
  struct QuotedTweet: Equatable {
    let author: String?
    let url: URL?
    let text: String
    let images: [URL]
  }

  enum Segment: Equatable {
    case text(String)
    case image(URL)
    /// 连续出现的图片，交给自适应网格铺成 1～2 排。
    case gallery([URL])
    /// 引用推文卡片。
    case quotedTweet(QuotedTweet)
  }

  /// 把连续的图片并成一组。图集（抖音图文帖、README 截图序列）因此能铺满阅读区
  /// 宽度。公众号不要走这条：抽取只留下「图 + 空行 + 图」，一合并就把横幅和
  /// 正文卡并成两列，作者的上下阅读顺序就没了。
  ///
  /// 只作用于渲染，`segments` 本身的结构保持不变。
  static func galleryGrouped(
    _ segments: [Segment],
    minimumGalleryCount: Int = 2,
    groupsConsecutiveImages: Bool = true
  ) -> [Segment] {
    guard groupsConsecutiveImages else { return segments }
    var result: [Segment] = []
    var run: [URL] = []
    func flushRun() {
      if run.count >= minimumGalleryCount {
        result.append(.gallery(run))
      } else {
        result.append(contentsOf: run.map(Segment.image))
      }
      run = []
    }
    for segment in segments {
      switch segment {
      case let .image(url):
        run.append(url)
      case let .text(chunk):
        // markdown 里图片之间必然夹着空行，那不是内容，不算打断图集。
        if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        flushRun()
        result.append(segment)
      case .gallery, .quotedTweet:
        flushRun()
        result.append(segment)
      }
    }
    flushRun()
    return result
  }

  /// 图片标记（Markdown 图片与 `<img>`）的匹配式。编译一次复用：这个扫描
  /// 在每次切段时都要跑，正则编译本身不便宜，不能按调用现编。
  private static let imageMarkupExpression = try? NSRegularExpression(
    pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)|<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
    options: [.caseInsensitive]
  )

  static func segments(markdown: String, localImageURLs: [URL], appendsUnusedLocalImages: Bool = true) -> [Segment] {
    let byHash = Dictionary(uniqueKeysWithValues: localImageURLs.map { ($0.lastPathComponent, $0) })
    // 评论区必须作为一个整体交给 MarkdownPresentation：评论正文里也可能带图，
    // 如果先按图片切段，图片后的回复会失去 `## 评论（…）` 上下文，退回成普通
    // Markdown 列表。评论组件会在每条评论内部再次切图，因此这里保留整个尾段。
    if let commentStart = commentSectionStart(in: markdown) {
      var result: [Segment] = []
      let head = String(markdown[..<commentStart])
      if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(contentsOf: segments(
          markdown: head,
          localImageURLs: localImageURLs,
          appendsUnusedLocalImages: false
        ))
      }
      result.append(.text(String(markdown[commentStart...])))
      if appendsUnusedLocalImages {
        let referenced = referencedLocalImagePaths(in: markdown, byHash: byHash)
        result.append(contentsOf: localImageURLs
          .filter { !referenced.contains($0.path) }
          .map(Segment.image))
      }
      return result
    }
    // 引用卡先剥离：它可能没有图片（纯文字引用），所以必须在「无本地图片就整段
    // 返回」之前处理，否则标记会被当成字面文本渲染出来。
    if let quoteRange = quotedTweetRange(in: markdown) {
      var result: [Segment] = []
      let head = String(markdown[markdown.startIndex..<quoteRange.lowerBound])
      if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(contentsOf: segments(markdown: head, localImageURLs: localImageURLs, appendsUnusedLocalImages: false))
      }
      if let card = parseQuotedTweet(String(markdown[quoteRange]), byHash: byHash) {
        result.append(.quotedTweet(card))
      }
      let tail = String(markdown[quoteRange.upperBound...])
      if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(contentsOf: segments(markdown: tail, localImageURLs: localImageURLs, appendsUnusedLocalImages: false))
      }
      return result.isEmpty ? [.text(markdown)] : result
    }
    guard !localImageURLs.isEmpty else { return [.text(markdown)] }
    guard let expression = imageMarkupExpression else { return [.text(markdown)] }

    var segments: [Segment] = []
    var cursor = markdown.startIndex
    let nsRange = NSRange(markdown.startIndex..., in: markdown)
    let matches = expression.matches(in: markdown, range: nsRange)
    var used = Set<String>()

    for match in matches {
      guard let full = Range(match.range, in: markdown) else { continue }
      if cursor < full.lowerBound {
        segments.append(.text(String(markdown[cursor..<full.lowerBound])))
      }
      let rawURL: String? = {
        if match.numberOfRanges > 2, let r = Range(match.range(at: 2), in: markdown), !r.isEmpty {
          return String(markdown[r])
        }
        if match.numberOfRanges > 3, let r = Range(match.range(at: 3), in: markdown), !r.isEmpty {
          return String(markdown[r])
        }
        return nil
      }()
      if let rawURL, let local = resolveLocal(rawURL: rawURL, byHash: byHash) {
        segments.append(.image(local))
        // This records storage use for the trailing-gallery decision only;
        // repeated body markers intentionally render the same cached file.
        used.insert(local.path)
      } else {
        // Keep the original marker as text when no local file is available.
        segments.append(.text(String(markdown[full])))
      }
      cursor = full.upperBound
    }
    if cursor < markdown.endIndex {
      segments.append(.text(String(markdown[cursor...])))
    }

    // Append any unused local images (e.g. relative refs we couldn't resolve) at the end.
    if appendsUnusedLocalImages {
      let unused = localImageURLs.filter { !used.contains($0.path) }
      for url in unused {
        segments.append(.image(url))
      }
    }
    return segments.isEmpty ? [.text(markdown)] : segments
  }

  private static func commentSectionStart(in markdown: String) -> String.Index? {
    var lineStart = markdown.startIndex
    while lineStart < markdown.endIndex {
      let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
      let line = markdown[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
      if (line.hasPrefix("## 评论（") || line.hasPrefix("## 评论与回复（")), line.hasSuffix("）") {
        var nextStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
        while nextStart < markdown.endIndex {
          let nextEnd = markdown[nextStart...].firstIndex(of: "\n") ?? markdown.endIndex
          let candidate = markdown[nextStart..<nextEnd].trimmingCharacters(in: .whitespaces)
          if !candidate.isEmpty {
            guard candidate.hasPrefix("- **"),
                  let authorEnd = candidate.dropFirst(4).range(of: "**")
            else { break }
            let remainder = candidate.dropFirst(4)
            let author = String(remainder[..<authorEnd.lowerBound])
            let isGenericCommunity = line.hasPrefix("## 评论与回复（")
            if isGenericCommunity
              || author.hasPrefix("u/")
              || candidate.contains("score ")
              || candidate.contains("[原评论](")
              || candidate.contains("回复层级 ") {
              return lineStart
            }
            break
          }
          guard nextEnd < markdown.endIndex else { break }
          nextStart = markdown.index(after: nextEnd)
        }
      }
      guard lineEnd < markdown.endIndex else { break }
      lineStart = markdown.index(after: lineEnd)
    }
    return nil
  }

  private static func referencedLocalImagePaths(
    in markdown: String,
    byHash: [String: URL]
  ) -> Set<String> {
    guard let expression = imageMarkupExpression else { return [] }
    let matches = expression.matches(
      in: markdown,
      range: NSRange(markdown.startIndex..., in: markdown)
    )
    return Set(matches.compactMap { match in
      let rawURL: String? = {
        if match.numberOfRanges > 2,
           let range = Range(match.range(at: 2), in: markdown), !range.isEmpty {
          return String(markdown[range])
        }
        if match.numberOfRanges > 3,
           let range = Range(match.range(at: 3), in: markdown), !range.isEmpty {
          return String(markdown[range])
        }
        return nil
      }()
      guard let rawURL, let local = resolveLocal(rawURL: rawURL, byHash: byHash) else { return nil }
      return local.path
    })
  }

  /// 定位引用卡标记块 `<!--LDQUOTE ...-->...<!--/LDQUOTE-->` 的完整范围。
  static func quotedTweetRange(in markdown: String) -> Range<String.Index>? {
    guard let start = markdown.range(of: "<!--LDQUOTE "),
          let end = markdown.range(of: "<!--/LDQUOTE-->", range: start.upperBound..<markdown.endIndex)
    else { return nil }
    return start.lowerBound..<end.upperBound
  }

  /// 解析引用卡：从开标记里取 author/url，块内 `![]()` 取图片（解析成本地文件），
  /// 其余为正文。取不到本地图片的就略过该图，正文与卡片仍然显示。
  static func parseQuotedTweet(_ block: String, byHash: [String: URL]) -> QuotedTweet? {
    guard let headerEnd = block.range(of: "-->"),
          let footerStart = block.range(of: "<!--/LDQUOTE-->")
    else { return nil }
    let header = String(block[block.startIndex..<headerEnd.lowerBound])
    let inner = String(block[headerEnd.upperBound..<footerStart.lowerBound])

    func attribute(_ name: String) -> String? {
      guard let r = header.range(of: "\(name)=\"") else { return nil }
      guard let close = header.range(of: "\"", range: r.upperBound..<header.endIndex) else { return nil }
      let value = String(header[r.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }

    var images: [URL] = []
    var textLines: [String] = []
    if let imageExpr = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)"#) {
      for line in inner.components(separatedBy: "\n") {
        let range = NSRange(line.startIndex..., in: line)
        if let match = imageExpr.firstMatch(in: line, range: range),
           let r = Range(match.range(at: 1), in: line) {
          if let local = resolveLocal(rawURL: String(line[r]), byHash: byHash) { images.append(local) }
        } else {
          textLines.append(line)
        }
      }
    } else {
      textLines = inner.components(separatedBy: "\n")
    }
    let text = textLines.joined(separator: "\n")
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !images.isEmpty else { return nil }
    return QuotedTweet(
      author: attribute("author"),
      url: attribute("url").flatMap(URL.init(string:)),
      text: text,
      images: images
    )
  }

  private static func resolveLocal(rawURL: String, byHash: [String: URL]) -> URL? {
    let candidates = expandedURLCandidates(rawURL)
    for candidate in candidates {
      let hash = SHA256.hash(data: Data(candidate.utf8)).map { String(format: "%02x", $0) }.joined()
      if let url = byHash[hash] { return url }
    }
    return nil
  }

  private static func expandedURLCandidates(_ raw: String) -> [String] {
    var values = [raw]
    if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
      return values
    }
    // Common GitHub relative forms; hash is over the absolute string used at download time.
    if !raw.hasPrefix("/") {
      values.append("https://raw.githubusercontent.com/" + raw)
    }
    return values
  }
}

/// Presentation-only Markdown conversion. Stored snapshots/artifacts and all
/// exports retain their original text; this layer never writes a transformed
/// representation back into History.
enum MarkdownPresentation {
  static let omittedHTML = "[已省略 HTML 片段]"
  static let bodyFontSize: CGFloat = 16.5
  static let bodyLineSpacing: CGFloat = 11

  static func sanitized(_ source: String) -> String {
    var value = replacingHTMLLikeTokensPreservingCode(in: source)
    value = replacing(#"(?:\[已省略 HTML 片段\]\s*){2,}"#, in: value, with: omittedHTML + "\n")
    return value
  }

  static func attributed(_ source: String) -> AttributedString {
    inlineAttributed(sanitized(source))
  }

  /// Inline-only Markdown (bold/italic/code/links). Used inside structural blocks
  /// so SwiftUI view-level `.font` never has to paint the whole document at once.
  static func inlineAttributed(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    let withWiki = rewritingWikiLinksAsMarkdown(source)
    let normalized = normalizingCJKEmphasis(withWiki)
    return (try? AttributedString(markdown: normalized, options: options))
      ?? AttributedString(normalized)
  }

  /// 阅读区要把 `[[笔记]]` 变成可点的链接。Foundation 的 Markdown 不认双链，
  /// 先改写成 `[显示](linkdigest-wiki:/标题)`，点击仍走 `WikiLinkURL`，不会进浏览器。
  static func rewritingWikiLinksAsMarkdown(_ source: String) -> String {
    let refs = WikiLink.references(in: source)
    guard !refs.isEmpty else { return source }
    let protected = preservedCodeRanges(in: source)
    var result = source
    for ref in refs.reversed() {
      if protected.contains(where: { $0.overlaps(ref.range) }) { continue }
      let destination = WikiLinkURL.url(forTitle: ref.target).absoluteString
      let label = ref.label
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
      result.replaceSubrange(ref.range, with: "[\(label)](\(destination))")
    }
    return result
  }

  /// 把中文里「标点紧贴闭合标记」的强调改写成 CommonMark 认得的形式。
  ///
  /// CommonMark 规定：闭合的 `**` 若**前面是标点、后面又不是空格或标点**，就不算
  /// 闭合标记。Foundation 严格照做，所以 `**重要提示：**您的礼品…` 会原样显示星号。
  ///
  /// 这不是某个页面的毛病，是规则本身为空格分隔语言设计的——中文正文不写空格，
  /// 「提示：」后面直接接下文是常态，于是所有中文加粗都可能被打断。实测：
  /// `**重要提示：**您的…` 失败，`**重要提示：** 您的…`（补空格）成功，
  /// 英文的 `**Important:**your` 同样失败。
  ///
  /// 改写方式是把紧贴闭合标记的那个标点**移到强调范围之外**：
  /// `**重要提示：**您` → `**重要提示**：您`。字符不增不减，只是标点不再加粗，
  /// 视觉上几乎无差别，但能正常解析。
  ///
  /// 只在渲染前做，不动库里的原文：原文要如实保留页面写了什么，而且这样已有记录
  /// 全部当场生效，不必重抓。
  static func normalizingCJKEmphasis(_ source: String) -> String {
    guard source.contains("*") || source.contains("_") else { return source }
    // 行内代码里的星号是代码，不是强调。按反引号切段，只处理段外的部分。
    let segments = source.split(separator: "`", omittingEmptySubsequences: false)
    var rebuilt: [String] = []
    for (index, segment) in segments.enumerated() {
      // 偶数段在反引号之外，奇数段在代码跨度之内。
      rebuilt.append(index % 2 == 0 ? rewritingEmphasis(String(segment)) : String(segment))
    }
    return rebuilt.joined(separator: "`")
  }

  private static func rewritingEmphasis(_ value: String) -> String {
    var result = value
    for marker in ["**", "__", "*", "_"] {
      result = rewritingEmphasis(result, marker: marker)
    }
    return result
  }

  private static func rewritingEmphasis(_ value: String, marker: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: marker)
    let single = NSRegularExpression.escapedPattern(for: String(marker.first!))
    // 内容里不含标记字符本身与换行；结尾一个标点；闭合标记后面既不是空白也不是标点。
    let pattern =
      "\(escaped)([^\(single)\\n]*?)([\\p{P}\\p{S}])\(escaped)(?![\(single)])(?=[^\\s\\p{P}\\p{S}])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    return regex.stringByReplacingMatches(
      in: value,
      range: NSRange(value.startIndex..., in: value),
      withTemplate: "\(marker)$1\(marker)$2"
    )
  }

  /// Plain-text mode intentionally shares the same HTML-safe presentation
  /// projection as rich mode. It differs only in Markdown interpretation, not
  /// in what untrusted persisted source may become visible on screen.
  static func plainTextPresentation(_ source: String) -> String {
    sanitized(source)
  }

  static func calloutLabel(_ kind: String) -> String {
    switch kind {
    case "warning", "caution": return "注意"
    case "danger": return "危险"
    case "tip", "hint": return "提示"
    case "important": return "重要"
    case "success": return "完成"
    default: return "说明"
    }
  }

  static func calloutColor(_ kind: String, accent: Color) -> Color {
    switch kind {
    case "warning", "caution": return Color.orange
    case "danger": return Color.red
    case "success": return Color.green
    default: return accent
    }
  }

  // MARK: - Structural blocks (visible hierarchy)

  // Hashable：阅读渲染缓存（ReadingRenderCache）按块数组做键。
  enum Block: Equatable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// 有序与无序合成同一个块。
    ///
    /// 原本是 `.list` 和 `.orderedList` 两个 case，各自持平铺的 `[String]`。
    /// 两个问题：层级无处安放（子项只能和父项平起平坐），以及**混合列表会被
    /// 切开**——`1. 父项` 底下挂一个 `- 子项`，扫描有序列表时撞上 `- ` 就收尾，
    /// 于是一个列表变成三个块，而每块的编号都从 1 重数（步骤 2、3 显示成 1、2）。
    /// 一个 case 带 `ListEntry.depth` 才能如实表达「同一个列表」。
    case list([ListEntry])
    /// 社区评论不能降级成普通 Markdown 列表：列表会丢掉作者、回复对象和层级，
    /// 也无法提供局部展开。原始 Markdown / 导出文本保持不变，只在阅读呈现层
    /// 把扩展已经写出的缩进和元数据恢复成结构化评论。
    case comments(CommentSection)
    /// 任务列表。编辑器已经能续写 `- [ ]`，阅读区却把方括号当普通文字显示，
    /// 于是同一条清单在「写」和「读」两侧长得不一样。
    case taskList([TaskItem])
    case quote(String)
    /// Obsidian 风格 `> [!WARNING]`。没有独立告示组件时，至少不要把标记当正文。
    case callout(kind: String, text: String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    /// `---` 之类的分隔线。不单独成块的话它会掉进段落，显示成一行光秃秃的横杠。
    case divider
  }

  struct TaskItem: Equatable, Hashable {
    public let isDone: Bool
    public let text: String
  }

  /// 列表里的一项。
  ///
  /// `number` 在**解析时**就算好，而不是留给每个消费点 `enumerated()` 自己数。
  /// 阅读区、导出、选中复制是三个独立的消费点，各数各的必然漂移——嵌套一进来，
  /// 「第几项」和「数组下标」就不再是同一件事了。
  struct ListEntry: Equatable, Hashable {
    /// 嵌套深度，0 为顶层。
    public let depth: Int
    /// 有序项的显示编号；无序项为 nil。
    public let number: Int?
    public let text: String

    public var isOrdered: Bool { number != nil }
  }

  struct CommentSection: Equatable, Hashable {
    let title: String
    let loadedCount: Int?
    let expectedCount: Int?
    let isCapped: Bool
    let items: [CommentItem]

    var countTitle: String {
      if let loadedCount, let expectedCount { return "\(title) \(loadedCount)/\(expectedCount)" }
      if let loadedCount { return "\(title) \(loadedCount)" }
      return title
    }

    var progressLabel: String? {
      guard let loadedCount else { return nil }
      guard let expectedCount, expectedCount > 0 else { return "已加载 \(loadedCount) 条" }
      if loadedCount >= expectedCount { return "已加载全部" }
      return "已加载 \(Int((Double(loadedCount) / Double(expectedCount) * 100).rounded()))%"
    }
  }

  struct CommentItem: Equatable, Hashable, Identifiable {
    let sequence: Int
    let depth: Int
    let author: String
    let parentAuthor: String?
    let score: String?
    let published: String?
    let permalink: URL?
    let body: String
    let isDeleted: Bool

    var id: Int { sequence }

    var displayAuthor: String {
      guard !isDeleted else { return "已删除用户" }
      return author.hasPrefix("u/") ? String(author.dropFirst(2)) : author
    }

    var replyHandle: String {
      let value = author.hasPrefix("u/") ? String(author.dropFirst(2)) : author
      return value.replacingOccurrences(of: "[deleted]", with: "已删除用户")
    }
  }

  /// Splits sanitized Markdown into block-level units so the view can apply
  /// real spacing, heading sizes and list chrome — independent of AttributedString
  /// presentation intents that SwiftUI often flattens under `.font(...)`.
  static func blocks(from source: String) -> [Block] {
    let lines = sanitized(source)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")

    var blocks: [Block] = []
    var index = 0
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        index += 1
        continue
      }

      if let fence = openingFence(trimmed) {
        var codeLines: [String] = []
        index += 1
        while index < lines.count {
          if isClosingFence(lines[index], opening: fence) {
            index += 1
            break
          }
          codeLines.append(lines[index])
          index += 1
        }
        blocks.append(.code(language: fence.language, content: codeLines.joined(separator: "\n")))
        continue
      }

      // 抓取器把 Reddit / 社区评论附在严格格式的评论标题后。必须在普通标题
      // 和普通列表之前识别，否则 `trimmingCharacters` 会把层级永久抹掉。
      if let parsed = commentSection(in: lines, startingAt: index) {
        blocks.append(.comments(parsed.section))
        index = parsed.nextIndex
        continue
      }

      // Older X captures exposed the code-language toolbar as a standalone
      // line but omitted the surrounding fence. Repair only unmistakable code.
      if let language = legacyCodeLanguage(trimmed), index + 1 < lines.count,
         looksLikeLegacyCode(lines[index + 1]) {
        var codeLines: [String] = []
        index += 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          codeLines.append(lines[index])
          index += 1
        }
        blocks.append(.code(language: language, content: codeLines.joined(separator: "\n")))
        continue
      }

      if let heading = headingMatch(trimmed) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if trimmed.hasPrefix("> ") || trimmed == ">" {
        var quoteLines: [String] = []
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          if line.hasPrefix("> ") {
            quoteLines.append(String(line.dropFirst(2)))
            index += 1
          } else if line == ">" {
            quoteLines.append("")
            index += 1
          } else {
            break
          }
        }
        let text = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          blocks.append(calloutBlock(from: text) ?? .quote(text))
        }
        continue
      }

      if index + 1 < lines.count,
         let headers = tableCells(trimmed),
         isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
        let width = headers.count
        var rows: [[String]] = []
        index += 2
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          if line.isEmpty { break }
          if headingMatch(line) != nil || openingFence(line) != nil { break }
          guard let cells = tableCells(line), !isTableSeparator(line) else { break }
          rows.append(alignedTableRow(cells, width: width))
          index += 1
        }
        blocks.append(.table(headers: headers, rows: rows))
        continue
      }

      if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        blocks.append(.divider)
        index += 1
        continue
      }

      // 任务列表先于普通列表判断：`- [ ] 做事` 也满足 `isListItem`，顺序反了
      // 就永远走不到这里。
      if taskItem(trimmed) != nil {
        var items: [TaskItem] = []
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          if line.isEmpty {
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if taskItem(next) != nil {
              index += 1
              continue
            }
            break
          }
          guard let item = taskItem(line) else { break }
          items.append(item)
          index += 1
        }
        if !items.isEmpty { blocks.append(.taskList(items)) }
        continue
      }

      // 有序与无序走同一个扫描器：混排的列表必须留在**一个**块里，否则编号
      // 会在每个子列表之后重新从 1 开始。
      if listMarker(trimmed) != nil, taskItem(trimmed) == nil {
        var entries: [ListEntry] = []
        // 每层各自计数。回到浅层时把更深的计数器作废，下一个子列表才会重新
        // 从 1 起；不作废的话，第二个父项底下的子列表会接着上一个往下数。
        var counters: [Int: Int] = [:]
        while index < lines.count {
          let raw = lines[index]
          let line = raw.trimmingCharacters(in: .whitespaces)
          if line.isEmpty {
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if listMarker(next) != nil, taskItem(next) == nil {
              index += 1
              continue
            }
            break
          }
          // 撞上任务项就收尾：两种清单混在一起时，让它们各自成块。
          guard let marker = listMarker(line), taskItem(line) == nil else { break }
          let depth = listDepth(of: raw)
          for key in counters.keys where key > depth { counters[key] = nil }
          var number: Int?
          if marker.ordered {
            let next = (counters[depth] ?? 0) + 1
            counters[depth] = next
            number = next
          }
          entries.append(ListEntry(depth: depth, number: number, text: marker.text))
          index += 1
        }
        if !entries.isEmpty { blocks.append(.list(entries)) }
        continue
      }

      var paragraphLines: [String] = [trimmed]
      index += 1
      while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
          index += 1
          break
        }
        if headingMatch(line) != nil
          || openingFence(line) != nil
          || isListItem(line)
          || orderedListItem(line) != nil
          || line.hasPrefix("> ")
          || line == ">"
          || (index + 1 < lines.count
              && tableCells(line) != nil
              && isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces))) {
          break
        }
        paragraphLines.append(line)
        index += 1
      }
      let text = joinParagraphLines(paragraphLines)
      if !text.isEmpty { blocks.append(.paragraph(text)) }
    }
    return blocks
  }

  private static func commentSection(
    in lines: [String],
    startingAt start: Int
  ) -> (section: CommentSection, nextIndex: Int)? {
    let headingLine = lines[start].trimmingCharacters(in: .whitespaces)
    guard let heading = headingMatch(headingLine), heading.level == 2 else { return nil }
    let isComments = heading.text.hasPrefix("评论（") || heading.text.hasPrefix("评论与回复（")
    guard isComments, heading.text.hasSuffix("）") else { return nil }

    let title = heading.text.hasPrefix("评论与回复") ? "评论与回复" : "评论"
    guard let opening = heading.text.firstIndex(of: "（") else { return nil }
    let metadata = String(heading.text[heading.text.index(after: opening)..<heading.text.index(before: heading.text.endIndex)])
    let counts = integers(in: metadata)
    let loadedCount = counts.first
    let expectedCount = metadata.contains("页面显示") && counts.count > 1 ? counts[1] : nil

    var cursor = start + 1
    while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      cursor += 1
    }
    guard cursor < lines.count,
          let firstHeader = commentHeader(from: lines[cursor]),
          isCommentHeader(firstHeader, sectionTitle: title)
    else { return nil }

    var items: [CommentItem] = []
    var latestAuthorByDepth: [Int: String] = [:]
    while cursor < lines.count {
      guard let header = commentHeader(from: lines[cursor]),
            isCommentHeader(header, sectionTitle: title)
      else { break }
      let nextHeader = nextCommentHeader(in: lines, after: cursor, sectionTitle: title)
      let bodyLines = Array(lines[(cursor + 1)..<nextHeader])
      let body = normalizedCommentBody(bodyLines, removingIndent: header.indent + 2)
      let details = commentDetails(from: header.details)
      let depth = max(details.explicitDepth ?? header.indent / 2, 0)
      let parentAuthor: String? = {
        guard depth > 0 else { return nil }
        for candidateDepth in stride(from: depth - 1, through: 0, by: -1) {
          if let author = latestAuthorByDepth[candidateDepth] { return author }
        }
        return nil
      }()

      let isDeleted = header.author.localizedCaseInsensitiveContains("[deleted]")
      let author = isDeleted ? "已删除用户" : header.author
      let replyHandle = author.hasPrefix("u/") ? String(author.dropFirst(2)) : author
      latestAuthorByDepth = latestAuthorByDepth.filter { $0.key < depth }
      latestAuthorByDepth[depth] = replyHandle

      items.append(CommentItem(
        sequence: items.count,
        depth: depth,
        author: author,
        parentAuthor: parentAuthor,
        score: details.score,
        published: details.published,
        permalink: details.permalink,
        body: body,
        isDeleted: isDeleted
      ))
      cursor = nextHeader
    }

    guard !items.isEmpty else { return nil }
    return (
      CommentSection(
        title: title,
        loadedCount: loadedCount,
        expectedCount: expectedCount,
        isCapped: metadata.contains("仅保留前"),
        items: items
      ),
      cursor
    )
  }

  private static func commentHeader(
    from line: String
  ) -> (indent: Int, author: String, details: String)? {
    let prefix = line.prefix { $0 == " " || $0 == "\t" }
    let indent = prefix.reduce(into: 0) { count, character in
      count += character == "\t" ? 2 : 1
    }
    let trimmed = line.dropFirst(prefix.count)
    guard trimmed.hasPrefix("- **") else { return nil }
    let afterMarker = trimmed.dropFirst(4)
    guard let closing = afterMarker.range(of: "**") else { return nil }
    let author = String(afterMarker[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
    guard !author.isEmpty else { return nil }
    var details = String(afterMarker[closing.upperBound...]).trimmingCharacters(in: .whitespaces)
    if details.hasPrefix("·") {
      details = String(details.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return (indent, author, details)
  }

  private static func isCommentHeader(
    _ header: (indent: Int, author: String, details: String),
    sectionTitle: String
  ) -> Bool {
    if sectionTitle == "评论与回复" {
      // 通用社区适配器当前只输出平铺回复；正文里的加粗子列表仍属于该条评论。
      return header.indent == 0
    }
    // Reddit 用户名固定带 `u/`。元数据判据是对旧夹具/删除用户的兼容保护，
    // 避免评论正文里的 `- **重点**` 被误认成新用户。
    return header.author.hasPrefix("u/")
      || header.details.contains("score ")
      || header.details.contains("[原评论](")
      || header.details.contains("回复层级 ")
  }

  private static func nextCommentHeader(
    in lines: [String],
    after index: Int,
    sectionTitle: String
  ) -> Int {
    var cursor = index + 1
    while cursor < lines.count {
      if let header = commentHeader(from: lines[cursor]),
         isCommentHeader(header, sectionTitle: sectionTitle) {
        return cursor
      }
      cursor += 1
    }
    return lines.count
  }

  private static func normalizedCommentBody(_ lines: [String], removingIndent count: Int) -> String {
    var normalized = lines.map { line -> String in
      var remainder = line[...]
      var removed = 0
      while removed < count, let first = remainder.first, first == " " || first == "\t" {
        remainder = remainder.dropFirst()
        removed += first == "\t" ? 2 : 1
      }
      return String(remainder).trimmingCharacters(in: .whitespaces)
    }
    while normalized.first?.isEmpty == true { normalized.removeFirst() }
    while normalized.last?.isEmpty == true { normalized.removeLast() }
    return normalized.joined(separator: "\n")
  }

  private static func commentDetails(
    from raw: String
  ) -> (score: String?, published: String?, permalink: URL?, explicitDepth: Int?) {
    var score: String?
    var published: [String] = []
    var permalink: URL?
    var explicitDepth: Int?
    for part in raw.components(separatedBy: " · ") {
      let value = part.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("score ") {
        score = String(value.dropFirst("score ".count)).trimmingCharacters(in: .whitespaces)
      } else if value.hasPrefix("[原评论]("), value.hasSuffix(")") {
        permalink = URL(string: String(value.dropFirst("[原评论](".count).dropLast()))
      } else if value.hasPrefix("回复层级 ") {
        explicitDepth = Int(value.dropFirst("回复层级 ".count).trimmingCharacters(in: .whitespaces))
      } else if !value.isEmpty {
        published.append(value)
      }
    }
    return (score, published.isEmpty ? nil : published.joined(separator: " · "), permalink, explicitDepth)
  }

  private static func integers(in text: String) -> [Int] {
    var result: [Int] = []
    var digits = ""
    func flush() {
      if let value = Int(digits) { result.append(value) }
      digits = ""
    }
    for character in text {
      if character.isNumber { digits.append(character) } else { flush() }
    }
    flush()
    return result
  }

  private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else { return nil }
    var level = 0
    for character in line {
      if character == "#" { level += 1 } else { break }
    }
    guard (1...6).contains(level) else { return nil }
    let rest = line.dropFirst(level)
    guard rest.first == " " || rest.first == "\t" || rest.isEmpty else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (level, text)
  }

  private static func isListItem(_ line: String) -> Bool {
    line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
  }

  /// `- [ ] 待办` / `- [x] 已完成`。不是任务项则返回 nil。
  private static func taskItem(_ line: String) -> TaskItem? {
    guard isListItem(line) else { return nil }
    let rest = String(line.dropFirst(2))
    guard rest.count >= 3, rest.hasPrefix("[") else { return nil }
    let mark = rest[rest.index(rest.startIndex, offsetBy: 1)]
    guard rest[rest.index(rest.startIndex, offsetBy: 2)] == "]" else { return nil }
    let done: Bool
    switch mark {
    case " ": done = false
    case "x", "X": done = true
    default: return nil
    }
    let text = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    return TaskItem(isDone: done, text: text)
  }

  /// 一行是不是列表项，以及它是有序还是无序。调用方必须先排除任务项
  /// （`- [ ]` 同时满足 `isListItem`）。
  private static func listMarker(_ line: String) -> (ordered: Bool, text: String)? {
    if isListItem(line) { return (false, listItemText(line)) }
    if let text = orderedListItem(line) { return (true, text) }
    return nil
  }

  /// 行首缩进换算成嵌套深度。抽取侧每层缩进两个空格，这里按两空格一层折算，
  /// 奇数个空格向下取整。
  ///
  /// 上限 3 层：再深的层级，正文在阅读宽度里已经被缩得没地方放了；宁可让最深
  /// 的几层挤在一起，也不要把正文挤成一列。
  private static func listDepth(of line: String) -> Int {
    var spaces = 0
    for character in line {
      if character == " " {
        spaces += 1
      } else if character == "\t" {
        spaces += 2
      } else {
        break
      }
    }
    return min(spaces / 2, 3)
  }

  private static func listItemText(_ line: String) -> String {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return line
  }

  private struct Fence {
    let marker: Character
    let length: Int
    let language: String?
  }

  private static func openingFence(_ line: String) -> Fence? {
    guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
    let run = line.prefix { $0 == marker }
    guard run.count >= 3 else { return nil }
    let info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
    let token = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    let language = token?.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    return Fence(marker: marker, length: run.count, language: language?.isEmpty == false ? language : nil)
  }

  private static func isClosingFence(_ line: String, opening: Fence) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.first == opening.marker else { return false }
    let run = trimmed.prefix { $0 == opening.marker }
    guard run.count >= opening.length else { return false }
    return trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
  }

  private static func orderedListItem(_ line: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: #"^\d+[.)]\s+(.+)$"#),
          let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: line) else { return nil }
    return String(line[range]).trimmingCharacters(in: .whitespaces)
  }

  private static func legacyCodeLanguage(_ line: String) -> String? {
    let value = line.lowercased()
    let languages: Set<String> = ["text", "markdown", "json", "yaml", "swift", "typescript", "javascript", "python", "bash", "shell"]
    return languages.contains(value) ? value : nil
  }

  private static func looksLikeLegacyCode(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("project/")
      || trimmed.hasPrefix("{")
      || trimmed.hasPrefix("[")
      || trimmed.hasPrefix("$")
      || trimmed.contains("├──")
      || trimmed.contains("└──")
      || trimmed.contains("│")
  }

  private static func joinParagraphLines(_ lines: [String]) -> String {
    guard var result = lines.first else { return "" }
    for line in lines.dropFirst() {
      if needsASCIISpace(before: line, after: result) {
        result += " " + line
      } else {
        result += line
      }
    }
    return result
  }

  private static func needsASCIISpace(before next: String, after previous: String) -> Bool {
    guard let last = previous.last, let first = next.first else { return false }
    return last.isASCII && last.isLetter && first.isASCII && first.isLetter
  }

  /// 代码里的 `<task>` 是字面量。整篇扫描会把开发文洗成「已省略 HTML 片段」。
  private static func replacingHTMLLikeTokensPreservingCode(in source: String) -> String {
    var result = ""
    var index = source.startIndex
    while index < source.endIndex {
      if let fence = fenceRange(startingAt: index, in: source) {
        result.append(contentsOf: source[fence])
        index = fence.upperBound
        continue
      }
      if let code = inlineCodeRange(startingAt: index, in: source) {
        result.append(contentsOf: source[code])
        index = code.upperBound
        continue
      }
      let next = nextPreservedCodeStart(from: index, in: source)
      result.append(replacingHTMLLikeTokens(in: String(source[index..<next])))
      index = next
    }
    return result
  }

  private static func preservedCodeRanges(in source: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var index = source.startIndex
    while index < source.endIndex {
      if let fence = fenceRange(startingAt: index, in: source) {
        ranges.append(fence)
        index = fence.upperBound
        continue
      }
      if let code = inlineCodeRange(startingAt: index, in: source) {
        ranges.append(code)
        index = code.upperBound
        continue
      }
      index = source.index(after: index)
    }
    return ranges
  }

  private static func nextPreservedCodeStart(from index: String.Index, in source: String) -> String.Index {
    var cursor = index
    while cursor < source.endIndex {
      let character = source[cursor]
      if character == "`" || character == "~",
         fenceRange(startingAt: cursor, in: source) != nil
          || inlineCodeRange(startingAt: cursor, in: source) != nil {
        return cursor
      }
      cursor = source.index(after: cursor)
    }
    return source.endIndex
  }

  private static func isLineStart(_ index: String.Index, in source: String) -> Bool {
    index == source.startIndex || source[source.index(before: index)] == "\n"
  }

  private static func fenceRange(startingAt index: String.Index, in source: String) -> Range<String.Index>? {
    guard isLineStart(index, in: source) else { return nil }
    let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
    let line = String(source[index..<lineEnd])
    guard let fence = openingFence(line.trimmingCharacters(in: .whitespaces)) else { return nil }
    var cursor = lineEnd == source.endIndex ? source.endIndex : source.index(after: lineEnd)
    while cursor < source.endIndex {
      let nextEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
      if isClosingFence(String(source[cursor..<nextEnd]), opening: fence) {
        let closeEnd = nextEnd == source.endIndex ? source.endIndex : source.index(after: nextEnd)
        return index..<closeEnd
      }
      cursor = nextEnd == source.endIndex ? source.endIndex : source.index(after: nextEnd)
    }
    return nil
  }

  private static func inlineCodeRange(startingAt index: String.Index, in source: String) -> Range<String.Index>? {
    guard source[index] == "`" else { return nil }
    if isLineStart(index, in: source) {
      let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
      if openingFence(String(source[index..<lineEnd]).trimmingCharacters(in: .whitespaces)) != nil {
        return nil
      }
    }
    var ticks = 0
    var cursor = index
    while cursor < source.endIndex, source[cursor] == "`" {
      ticks += 1
      cursor = source.index(after: cursor)
    }
    guard ticks >= 1 else { return nil }
    var search = cursor
    while search < source.endIndex {
      if source[search] == "`" {
        var count = 0
        var close = search
        while close < source.endIndex, source[close] == "`" {
          count += 1
          close = source.index(after: close)
        }
        if count == ticks { return index..<close }
        search = close
      } else if source[search] == "\n", ticks == 1 {
        return nil
      } else {
        search = source.index(after: search)
      }
    }
    return nil
  }

  private static func tableCells(_ line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else { return nil }
    var body = trimmed
    if body.hasPrefix("|") { body.removeFirst() }
    if body.hasSuffix("|") { body.removeLast() }
    // 只在**未转义**的竖线上切分。抽取侧按 GFM 规矩把单元格内的 `|` 写成 `\|`，
    // 照单全收地 split 会把一格切成两格，整行随后被裁到表宽——内容直接丢失。
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in body {
      if escaped {
        // 只有 `\|` 是转义；其余情况把反斜杠原样留下，免得吃掉 Windows 路径
        // 和正则里的反斜杠。
        if character != "|" { current.append("\\") }
        current.append(character)
        escaped = false
        continue
      }
      switch character {
      case "\\":
        escaped = true
      case "|":
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      default:
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    guard cells.count >= 2 else { return nil }
    return cells
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    guard let cells = tableCells(line) else { return false }
    return cells.allSatisfy { cell in
      cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        && cell.filter { $0 == "-" }.count >= 3
    }
  }

  private static func alignedTableRow(_ cells: [String], width: Int) -> [String] {
    if cells.count == width { return cells }
    if cells.count > width { return Array(cells.prefix(width)) }
    return cells + Array(repeating: "", count: width - cells.count)
  }

  private static func calloutBlock(from text: String) -> Block? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first else { return nil }
    let firstLine = String(first)
    guard let expression = try? NSRegularExpression(pattern: #"^\[!([A-Za-z]{2,16})\](?:\s+(.*))?$"#),
          let match = expression.firstMatch(
            in: firstLine,
            range: NSRange(firstLine.startIndex..., in: firstLine)
          ),
          match.numberOfRanges > 1,
          let kindRange = Range(match.range(at: 1), in: firstLine)
    else { return nil }
    let kind = String(firstLine[kindRange]).lowercased()
    var body: [String] = []
    if match.numberOfRanges > 2, let rest = Range(match.range(at: 2), in: firstLine) {
      let trailing = String(firstLine[rest]).trimmingCharacters(in: .whitespaces)
      if !trailing.isEmpty { body.append(trailing) }
    }
    body.append(contentsOf: lines.dropFirst().map(String.init))
    let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return .callout(kind: kind, text: joined)
  }

  /// Splits HTML-like input in one pass rather than treating the first `>` as
  /// a terminator. Quoted attribute values may contain delimiters and newlines.
  /// An unterminated candidate consumes the remaining source as one omission so
  /// a truncated tag or its attributes can never reach either display mode.
  private static func replacingHTMLLikeTokens(in source: String) -> String {
    var result = ""
    var index = source.startIndex

    while index < source.endIndex {
      guard source[index] == "<" else {
        result.append(source[index])
        index = source.index(after: index)
        continue
      }
      let next = source.index(after: index)
      guard next < source.endIndex, beginsHTMLLikeToken(source[next]) else {
        result.append(source[index])
        index = next
        continue
      }

      let tokenStart = index
      var cursor = next
      var quote: Character?
      var closed = false
      while cursor < source.endIndex {
        let character = source[cursor]
        if let activeQuote = quote {
          if character == activeQuote {
            quote = nil
          }
        } else if character == "\"" || character == "'" {
          quote = character
        } else if character == ">" {
          cursor = source.index(after: cursor)
          closed = true
          break
        }
        cursor = source.index(after: cursor)
      }

      guard closed else {
        result.append(contentsOf: omittedHTML)
        break
      }
      result.append(contentsOf: replacement(forHTMLLikeToken: String(source[tokenStart..<cursor])))
      index = cursor
    }
    return result
  }

  private static func beginsHTMLLikeToken(_ character: Character) -> Bool {
    character == "/" || character == "!" || character == "?" || character.isLetter
  }

  private static func replacement(forHTMLLikeToken token: String) -> String {
    let body = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return omittedHTML }

    let isClosing = body.first == "/"
    let nameAndSuffix = String(isClosing ? body.dropFirst() : Substring(body))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = nameAndSuffix.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
    guard !name.isEmpty else { return omittedHTML }

    let suffix = nameAndSuffix.dropFirst(name.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if isClosing && !suffix.isEmpty {
      return omittedHTML
    }

    switch (name, isClosing) {
    case ("br", false): return "\n"
    case ("p", false), ("p", true): return "\n\n"
    case ("strong", false), ("b", false), ("strong", true), ("b", true): return "**"
    case ("em", false), ("i", false), ("em", true), ("i", true): return "*"
    case ("code", false), ("code", true): return "`"
    default: return omittedHTML
    }
  }

  private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
  }
}

extension AttributedString {
  /// Sets a base reading font while keeping bold/italic traits from inline Markdown.
  /// The reading font is user-selectable (serif / sans / named built-in family);
  /// code is rendered by a separate monospaced view and never passes through this path.
  func applyingBaseFont(size: CGFloat, readingFont: ResolvedReadingFont) -> AttributedString {
    let mutable = NSMutableAttributedString(attributedString: NSAttributedString(self))
    let full = NSRange(location: 0, length: mutable.length)
    guard full.length > 0 else { return self }

    var sawFont = false
    mutable.enumerateAttribute(.font, in: full) { value, range, _ in
      let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      if value != nil { sawFont = true }
      var descriptor = readingFont.nsFontDescriptor(size: size)
      if traits.contains(.bold) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .bold])
      }
      if traits.contains(.italic) {
        descriptor = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .italic])
      }
      let font = NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
      mutable.addAttribute(.font, value: font, range: range)
    }
    if !sawFont {
      let descriptor = readingFont.nsFontDescriptor(size: size)
      mutable.addAttribute(
        .font,
        value: NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size),
        range: full
      )
    }
    return AttributedString(mutable)
  }
}

/// 章节锚点的面板命名空间包装：阅读面板保活后多个面板同时挂载，
/// `.block(n)` 必须按面板隔离（见 MarkdownContentView.anchorScope）。
struct ScopedReadingAnchor: Hashable {
  let scope: String
  let block: Int
}

struct MarkdownContentView: View {
  let source: String
  var sourceURL: URL?
  var localImageURLs: [URL] = []
  var appendsUnusedLocalImages = true
  /// 公众号相邻图中间只有空行，不能并成图集；抖音图文 / README 截图序列才并。
  var groupsConsecutiveImages = true
  var readingFont: ResolvedReadingFont = .sans
  var primaryTextColor: Color = .primary
  var secondaryTextColor: Color = .secondary
  var accentColor: Color = .accentColor
  @Binding var showsPlainText: Bool
  var showsInlinePlainTextToggle: Bool = true
  /// 正文下方的模块（脑图 / 图片 / 标注 / 标签…）。由详情页按实际存在的模块传入——
  /// 这里不知道页面上有什么，硬猜只会列出点了跳不到的死链接。
  var navigationModules: [ReadingModuleLink] = []
  /// 章节锚点的命名空间。阅读面板保活后多个面板同时挂载，各自的
  /// `.block(n)` 锚点必须按面板隔离，否则目录跳转会撞到隐藏面板的同名
  /// 锚点；空串等于原来的全局命名（单面板场景，测试里也这么用）。
  var anchorScope: String = ""
  var revealText: String?
  var onFollowWikiLink: ((String) -> Void)?
  /// 单击正文进入编辑。只给转写 / 笔记 / 稿这些可写正文。
  var onRequestEdit: ((String?) -> Void)?
  @State private var rejectedLink = false
  @State private var showsOutlinePopover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 正文章节。
  ///
  /// 缓存在 state 里而不是每次 body 求值现算：解析全文的成本随正文长度线性增长，
  /// 库里最长那条 73432 字，跟着每次重绘重算会肉眼可见地卡。按 source 重算一次。
  @State private var outlineEntries: [MarkdownOutline.Entry] = []

  /// 少于 3 条不显示入口——一两个标题直接滚更快，摆个按钮只是噪音。
  private var showsOutlineEntry: Bool {
    guard !showsPlainText else { return false }
    return MarkdownOutline.shouldPresent(outlineEntries) || !navigationModules.isEmpty
  }

  /// 有模块时不能只写「章节」——那会让人以为点开只有正文标题，白白错过跳转入口。
  private var outlineButtonTitle: String {
    let sections = MarkdownOutline.shouldPresent(outlineEntries) ? outlineEntries.count : 0
    if sections > 0, !navigationModules.isEmpty { return "导航 \(sections + navigationModules.count)" }
    if sections > 0 { return "章节 \(sections)" }
    return "模块 \(navigationModules.count)"
  }

  /// 目录用弹层而不是常驻侧栏：阅读列宽只有 590pt，再切一栏会一直压缩正文；
  /// 而实测只有约两成条目的标题数够得上目录，常驻等于八成时间白占宽度。
  @ViewBuilder private var outlineButton: some View {
    Button {
      showsOutlinePopover = true
    } label: {
      Label(outlineButtonTitle, systemImage: "list.bullet.indent")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("history-content-outline-button")
    .popover(isPresented: $showsOutlinePopover, arrowEdge: .bottom) {
      outlinePopover(outlineEntries)
    }
  }

  @ViewBuilder private func outlinePopover(_ entries: [MarkdownOutline.Entry]) -> some View {
    let showsSections = MarkdownOutline.shouldPresent(entries)
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if showsSections {
          popoverGroupTitle("章节")
          ForEach(entries) { entry in
            popoverRow(
              title: entry.text,
              indent: CGFloat(MarkdownOutline.indentDepth(of: entry, in: entries)) * 14,
              target: .block(entry.blockIndex)
            )
          }
        }
        // 正文下方的模块跟章节走同一个入口：读者要去的是「图片那块」，
        // 不该因为它不在正文里就得改用另一种操作。
        if !navigationModules.isEmpty {
          if showsSections {
            Divider().padding(.vertical, 6)
          }
          popoverGroupTitle("模块")
          ForEach(navigationModules) { link in
            popoverRow(
              title: link.title,
              systemImage: link.systemImage,
              target: .module(link.anchor)
            )
          }
        }
      }
      .padding(12)
    }
    .frame(
      width: 260,
      height: min(CGFloat(entries.count + navigationModules.count) * 26 + 72, 400)
    )
    .accessibilityIdentifier("history-content-outline-popover")
  }

  @ViewBuilder private func popoverGroupTitle(_ text: String) -> some View {
    Text(text)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.tertiary)
      .padding(.bottom, 2)
  }

  @ViewBuilder private func popoverRow(
    title: String,
    systemImage: String? = nil,
    indent: CGFloat = 0,
    target: ReadingAnchor
  ) -> some View {
    Button {
      showsOutlinePopover = false
      scrollTarget = target
    } label: {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: DesignTokens.IconSize.inline))
            .foregroundStyle(.secondary)
            .frame(width: 14)
        }
        Text(title)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.leading, indent)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
  }

  /// 点击目录后要滚到的块下标。用 `ScrollViewReader` 驱动**外层**滚动容器——
  /// 它放在 ScrollView 内部就能生效，不必把 proxy 从详情页一层层传进来。
  @State private var scrollTarget: ReadingAnchor?

  init(
    source: String,
    sourceURL: URL? = nil,
    localImageURLs: [URL] = [],
    appendsUnusedLocalImages: Bool = true,
    groupsConsecutiveImages: Bool = true,
    readingFont: ResolvedReadingFont = .sans,
    primaryTextColor: Color = .primary,
    secondaryTextColor: Color = .secondary,
    accentColor: Color = .accentColor,
    showsPlainText: Binding<Bool> = .constant(false),
    showsInlinePlainTextToggle: Bool = true,
    navigationModules: [ReadingModuleLink] = [],
    anchorScope: String = "",
    revealText: String? = nil,
    onFollowWikiLink: ((String) -> Void)? = nil,
    onRequestEdit: ((String?) -> Void)? = nil
  ) {
    self.source = source
    self.sourceURL = sourceURL
    self.localImageURLs = localImageURLs
    self.appendsUnusedLocalImages = appendsUnusedLocalImages
    self.groupsConsecutiveImages = groupsConsecutiveImages
    self.readingFont = readingFont
    self.primaryTextColor = primaryTextColor
    self.secondaryTextColor = secondaryTextColor
    self.accentColor = accentColor
    self._showsPlainText = showsPlainText
    self.showsInlinePlainTextToggle = showsInlinePlainTextToggle
    self.navigationModules = navigationModules
    self.anchorScope = anchorScope
    self.revealText = revealText
    self.onFollowWikiLink = onFollowWikiLink
    self.onRequestEdit = onRequestEdit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // 目录入口不能挂在「纯文本」那一行里：真实阅读区两个调用点都传
      // showsInlinePlainTextToggle: false（纯文本开关在菜单里），挂上去等于永不显示。
      if showsInlinePlainTextToggle || showsOutlineEntry {
        HStack(spacing: 12) {
          if showsOutlineEntry { outlineButton }
          Spacer(minLength: 0)
          if showsInlinePlainTextToggle {
            Toggle(isOn: $showsPlainText) {
              Text("纯文本")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tertiary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .accessibilityIdentifier("history-content-plain-text-toggle")
          }
        }
      }

      if showsPlainText {
        SelectableReadingTextView(
          attributed: ReadingRenderCache.plainAttributed(
            source: source,
            readingFont: readingFont,
            color: NSColor(primaryTextColor)
          ),
          accent: NSColor(accentColor),
          onOpenLink: { url in _ = openValidated(url) },
          revealText: revealText,
          onRequestEdit: onRequestEdit
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if localImageURLs.isEmpty && LocalMarkdownImageLayout.quotedTweetRange(in: source) == nil {
        structuredMarkdown(source)
          .accessibilityIdentifier("history-content-markdown")
      } else {
        // 切段走备忘缓存：整篇正则扫描 + 图集合并只随正文与图片清单变化，
        // 巨型 ViewModel 引发的无关重绘不再重付这一遍。
        ForEach(
          Array(
            ReadingRenderCache.gallerySegments(
              markdown: source,
              localImageURLs: localImageURLs,
              appendsUnusedLocalImages: appendsUnusedLocalImages,
              groupsConsecutiveImages: groupsConsecutiveImages
            ).enumerated()
          ),
          id: \.offset
        ) { _, segment in
          switch segment {
          case let .text(chunk):
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              structuredMarkdown(chunk)
            }
          case let .image(url):
            // 白色衬卡 + 后台下采样解码 + 双击进灯箱；见 ArticleImageViewing。
            InlineArticleImageView(url: url)
          case let .gallery(urls):
            InlineArticleGalleryView(urls: urls)
          case let .quotedTweet(quote):
            QuotedTweetCardView(quote: quote, accentColor: accentColor, onOpenURL: { _ = openValidated($0) })
          }
        }
        .accessibilityIdentifier("history-content-markdown")
      }
    }
    .environment(\.openURL, OpenURLAction { url in
      openValidated(url)
    })
    .alert("无法打开链接", isPresented: $rejectedLink) {
      Button("好", role: .cancel) {}
    } message: {
      Text("该链接未通过安全校验。")
    }
    // 换条目就重算一次目录；同一条正文内的重绘不再解析。
    .task(id: source) {
      outlineEntries = MarkdownOutline.entries(
        from: ReadingRenderCache.blocks(from: MarkdownPresentation.sanitized(source))
      )
    }
  }

  /// Block-first reading layout: air before headings, body leading ~1.65, clear lists.
  private func structuredMarkdown(_ value: String) -> some View {
    // 相邻文本块合成一个 NSTextView 段（跨段连续选择）；代码块保持
    // SwiftUI 卡片独立渲染，复制按钮不丢。
    // 解析走备忘缓存：这个 body 每次重新求值都会路过这里，正文没变就不再重新解析。
    let blocks = ReadingRenderCache.blocks(from: value)
    let anchorable = MarkdownOutline.shouldPresent(MarkdownOutline.entries(from: blocks))
    var runs: [(anchor: Int, run: StructuredRun)] = []
    for (index, block) in blocks.enumerated() {
      // 目录可用时在标题处另起一段，这样每个章节都有自己的锚点可以跳。
      //
      // 代价是跨章节的连续选择会断在标题上——章节内部的跨段选择不受影响。
      // 只在目录真的会出现时才切；不够格出目录的文档（约八成）保持原有的
      // 「相邻文本块合成一个 NSTextView」，一个字都没变。
      let startsSection: Bool = {
        guard anchorable, case .heading = block else { return false }
        return true
      }()
      if case let .code(language, content) = block {
        runs.append((index, .code(language: language, content: content)))
      } else if case let .table(headers, rows) = block {
        runs.append((index, .table(headers: headers, rows: rows)))
      } else if case let .comments(section) = block {
        runs.append((index, .comments(section)))
      } else if !startsSection, case var .text(accumulated) = runs.last?.run {
        accumulated.append(block)
        runs[runs.count - 1].run = .text(accumulated)
      } else {
        runs.append((index, .text([block])))
      }
    }
    return ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(runs.enumerated()), id: \.offset) { _, entry in
          runView(entry.run)
            .id(ScopedReadingAnchor(scope: anchorScope, block: entry.anchor))
        }
      }
      .onChange(of: scrollTarget) { _, target in
        guard let target else { return }
        // 命名空间后的落点：模块锚点（tags 等）只在详情页注册一份，保持原值；
        // 章节锚点按面板隔离，避免撞到保活的隐藏面板。
        let resolved: AnyHashable = switch target {
        case let .block(index): ScopedReadingAnchor(scope: anchorScope, block: index)
        case let .module(anchor): ReadingAnchor.module(anchor)
        }
        // 开了「减弱动态效果」就直接落位：跳转本身是必要的，滚动过程不是。
        if reduceMotion {
          proxy.scrollTo(resolved, anchor: .top)
        } else {
          // 走 token 而不是写死 0.25：全 App 的「展开/切换」都用这一档，
          // 散落的自定义时长正是当初间距和字号失控的同一个成因。
          withAnimation(DesignTokens.Motion.standard) { proxy.scrollTo(resolved, anchor: .top) }
        }
        scrollTarget = nil
      }
    }
  }

  @ViewBuilder
  private func runView(_ run: StructuredRun) -> some View {
    switch run {
    case let .text(textBlocks):
      SelectableReadingTextView(
        // 组装走备忘缓存：内容、字体、配色没变时拿回同一个实例，
        // NSTextView 侧靠实例同一性直接短路（连深比较都不用做）。
        attributed: ReadingRenderCache.attributed(
          blocks: textBlocks,
          readingFont: readingFont,
          palette: .init(
            primary: NSColor(primaryTextColor),
            secondary: NSColor(secondaryTextColor),
            accent: NSColor(accentColor)
          )
        ),
        accent: NSColor(accentColor),
        onOpenLink: { url in _ = openValidated(url) },
        revealText: revealText,
        onRequestEdit: onRequestEdit
      )
    case let .code(language, content):
      codeBlock(language: language, content: content)
        .padding(.bottom, 20)
    case let .table(headers, rows):
      markdownTable(headers: headers, rows: rows)
        .padding(.bottom, 20)
    case let .comments(section):
      CommentThreadSectionView(
        section: section,
        localImageURLs: localImageURLs,
        readingFont: readingFont,
        primaryTextColor: primaryTextColor,
        secondaryTextColor: secondaryTextColor,
        accentColor: accentColor,
        onOpenURL: { _ = openValidated($0) }
      )
    }
  }

  private enum StructuredRun {
    case text([MarkdownPresentation.Block])
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    case comments(MarkdownPresentation.CommentSection)
  }

  @ViewBuilder
  private func markdownBlock(_ block: MarkdownPresentation.Block, previous: MarkdownPresentation.Block?) -> some View {
    switch block {
    case let .heading(level, text):
      Text(stripInlineMarkers(text))
        .font(headingFont(level))
        .tracking(headingTracking(level))
        .foregroundStyle(primaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, headingTopPadding(level: level, previous: previous))
        .padding(.bottom, level <= 2 ? 12 : 10)
        .overlay(alignment: .leading) {
          if level <= 2 {
            RoundedRectangle(cornerRadius: 1)
              .fill(accentColor.opacity(0.55))
              .frame(width: 3, height: level == 1 ? 18 : 15)
              .offset(x: -10)
          }
        }
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
    case let .paragraph(text):
      inlineBody(text, baseSize: readingFont.bodySize)
        .lineSpacing(MarkdownPresentation.bodyLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 20)
    case let .list(entries):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<entries.count, id: \.self) { index in
          let entry = entries[index]
          HStack(alignment: .top, spacing: 0) {
            if let number = entry.number {
              Text("\(number).")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(secondaryTextColor)
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 9)
                .padding(.top, 1)
            } else {
              Circle()
                // 子层的点小一档、淡一点：层级要在余光里就看出来，不能只靠缩进。
                .fill(secondaryTextColor.opacity(entry.depth > 0 ? 0.55 : 0.85))
                .frame(width: entry.depth > 0 ? 4 : 5, height: entry.depth > 0 ? 4 : 5)
                .frame(width: 22, alignment: .center)
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
            inlineBody(entry.text, baseSize: 16.5)
              .lineSpacing(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading, CGFloat(entry.depth) * 22)
        }
      }
      .padding(.leading, 4)
      .padding(.bottom, 18)
    case let .taskList(items):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<items.count, id: \.self) { index in
          HStack(alignment: .top, spacing: 0) {
            Image(systemName: items[index].isDone ? "checkmark.square.fill" : "square")
              .font(.system(size: DesignTokens.IconSize.control))
              .foregroundStyle(items[index].isDone ? accentColor : secondaryTextColor.opacity(0.7))
              .frame(width: 22, alignment: .center)
              .padding(.top, 3)
              .accessibilityLabel(items[index].isDone ? "已完成" : "未完成")
            inlineBody(items[index].text, baseSize: 16.5)
              .lineSpacing(8)
              // 划掉已完成的：一屏待办里，做完的那些应该退到背景去。
              .strikethrough(items[index].isDone, color: secondaryTextColor.opacity(0.6))
              .foregroundStyle(items[index].isDone ? secondaryTextColor : primaryTextColor)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.leading, 4)
      .padding(.bottom, 18)
    case .divider:
      Rectangle()
        .fill(secondaryTextColor.opacity(0.18))
        .frame(height: 1)
        .padding(.vertical, 10)
        .padding(.bottom, 18)
        .accessibilityHidden(true)
    case let .quote(text):
      inlineBody(text, baseSize: 15.5)
        .foregroundStyle(secondaryTextColor)
        .lineSpacing(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(alignment: .leading) {
          UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
          )
          .fill(accentColor.opacity(0.75))
          .frame(width: 3)
        }
        .padding(.bottom, 20)
    case let .callout(kind, text):
      VStack(alignment: .leading, spacing: 6) {
        Text(MarkdownPresentation.calloutLabel(kind))
          .font(.caption.weight(.semibold))
          .foregroundStyle(MarkdownPresentation.calloutColor(kind, accent: accentColor))
        if !text.isEmpty {
          inlineBody(text, baseSize: 15.5)
            .foregroundStyle(secondaryTextColor)
            .lineSpacing(9)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 12)
      .padding(.horizontal, 14)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(
          topLeadingRadius: 10,
          bottomLeadingRadius: 10,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(MarkdownPresentation.calloutColor(kind, accent: accentColor).opacity(0.85))
        .frame(width: 3)
      }
      .padding(.bottom, 20)
      .accessibilityIdentifier("history-content-markdown-callout")
    case let .code(language, content):
      codeBlock(language: language, content: content)
        .padding(.bottom, 20)
    case let .table(headers, rows):
      markdownTable(headers: headers, rows: rows)
        .padding(.bottom, 20)
    case let .comments(section):
      CommentThreadSectionView(
        section: section,
        localImageURLs: localImageURLs,
        readingFont: readingFont,
        primaryTextColor: primaryTextColor,
        secondaryTextColor: secondaryTextColor,
        accentColor: accentColor,
        onOpenURL: { _ = openValidated($0) }
      )
    }
  }

  private func inlineBody(_ value: String, baseSize: CGFloat = 16.5) -> some View {
    let attributed = MarkdownPresentation.inlineAttributed(value).applyingBaseFont(
      size: baseSize,
      readingFont: readingFont
    )
    return Text(attributed).textSelection(.enabled)
  }

  private func codeBlock(language: String?, content: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(language?.isEmpty == false ? language! : "代码")
          .font(.system(.subheadline, design: .monospaced).weight(.semibold))
          .foregroundStyle(secondaryTextColor)
        Spacer(minLength: 0)
        CodeCopyButton(content: content)
      }
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(primaryTextColor.opacity(0.055))

      ScrollView(.horizontal, showsIndicators: true) {
        Text(content)
          .font(.system(.body, design: .monospaced))
          .lineSpacing(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .padding(12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(primaryTextColor.opacity(0.025))
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(primaryTextColor.opacity(0.1), lineWidth: 1)
    )
    .accessibilityIdentifier("history-content-code-block")
  }

  private func stripInlineMarkers(_ value: String) -> String {
    value
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "`", with: "")
  }

  /// Size + weight + leading as a set (WWDC typography).
  private func headingFont(_ level: Int) -> Font {
    switch level {
    // 设计稿字号按用户正文字号等比缩放：调大正文时标题层级跟着走，
    // 否则 22pt 正文配 23pt 一级标题，层级会塌掉。
    case 1: return readingFont.scaled(designSize: 23, weight: .bold)
    case 2: return readingFont.scaled(designSize: 19.5, weight: .semibold)
    case 3: return readingFont.scaled(designSize: 17, weight: .semibold)
    default: return readingFont.scaled(designSize: 16, weight: .semibold)
    }
  }

  private func headingTracking(_ level: Int) -> CGFloat {
    switch level {
    case 1: return -0.45
    case 2: return -0.35
    default: return -0.15
    }
  }

  private func headingTopPadding(level: Int, previous: MarkdownPresentation.Block?) -> CGFloat {
    guard previous != nil else { return 6 }
    switch level {
    case 1: return 32
    case 2: return 30
    case 3: return 22
    default: return 16
    }
  }

  private func openValidated(_ url: URL) -> OpenURLAction.Result {
    if let title = WikiLinkURL.title(from: url) {
      onFollowWikiLink?(title)
      return .handled
    }
    guard let resolved = try? MarkdownLinkResolver.resolve(url, sourceURL: sourceURL) else {
      rejectedLink = true
      return .handled
    }
    NSWorkspace.shared.open(resolved)
    return .handled
  }

  private func markdownTable(headers: [String], rows: [[String]]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      tableRow(headers, isHeader: true)
      Rectangle().fill(primaryTextColor.opacity(0.12)).frame(height: 1)
      ForEach(rows.indices, id: \.self) { index in
        tableRow(rows[index], isHeader: false)
        if index < rows.count - 1 {
          Rectangle().fill(primaryTextColor.opacity(0.06)).frame(height: 1)
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(primaryTextColor.opacity(0.1), lineWidth: 1)
    )
    .accessibilityIdentifier("history-content-markdown-table")
  }

  private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(cells.indices, id: \.self) { index in
        Group {
          if isHeader {
            Text(stripInlineMarkers(cells[index]))
              .font(readingFont.scaled(designSize: 14.5, weight: .semibold))
              .foregroundStyle(primaryTextColor)
          } else {
            inlineBody(cells[index], baseSize: 14.5)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        if index < cells.count - 1 {
          Rectangle().fill(primaryTextColor.opacity(0.08)).frame(width: 1)
        }
      }
    }
  }
}

/// 仿 X 原生引用卡：带边框圆角框，顶部被引作者（加粗），正文正常颜色，图片在
/// 卡内，底部「查看原推」。整体作为一个视觉整体，区别于作者本人的正文。
struct QuotedTweetCardView: View {
  let quote: LocalMarkdownImageLayout.QuotedTweet
  var accentColor: Color = .accentColor
  let onOpenURL: (URL) -> Void

  private var paragraphs: [String] {
    quote.text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let author = quote.author, !author.isEmpty {
        Text(author)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
      }
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
        // Text 的 markdown 解析会把 t.co 等裸链接自动做成可点链接。
        Text(LocalizedStringKey(paragraph))
          .font(.title3)
          .foregroundStyle(.primary)
          .tint(accentColor)
          .lineSpacing(5)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(Array(quote.images.enumerated()), id: \.offset) { _, url in
        InlineArticleImageView(url: url, layout: .gallery)
      }
      if let url = quote.url {
        Button {
          onOpenURL(url)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.up.right.square").font(.system(size: DesignTokens.IconSize.inline))
            Text("查看原推").font(.callout)
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .fill(Color.primary.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    )
    .padding(.bottom, 20)
    .accessibilityIdentifier("history-quoted-tweet-card")
  }
}

/// Copy button for a code card: hover raises it from secondary to primary so
/// the pointer affordance is visible before the click.
private struct CodeCopyButton: View {
  let content: String
  @State private var isHovered = false

  var body: some View {
    Button {
      CopyFeedbackController.shared.copy(content)
    } label: {
      Label("复制", systemImage: "doc.on.doc")
        .labelStyle(.iconOnly)
    }
    .buttonStyle(.plain)
    .foregroundStyle(isHovered ? .primary : .secondary)
    .onHover { isHovered = $0 }
    .accessibilityLabel("复制代码")
  }
}

/// Inline image context-menu actions: save the cached original bytes to a
/// user-chosen location and copy to the pasteboard. Cached filenames are
/// content hashes without extensions, so the format is sniffed from magic
/// bytes to suggest a usable default filename.
enum MarkdownInlineImageActions {
  @MainActor
  static func saveImage(at url: URL) {
    guard let data = try? Data(contentsOf: url) else {
      presentFailure("这张图片的本机缓存已经不在了，重新抓取这条记录后再试。")
      return
    }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedFilename(for: url, data: data)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    // 用户选完位置、点了保存，写失败必须说话：原来是 `try?`，磁盘满、无权限、
    // 目标被占用都表现为「什么都没发生」，人会以为存好了，去那个目录才发现没有。
    // 旁边的 copyImage 尚且有 flash 反馈，保存这种更重的动作反而无声。
    do {
      try data.write(to: destination)
    } catch {
      presentFailure("图片没能保存到所选位置：\(error.localizedDescription)")
    }
  }

  @MainActor
  private static func presentFailure(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "保存图片失败"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }

  static func copyImage(_ image: NSImage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    Task { @MainActor in CopyFeedbackController.shared.flash() }
  }

  static func suggestedFilename(for url: URL, data: Data) -> String {
    let base = url.deletingPathExtension().lastPathComponent
    let stem = base.count > 16 ? String(base.prefix(16)) : base
    let existing = url.pathExtension
    let ext = existing.isEmpty ? imageExtension(for: data) : existing
    return "\(stem).\(ext)"
  }

  /// Magic-byte sniffing for the formats the capture pipeline stores.
  static func imageExtension(for data: Data) -> String {
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
    if data.count >= 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]),
       data[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "webp" }
    return "png"
  }
}
