import Foundation
import LinkDigestCore

/// 主列表的「找回线索」：分组、标题、预览、时间都围绕「人凭什么记住一篇东西」来取。
///
/// 记忆强弱大致是：讲的是什么 > 长什么样 > 谁发的 > 大概哪天存的 > 我对它做过什么。
/// 这里只放纯函数，行视图和列表只管画。
enum HistoryListFinding {
  // MARK: - 按存入时间分组

  /// 列表分组。组内顺序跟列表查询一致：存入时间倒序。
  enum DayGroup: Hashable {
    case today
    case yesterday
    case lastWeek
    case month(year: Int, month: Int)

    func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
      switch self {
      case .today: "今天"
      case .yesterday: "昨天"
      case .lastWeek: "近 7 天"
      case let .month(year, month):
        year == calendar.component(.year, from: now) ? "\(month) 月" : "\(year) 年 \(month) 月"
      }
    }
  }

  static func savedAtMilliseconds(of row: HistoryRowProjection) -> Int64 {
    row.createdAtMilliseconds ?? row.updatedAtMilliseconds
  }

  static func dayGroup(
    savedAtMilliseconds milliseconds: Int64,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> DayGroup {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    // 按日历天算：昨晚 23 点存的，今早看就是「昨天」。
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
    ).day ?? 0
    switch days {
    case ...0: return .today
    case 1: return .yesterday
    case 2...6: return .lastWeek
    default:
      let parts = calendar.dateComponents([.year, .month], from: date)
      return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }
  }

  struct Section: Identifiable {
    let group: DayGroup
    /// 全局下标跟着走：「同一博主连续出现只显示一次作者」要看的是整张列表里的上一行。
    let entries: [(index: Int, row: HistoryRowProjection)]
    var id: DayGroup { group }
  }

  static func sections(
    for rows: [HistoryRowProjection],
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Section] {
    // 攒满一组再收：原来每加一行就把整组复制一遍，几百行落在同一组时是平方级。
    var result: [Section] = []
    var currentGroup: DayGroup?
    var currentEntries: [(index: Int, row: HistoryRowProjection)] = []
    for (index, row) in rows.enumerated() {
      let group = dayGroup(savedAtMilliseconds: savedAtMilliseconds(of: row), now: now, calendar: calendar)
      if group != currentGroup, let finished = currentGroup {
        result.append(Section(group: finished, entries: currentEntries))
        currentEntries = []
      }
      currentGroup = group
      currentEntries.append((index, row))
    }
    if let currentGroup {
      result.append(Section(group: currentGroup, entries: currentEntries))
    }
    return result
  }

  /// 行尾时间。分组标题已经说了「哪天」，今天和昨天只补几点；更早的给日期。
  static func compactSavedTime(
    savedAtMilliseconds milliseconds: Int64,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    switch dayGroup(savedAtMilliseconds: milliseconds, now: now, calendar: calendar) {
    case .today, .yesterday:
      return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    case .lastWeek, .month:
      return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
  }

  // MARK: - 标题：跳过开头的感叹

  /// 开头这句只是情绪（「卧槽！」「爽了！」「绝了」），不说明内容讲什么。
  static func isHook(_ sentence: String) -> Bool {
    let meaningful = sentence.filter { $0.isLetter || $0.isNumber }
    return !meaningful.isEmpty && meaningful.count <= hookCharacterLimit
  }

  static let hookCharacterLimit = 6

  /// 标题取自正文首句、而首句只是感叹时，往后找第一句真正有内容的话。
  ///
  /// 只动「从正文合成的标题」：文章本来的标题、总结生成的标题都原样保留。
  /// 找不到更好的就退回原标题，永远不返回空。
  static func informativeCaptionTitle(caption: String, sourcePreview: String?) -> String {
    guard isHook(caption.replacingOccurrences(of: "…", with: "")),
          var remainder = sourcePreview?.trimmingCharacters(in: .whitespacesAndNewlines),
          !remainder.isEmpty
    else { return caption }
    while !remainder.isEmpty {
      let sentence = CapturedContentNaming.leadingSentence(from: remainder)
      guard !sentence.isEmpty else { break }
      let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
      // 「！！！」这种只剩标点的碎片也跳过。
      let hasWords = trimmed.contains { $0.isLetter || $0.isNumber }
      if hasWords, !isHook(trimmed),
         let title = CapturedContentNaming.captionTitle(from: trimmed) {
        return title
      }
      remainder = String(remainder.dropFirst(sentence.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return caption
  }

  // MARK: - 预览：正文里接下来那句

  /// 没总结过的内容，预览行显示正文——去掉和标题重复的开头。
  ///
  /// 原来这一行在没有总结时拿作者名来填，和下面的作者行重复，等于白占一行。
  /// 取不到有用的文字就返回 nil，让这一行干脆不出现。
  static func sourcePreviewLine(title: String, sourcePreview: String?, titleComesFromBody: Bool = true) -> String? {
    guard let cleaned = HistoryRowProjection.sanitizedDirectoryPreview(sourcePreview, isSummary: false) else {
      return nil
    }
    // 裸网址不是「讲了什么」：「7 more ideas…」那种推文去掉标题后只剩一个链接。
    var text = cleaned.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    let head = title.hasSuffix("…") ? String(title.dropLast()) : title
    // 只有标题本来就是从正文截出来的，才去正文中间找它：文章自己的标题（比如「Claude」）
    // 恰好出现在正文前几十个字里时，去掉它会把句子从中间截断。
    if titleComesFromBody, !head.isEmpty, let range = text.range(of: head), text[..<range.lowerBound].count <= 40 {
      // 标题可能是跳过感叹句后取的第二句，所以前面允许有一小段。
      text = String(text[range.upperBound...])
    } else {
      // 标题比预览片段还长（整条推文当标题）时 range(of:) 找不到，按公共开头去重。
      let shared = zip(text, head).prefix { $0 == $1 }.count
      if shared >= min(24, head.count) { text = String(text.dropFirst(shared)) }
    }
    text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    guard text.filter({ $0.isLetter || $0.isNumber }).count >= 4 else { return nil }
    return text
  }

  /// 行里最多露几个标签：多了挤掉作者和时间，一个就够当关键词——
  /// 找回有侧栏标签云和搜索两个入口，行内只是提示。
  static let visibleTagLimit = 1
}
