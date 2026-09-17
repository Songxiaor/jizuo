import Foundation

/// 正文里的时间码 ↔ 可点击的跳转链接。
///
/// 为什么在**渲染时**转换，而不是把链接写进落库的正文：
/// - 已经存下来的稿子（听写、画面字幕）立刻就能点，不必重跑一遍识别；
/// - 导出的 Markdown、知识库文件仍是干净的 `00:00 正文`，下游检索不会突然
///   多出一堆自定义 scheme；
/// - 时间码的书写格式将来若要调整，只需改这里一处。
public enum MediaSeekLink {
  public static let scheme = "linkdigest-seek"

  public static func url(atSeconds seconds: Int) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    // 秒数放 path：host 会被规范化，数字虽然安全，但和 WikiLinkURL 保持同一种写法。
    components.path = "/\(max(0, seconds))"
    return components.url ?? URL(string: "\(scheme):/0")!
  }

  /// 从点击到的地址还原秒数；不是跳转地址则返回 nil。
  public static func seconds(from url: URL) -> Int? {
    guard url.scheme == scheme else { return nil }
    return Int(url.path.dropFirst())
  }

  /// 把每段开头的时间码替换成可点击链接。
  ///
  /// 只认**行首**的时间码。正文里出现的 `3:15`（比如「第 3:15 条」这种）不该
  /// 变成跳转链接——段首时间码是排版的一部分，行中的数字是内容。
  ///
  /// 接受 `MM:SS` 和 `H:MM:SS` 两种写法，与 `TimedTranscriptionAccumulator.clock`
  /// 及 `BurnedInSubtitles.timestamp` 的输出一致。
  public static func linkifyingTimestamps(in markdown: String) -> String {
    guard markdown.contains(":") else { return markdown }
    var output: [String] = []
    output.reserveCapacity(markdown.count / 40)
    for line in markdown.components(separatedBy: "\n") {
      guard let parsed = leadingTimestamp(in: line) else {
        output.append(line)
        continue
      }
      let rest = String(line[parsed.endIndex...])
      let link = url(atSeconds: parsed.seconds).absoluteString
      output.append("[\(parsed.text)](\(link))\(rest)")
    }
    return output.joined(separator: "\n")
  }

  /// 行首时间码的解析结果。
  struct LeadingTimestamp {
    let text: String
    let seconds: Int
    let endIndex: String.Index
  }

  static func leadingTimestamp(in line: String) -> LeadingTimestamp? {
    var index = line.startIndex
    var fields: [Int] = []
    var digits = ""

    while index < line.endIndex {
      let character = line[index]
      if character.isNumber {
        digits.append(character)
        // 三位以上不可能是时间码的一段，直接判否，免得把长数字吃进来。
        if digits.count > 2 { return nil }
        index = line.index(after: index)
        continue
      }
      if character == ":" {
        guard let value = Int(digits) else { return nil }
        fields.append(value)
        digits = ""
        index = line.index(after: index)
        continue
      }
      break
    }

    // 收尾的那一段（秒）必须存在，且必须是两位——`0:0` 不是合法时间码。
    guard digits.count == 2, let last = Int(digits) else { return nil }
    fields.append(last)
    // 时间码后面必须跟空白，否则那是别的东西（例如 `12:30PM`）。
    guard index < line.endIndex, line[index].isWhitespace else { return nil }

    let seconds: Int
    switch fields.count {
    case 2: seconds = fields[0] * 60 + fields[1]
    case 3: seconds = fields[0] * 3600 + fields[1] * 60 + fields[2]
    default: return nil
    }
    guard fields.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
    return LeadingTimestamp(text: String(line[line.startIndex..<index]), seconds: seconds, endIndex: index)
  }
}

/// 转写稿「当文章读」的样子：去掉段首时间码，把一句一段的字幕合成正常段落。
///
/// 只改显示，不改存下来的正文。时间码对「对照视频」有用，对「当文章读」是噪音。
public enum TranscriptReadingText {
  /// 前面几十行里至少有两行以时间码开头，才算带时间码的转写稿。只扫开头，长稿也不费事。
  public static func hasLeadingTimecodes(_ markdown: String, scanLines: Int = 40) -> Bool {
    var hits = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: true).prefix(scanLines) {
      if MediaSeekLink.leadingTimestamp(in: String(line)) != nil {
        hits += 1
        if hits >= 2 { return true }
      }
    }
    return false
  }

  /// - Parameters:
  ///   - pauseSeconds: 相邻两句开始时间差这么多秒以上，另起一段（说话停顿、换话题）。
  ///   - paragraphCharacters: 一段累计到这么长，遇到句末标点就另起一段，免得整篇一大坨。
  public static func removingTimecodes(
    from markdown: String,
    pauseSeconds: Int = 12,
    paragraphCharacters: Int = 280
  ) -> String {
    guard hasLeadingTimecodes(markdown) else { return markdown }
    var output: [String] = []
    var paragraph = ""
    var lastSeconds: Int?

    func flush() {
      let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { output.append(trimmed) }
      paragraph = ""
    }

    for rawLine in markdown.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      guard let stamp = MediaSeekLink.leadingTimestamp(in: line) else {
        // 标题、说明这类不带时间码的行原样保留，自成一段。
        flush()
        output.append(line)
        lastSeconds = nil
        continue
      }
      let text = String(line[stamp.endIndex...]).trimmingCharacters(in: .whitespaces)
      if let lastSeconds, stamp.seconds - lastSeconds >= pauseSeconds {
        flush()
      } else if paragraph.count >= paragraphCharacters, endsSentence(paragraph) {
        flush()
      }
      lastSeconds = stamp.seconds
      guard !text.isEmpty else { continue }
      paragraph = joined(paragraph, text)
    }
    flush()
    return output.joined(separator: "\n\n")
  }

  private static func endsSentence(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
    return "。！？.!?…」\"”".contains(last)
  }

  /// 中文句子之间不加空格，英文句子之间加一个。
  private static func joined(_ head: String, _ tail: String) -> String {
    guard let left = head.last, let right = tail.first else { return head + tail }
    let isCJK: (Character) -> Bool = { $0.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false }
    return isCJK(left) || isCJK(right) ? head + tail : head + " " + tail
  }
}
