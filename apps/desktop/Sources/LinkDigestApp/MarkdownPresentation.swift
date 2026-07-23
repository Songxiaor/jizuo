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
  enum Segment: Equatable {
    case text(String)
    case image(URL)
  }

  static func segments(markdown: String, localImageURLs: [URL], appendsUnusedLocalImages: Bool = true) -> [Segment] {
    guard !localImageURLs.isEmpty else { return [.text(markdown)] }
    let byHash = Dictionary(uniqueKeysWithValues: localImageURLs.map { ($0.lastPathComponent, $0) })
    guard let expression = try? NSRegularExpression(
      pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)|<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
      options: [.caseInsensitive]
    ) else { return [.text(markdown)] }

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
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
  }

  /// Plain-text mode intentionally shares the same HTML-safe presentation
  /// projection as rich mode. It differs only in Markdown interpretation, not
  /// in what untrusted persisted source may become visible on screen.
  static func plainTextPresentation(_ source: String) -> String {
    sanitized(source)
  }

  // MARK: - Structural blocks (visible hierarchy)

  enum Block: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, content: String)
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
          if isListItem(line) {
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
  @State private var rejectedLink = false

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
    showsInlinePlainTextToggle: Bool = true
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
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsInlinePlainTextToggle {
        HStack {
          Spacer(minLength: 0)
          Toggle(isOn: $showsPlainText) {
            Text("纯文本")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.tertiary)
          }
          .toggleStyle(.checkbox)
          .controlSize(.mini)
          .accessibilityIdentifier("history-content-plain-text-toggle")
        }
      }

      if showsPlainText {
        SelectableReadingTextView(
          attributed: ReadingTextComposer.plain(
            MarkdownPresentation.plainTextPresentation(source),
            readingFont: readingFont,
            color: NSColor(primaryTextColor)
          ),
          accent: NSColor(accentColor),
          onOpenLink: { url in openValidated(url) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if localImageURLs.isEmpty {
        structuredMarkdown(source)
          .accessibilityIdentifier("history-content-markdown")
      } else {
        ForEach(Array(LocalMarkdownImageLayout.segments(markdown: source, localImageURLs: localImageURLs, appendsUnusedLocalImages: appendsUnusedLocalImages).enumerated()), id: \.offset) { _, segment in
          switch segment {
          case let .text(chunk):
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              structuredMarkdown(chunk)
            }
          case let .image(url):
            // 白色衬卡 + 后台下采样解码 + 双击进灯箱；见 ArticleImageViewing。
            InlineArticleImageView(url: url)
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
  }

  /// Block-first reading layout: air before headings, body leading ~1.65, clear lists.
  @ViewBuilder
  private func structuredMarkdown(_ value: String) -> some View {
    // 相邻文本块合成一个 NSTextView 段（跨段连续选择）；代码块保持
    // SwiftUI 卡片独立渲染，复制按钮不丢。
    let blocks = MarkdownPresentation.blocks(from: value)
    var runs: [StructuredRun] = []
    for block in blocks {
      if case let .code(language, content) = block {
        runs.append(.code(language: language, content: content))
      } else if case var .text(accumulated) = runs.last {
        accumulated.append(block)
        runs[runs.count - 1] = .text(accumulated)
      } else {
        runs.append(.text([block]))
      }
    }
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
        switch run {
        case let .text(textBlocks):
          SelectableReadingTextView(
            attributed: ReadingTextComposer.attributed(
              blocks: textBlocks,
              readingFont: readingFont,
              palette: .init(
                primary: NSColor(primaryTextColor),
                secondary: NSColor(secondaryTextColor),
                accent: NSColor(accentColor)
              )
            ),
            accent: NSColor(accentColor),
            onOpenLink: { url in openValidated(url) }
          )
        case let .code(language, content):
          codeBlock(language: language, content: content)
            .padding(.bottom, 20)
        }
      }
    }
    .foregroundStyle(primaryTextColor)
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
      inlineBody(text, baseSize: MarkdownPresentation.bodyFontSize)
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
    case let .orderedList(items):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<items.count, id: \.self) { index in
          HStack(alignment: .top, spacing: 0) {
            Text("\(index + 1).")
              .font(.system(size: 14, weight: .medium, design: .rounded))
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(secondaryTextColor)
        Spacer(minLength: 0)
        CodeCopyButton(content: content)
      }
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(primaryTextColor.opacity(0.055))

      ScrollView(.horizontal, showsIndicators: true) {
        Text(content)
          .font(.system(size: 13.5, design: .monospaced))
          .lineSpacing(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .padding(12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(primaryTextColor.opacity(0.025))
    }
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
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
    case 1: return readingFont.font(size: 23, weight: .bold)
    case 2: return readingFont.font(size: 19.5, weight: .semibold)
    case 3: return readingFont.font(size: 17, weight: .semibold)
    default: return readingFont.font(size: 16, weight: .semibold)
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

/// Copy button for a code card: hover raises it from secondary to primary so
/// the pointer affordance is visible before the click.
private struct CodeCopyButton: View {
  let content: String
  @State private var isHovered = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(content, forType: .string)
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
  static func saveImage(at url: URL) {
    guard let data = try? Data(contentsOf: url) else { return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedFilename(for: url, data: data)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    try? data.write(to: destination)
  }

  static func copyImage(_ image: NSImage) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
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
