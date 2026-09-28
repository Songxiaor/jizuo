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
    /// 长文里穿插的视频，按原文位置渲染。
    case video(ArticleEmbeddedVideo)
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
      case .gallery, .quotedTweet, .video:
        flushRun()
        result.append(segment)
      }
    }
    flushRun()
    return result
  }

  /// 每个段起点之前累计的标题数（只统计文本段）。
  ///
  /// 旧写法把 `segments.prefix(i).reduce` 放在 `ForEach` 里，26 段的正文每帧要重扫
  /// 约 350 次前缀切片并重查 `ReadingRenderCache`；这里一趟算完，循环里只查表。
  /// 解析本身仍走备忘缓存，不改成每帧重算。
  /// `blocks(from:)` 是主线程隔离的；本函数只在 view body 里调用。
  @MainActor
  static func headingOffsets(of segments: [Segment]) -> [Int] {
    var offsets = [Int](repeating: 0, count: segments.count + 1)
    for (index, segment) in segments.enumerated() {
      var count = offsets[index]
      if case let .text(previous) = segment {
        count += MarkdownOutline.entries(from: ReadingRenderCache.blocks(from: previous)).count
      }
      offsets[index + 1] = count
    }
    return offsets
  }

  /// 图片标记（Markdown 图片与 `<img>`）的匹配式。编译一次复用：这个扫描
  /// 在每次切段时都要跑，正则编译本身不便宜，不能按调用现编。
  private static let imageMarkupExpression = try? NSRegularExpression(
    pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)|<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
    options: [.caseInsensitive]
  )

  static func segments(markdown: String, localImageURLs: [URL], appendsUnusedLocalImages: Bool = true) -> [Segment] {
    // 同名文件（不同目录下的同一个哈希名）不该让渲染崩掉，保留后一条。
    let byHash = Dictionary(
      localImageURLs.map { ($0.lastPathComponent, $0) },
      uniquingKeysWith: { _, new in new }
    )
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
    // 文中视频先剥离：没有本地图片时也必须变成卡片，不能把标记当正文。
    if let videoRange = firstVideoMarkerRange(in: markdown) {
      var result: [Segment] = []
      let head = String(markdown[markdown.startIndex..<videoRange.lowerBound])
      if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(contentsOf: segments(
          markdown: head,
          localImageURLs: localImageURLs,
          appendsUnusedLocalImages: false
        ))
      }
      if let video = parseVideoMarker(String(markdown[videoRange])) {
        result.append(.video(video))
      }
      let tail = String(markdown[videoRange.upperBound...])
      if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(contentsOf: segments(
          markdown: tail,
          localImageURLs: localImageURLs,
          appendsUnusedLocalImages: false
        ))
      }
      if appendsUnusedLocalImages {
        let referenced = referencedLocalImagePaths(in: markdown, byHash: byHash)
        result.append(contentsOf: localImageURLs
          .filter { !referenced.contains($0.path) }
          .map(Segment.image))
      }
      return result.isEmpty ? [.text(markdown)] : result
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

  /// 定位正文视频标记 `<!--LDVIDEO ... -->`。
  static func firstVideoMarkerRange(in markdown: String) -> Range<String.Index>? {
    guard let start = markdown.range(of: "<!--LDVIDEO "),
          let end = markdown.range(of: "-->", range: start.upperBound..<markdown.endIndex)
    else { return nil }
    return start.lowerBound..<end.upperBound
  }

  static func parseVideoMarker(_ raw: String) -> ArticleEmbeddedVideo? {
    guard raw.hasPrefix("<!--LDVIDEO "),
          let close = raw.range(of: "-->")
    else { return nil }
    let header = String(raw[raw.index(raw.startIndex, offsetBy: 12)..<close.lowerBound])
    func attribute(_ name: String) -> String? {
      guard let range = header.range(of: "\(name)=\"") else { return nil }
      guard let closeQuote = header.range(of: "\"", range: range.upperBound..<header.endIndex)
      else { return nil }
      let value = unescapeMarkerAttribute(String(header[range.upperBound..<closeQuote.lowerBound]))
      return value.isEmpty ? nil : value
    }
    guard let kindRaw = attribute("kind"),
          let kind = ArticleEmbeddedVideo.Kind(rawValue: kindRaw)
    else { return nil }
    return ArticleEmbeddedVideo(
      kind: kind,
      platform: attribute("platform") ?? "generic",
      id: attribute("id"),
      url: attribute("url").flatMap(URL.init(string:)),
      title: attribute("title")
    )
  }

  private static func unescapeMarkerAttribute(_ raw: String) -> String {
    raw.replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
  /// 读者看到的占位文字。
  ///
  /// 原来写的是「[已省略 HTML 片段]」——那是说给写代码的人听的：读者不知道
  /// 什么是 HTML 片段，也不知道是谁省略的、能不能找回来。这里只说清读者需要
  /// 知道的那件事：这个位置有东西，但显示不出来。
  static let omittedHTML = "（此处内容无法显示）"
  static let bodyFontSize: CGFloat = 16.5
  /// 正文行间距（**行与行之间的空隙**，不是行高）。行高 = `bodyFontSize` + 这个值。
  ///
  /// 10 → 行高 26.5pt → 1.61 倍字号。中文字面方正、笔画比拉丁密，要比英文正文略松。
  ///
  /// 曾经是 13（1.79 倍）：单看一段不挤，但段落间距只有 20pt，行距和段距差得太少，
  /// 一段折成两行时看起来像两段话。行距必须明显小于段距，读者才分得出「换行」和「换段」。
  ///
  /// 改这里要连带想到 `SelectableReadingText`：那边的引用块、列表项各有自己的
  /// 行距常数，正文松了而它们没动，段落之间会显得节奏不齐。
  ///
  /// 2026-09-23 收到 6：正文改回苹方 15pt 后，苹方自带行高已约 1.4 倍，再加 10pt 行距到 2 倍，
  /// 配上逐句分段，满屏都是空白，和紧凑的侧栏、列表不是一个节奏。6pt 约合 1.8 倍。
  ///
  /// 2026-09-28 正文排版样稿：默认改宋体 16 号后调到 7，约 1.85 倍行高。
  static let bodyLineSpacing: CGFloat = 7

  static func sanitized(_ source: String) -> String {
    var value = replacingHTMLLikeTokensPreservingCode(in: source)
    value = replacing(#"(?:（此处内容无法显示）\s*){2,}"#, in: value, with: omittedHTML + "\n")
    value = collapsingCJKAdjacentSpaces(value)
    return value
  }

  /// 中文字旁边连着的两个以上空格压成一个（2026-09-25 走查：译文里「谈  tokenization」）。
  /// 只动紧贴汉字或中文标点的那一段，行首缩进和行尾两空格换行都不碰。
  /// 代码块、行内代码原样保留：目录树这类内容靠空格对齐。
  static func collapsingCJKAdjacentSpaces(_ text: String) -> String {
    guard text.contains("  ") else { return text }
    var inFence = false
    let lines = text.components(separatedBy: "\n").map { line -> String in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        return line
      }
      guard !inFence, line.contains("  ") else { return line }
      // 反引号切开：偶数段是正文，奇数段是行内代码。
      return line.components(separatedBy: "`").enumerated().map { index, part in
        guard index.isMultiple(of: 2) else { return part }
        var value = replacing(#"(?<=[\p{Han}，。、；：！？）」』])[ \u00A0]{2,}(?=\S)"#, in: part, with: " ")
        value = replacing(#"(?<=\S)[ \u00A0]{2,}(?=[\p{Han}（「『])"#, in: value, with: " ")
        return value
      }.joined(separator: "`")
    }
    return lines.joined(separator: "\n")
  }

  static func attributed(_ source: String) -> AttributedString {
    inlineAttributed(sanitized(source))
  }

  /// Inline-only Markdown (bold/italic/code/links). Used inside structural blocks
  /// so SwiftUI view-level `.font` never has to paint the whole document at once.
  /// - Parameter marksMath: 把 `$…$` 行内公式换成内部记号，交给阅读排版层换成公式图片。
  ///   只有阅读区（`SelectableReadingText`）打开它；导出、界面文字保留 `$…$` 原样。
  static func inlineAttributed(_ source: String, marksMath: Bool = false) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    let withWiki = rewritingWikiLinksAsMarkdown(marksMath ? InlineMath.marking(source) : source)
    let normalized = normalizingCJKEmphasis(withWiki)
    let parsed = (try? AttributedString(markdown: normalized, options: options))
      ?? AttributedString(normalized)
    return applyingScripts(applyingHighlights(parsed))
  }

  /// 把 `==高亮==` 变成带背景色的片段。
  ///
  /// Foundation 的 Markdown 解析器不认这个记号（实测原样输出 `==高亮==`），
  /// 而作者主动标黄的句子往往是全文最要紧的。不降级成 `**加粗**`：那会和真正
  /// 的强调混在一起，读者分不出哪个是原文强调、哪个是原文高亮。
  ///
  /// 在解析**之后**做：先让 Markdown 处理完粗体斜体链接，再在结果上按记号
  /// 着色，这样高亮里的其它标记不会被吃掉。
  static func applyingHighlights(_ source: AttributedString) -> AttributedString {
    var value = source
    var searchStart = value.startIndex
    while searchStart < value.endIndex,
          let opening = value[searchStart...].range(of: "=="),
          let closing = value[opening.upperBound...].range(of: "==") {
      let inner = opening.upperBound..<closing.lowerBound
      if isHighlightPair(value, opening: opening, closing: closing, inner: inner) {
        value[inner].backgroundColor = Self.highlightMarkerColor
        // 阅读区走 NSTextView：SwiftUI 的颜色属性转成系统文本时会丢，高亮底色原来
        // 一直没显示出来（2026-09-24 目检）。系统文本认的颜色另写一份。
        value[inner].appKit.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.32)
        value.removeSubrange(closing)
        value.removeSubrange(opening)
        searchStart = value.startIndex
      } else {
        // 不是高亮就跳过这个 `==` 继续找，**不能**把它删掉——`FOO==1` 里的
        // 等号是内容的一部分，删了值就变了。
        searchStart = opening.upperBound
      }
    }
    return value
  }

  /// 这一对 `==` 是不是高亮标记。
  ///
  /// 只按字符匹配会毁掉三类正常内容，都是实测撞到的：
  /// - 行内代码里的比较：`` `if (a == b)` 和 `c == d` `` 被吃成 `if (a  b) 和 c  d`
  /// - 配置值：`FOO==1 与 BAR==2` 被吃成 `FOO1 与 BAR2`
  /// - 连续等号：`===== 分隔线` 被吃剩一个 `=`
  ///
  /// 判据取自 GFM 的强调规则：开标记后面、闭标记前面都不能是空白（`== x ==`
  /// 不是高亮），两端不能紧贴等号（避免咬进 `===` 这类连续记号），且跨度内不能
  /// 换行。行内代码整段跳过——那里的等号是代码，不是标记。
  private static func isHighlightPair(
    _ value: AttributedString,
    opening: Range<AttributedString.Index>,
    closing: Range<AttributedString.Index>,
    inner: Range<AttributedString.Index>
  ) -> Bool {
    let body = value[inner]
    if body.characters.isEmpty { return false }
    if body.characters.contains("\n") { return false }
    // 紧贴内侧的字符不能是空白：`== 前后有空格 ==` 按 GFM 不算强调。
    if body.characters.first?.isWhitespace == true { return false }
    if body.characters.last?.isWhitespace == true { return false }
    // 开标记左侧不能紧贴字母数字。真正的高亮从词边界起头（句首、空格后、
    // 标点后）；紧贴单词的等号是内容，例如 `FOO==1 与 BAR==2` 里的配置值——
    // 那两个 `==` 恰好成对，只看两侧非空白会把 `1 与 BAR` 整段吃掉着色。
    // 两端也不能再挨着等号，否则 `===` / `=====` 会被拆开当标记。
    if opening.lowerBound > value.startIndex {
      let before = value.characters[value.index(beforeCharacter: opening.lowerBound)]
      if before == "=" { return false }
      if before.isLetter || before.isNumber { return false }
    }
    if closing.upperBound < value.endIndex {
      let after = value.characters[closing.upperBound]
      if after == "=" { return false }
      // 闭标记右侧同理：`==1` 这种收尾说明它是值的一部分。
      if after.isLetter || after.isNumber { return false }
    }
    // 行内代码里的等号是代码。任一端落在代码跨度内就不算标记。
    if value[opening].inlinePresentationIntent?.contains(.code) == true { return false }
    if value[closing].inlinePresentationIntent?.contains(.code) == true { return false }
    if body.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) {
      return false
    }
    return true
  }

  /// 高亮底色。
  ///
  /// 用系统黄的低透明度而不是固定色值：阅读区在深浅两套外观下都要读得清，
  /// 写死颜色会在其中一套里糊成一片。透明度压得低，文字对比度不受影响。
  static let highlightMarkerColor = Color.yellow.opacity(0.28)

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

  /// 按「从左往右一对一对」找强调标记，只改够不上 CommonMark flanking 规则的那几对。
  ///
  /// 2026-09-28 修：原来用一条正则直接找「标点 + 闭合标记 + 汉字」，不认配对——
  /// `**核心结论**：……小团队：**Codex……**。` 里，第一对的**闭合**标记被当成了
  /// 开头，一直吃到第二对的开头，结果两对都拆坏，星号露在正文里。
  private static func rewritingEmphasis(_ value: String, marker: String) -> String {
    let m = NSRegularExpression.escapedPattern(for: marker)
    let single = NSRegularExpression.escapedPattern(for: String(marker.first!))
    // 单字符标记不能是双字符标记的一半。
    let pattern = marker.count == 1
      ? "(?<!\(single))\(m)(?!\(single))([^\(single)\\n]+?)(?<!\(single))\(m)(?!\(single))"
      : "\(m)([^\(single)\\n]+?)\(m)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let ns = value as NSString
    var result = ""
    var cursor = 0
    func isPunct(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }
    for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      cursor = match.range.location + match.range.length
      var inner = ns.substring(with: match.range(at: 1))
      var before = ""
      var after = ""
      let previous = match.range.location > 0
        ? Character(ns.substring(with: NSRange(location: match.range.location - 1, length: 1))) : nil
      let following = cursor < ns.length ? Character(ns.substring(with: NSRange(location: cursor, length: 1))) : nil
      // 闭合标记前是标点、后面紧跟文字：把末尾标点移到标记外面。
      if let last = inner.last, isPunct(last), inner.count > 1,
         let following, !following.isWhitespace, !isPunct(following) {
        inner.removeLast()
        after = String(last)
      }
      // 开头标记后是标点、前面紧挨文字：把开头标点移到标记前面。
      if let first = inner.first, isPunct(first), inner.count > 1,
         let previous, !previous.isWhitespace, !isPunct(previous) {
        inner.removeFirst()
        before = String(first)
      }
      result += before + marker + inner + marker + after
    }
    result += ns.substring(from: cursor)
    return result
  }

  /// 总结开头的套话（「根据捕获的内容，总结如下：」）只在显示时去掉，存档原样保留。
  /// 只认第一段、且整段就是一句以冒号结尾的开场白，正文里的同类句子不动。
  static func strippingSummaryPreamble(_ markdown: String) -> String {
    let trimmed = markdown.drop(while: { $0.isWhitespace || $0.isNewline })
    guard let lineEnd = trimmed.firstIndex(of: "\n") else { return markdown }
    let first = trimmed[..<lineEnd].trimmingCharacters(in: .whitespaces)
    let pattern = #"^(根据|基于|以下是|下面是|这是|好的[，,]?)[^\n。]{0,24}(总结|摘要|要点|概括|梳理)[^\n。]{0,8}[：:]$"#
    guard first.count <= 40, first.range(of: pattern, options: .regularExpression) != nil else { return markdown }
    return String(trimmed[lineEnd...]).trimmingCharacters(in: .newlines)
  }

  /// Plain-text mode intentionally shares the same HTML-safe presentation
  /// projection as rich mode. It differs only in Markdown interpretation, not
  /// in what untrusted persisted source may become visible on screen.
  static func plainTextPresentation(_ source: String) -> String {
    removingInlineMarkers(sanitized(source))
  }

  /// 去掉上下标等内部记号（私用区字符），给纯文本、复制、导出用。
  static func removingInlineMarkers(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { (0xF8F0...0xF8F7).contains($0.value) }) else { return text }
    return String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0xF8F0...0xF8F7).contains($0.value) }))
  }

  /// 提示框类型：Obsidian 与 GitHub 的写法都认，别名归到同一类。
  static func calloutFamily(_ kind: String) -> String {
    switch kind {
    case "abstract", "summary", "tldr": return "abstract"
    case "info": return "info"
    case "todo": return "todo"
    case "tip", "hint": return "tip"
    case "important": return "important"
    case "success", "check", "done": return "success"
    case "question", "help", "faq": return "question"
    case "warning", "caution", "attention": return "warning"
    case "failure", "fail", "missing": return "failure"
    case "danger", "error": return "danger"
    case "bug": return "bug"
    case "example": return "example"
    case "quote", "cite": return "quote"
    case "details": return "details"
    default: return "note"
    }
  }

  static func calloutLabel(_ kind: String) -> String {
    switch calloutFamily(kind) {
    case "abstract": return "摘要"
    case "info": return "信息"
    case "todo": return "待办"
    case "tip": return "提示"
    case "important": return "重要"
    case "success": return "完成"
    case "question": return "问题"
    case "warning": return "注意"
    case "failure": return "失败"
    case "danger": return "危险"
    case "bug": return "缺陷"
    case "example": return "示例"
    case "quote": return "引用"
    case "details": return "详细信息"
    default: return "说明"
    }
  }

  static func calloutSymbol(_ kind: String) -> String {
    switch calloutFamily(kind) {
    case "abstract": return "list.bullet.clipboard"
    case "info": return "info.circle"
    case "todo": return "checkmark.circle"
    case "tip": return "lightbulb"
    case "important": return "exclamationmark.bubble"
    case "success": return "checkmark.seal"
    case "question": return "questionmark.circle"
    case "warning": return "exclamationmark.triangle"
    case "failure": return "xmark.octagon"
    case "danger": return "bolt.trianglebadge.exclamationmark"
    case "bug": return "ladybug"
    case "example": return "list.number"
    case "quote": return "quote.opening"
    case "details": return "text.alignleft"
    default: return "pencil"
    }
  }

  static func calloutColor(_ kind: String, accent: Color) -> Color {
    switch calloutFamily(kind) {
    case "warning": return Color.orange
    case "danger", "failure", "bug": return Color.red
    case "success", "todo": return Color.green
    case "tip", "abstract": return Color.teal
    case "important", "example": return Color.purple
    case "question": return Color.yellow
    case "quote", "details": return Color.gray
    default: return accent
    }
  }

  // MARK: - Structural blocks (visible hierarchy)

  // Hashable：阅读渲染缓存（ReadingRenderCache）按块数组做键。
  enum Block: Equatable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// 每项带嵌套深度（0 为顶层）。原本是平铺的 `[String]`，缩进在解析时就被
    /// trim 掉了，三层清单会全部塌成并列条目。
    case list([ListItem])
    /// `start` 是这一段的**起始编号**，来自原文而不是数组下标：抽取侧认 `<ol start>`
    /// 并按实际产出的行递增，渲染时重编会把它全抹掉。
    case orderedList(start: Int, items: [String])
    /// 社区评论不能降级成普通 Markdown 列表：列表会丢掉作者、回复对象和层级，
    /// 也无法提供局部展开。原始 Markdown / 导出文本保持不变，只在阅读呈现层
    /// 把扩展已经写出的缩进和元数据恢复成结构化评论。
    case comments(CommentSection)
    /// 任务列表。编辑器已经能续写 `- [ ]`，阅读区却把方括号当普通文字显示，
    /// 于是同一条清单在「写」和「读」两侧长得不一样。
    case taskList([TaskItem])
    /// `depth` 是嵌套层级（0 为最外层）。平铺时 `>>` 的第二层会被当成正文，
    /// 引用框里就会裸露出一个 `>` 记号。
    case quote(depth: Int, text: String)
    /// Obsidian 风格 `> [!WARNING]`。没有独立告示组件时，至少不要把标记当正文。
    /// `title` 为空表示用类型的默认名；`fold` 对应 `[!TIP]-`（默认收起）/ `[!TIP]+`（可收起、默认展开）。
    case callout(kind: String, title: String, text: String, fold: CalloutFold)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]], alignments: [ColumnAlignment])
    /// `---` 之类的分隔线。不单独成块的话它会掉进段落，显示成一行光秃秃的横杠。
    case divider
  }

  /// 列对齐。抓取侧从 `align` 属性或行内 `text-align` 读出来，写进分隔行
  /// （`:---:` / `---:`）。统一按左对齐渲染会把数字列的可扫读性毁掉。
  enum ColumnAlignment: Equatable, Hashable {
    case leading, center, trailing

    var frameAlignment: Alignment {
      switch self {
      case .leading: .leading
      case .center: .center
      case .trailing: .trailing
      }
    }

    var textAlignment: TextAlignment {
      switch self {
      case .leading: .leading
      case .center: .center
      case .trailing: .trailing
      }
    }
  }

  enum CalloutFold: Equatable, Hashable {
    case none, expanded, collapsed
  }

  struct ListItem: Equatable, Hashable {
    let depth: Int
    let text: String

    init(depth: Int = 0, text: String) {
      self.depth = depth
      self.text = text
    }
  }

  struct TaskItem: Equatable, Hashable {
    public let isDone: Bool
    public let text: String
  }

  struct CommentSection: Equatable, Hashable {
    let title: String
    let loadedCount: Int?
    let expectedCount: Int?
    let isCapped: Bool
    /// 标题写的是「已保存 N 条」：用户勾选后的结果，不是页面加载进度。
    var isSelection: Bool = false
    let items: [CommentItem]

    var countTitle: String {
      if let loadedCount, let expectedCount { return "\(title) \(loadedCount)/\(expectedCount)" }
      if let loadedCount { return "\(title) \(loadedCount)" }
      return title
    }

    var progressLabel: String? {
      guard let loadedCount else { return nil }
      // 勾选保存的评论段（扩展与 App「抓取评论」）：说「已保存」，不说「已加载」。
      if isSelection {
        guard let expectedCount, expectedCount > loadedCount else { return "已保存 \(loadedCount) 条" }
        return "已保存 \(loadedCount) 条 · 共约 \(expectedCount) 条"
      }
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
    /// 点赞数（X、B 站、抖音等），原样保留平台写法如「1.2万」。
    var likes: String? = nil
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
    let lines = resolvingFootnotes(sanitized(source))
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

      // 整段公式 `$$ … $$`（单行或多行），当作 math 代码块交给公式排版。
      if trimmed.hasPrefix("$$") {
        var body = String(trimmed.dropFirst(2))
        if body.hasSuffix("$$"), body.count >= 2 {
          blocks.append(.code(language: "math", content: String(body.dropLast(2)).trimmingCharacters(in: .whitespaces)))
          index += 1
          continue
        }
        var cursor = index + 1
        var closed = false
        while cursor < lines.count {
          let line = lines[cursor].trimmingCharacters(in: .whitespaces)
          if line.hasSuffix("$$") {
            body += "\n" + String(line.dropLast(2))
            closed = true
            break
          }
          body += "\n" + lines[cursor]
          cursor += 1
        }
        if closed {
          blocks.append(.code(language: "math", content: body.trimmingCharacters(in: .whitespacesAndNewlines)))
          index = cursor + 1
          continue
        }
      }

      if trimmed.hasPrefix("> ") || trimmed == ">" {
        // 逐行读出层级，**按层级分块**。
        //
        // 只认 `> ` 会把 `>> 内层` 剥成 `> 内层` 留在正文，引用框里裸露出一个
        // `>` 记号；而只记「最深那层」又会把整块统一按最深缩进——`> 甲说 /
        // >> 乙说 / >>> 丙说` 会让甲说也被推到第三层去。连续同层的行归一块，
        // 层级一变就开新块，每层各自成一个视觉块。
        var pending: [(depth: Int, line: String)] = []
        while index < lines.count {
          let line = lines[index].trimmingCharacters(in: .whitespaces)
          guard line.hasPrefix(">") else { break }
          var rest = Substring(line)
          var depth = 0
          while rest.hasPrefix(">") {
            depth += 1
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
          }
          pending.append((min(depth - 1, 2), String(rest)))
          index += 1
        }
        var groupStart = 0
        while groupStart < pending.count {
          let depth = pending[groupStart].depth
          var groupEnd = groupStart
          while groupEnd < pending.count, pending[groupEnd].depth == depth { groupEnd += 1 }
          let text = pending[groupStart..<groupEnd]
            .map(\.line)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty {
            blocks.append(calloutBlock(from: text) ?? .quote(depth: depth, text: text))
          }
          groupStart = groupEnd
        }
        continue
      }

      if index + 1 < lines.count,
         let headers = tableCells(trimmed),
         isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
        let separatorIndex = index + 1
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
        let alignments = tableAlignments(
          lines[separatorIndex].trimmingCharacters(in: .whitespaces),
          width: width
        )
        blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
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
        var items: [ListItem] = []
        while index < lines.count {
          let raw = lines[index]
          let line = raw.trimmingCharacters(in: .whitespaces)
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
            // 深度必须从**未 trim 的原行**上算——trim 之后缩进就没了。
            items.append(ListItem(depth: listDepth(raw), text: listItemText(line)))
            index += 1
          } else {
            break
          }
        }
        if !items.isEmpty { blocks.append(.list(items)) }
        continue
      }

      if orderedListItem(trimmed) != nil {
        let start = orderedListNumber(trimmed) ?? 1
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
        if !items.isEmpty { blocks.append(.orderedList(start: start, items: items)) }
        continue
      }

      var paragraphLines: [String] = [lines[index]]
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
        paragraphLines.append(lines[index])
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
        likes: details.likes,
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
        isSelection: metadata.contains("已保存"),
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
  ) -> (score: String?, likes: String?, published: String?, permalink: URL?, explicitDepth: Int?) {
    var score: String?
    var likes: String?
    var published: [String] = []
    var permalink: URL?
    var explicitDepth: Int?
    for part in raw.components(separatedBy: " · ") {
      let value = part.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("score ") {
        score = String(value.dropFirst("score ".count)).trimmingCharacters(in: .whitespaces)
      } else if value.hasPrefix("赞 ") {
        likes = String(value.dropFirst("赞 ".count)).trimmingCharacters(in: .whitespaces)
      } else if value.hasPrefix("[原评论]("), value.hasSuffix(")") {
        permalink = URL(string: String(value.dropFirst("[原评论](".count).dropLast()))
      } else if value.hasPrefix("回复层级 ") {
        explicitDepth = Int(value.dropFirst("回复层级 ".count).trimmingCharacters(in: .whitespaces))
      } else if !value.isEmpty {
        published.append(value)
      }
    }
    return (score, likes, published.isEmpty ? nil : published.joined(separator: " · "), permalink, explicitDepth)
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

  private static func listItemText(_ line: String) -> String {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      return droppingLeadingBulletGlyph(text)
    }
    return line
  }

  /// 网页原文的列表项常常自带一个「•」字符，抓取、翻译后变成 `- • 文字`，
  /// 阅读区于是画出两个圆点（2026-09-24 实库：论文译文的「亮点」列表）。
  /// 列表自己会画圆点，这里只去掉紧跟在列表记号后面的那一个装饰字符；存的原文不动。
  static func droppingLeadingBulletGlyph(_ text: String) -> String {
    guard let first = text.first, "•·▪◦●‣⁃".contains(first) else { return text }
    let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? text : rest
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

  /// 列表项的嵌套深度。每两个空格（或一个 Tab）算一层，与抽取侧的缩进约定一致。
  ///
  /// 解析时把行首缩进 trim 掉，层级就地消失——抽取侧辛苦缩出来的两格到了阅读区
  /// 全变成顶层项，三层清单读起来是一堆并列条目。
  static func listDepth(_ line: String) -> Int {
    var spaces = 0
    for character in line {
      if character == " " { spaces += 1 }
      else if character == "\t" { spaces += 2 }
      else { break }
    }
    // 上限 3 层：再深的缩进在正文宽度里已经没有意义，且多半是原站排版噪声。
    return min(spaces / 2, 3)
  }

  /// 有序项的**原始编号**。渲染时按数组下标重编会把 `3.` 显示成 `1.`——抽取侧
  /// 已经按 `start` 和实际产出行算好了编号，读的一侧不该再算一遍。
  /// 行首编号本身，不判断是否算列表项——`orderedListItem` 的上限检查要用它，
  /// 不能反过来调用那个函数，否则互相递归。
  private static func orderedListLeadingNumber(_ line: String) -> Int? {
    guard let expression = try? NSRegularExpression(pattern: #"^(\d+)[.)]\s+.+$"#),
          let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: line) else { return nil }
    return Int(line[range])
  }

  private static func orderedListNumber(_ line: String) -> Int? {
    guard let expression = try? NSRegularExpression(pattern: #"^(\d+)[.)]\s+.+$"#),
          let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: line) else { return nil }
    return Int(line[range])
  }

  /// 有序项的编号上限。
  ///
  /// 按 CommonMark，`2026. 这一年发生了很多事` 确实是一个编号 2026 的列表项，
  /// GitHub 也这么渲染。但阅读场景里没有上千项的清单，而以年份、编号开头的
  /// **句子**很常见——判成列表的代价（正文变成一个孤零零的编号项，后面段落
  /// 继续 2027、2028）比漏判大得多。
  static let maximumOrderedListNumber = 999

  private static func orderedListItem(_ line: String) -> String? {
    // 超过上限的不当列表项，让它留在正文里。
    if let number = orderedListLeadingNumber(line), number > maximumOrderedListNumber {
      return nil
    }
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
    guard let first = lines.first else { return "" }
    var result = first.trimmingCharacters(in: .whitespaces)
    var previous = first
    for raw in lines.dropFirst() {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if previous.hasSuffix("  ") {
        result += "\n" + line
      } else if needsASCIISpace(before: line, after: result) {
        result += " " + line
      } else {
        result += line
      }
      previous = raw
    }
    return result
  }

  private static func needsASCIISpace(before next: String, after previous: String) -> Bool {
    guard let last = previous.last, let first = next.first else { return false }
    return last.isASCII && last.isLetter && first.isASCII && first.isLetter
  }

  /// 代码里的 `<task>` 是字面量。整篇扫描会把开发文洗成「已省略 HTML 片段」。
  private static func replacingHTMLLikeTokensPreservingCode(in source: String) -> String {
    // 折叠块先按整段处理：它常常把代码块包在里面（GitHub 说明文档的常见写法），
    // 按「代码 / 非代码」切开以后开头和结尾落在两边，就再也配不上对了。
    let source = convertingDetailsBlocks(source)
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
      let segment = preprocessingHTMLBlocks(String(source[index..<next]))
      result.append(convertingScriptSyntax(in: replacingHTMLLikeTokens(in: segment)))
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
        // GFM 只要求至少一个短横线；`| :-- | --: |` 这类短写法原来整表失效。
        && cell.contains("-")
    }
  }

  /// 从分隔行读出每列对齐：`:---:` 居中、`---:` 右、其余左。
  static func tableAlignments(_ separator: String, width: Int) -> [ColumnAlignment] {
    guard let cells = tableCells(separator) else {
      return Array(repeating: .leading, count: width)
    }
    var result: [ColumnAlignment] = cells.map { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespaces)
      let left = trimmed.hasPrefix(":")
      let right = trimmed.hasSuffix(":")
      if left && right { return .center }
      if right { return .trailing }
      return .leading
    }
    // 分隔行的列数和表宽对不上时按左对齐补齐——宁可不标，也不要错位。
    if result.count < width {
      result += Array(repeating: .leading, count: width - result.count)
    }
    return Array(result.prefix(width))
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
    guard let expression = try? NSRegularExpression(pattern: #"^\[!([A-Za-z]{2,16})\]([+-])?(?:\s+(.*))?$"#),
          let match = expression.firstMatch(
            in: firstLine,
            range: NSRange(firstLine.startIndex..., in: firstLine)
          ),
          let kindRange = Range(match.range(at: 1), in: firstLine)
    else { return nil }
    let kind = String(firstLine[kindRange]).lowercased()
    var fold = CalloutFold.none
    if let foldRange = Range(match.range(at: 2), in: firstLine) {
      fold = firstLine[foldRange] == "-" ? .collapsed : .expanded
    }
    // 标记后面那段是标题（Obsidian / Tolaria 的写法），不是正文第一句。
    var title = ""
    if let rest = Range(match.range(at: 3), in: firstLine) {
      title = String(firstLine[rest]).trimmingCharacters(in: .whitespaces)
    }
    let body = lines.dropFirst().map(String.init)
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return .callout(kind: kind, title: title, text: body, fold: fold)
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

      // 没有闭合的 `<` 不是标签，是正文里的小于号（`a<b`、`x<10`）。原来这里
      // 放一个占位符然后 `break`——那一个字符之后的整篇正文都被吞掉了。
      guard closed else {
        // 例外：看起来是被截断的真标签（已知标签名后跟属性，如结尾残留的
        // `<img src="…`），这一行剩下的都是标签残片，换成一个占位，不漏网址碎片。
        if looksLikeTruncatedTag(source[next...]) {
          result.append(contentsOf: omittedHTML)
          let lineEnd = source[next...].firstIndex(of: "\n") ?? source.endIndex
          index = lineEnd
          continue
        }
        result.append(source[index])
        index = next
        continue
      }
      result.append(contentsOf: replacement(forHTMLLikeToken: String(source[tokenStart..<cursor])))
      index = cursor
    }
    return result
  }

  private static func looksLikeTruncatedTag(_ rest: Substring) -> Bool {
    let line = rest.prefix { $0 != "\n" }
    let name = line.prefix { $0.isLetter || $0.isNumber }.lowercased()
    guard HTMLTokenPolicy.knownTags.contains(name) else { return false }
    let afterName = line.dropFirst(name.count)
    return afterName.first?.isWhitespace == true && afterName.contains("=")
  }

  private static func beginsHTMLLikeToken(_ character: Character) -> Bool {
    character == "/" || character == "!" || character == "?" || character.isLetter
  }

  /// 脚注（2026-09-24 对齐 Tolaria）：正文里的 `[^名字]` 换成上标编号，
  /// `[^名字]: 说明` 这些定义从原位置拿走，按被引用的先后编号，统一排到正文末尾。
  ///
  /// 没被引用的定义照样列出（排在后面），不丢内容；引用了却没定义的保持原样。
  /// 代码块里的方括号不动。
  static func resolvingFootnotes(_ source: String) -> String {
    guard source.contains("[^") else { return source }
    var definitions: [(id: String, text: String)] = []
    var bodyLines: [String] = []
    var inFence = false
    var lastDefinition: Int?
    let definitionPattern = try? NSRegularExpression(pattern: #"^\s{0,3}\[\^([^\]\s]+)\]:\s?(.*)$"#)
    for line in source.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
      if !inFence, let definitionPattern,
         let match = definitionPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
         let idRange = Range(match.range(at: 1), in: line),
         let textRange = Range(match.range(at: 2), in: line) {
        definitions.append((String(line[idRange]), String(line[textRange])))
        lastDefinition = definitions.count - 1
        continue
      }
      // 定义下面缩进的续行属于这条定义。
      if !inFence, let current = lastDefinition, line.hasPrefix("    ") || line.hasPrefix("\t"), !trimmed.isEmpty {
        definitions[current].text += " " + trimmed
        continue
      }
      if !trimmed.isEmpty { lastDefinition = nil }
      bodyLines.append(line)
    }
    guard !definitions.isEmpty else { return source }
    let known = Set(definitions.map(\.id))
    var numbers: [String: Int] = [:]
    var body = ""
    inFence = false
    let referencePattern = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
    for (offset, line) in bodyLines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
      var output = line
      if !inFence, let referencePattern {
        let ns = line as NSString
        var rebuilt = ""
        var cursor = 0
        for match in referencePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
          let id = ns.substring(with: match.range(at: 1))
          guard known.contains(id) else { continue }
          let number = numbers[id] ?? {
            let next = numbers.count + 1
            numbers[id] = next
            return next
          }()
          rebuilt += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
          rebuilt += String(ScriptMarker.supOpen) + "\(number)" + String(ScriptMarker.supClose)
          cursor = match.range.location + match.range.length
        }
        rebuilt += ns.substring(from: cursor)
        output = rebuilt
      }
      body += output
      if offset < bodyLines.count - 1 { body += "\n" }
    }
    let ordered = definitions.sorted { (numbers[$0.id] ?? Int.max) < (numbers[$1.id] ?? Int.max) }
    var notes = "\n\n---\n\n"
    for (index, definition) in ordered.enumerated() {
      notes += "\(index + 1). \(definition.text)\n"
    }
    // 列表序号与正文上标一致：按引用先后排，没被引用的接在后面。
    return body.trimmingCharacters(in: .whitespacesAndNewlines) + notes
  }

  /// 标签怎么换（2026-09-24 对齐 Tolaria 正文显示）。
  ///
  /// 原来只认 br、p、b/strong、i/em、code 这几个，其余一律换成「此处内容无法显示」。
  /// 实库里真正受害的是讲提示词的文章：`<instructions>`、`<system>`、`<context>`
  /// 本身就是正文，被整段吞掉。现在分三类：
  /// - 排版标签：换成对应的 Markdown 或内部记号，照格式显示；
  /// - 网页结构标签（div、span、表格零件…）：拆掉标签、留下文字；
  /// - 不认识的标签：多半是正文里写的尖括号，按原样显示。
  /// 注释、脚本、样式、表单控件这些网页杂质在 `preprocessingHTMLBlocks` 里连内容一起去掉。
  private static func replacement(forHTMLLikeToken token: String) -> String {
    let body = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return literalHTMLToken(token) }
    // `<!doctype>`、`<?xml ?>`、残留注释：网页壳子，不是正文。
    if body.hasPrefix("!") || body.hasPrefix("?") { return "" }

    let isClosing = body.first == "/"
    let nameAndSuffix = String(isClosing ? body.dropFirst() : Substring(body))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = nameAndSuffix.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }.lowercased()
    guard !name.isEmpty else { return literalHTMLToken(token) }
    let suffix = String(nameAndSuffix.dropFirst(name.count))

    guard HTMLTokenPolicy.knownTags.contains(name) else { return literalHTMLToken(token) }

    switch (name, isClosing) {
    case ("br", _): return "\n"
    case ("hr", false): return "\n\n---\n\n"
    case ("p", _): return "\n\n"
    case ("strong", _), ("b", _): return "**"
    case ("em", _), ("i", _), ("cite", _), ("dfn", _), ("var", _): return "*"
    case ("code", _), ("kbd", _), ("samp", _), ("tt", _): return "`"
    case ("s", _), ("del", _), ("strike", _): return "~~"
    case ("mark", _): return "=="
    case ("sup", false): return String(ScriptMarker.supOpen)
    case ("sup", true): return String(ScriptMarker.supClose)
    case ("sub", false): return String(ScriptMarker.subOpen)
    case ("sub", true): return String(ScriptMarker.subClose)
    case let (heading, false) where HTMLTokenPolicy.headingLevel(heading) != nil:
      return "\n\n" + String(repeating: "#", count: HTMLTokenPolicy.headingLevel(heading)!) + " "
    case let (heading, true) where HTMLTokenPolicy.headingLevel(heading) != nil:
      return "\n\n"
    case ("li", false): return "\n- "
    case ("li", true): return ""
    case ("img", false):
      guard let src = HTMLTokenPolicy.attribute("src", in: suffix), !src.isEmpty else { return "" }
      let alt = HTMLTokenPolicy.attribute("alt", in: suffix) ?? ""
      return "\n\n![\(alt)](\(src))\n\n"
    default:
      return HTMLTokenPolicy.blockTags.contains(name) ? "\n" : ""
    }
  }

  /// 按原样显示一个认不出的尖括号片段。反斜杠转义让 Markdown 解析器把它当普通文字。
  private static func literalHTMLToken(_ token: String) -> String {
    "\\" + token
  }

  /// 标签之外、成块出现的网页片段。在逐个标签替换之前处理：
  /// - 注释 `<!-- -->`：直接去掉（实库 83 篇带注释，原来每处都显示「无法显示」）；
  /// - 脚本、样式、表单控件、内嵌框架：连内容一起去掉，里面没有给人读的正文；
  /// - `<details><summary>标题</summary>内容</details>`：转成默认收起的提示框，
  ///   和 `> [!NOTE]-` 走同一个折叠组件。
  static func preprocessingHTMLBlocks(_ source: String) -> String {
    guard source.contains("<") else { return source }
    var value = replacing(#"<!--[\s\S]*?-->"#, in: source, with: "")
    // 不给人读的：连内容一起静默去掉。
    value = replacing(
      #"(?is)<(script|style|noscript|template|select|textarea|head|button)\b[^>]*>.*?</\1\s*>"#,
      in: value,
      with: ""
    )
    // 带画面的内嵌内容：显示不了，但要让读者知道这里原本有东西。
    value = replacing(
      #"(?is)<(iframe|object|embed|svg|canvas|audio|video)\b[^>]*>(?:.*?</\1\s*>)?"#,
      in: value,
      with: omittedHTML
    )
    return value
  }

  private static func convertingDetailsBlocks(_ source: String) -> String {
    guard source.range(of: "<details", options: .caseInsensitive) != nil,
          let expression = try? NSRegularExpression(
            pattern: #"(?is)<details\b([^>]*)>\s*(?:<summary\b[^>]*>(.*?)</summary\s*>)?(.*?)</details\s*>"#
          )
    else { return source }
    let nsSource = source as NSString
    var result = ""
    var cursor = 0
    let codeRanges = preservedCodeRanges(in: source).map { NSRange($0, in: source) }
    for match in expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
      // 代码里示范 `<details>` 写法的，是代码，不动。
      if codeRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
      result += nsSource.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let attributes = match.range(at: 1).location != NSNotFound ? nsSource.substring(with: match.range(at: 1)) : ""
      let summaryRaw = match.range(at: 2).location != NSNotFound ? nsSource.substring(with: match.range(at: 2)) : ""
      let bodyRaw = match.range(at: 3).location != NSNotFound ? nsSource.substring(with: match.range(at: 3)) : ""
      let title = replacingHTMLLikeTokens(in: summaryRaw)
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let bodyLines = replacingHTMLLikeTokensPreservingCode(in: bodyRaw)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
      let fold = attributes.range(of: "open", options: .caseInsensitive) == nil ? "-" : "+"
      var block = "\n\n> [!DETAILS]\(fold) \(title.isEmpty ? "详细信息" : title)"
      for line in bodyLines { block += "\n> " + line }
      result += block + "\n\n"
      cursor = match.range.location + match.range.length
    }
    result += nsSource.substring(from: cursor)
    return result
  }

  /// `H~2~O`、`x^2^` 这类上下标写法，换成内部记号，解析完再排成上下标。
  ///
  /// 必须在交给系统解析器之前换：它把单个波浪线也当删除线，`H~2~O` 会变成
  /// 「H2O」且 2 带删除线。双波浪线 `~~删除~~` 不动。
  static func convertingScriptSyntax(in source: String) -> String {
    guard source.contains("~") || source.contains("^") else { return source }
    var value = replacing(#"(?<![~\\])~(?!~)([^\s~]{1,30})(?<!~)~(?!~)"#, in: source, with: String(ScriptMarker.subOpen) + "$1" + String(ScriptMarker.subClose))
    value = replacing(#"(?<![\^\\])\^([^\s^\[\]]{1,30})\^"#, in: value, with: String(ScriptMarker.supOpen) + "$1" + String(ScriptMarker.supClose))
    return value
  }

  /// 上下标的内部记号：私用区字符，正文里不会自然出现。
  enum ScriptMarker {
    static let supOpen: Character = "\u{F8F0}"
    static let supClose: Character = "\u{F8F1}"
    static let subOpen: Character = "\u{F8F2}"
    static let subClose: Character = "\u{F8F3}"
    static let superscriptOffset: CGFloat = 5
    static let subscriptOffset: CGFloat = 3
    /// 上下标字号相对正文的比例。
    static let scale: CGFloat = 0.72
  }

  /// 把上下标记号换成基线偏移。字号由阅读排版层按偏移缩小（见 `SelectableReadingText.inline`）。
  static func applyingScripts(_ source: AttributedString) -> AttributedString {
    var value = source
    for (open, close, offset) in [
      (ScriptMarker.supOpen, ScriptMarker.supClose, ScriptMarker.superscriptOffset),
      (ScriptMarker.subOpen, ScriptMarker.subClose, -ScriptMarker.subscriptOffset),
    ] {
      while let opening = value.characters.firstIndex(of: open) {
        let afterOpen = value.characters.index(after: opening)
        guard let closing = value.characters[afterOpen...].firstIndex(of: close) else {
          value.removeSubrange(opening..<afterOpen)
          continue
        }
        value[afterOpen..<closing].appKit.baselineOffset = offset
        value.removeSubrange(closing..<value.characters.index(after: closing))
        value.removeSubrange(opening..<afterOpen)
      }
    }
    return value
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
  /// 已保存到本机的视频；按正文里第一段可绑定的文中视频就地播放。
  var localMediaFileURL: URL? = nil
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
  /// 点击正文里的时间码。没接就当普通链接处理（会被安全校验拦下）。
  var onSeekMedia: ((Double) -> Void)?
  /// 单击正文进入编辑。只给转写 / 笔记 / 稿这些可写正文。
  var onRequestEdit: ((String?) -> Void)?
  @State private var rejectedLink = false
  @State private var showsOutlinePopover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  /// 公式 / 流程图排好一批就会变；观察它，正文才会把占位换成图片。
  @ObservedObject private var webRenderer = ReadingWebRenderer.shared
  /// 打开了源码的流程图、打开了预览的 html 代码块（按内容区分）。
  @State private var toggledCodeBlocks: Set<String> = []

  /// 正文章节。
  ///
  /// 缓存在 state 里而不是每次 body 求值现算：解析全文的成本随正文长度线性增长，
  /// 库里最长那条 73432 字，跟着每次重绘重算会肉眼可见地卡。按 source 重算一次。
  @State private var outlineEntries: [MarkdownOutline.Entry] = []
  /// 收起的章节（按全文标题序号）。只改显示，不写回正文；换条目清空。
  @State private var collapsedHeadings: Set<Int> = []

  /// 少于 3 条不显示入口——一两个标题直接滚更快，摆个按钮只是噪音。
  private var showsOutlineEntry: Bool {
    guard !showsPlainText else { return false }
    if MarkdownOutline.shouldPresent(outlineEntries) { return true }
    // 只有模块、没有章节时，正文得长到需要跳转才值得占一行；一段 60 字的配文上
    // 摆个「目录 · 3 个模块」是噪音。
    return !navigationModules.isEmpty && source.count >= 600
  }

  /// 有模块时不能只写「章节」——那会让人以为点开只有正文标题，白白错过跳转入口。
  private var outlineButtonTitle: String {
    let sections = MarkdownOutline.shouldPresent(outlineEntries) ? outlineEntries.count : 0
    if sections > 0, !navigationModules.isEmpty { return "目录 · \(sections) 节及模块" }
    if sections > 0 { return "目录 · \(sections) 节" }
    return "目录 · \(navigationModules.count) 个模块"
  }

  /// 目录用弹层而不是常驻侧栏：阅读列宽只有 590pt，再切一栏会一直压缩正文；
  /// 而实测只有约两成条目的标题数够得上目录，常驻等于八成时间白占宽度。
  @ViewBuilder private var outlineButton: some View {
    Button {
      showsOutlinePopover = true
    } label: {
      Label(outlineButtonTitle, systemImage: "list.bullet.indent")
        .themedFont(.subheadline, weight: .medium)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help("正文章节与下方模块")
    .accessibilityLabel(outlineButtonTitle)
    .accessibilityIdentifier("history-content-outline-button")
    .popover(isPresented: $showsOutlinePopover, arrowEdge: .bottom) {
      outlinePopover(outlineEntries)
    }
  }

  @ViewBuilder private func outlinePopover(_ entries: [MarkdownOutline.Entry]) -> some View {
    let showsSections = MarkdownOutline.shouldPresent(entries)
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
        if showsSections {
          popoverGroupTitle("正文章节")
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
            Divider().padding(.vertical, DesignTokens.Space.sm)
          }
          popoverGroupTitle("下方模块")
          ForEach(navigationModules) { link in
            popoverRow(
              title: link.title,
              systemImage: link.systemImage,
              target: .module(link.anchor)
            )
          }
        }
      }
      .padding(DesignTokens.Space.md)
    }
    .frame(
      width: 260,
      height: min(CGFloat(entries.count + navigationModules.count) * 26 + 72, 400)
    )
    .accessibilityIdentifier("history-content-outline-popover")
  }

  @ViewBuilder private func popoverGroupTitle(_ text: String) -> some View {
    Text(text)
      .themedFont(.footnote, weight: .semibold)
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
          .themedFont(.callout)
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
    localMediaFileURL: URL? = nil,
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
    onSeekMedia: ((Double) -> Void)? = nil,
    onRequestEdit: ((String?) -> Void)? = nil
  ) {
    self.source = source
    self.sourceURL = sourceURL
    self.localImageURLs = localImageURLs
    self.localMediaFileURL = localMediaFileURL
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
    self.onSeekMedia = onSeekMedia
    self.onRequestEdit = onRequestEdit
  }

  var body: some View {
    ScrollViewReader { proxy in
    VStack(alignment: .leading, spacing: 10) {
      // 目录入口不能挂在「纯文本」那一行里：真实阅读区两个调用点都传
      // showsInlinePlainTextToggle: false（纯文本开关在菜单里），挂上去等于永不显示。
      if showsInlinePlainTextToggle || showsOutlineEntry {
        HStack(spacing: DesignTokens.Space.sm) {
          if showsOutlineEntry { outlineButton }
          Spacer(minLength: 0)
          if showsInlinePlainTextToggle {
            Toggle(isOn: $showsPlainText) {
              Text("纯文本")
                .themedFont(.subheadline, weight: .medium)
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
      } else if localImageURLs.isEmpty
                  && LocalMarkdownImageLayout.quotedTweetRange(in: source) == nil
                  && LocalMarkdownImageLayout.firstVideoMarkerRange(in: source) == nil {
        structuredMarkdown(source)
          .accessibilityIdentifier("history-content-markdown")
      } else {
        // 切段走备忘缓存：整篇正则扫描 + 图集合并只随正文与图片清单变化，
        // 巨型 ViewModel 引发的无关重绘不再重付这一遍。
        let segments = ReadingRenderCache.gallerySegments(
          markdown: source, localImageURLs: localImageURLs,
          appendsUnusedLocalImages: appendsUnusedLocalImages,
          groupsConsecutiveImages: groupsConsecutiveImages
        )
        // 标题前缀和一趟算完：旧写法把 `segments.prefix(i).reduce` 放在 ForEach 里，
        // 26 段的正文每帧要重扫约 350 次前缀切片并重查 blocks 缓存。循环里现在只查表。
        let headingOffsets = LocalMarkdownImageLayout.headingOffsets(of: segments)
        ForEach(
          Array(segments.enumerated()),
          // 不能只用 offset：换条目后同位置常仍是「第一张图」，SwiftUI 会复用
          // 子视图。把图片路径编进 id，强制按文件身份重建。
          id: \.offset
        ) { segmentIndex, segment in
          let folding = SectionFolding(entries: outlineEntries, collapsed: collapsedHeadings)
          // 图片、视频这些段夹在章节里：所在章节收起时一起藏。文字段自己按章节处理。
          let isMedia: Bool = { if case .text = segment { return false } else { return true } }()
          if isMedia, folding.isContentHidden(after: headingOffsets[segmentIndex] - 1) {
            EmptyView()
          } else {
          switch segment {
          case let .text(chunk):
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              structuredMarkdown(
                chunk,
                headingOffset: headingOffsets[segmentIndex],
                segmentIndex: segmentIndex
              )
            }
          case let .image(url):
            // 白底/描边由 InlineArticleImageView 控制；本文件不改其 chrome。
            // 比例、双击放大、菜单动作仍走原组件。
            InlineArticleImageView(url: url)
              .id(url.path)
          case let .gallery(urls):
            InlineArticleGalleryView(urls: urls)
              .id(urls.map(\.path).joined(separator: "|"))
          case let .quotedTweet(quote):
            QuotedTweetCardView(quote: quote, accentColor: accentColor, onOpenURL: { _ = openValidated($0) })
          case let .video(video):
            ArticleInlineVideoCard(
              video: video,
              localFileURL: localFile(forVideoAt: segmentIndex, in: segments),
              pageURL: sourceURL,
              onOpenURL: { _ = openValidated($0) }
            )
          }
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
      collapsedHeadings = []
      outlineEntries = MarkdownOutline.entries(
        from: ReadingRenderCache.blocks(from: MarkdownPresentation.sanitized(source))
      )
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

  /// Block-first reading layout: air before headings, body leading ~1.65, clear lists.
  private func structuredMarkdown(
    _ value: String,
    headingOffset: Int = 0,
    segmentIndex: Int = 0,
    foldsSections: Bool = true
  ) -> some View {
    // 相邻文本块合成一个 NSTextView 段（跨段连续选择）；代码块保持
    // SwiftUI 卡片独立渲染，复制按钮不丢。
    // 解析走备忘缓存：这个 body 每次重新求值都会路过这里，正文没变就不再重新解析。
    let blocks = ReadingRenderCache.blocks(from: value)
    let localHeadings = MarkdownOutline.entries(from: blocks)
    // 提示框里的正文不参与目录和章节折叠：它的标题不在全文目录的序号里。
    let anchorable = foldsSections && MarkdownOutline.shouldPresent(outlineEntries)
    func resolvedBlockIndex(_ localIndex: Int) -> Int {
      if foldsSections,
         let ordinal = localHeadings.firstIndex(where: { $0.blockIndex == localIndex }),
         outlineEntries.indices.contains(headingOffset + ordinal) {
        return outlineEntries[headingOffset + ordinal].blockIndex
      }
      return -((segmentIndex + 1) * 1_000_000 + localIndex + 1)
    }
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
      } else if case let .table(headers, rows, alignments) = block {
        runs.append((index, .table(headers: headers, rows: rows, alignments: alignments)))
      } else if case let .comments(section) = block {
        runs.append((index, .comments(section)))
      } else if case let .callout(kind, title, text, fold) = block {
        runs.append((index, .callout(kind: kind, title: title, text: text, fold: fold)))
      } else if !startsSection, case var .text(accumulated) = runs.last?.run {
        accumulated.append(block)
        runs[runs.count - 1].run = .text(accumulated)
      } else {
        runs.append((index, .text([block])))
      }
    }
    let folding = SectionFolding(entries: outlineEntries, collapsed: collapsedHeadings)
    /// 某个块属于全文第几个标题之下（含它自己是标题的情况）；在第一个标题之前为 nil。
    func owningHeading(_ localIndex: Int) -> Int? {
      let count = localHeadings.filter { $0.blockIndex <= localIndex }.count
      if count > 0 { return headingOffset + count - 1 }
      return headingOffset > 0 ? headingOffset - 1 : nil
    }
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(runs.enumerated()), id: \.offset) { position, entry in
          let owner = foldsSections ? owningHeading(entry.anchor) : nil
          // 文字段后面紧跟代码 / 表格 / 提示框时，文字末尾那一行空行会把两者撑得很开；
          // 去掉它，改由后面的块自己留一点上边距。文字段之间的节奏不变。
          // 提示框里的最后一段也去掉末尾空行（2026-09-25 并排对比）：否则框底多出两行高的空白。
          let isLastInEmbedded = !foldsSections && position == runs.count - 1
          let nextIsCard = (position + 1 < runs.count && !runs[position + 1].run.isText) || isLastInEmbedded
          let followsText = position > 0 && runs[position - 1].run.isText
          let headingLevel: Int? = {
            guard anchorable,
                  let local = localHeadings.first(where: { $0.blockIndex == entry.anchor }) else { return nil }
            return local.level
          }()
          if let level = headingLevel, let heading = owner {
            // 章节开头：标题旁放收起 / 展开的小三角（对齐 Tolaria）。
            if !folding.isHeadingHidden(heading) {
              let collapsed = folding.isCollapsed(heading)
              runView(collapsed ? entry.run.headingOnly : entry.run, trimsTrailingLine: nextIsCard && !collapsed, followsText: followsText)
                .overlay(alignment: .topLeading) {
                  SectionFoldToggle(isCollapsed: collapsed, level: level, tint: secondaryTextColor) {
                    if collapsedHeadings.contains(heading) {
                      collapsedHeadings.remove(heading)
                    } else {
                      collapsedHeadings.insert(heading)
                    }
                  }
                }
                .id(ScopedReadingAnchor(scope: anchorScope, block: resolvedBlockIndex(entry.anchor)))
            }
          } else if !folding.isContentHidden(after: owner ?? -1) {
            runView(
              entry.run, trimsTrailingLine: nextIsCard, followsText: followsText,
              // 全文第一段文字（不在提示框里）才当导语。
              emphasizesLede: foldsSections && segmentIndex == 0 && entry.anchor == 0
            )
              .id(ScopedReadingAnchor(scope: anchorScope, block: resolvedBlockIndex(entry.anchor)))
          }
        }
    }
  }

  @ViewBuilder
  private func runView(
    _ run: StructuredRun, trimsTrailingLine: Bool = false, followsText: Bool = false, emphasizesLede: Bool = false
  ) -> some View {
    if case .text = run {
      runContent(run, trimsTrailingLine: trimsTrailingLine, emphasizesLede: emphasizesLede)
    } else {
      runContent(run, trimsTrailingLine: false)
        .padding(.top, followsText ? 10 : 0)
    }
  }

  @ViewBuilder
  private func runContent(_ run: StructuredRun, trimsTrailingLine: Bool, emphasizesLede: Bool = false) -> some View {
    switch run {
    case let .text(textBlocks):
      let composed = ReadingRenderCache.attributed(
        blocks: textBlocks,
        readingFont: readingFont,
        palette: .init(
          primary: NSColor(primaryTextColor),
          secondary: NSColor(secondaryTextColor),
          accent: NSColor(accentColor)
        ),
        emphasizesLede: emphasizesLede
      )
      SelectableReadingTextView(
        // 组装走备忘缓存：内容、字体、配色没变时拿回同一个实例，
        // NSTextView 侧靠实例同一性直接短路（连深比较都不用做）。
        attributed: trimsTrailingLine ? ReadingRenderCache.trimmingTrailingNewline(composed) : composed,
        accent: NSColor(accentColor),
        onOpenLink: { url in _ = openValidated(url) },
        revealText: revealText,
        onRequestEdit: onRequestEdit
      )
      // 文字收在约 36 字的版心里；图片、代码、表格这些卡片仍用整栏宽（2026-09-28 样稿）。
      .frame(maxWidth: readingFont.bodySize * DesignTokens.Layout.readingTextMeasureEm, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    case let .callout(kind, title, text, fold):
      ReadingCalloutCard(
        kind: kind,
        title: title,
        fold: fold,
        accentColor: accentColor,
        secondaryTextColor: secondaryTextColor
      ) {
        if !text.isEmpty {
          // 按完整正文排：提示框 / 折叠块里常有代码、表格，只用文字视图会把它们丢掉。
          // AnyView 断开「结构化正文里套结构化正文」的类型递归。
          AnyView(structuredMarkdown(text, segmentIndex: 900_000 + text.utf8.count % 99_999, foldsSections: false))
        }
      }
      .padding(.bottom, 20)
    case let .code(language, content):
      specialCodeBlock(language: language, content: content)
        .padding(.bottom, 20)
    case let .table(headers, rows, alignments):
      markdownTable(headers: headers, rows: rows, alignments: alignments)
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
    case table(headers: [String], rows: [[String]], alignments: [MarkdownPresentation.ColumnAlignment])
    case comments(MarkdownPresentation.CommentSection)
    case callout(kind: String, title: String, text: String, fold: MarkdownPresentation.CalloutFold)

    var isText: Bool {
      if case .text = self { return true }
      return false
    }

    /// 章节收起时只留标题那一块。
    var headingOnly: StructuredRun {
      guard case let .text(blocks) = self, let first = blocks.first else { return self }
      return .text([first])
    }
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
            // 层级靠左缩进 + 点的形状一起表达：只缩进，扫一眼分不出是层级还是
            // 排版抖动；只换形状，长清单里又看不出从属关系。
            Group {
              if items[index].depth == 0 {
                Circle().fill(secondaryTextColor.opacity(0.85))
              } else {
                Circle().strokeBorder(secondaryTextColor.opacity(0.75), lineWidth: 1.2)
              }
            }
            .frame(width: 5, height: 5)
            .frame(width: 22, alignment: .center)
            .padding(.top, 8)
            .accessibilityHidden(true)
            inlineBody(items[index].text, baseSize: 16.5)
              .lineSpacing(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading, CGFloat(items[index].depth) * 18)
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
    case let .orderedList(start, items):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<items.count, id: \.self) { index in
          HStack(alignment: .top, spacing: 0) {
            Text("\(start + index).")
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
    case let .quote(depth, text):
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
        // 内层引用整体右移，层级一眼可见。
        .padding(.leading, CGFloat(depth) * 20)
        .padding(.bottom, 20)
    case let .callout(kind, title, text, _):
      VStack(alignment: .leading, spacing: 6) {
        Text(title.isEmpty ? MarkdownPresentation.calloutLabel(kind) : title)
          .themedFont(.caption, weight: .semibold)
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
    case let .table(headers, rows, alignments):
      markdownTable(headers: headers, rows: rows, alignments: alignments)
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

  /// 代码块按语言分流：公式、流程图排成图片；html 可切换预览；其余照常显示代码。
  @ViewBuilder
  private func specialCodeBlock(language: String?, content: String) -> some View {
    switch ReadingSpecialCode.kind(of: language) {
    case .math:
      ReadingRenderedBlock(
        request: webRequest(.blockMath, content),
        alignment: .center,
        failureTitle: "公式没有排出来，下面是原文"
      ) {
        codeBlock(language: language, content: content)
      }
    case .mermaid:
      let key = "mermaid|" + content
      let showsSource = toggledCodeBlocks.contains(key)
      VStack(alignment: .leading, spacing: 6) {
        specialBlockToolbar(title: "流程图", toggleTitle: showsSource ? "看图" : "看源码", key: key)
        if showsSource {
          codeBlock(language: language, content: content)
        } else {
          ReadingRenderedBlock(
            request: webRequest(.mermaid, content),
            alignment: .center,
            failureTitle: "流程图没有画出来，下面是原文"
          ) {
            codeBlock(language: language, content: content)
          }
        }
      }
    case .html:
      let key = "html|" + content
      let previews = toggledCodeBlocks.contains(key)
      VStack(alignment: .leading, spacing: 6) {
        specialBlockToolbar(title: "HTML", toggleTitle: previews ? "看代码" : "预览", key: key)
        if previews {
          ReadingRenderedBlock(
            request: webRequest(.html, content, width: 640),
            alignment: .leading,
            failureTitle: "预览失败，下面是代码"
          ) {
            codeBlock(language: language, content: content)
          }
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
              .strokeBorder(primaryTextColor.opacity(0.1), lineWidth: 1)
          )
        } else {
          codeBlock(language: language, content: content)
        }
      }
    case .none:
      if ReadingSpecialCode.isProse(language: language, content: content) {
        proseBlock(content)
      } else {
        codeBlock(language: language, content: content)
      }
    }
  }

  /// 装的是文字而不是代码的「代码块」（提示词、说明、txt / markdown）：用正文字体、
  /// 自动换行、不编行号。原来整块等宽字体加行号，和左边列表、上下文正文像两个软件
  /// （2026-09-24 Syc 对照 Tolaria 指出一体感差）。
  private func proseBlock(_ content: String) -> some View {
    Text(content)
      .font(readingFont.font(size: readingFont.bodySize - 1))
      .foregroundStyle(primaryTextColor.opacity(0.88))
      .lineSpacing(6)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 14)
      .padding(.leading, 16)
      .padding(.trailing, 40)
      .background(primaryTextColor.opacity(0.035), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
      .overlay(alignment: .topTrailing) {
        CodeCopyButton(content: content)
          .padding(8)
      }
      .accessibilityIdentifier("history-content-prose-block")
  }

  private func specialBlockToolbar(title: String, toggleTitle: String, key: String) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .themedFont(.caption, weight: .semibold)
        .foregroundStyle(secondaryTextColor)
      Spacer(minLength: 0)
      Button(toggleTitle) {
        if toggledCodeBlocks.contains(key) { toggledCodeBlocks.remove(key) } else { toggledCodeBlocks.insert(key) }
      }
      .buttonStyle(.link)
      .themedFont(.caption)
    }
  }

  private func webRequest(_ kind: ReadingWebRenderer.Kind, _ source: String, width: CGFloat = 0) -> ReadingWebRenderer.Request {
    ReadingWebRenderer.Request(
      kind: kind,
      source: source,
      color: NSColor(primaryTextColor).readingHex,
      fontSize: (readingFont.bodySize * (kind == .blockMath ? 1.15 : 1)).rounded(),
      isDark: colorScheme == .dark,
      width: width
    )
  }

  private func codeBlock(language: String?, content: String) -> some View {
    let lineCount = content.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
    return VStack(alignment: .leading, spacing: 0) {
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

      // 行号和代码分两列：行号只是阅读辅助，不跟代码一起被选中、复制（对齐 Tolaria）。
      // 代码不折行，两列逐行对齐。
      HStack(alignment: .top, spacing: 0) {
        if lineCount > 1 {
          Text((1...lineCount).map(String.init).joined(separator: "\n"))
            .font(.system(size: readingFont.bodySize - 2, design: .monospaced))
            .lineSpacing(4)
            .fixedSize()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(secondaryTextColor.opacity(0.55))
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .accessibilityHidden(true)
        }
        ScrollView(.horizontal, showsIndicators: true) {
          Text(CodeSyntaxHighlighter.highlighted(content, language: language))
            .font(.system(size: readingFont.bodySize - 2, design: .monospaced))
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize()
            .padding(12)
        }
        .fixedSize(horizontal: false, vertical: true)
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

  private func localFile(
    forVideoAt index: Int,
    in segments: [LocalMarkdownImageLayout.Segment]
  ) -> URL? {
    guard let localMediaFileURL else { return nil }
    let playable = segments.enumerated().compactMap { offset, segment -> Int? in
      if case let .video(video) = segment, video.bindsLocalFile { return offset }
      return nil
    }
    return playable.first == index ? localMediaFileURL : nil
  }

  private func openValidated(_ url: URL) -> OpenURLAction.Result {
    if let title = WikiLinkURL.title(from: url) {
      onFollowWikiLink?(title)
      return .handled
    }
    // 时间码跳转在安全校验之前拦下：它是内部指令，不该走 NSWorkspace 打开。
    if let seconds = MediaSeekLink.seconds(from: url) {
      onSeekMedia?(Double(seconds))
      return .handled
    }
    guard let resolved = try? MarkdownLinkResolver.resolve(url, sourceURL: sourceURL) else {
      rejectedLink = true
      return .handled
    }
    NSWorkspace.shared.open(resolved)
    return .handled
  }

  private func markdownTable(
    headers: [String],
    rows: [[String]],
    alignments: [MarkdownPresentation.ColumnAlignment]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      tableRow(headers, isHeader: true, alignments: alignments)
      Rectangle().fill(primaryTextColor.opacity(0.12)).frame(height: 1)
      ForEach(rows.indices, id: \.self) { index in
        tableRow(rows[index], isHeader: false, alignments: alignments)
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

  private func tableRow(
    _ cells: [String],
    isHeader: Bool,
    alignments: [MarkdownPresentation.ColumnAlignment]
  ) -> some View {
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
        // 按列对齐渲染：数字列右对齐、状态列居中，是作者排版时的决定，
        // 统一左对齐会让长表格的数字参差不齐、很难扫读。
        .multilineTextAlignment(
          (index < alignments.count ? alignments[index] : .leading).textAlignment
        )
        .frame(
          maxWidth: .infinity,
          alignment: (index < alignments.count ? alignments[index] : .leading).frameAlignment
        )
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
          .themedFont(.body, weight: .semibold)
          .foregroundStyle(.primary)
      }
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
        // Text 的 markdown 解析会把 t.co 等裸链接自动做成可点链接。
        Text(LocalizedStringKey(paragraph))
          .themedFont(.title3)
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
            Text("查看原推").themedFont(.callout)
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

/// 网页标签的分类（见 `MarkdownPresentation.replacement(forHTMLLikeToken:)`）。
enum HTMLTokenPolicy {
  /// 标准 HTML 标签。不在这里的一律当正文里的尖括号原样显示。
  static let knownTags: Set<String> = [
    "a", "abbr", "address", "article", "aside", "audio", "b", "bdi", "bdo", "big", "blockquote", "body",
    "br", "caption", "center", "cite", "code", "col", "colgroup", "data", "dd", "del", "details", "dfn",
    "div", "dl", "dt", "em", "figcaption", "figure", "font", "footer", "form", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hr", "html", "i", "img", "input", "ins", "kbd", "label", "legend", "li", "link",
    "main", "mark", "meta", "nav", "ol", "optgroup", "option", "p", "picture", "pre", "q", "s", "samp",
    "section", "small", "source", "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody",
    "td", "tfoot", "th", "thead", "time", "title", "tr", "tt", "u", "ul", "var", "video", "wbr", "fieldset",
    "track", "hgroup", "menu", "ruby", "rt", "rp",
  ]

  /// 拆掉后要留一个换行的块级标签，免得前后两段文字粘在一起。
  static let blockTags: Set<String> = [
    "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "div", "dl", "dt",
    "figcaption", "figure", "footer", "form", "header", "hgroup", "html", "legend", "main", "menu", "nav",
    "ol", "pre", "section", "table", "tbody", "tfoot", "thead", "tr", "ul", "fieldset", "details", "summary",
  ]

  static func headingLevel(_ name: String) -> Int? {
    guard name.count == 2, name.first == "h", let level = Int(String(name.last!)), (1...6).contains(level) else { return nil }
    return level
  }

  /// 读一个属性值：`src="…"`、`src='…'` 或不带引号。
  static func attribute(_ name: String, in text: String) -> String? {
    let pattern = #"(?i)\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    for group in 1...3 where match.range(at: group).location != NSNotFound {
      return ns.substring(with: match.range(at: group))
    }
    return nil
  }
}

/// 提示框卡片（对齐 Tolaria 的 callout）：左侧色条、浅底、图标和标题；
/// 带折叠标记的可以点标题收起 / 展开。正文仍是可选中的阅读文本。
struct ReadingCalloutCard<Content: View>: View {
  let kind: String
  let title: String
  let fold: MarkdownPresentation.CalloutFold
  let accentColor: Color
  let secondaryTextColor: Color
  let content: () -> Content
  @State private var isExpanded: Bool

  init(
    kind: String,
    title: String,
    fold: MarkdownPresentation.CalloutFold,
    accentColor: Color,
    secondaryTextColor: Color,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.kind = kind
    self.title = title
    self.fold = fold
    self.accentColor = accentColor
    self.secondaryTextColor = secondaryTextColor
    self.content = content
    _isExpanded = State(initialValue: fold != .collapsed)
  }

  private var tint: Color { MarkdownPresentation.calloutColor(kind, accent: accentColor) }
  private var heading: String { title.isEmpty ? MarkdownPresentation.calloutLabel(kind) : title }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if isExpanded {
        content()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
    .padding(.leading, 16)
    .padding(.trailing, 14)
    .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(
        topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0,
        style: .continuous
      )
      .fill(tint.opacity(0.85))
      .frame(width: 3)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history-content-markdown-callout")
  }

  private var label: some View {
    HStack(spacing: 6) {
      Image(systemName: MarkdownPresentation.calloutSymbol(kind))
        .foregroundStyle(tint)
      Text(heading)
        .themedFont(.subheadline, weight: .semibold)
        .foregroundStyle(tint)
        .multilineTextAlignment(.leading)
      if fold != .none {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(secondaryTextColor)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private var header: some View {
    if fold == .none {
      label
    } else {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        label.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "收起\(heading)" : "展开\(heading)")
    }
  }
}

/// 章节折叠的判定（2026-09-24 对齐 Tolaria：标题可收起下面的内容，直到下一个同级或更高级标题）。
struct SectionFolding {
  private var headingHidden: [Bool] = []
  private var contentHidden: [Bool] = []
  private let collapsed: Set<Int>

  init(entries: [MarkdownOutline.Entry], collapsed: Set<Int>) {
    self.collapsed = collapsed
    guard !collapsed.isEmpty else { return }
    var activeLevel: Int?
    for (ordinal, entry) in entries.enumerated() {
      if let active = activeLevel, entry.level <= active { activeLevel = nil }
      headingHidden.append(activeLevel != nil)
      if activeLevel == nil, collapsed.contains(ordinal) { activeLevel = entry.level }
      contentHidden.append(activeLevel != nil)
    }
  }

  func isCollapsed(_ ordinal: Int) -> Bool { collapsed.contains(ordinal) }

  func isHeadingHidden(_ ordinal: Int) -> Bool {
    headingHidden.indices.contains(ordinal) && headingHidden[ordinal]
  }

  /// 第 `ordinal` 个标题之后的正文是否被收起（-1 表示第一个标题之前，永远可见）。
  func isContentHidden(after ordinal: Int) -> Bool {
    contentHidden.indices.contains(ordinal) && contentHidden[ordinal]
  }
}

/// 标题左侧的收起 / 展开按钮。平时淡，悬停到这一节才明显，不给正文添噪点。
struct SectionFoldToggle: View {
  let isCollapsed: Bool
  let level: Int
  let tint: Color
  let action: () -> Void
  @State private var isHovering = false

  /// 按 `SelectableReadingText` 里标题的字号，让三角落在标题第一行中间。
  /// 章节总是从标题起一段新的文本视图，段首的段前距不生效，这里不计。
  private var topInset: CGFloat {
    let size: CGFloat = [1: 23, 2: 19.5, 3: 17][level] ?? 16
    return size * 0.68 - 8
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint.opacity(isCollapsed || isHovering ? 0.9 : 0.35))
    .onHover { isHovering = $0 }
    .offset(x: -20, y: topInset)
    .help(isCollapsed ? "展开这一节" : "收起这一节")
    .accessibilityLabel(isCollapsed ? "展开这一节" : "收起这一节")
  }
}

/// 需要特殊显示的代码块语言。
enum ReadingSpecialCode {
  enum Kind { case math, mermaid, html }

  /// 这个代码块装的是文字而不是代码。
  /// 语言写明是纯文本 / Markdown / 提示词的算；没写语言时，中文占到字母数字三成以上也算。
  static func isProse(language: String?, content: String) -> Bool {
    let normalized = language?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
    if ["txt", "text", "plain", "plaintext", "markdown", "md", "prompt"].contains(normalized) { return true }
    guard normalized.isEmpty else { return false }
    var cjk = 0
    var alphanumeric = 0
    for scalar in content.unicodeScalars.prefix(4_000) {
      if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
        cjk += 1
      } else if CharacterSet.alphanumerics.contains(scalar) {
        alphanumeric += 1
      }
    }
    return cjk > 0 && Double(cjk) / Double(cjk + alphanumeric) >= 0.3
  }

  static func kind(of language: String?) -> Kind? {
    switch language?.lowercased().trimmingCharacters(in: .whitespaces) {
    case "math", "latex", "tex", "katex": return .math
    case "mermaid": return .mermaid
    case "html", "htm": return .html
    default: return nil
    }
  }
}

/// 离屏排好的图片；没排好时占位，排失败时显示说明和原文。
struct ReadingRenderedBlock<Fallback: View>: View {
  let request: ReadingWebRenderer.Request
  let alignment: HorizontalAlignment
  let failureTitle: String
  @ViewBuilder let fallback: () -> Fallback
  @ObservedObject private var renderer = ReadingWebRenderer.shared

  var body: some View {
    let _ = renderer.generation
    switch renderer.outcome(for: request) {
    case let .rendered(result):
      // 按排版时的原尺寸显示（缩放会让公式里的小字糊掉）；比正文还宽的图可以横向拖动。
      let image = Image(nsImage: result.image)
        .frame(width: result.size.width, height: result.size.height)
        .accessibilityLabel(request.kind == .mermaid ? "流程图" : "公式")
      // 按正文列的实际宽度判断放不放得下（2026-09-25）：原来和固定的 660 比，正文列更窄时
      // 640 宽的流程图既没换成可拖动、也放不下，右边一截被裁掉。
      if request.kind == .mermaid {
        // 流程图比正文宽时整张等比缩进正文宽度（和 Tolaria 一样）：横向拖动只能看到半张图。
        // 公式不缩，缩小后上下标会糊，仍然走下面的横向拖动。
        Image(nsImage: result.image)
          .resizable()
          .aspectRatio(result.size.width / max(1, result.size.height), contentMode: .fit)
          .frame(maxWidth: result.size.width)
          .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
          .accessibilityLabel("流程图")
      } else {
        ViewThatFits(in: .horizontal) {
          image.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
          ScrollView(.horizontal, showsIndicators: true) { image }
            .frame(height: result.size.height + 14)
        }
      }
    case let .failed(message):
      VStack(alignment: .leading, spacing: 6) {
        Text("\(failureTitle)（\(message)）")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
        fallback()
      }
    case .none:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(request.kind == .mermaid ? "正在画流程图…" : "正在排版…")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 36, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
  }
}

/// 行内公式 `$…$`（2026-09-24 对齐 Tolaria）。
///
/// 解析前把公式换成「记号 + 十六进制」：TeX 里的 `_`、`*`、`\` 会被 Markdown 当成强调或
/// 转义，编码后原样穿过解析，排版层再解码、换成公式图片。
///
/// 认公式的规则取自 Pandoc：开头 `$` 后面不能是空白，结尾 `$` 前面不能是空白、后面不能
/// 紧跟数字——「价格 $5 到 $10」不会被当成公式。行内代码里的 `$` 不动。
enum InlineMath {
  static let open: Character = "\u{F8F6}"
  static let close: Character = "\u{F8F7}"

  private static let pattern = try? NSRegularExpression(
    pattern: #"(`+[^`]*`+)|(?<![\\$0-9A-Za-z])\$(?![\s$])([^$\n]{1,300}?)(?<![\s\\])\$(?![0-9A-Za-z$])"#
  )

  static func marking(_ source: String) -> String {
    guard source.contains("$"), let pattern else { return source }
    let ns = source as NSString
    var result = ""
    var cursor = 0
    for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
      guard match.range(at: 2).location != NSNotFound else { continue }
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let tex = ns.substring(with: match.range(at: 2))
      result += String(open) + tex.utf8.map { String(format: "%02x", $0) }.joined() + String(close)
      cursor = match.range.location + match.range.length
    }
    guard cursor > 0 else { return source }
    result += ns.substring(from: cursor)
    return result
  }

  static func decode(_ hex: Substring) -> String {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
      if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
      index = next
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// 这些块里可能有行内公式（粗筛：有没有 `$`）。
  static func mayContainMath(_ blocks: [MarkdownPresentation.Block]) -> Bool {
    blocks.contains { block in
      switch block {
      case let .paragraph(text), let .heading(_, text), let .quote(_, text): return text.contains("$")
      case let .callout(_, title, text, _): return text.contains("$") || title.contains("$")
      case let .list(items): return items.contains { $0.text.contains("$") }
      case let .orderedList(_, items): return items.contains { $0.contains("$") }
      case let .taskList(items): return items.contains { $0.text.contains("$") }
      default: return false
      }
    }
  }
}

