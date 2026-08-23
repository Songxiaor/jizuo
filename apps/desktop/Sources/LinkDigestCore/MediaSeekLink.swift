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
