import Foundation
import LinkDigestCore

/// 列表/详情用的展示名称。只从已有 title/body 派生，不写回存储、不改导出、不调用模型。
enum CapturedContentNaming {
  enum Origin: Equatable {
    case sourceTitle
    case caption
    case fallback
  }

  struct Name: Equatable {
    let text: String
    let origin: Origin
  }

  static func name(
    title: String?,
    body: String?,
    host: String,
    author: String?,
    published: String?
  ) -> Name {
    let parsed = MarkdownNoteFrontmatter.parse(body ?? "")
    let cleaned = cleanedSourceText(parsed.body, preservesSoleHeading: true)
    let platform = platformKind(host)

    if platform == .douyin {
      if let text = derivedCaption(from: captionBasisTitle(title, host: host))
        ?? derivedCaption(from: firstSubstantialParagraph(in: cleaned))
      {
        return Name(text: text, origin: .caption)
      }
      return fallbackName(host: host, author: author, published: published)
    }

    if platform == .x, let basis = captionBasisTitle(title, host: host),
       titleMatchesBodyStart(basis, cleanedBody: cleaned)
    {
      if let text = derivedCaption(from: basis)
        ?? derivedCaption(from: firstSubstantialParagraph(in: cleaned))
      {
        return Name(text: text, origin: .caption)
      }
    }

    if platform != .douyin, let source = usableSourceTitle(title, host: host) {
      return Name(text: source, origin: .sourceTitle)
    }

    if let text = derivedCaption(from: firstSubstantialParagraph(in: cleaned)) {
      return Name(text: text, origin: .caption)
    }
    return fallbackName(host: host, author: author, published: published)
  }

  /// 仅当配文名称就是去图片/合成标题后的全文时，阅读区才藏掉重复标题。
  static func hidesRepeatedHeading(name: Name, body: String) -> Bool {
    guard name.origin == .caption else { return false }
    let cleaned = cleanedSourceText(MarkdownNoteFrontmatter.parse(body).body, preservesSoleHeading: true)
    let normalizedBody = normalizedWhitespace(cleaned)
    guard !normalizedBody.isEmpty else { return false }
    return normalizedBody == normalizedWhitespace(name.text)
  }
}

private extension CapturedContentNaming {
  enum PlatformKind {
    case douyin
    case x
    case independent
  }

  static let captionCharacterLimit = 40

  static func platformKind(_ host: String) -> PlatformKind {
    switch HistoryPlatformRegistry.canonicalHost(for: host) {
    case "douyin.com": return .douyin
    case "x.com": return .x
    default: return .independent
    }
  }

  static func titleDisplayURL(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if trimmed.contains("://") { return trimmed }
    return "https://\(trimmed)"
  }

  static func usableSourceTitle(_ title: String?, host: String) -> String? {
    let displayed = CapturedDocumentTitle.display(title, for: titleDisplayURL(host))
    return displayed == CapturedDocumentTitle.missing ? nil : displayed
  }

  /// 配文基础用去掉无标题/旧 URL 标题后的原句，不走课时名缩短。
  static func captionBasisTitle(_ title: String?, host: String) -> String? {
    guard usableSourceTitle(title, host: host) != nil else { return nil }
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  static func derivedCaption(from raw: String?) -> String? {
    guard var remainder = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !remainder.isEmpty
    else { return nil }
    while !remainder.isEmpty {
      let sentence = firstSentence(from: remainder)
      let stripped = strippingTrailingHashtags(sentence)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !stripped.isEmpty {
        if stripped.count <= captionCharacterLimit { return stripped }
        return String(stripped.prefix(captionCharacterLimit)) + "…"
      }
      if sentence.count >= remainder.count { break }
      remainder = String(remainder.dropFirst(sentence.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  static func firstSentence(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let chars = Array(trimmed)
    var index = 0
    while index < chars.count {
      let character = chars[index]
      if character == "\n" || character == "\r" {
        return String(chars[0..<index]).trimmingCharacters(in: .whitespaces)
      }
      if "。！？".contains(character) {
        return String(chars[0...index]).trimmingCharacters(in: .whitespaces)
      }
      if character == "." || character == "!" || character == "?" {
        if character == ".", isVersionDecimal(in: chars, at: index) {
          index += 1
          continue
        }
        let nextIsBoundary = index + 1 >= chars.count || chars[index + 1].isWhitespace
        if nextIsBoundary {
          return String(chars[0...index]).trimmingCharacters(in: .whitespaces)
        }
      }
      index += 1
    }
    return trimmed
  }

  static func isVersionDecimal(in chars: [Character], at index: Int) -> Bool {
    guard index > 0, index + 1 < chars.count else { return false }
    return isASCIIDigit(chars[index - 1]) && isASCIIDigit(chars[index + 1])
  }

  static func isASCIIDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
  }

  /// 尾部 `#话题` 串删掉；`C#`、`Issue#12` 这种普通 # 含义留下。
  static func strippingTrailingHashtags(_ text: String) -> String {
    var value = text
    while true {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let hash = trimmed.lastIndex(of: "#") else { return trimmed }
      let after = trimmed[trimmed.index(after: hash)...]
      guard !after.isEmpty, !after.contains(where: { $0.isWhitespace || $0 == "#" }) else {
        return trimmed
      }
      if hash > trimmed.startIndex {
        let previous = trimmed[trimmed.index(before: hash)]
        if previous.isASCII && (previous.isLetter || previous.isNumber) {
          return trimmed
        }
      }
      value = String(trimmed[..<hash])
    }
  }

  static func titleMatchesBodyStart(_ title: String, cleanedBody: String) -> Bool {
    let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let bodyText = cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !titleText.isEmpty, !bodyText.isEmpty else { return false }
    if bodyText.hasPrefix(titleText) { return true }
    if titleText.hasSuffix("…") {
      let stem = String(titleText.dropLast())
      if !stem.isEmpty, bodyText.hasPrefix(stem) { return true }
    }
    if titleText.hasSuffix("...") {
      let stem = String(titleText.dropLast(3))
      if !stem.isEmpty, bodyText.hasPrefix(stem) { return true }
    }
    return false
  }

  static func cleanedSourceText(_ markdown: String, preservesSoleHeading: Bool) -> String {
    let withoutImages = strippingMarkdownImages(from: markdown)
    return strippingLeadingATXHeading(from: withoutImages, preservesSoleHeading: preservesSoleHeading)
  }

  static func strippingMarkdownImages(from markdown: String) -> String {
    var text = markdown
    while let start = text.range(of: "![") {
      guard let altEnd = text.range(of: "](", range: start.upperBound..<text.endIndex),
            let close = text[altEnd.upperBound...].firstIndex(of: ")")
      else { break }
      text.removeSubrange(start.lowerBound...close)
    }
    return text
  }

  static func strippingLeadingATXHeading(from markdown: String, preservesSoleHeading: Bool) -> String {
    var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var removedHeading: String?
    if let headingIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      let headingLine = lines[headingIndex].trimmingCharacters(in: .whitespaces)
      if let heading = atxHeadingText(headingLine) {
        removedHeading = heading
        lines.remove(at: headingIndex)
        while headingIndex < lines.count,
              lines[headingIndex].trimmingCharacters(in: .whitespaces).isEmpty
        {
          lines.remove(at: headingIndex)
        }
      }
    }
    let body = lines.joined(separator: "\n")
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return preservesSoleHeading ? (removedHeading ?? "") : ""
    }
    return body
  }

  /// `# 标题` 才是 heading；`#话题` 没有空格，不是标题。
  static func atxHeadingText(_ line: String) -> String? {
    let hashes = line.prefix(while: { $0 == "#" })
    guard (1...6).contains(hashes.count) else { return nil }
    let rest = line.dropFirst(hashes.count)
    guard rest.first == " " || rest.first == "\t" else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  static func firstSubstantialParagraph(in markdown: String) -> String? {
    var inFence = false
    var current: [String] = []
    var paragraphs: [String] = []

    func flush() {
      let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      current.removeAll(keepingCapacity: true)
      if !block.isEmpty { paragraphs.append(block) }
    }

    for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      if inFence { continue }
      if trimmed.isEmpty {
        flush()
        continue
      }
      if isSkippableLine(trimmed) { continue }
      current.append(line)
    }
    flush()
    return paragraphs.first
  }

  static func isSkippableLine(_ trimmed: String) -> Bool {
    if atxHeadingText(trimmed) != nil { return true }
    if trimmed == "---" || trimmed == "***" || trimmed == "___" { return true }
    if isMarkdownImageLine(trimmed) { return true }
    if isBareURL(trimmed) { return true }
    if isHashtagOnly(trimmed) { return true }
    return false
  }

  static func isHashtagOnly(_ text: String) -> Bool {
    strippingTrailingHashtags(text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  static func isMarkdownImageLine(_ line: String) -> Bool {
    line.hasPrefix("![") && line.contains("](")
  }

  static func isBareURL(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
    return !trimmed.contains(where: \.isWhitespace)
  }

  static func fallbackName(host: String, author: String?, published: String?) -> Name {
    let owner = author?.trimmingCharacters(in: .whitespacesAndNewlines)
    let platform = HistoryPlatformDisplay.name(forHost: host)
    let head = (owner?.isEmpty == false ? owner! : platform)
    var text = "\(head) · 内容"
    if let date = dateOnly(from: published) {
      text += " · \(date)"
    }
    return Name(text: text, origin: .fallback)
  }

  static func dateOnly(from published: String?) -> String? {
    let raw = published?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else { return nil }
    if let match = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
      return String(raw[match])
    }
    if let match = raw.range(of: #"\d{4}年\d{1,2}月\d{1,2}日"#, options: .regularExpression) {
      return String(raw[match])
    }
    return nil
  }

  static func normalizedWhitespace(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
