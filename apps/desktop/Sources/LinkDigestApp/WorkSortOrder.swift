import Foundation

enum WorkSortOrder: String, CaseIterable, Identifiable {
  case original, newest, oldest, mostLiked, leastLiked
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: "抓取顺序"
    case .newest: "发布时间 · 新到旧"
    case .oldest: "发布时间 · 旧到新"
    case .mostLiked: "点赞 · 高到低"
    case .leastLiked: "点赞 · 低到高"
    }
  }

  /// Sort a display copy only. Unknown values are last in BOTH directions;
  /// ties retain discovery order, so refreshing metadata does not shuffle peers.
  func sorted<T>(_ items: [T], likes: (T) -> String?, published: (T) -> String?,
                 referenceDate: Date? = nil) -> [T] {
    guard self != .original else { return items }
    let parser = WorkSortDateParser(referenceDate: referenceDate)
    let metrics = self == .mostLiked || self == .leastLiked
    let descending = self == .mostLiked || self == .newest
    let keyed = items.enumerated().map { index, item in
      (index: index, item: item, value: metrics ? Self.metric(likes(item)) : parser.parse(published(item)))
    }
    return keyed.sorted { a, b in
      switch (a.value, b.value) {
      case let (x?, y?) where x != y: return descending ? x > y : x < y
      case (_?, nil): return true
      case (nil, _?): return false
      default: return a.index < b.index
      }
    }.map(\.item)
  }

  static func metric(_ raw: String?) -> Double? {
    guard var text = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    text = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
    if text.hasSuffix("+") { text.removeLast() }
    var multiplier = 1.0
    for (suffix, scale) in [("万", 10_000.0), ("亿", 100_000_000.0), ("w", 10_000.0),
                            ("k", 1_000.0), ("千", 1_000.0), ("m", 1_000_000.0), ("b", 1_000_000_000.0)] {
      if text.hasSuffix(suffix) { text.removeLast(suffix.count); multiplier = scale; break }
    }
    guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite,
          value >= 0, (value * multiplier).isFinite else { return nil }
    return value * multiplier
  }
}

/// Created once per sort, not once per comparator invocation.
private final class WorkSortDateParser {
  let referenceDate: Date?
  let iso = ISO8601DateFormatter()
  let fractional = ISO8601DateFormatter()
  let full: [DateFormatter]
  let short = DateFormatter()

  init(referenceDate: Date?) {
    self.referenceDate = referenceDate
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    full = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm",
            "yyyy年M月d日 HH:mm", "yyyy年M月d日", "EEE, MM/dd/yyyy – HH:mm"].map { format in
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.calendar = Calendar(identifier: .gregorian)
      f.isLenient = false
      f.dateFormat = format
      return f
    }
    short.locale = Locale(identifier: "en_US_POSIX")
    short.calendar = Calendar(identifier: .gregorian)
    short.isLenient = false
    short.dateFormat = "yyyy年M月d日"
  }

  func parse(_ raw: String?) -> Double? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    if let date = fractional.date(from: text) ?? iso.date(from: text) { return date.timeIntervalSince1970 }
    // Do not let DateFormatter invent a year for a page label like “8月31日”.
    if text.range(of: #"[12][0-9]{3}"#, options: .regularExpression) != nil {
      for f in full { if let date = f.date(from: text) { return date.timeIntervalSince1970 } }
    }
    guard let referenceDate else { return nil }
    let calendar = Calendar(identifier: .gregorian)
    if text == "今天" { return calendar.startOfDay(for: referenceDate).timeIntervalSince1970 }
    if text == "昨天" { return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: referenceDate))?.timeIntervalSince1970 }
    if text.range(of: #"^[0-9]{1,2}月[0-9]{1,2}日$"#, options: .regularExpression) != nil {
      let year = calendar.component(.year, from: referenceDate)
      guard var date = short.date(from: "\(year)年\(text)") else { return nil }
      if date > referenceDate, let previous = calendar.date(byAdding: .year, value: -1, to: date) { date = previous }
      return date.timeIntervalSince1970
    }
    return nil
  }
}
