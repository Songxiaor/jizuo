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
  /// 宽度；微信正文里穿插在段落之间的单张插图仍旧单排，阅读顺序不变。
  ///
  /// 只作用于渲染，`segments` 本身的结构保持不变。
  static func galleryGrouped(_ segments: [Segment], minimumGalleryCount: Int = 2) -> [Segment] {
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
    var value = replacingHTMLLikeTokens(in: source)
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
    let normalized = normalizingCJKEmphasis(source)
    return (try? AttributedString(markdown: normalized, options: options))
      ?? AttributedString(normalized)
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

  // MARK: - Structural blocks (visible hierarchy)

  // Hashable：阅读渲染缓存（ReadingRenderCache）按块数组做键。
  enum Block: Equatable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([String])
    case orderedList([String])
    /// 任务列表。编辑器已经能续写 `- [ ]`，阅读区却把方括号当普通文字显示，
    /// 于是同一条清单在「写」和「读」两侧长得不一样。
    case taskList([TaskItem])
    case quote(String)
    case code(language: String?, content: String)
    /// `---` 之类的分隔线。不单独成块的话它会掉进段落，显示成一行光秃秃的横杠。
    case divider
  }

  struct TaskItem: Equatable, Hashable {
    public let isDone: Bool
    public let text: String
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
        if !text.isEmpty { blocks.append(.quote(text)) }
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

      if isListItem(trimmed) {
        var items: [String] = []
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          if line.isEmpty {
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if isListItem(next) {
              index += 1
              continue
            }
            break
          }
          // 撞上任务项就收尾：两种清单混在一起时，让它们各自成块。
          if isListItem(line), taskItem(line) == nil {
            items.append(listItemText(line))
            index += 1
          } else {
            break
          }
        }
        if !items.isEmpty { blocks.append(.list(items)) }
        continue
      }

      if orderedListItem(trimmed) != nil {
        var items: [String] = []
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          if line.isEmpty {
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if orderedListItem(next) != nil {
              index += 1
              continue
            }
            break
          }
          if let item = orderedListItem(line) {
            items.append(item)
            index += 1
          } else {
            break
          }
        }
        if !items.isEmpty { blocks.append(.orderedList(items)) }
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
          || line == ">" {
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

private extension AttributedString {
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

struct MarkdownContentView: View {
  let source: String
  var sourceURL: URL?
  var localImageURLs: [URL] = []
  var appendsUnusedLocalImages = true
  var readingFont: ResolvedReadingFont = .sans
  var primaryTextColor: Color = .primary
  var secondaryTextColor: Color = .secondary
  var accentColor: Color = .accentColor
  @Binding var showsPlainText: Bool
  var showsInlinePlainTextToggle: Bool = true
  /// 正文下方的模块（脑图 / 图片 / 标注 / 标签…）。由详情页按实际存在的模块传入——
  /// 这里不知道页面上有什么，硬猜只会列出点了跳不到的死链接。
  var navigationModules: [ReadingModuleLink] = []
  var revealText: String?
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
    readingFont: ResolvedReadingFont = .sans,
    primaryTextColor: Color = .primary,
    secondaryTextColor: Color = .secondary,
    accentColor: Color = .accentColor,
    showsPlainText: Binding<Bool> = .constant(false),
    showsInlinePlainTextToggle: Bool = true,
    navigationModules: [ReadingModuleLink] = [],
    revealText: String? = nil
  ) {
    self.source = source
    self.sourceURL = sourceURL
    self.localImageURLs = localImageURLs
    self.appendsUnusedLocalImages = appendsUnusedLocalImages
    self.readingFont = readingFont
    self.primaryTextColor = primaryTextColor
    self.secondaryTextColor = secondaryTextColor
    self.accentColor = accentColor
    self._showsPlainText = showsPlainText
    self.showsInlinePlainTextToggle = showsInlinePlainTextToggle
    self.navigationModules = navigationModules
    self.revealText = revealText
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
          revealText: revealText
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
              appendsUnusedLocalImages: appendsUnusedLocalImages
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
            .id(ReadingAnchor.block(entry.anchor))
        }
      }
      .onChange(of: scrollTarget) { _, target in
        guard let target else { return }
        // 开了「减弱动态效果」就直接落位：跳转本身是必要的，滚动过程不是。
        if reduceMotion {
          proxy.scrollTo(target, anchor: .top)
        } else {
          // 走 token 而不是写死 0.25：全 App 的「展开/切换」都用这一档，
          // 散落的自定义时长正是当初间距和字号失控的同一个成因。
          withAnimation(DesignTokens.Motion.standard) { proxy.scrollTo(target, anchor: .top) }
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
        revealText: revealText
      )
    case let .code(language, content):
      codeBlock(language: language, content: content)
        .padding(.bottom, 20)
    }
  }

  private enum StructuredRun {
    case text([MarkdownPresentation.Block])
    case code(language: String?, content: String)
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
    case let .list(items):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<items.count, id: \.self) { index in
          HStack(alignment: .top, spacing: 0) {
            Circle()
              .fill(secondaryTextColor.opacity(0.85))
              .frame(width: 5, height: 5)
              .frame(width: 22, alignment: .center)
              .padding(.top, 8)
              .accessibilityHidden(true)
            inlineBody(items[index], baseSize: 16.5)
              .lineSpacing(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
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
    case let .orderedList(items):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<items.count, id: \.self) { index in
          HStack(alignment: .top, spacing: 0) {
            Text("\(index + 1).")
              .font(.system(.body, design: .rounded).weight(.medium))
              .foregroundStyle(secondaryTextColor)
              .frame(width: 30, alignment: .trailing)
              .padding(.trailing, 9)
              .padding(.top, 1)
            inlineBody(items[index], baseSize: 16.5)
              .lineSpacing(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.bottom, 18)
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
    case let .code(language, content):
      codeBlock(language: language, content: content)
        .padding(.bottom, 20)
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
    guard let resolved = try? MarkdownLinkResolver.resolve(url, sourceURL: sourceURL) else {
      rejectedLink = true
      return .handled
    }
    NSWorkspace.shared.open(resolved)
    return .handled
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
