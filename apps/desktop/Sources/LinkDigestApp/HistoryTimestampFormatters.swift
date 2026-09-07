import Foundation

// 列表行与播放卡片都在用；不能再藏在 HistoryContentView 里当 file-private。
extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
  var emptyToNil: String? { trimmedNonEmpty }
}

enum HistoryTimestampFormatter {
  // DateFormatter 的创建是毫秒级开销，而这条路在列表行和详情页反复走。
  // 配好即只读（只调 string(from:)），只读用法下 DateFormatter 线程安全。
  // 两档样式各缓存一份；测试注入自定义历法/时区时仍走现建路径。
  private static let sameDayFormatter = makeDefault(dateStyle: .none)
  private static let otherDayFormatter = makeDefault(dateStyle: .medium)

  private static func makeDefault(dateStyle: DateFormatter.Style) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = dateStyle
    formatter.timeStyle = .short
    return formatter
  }

  static func text(
    _ milliseconds: Int64?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    // 和 `HistoryPublishedTimestampFormatter` 同一个理由，这里之前漏了：
    // 界面通篇中文但 App 没有本地化资源，`.autoupdatingCurrent` 会回退成英文，
    // 于是详情页同一屏里出现「发布 2026年8月5日 14:37」和
    // 「创建时间 Aug 5, 2026 at 18:13」两种写法。钉住 zh_CN。
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    guard let milliseconds else { return "—" }
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    var localCalendar = calendar
    localCalendar.timeZone = timeZone
    let sameDay = localCalendar.isDate(date, inSameDayAs: now)
    if calendar == Calendar.autoupdatingCurrent,
       timeZone == TimeZone.autoupdatingCurrent,
       locale.identifier == "zh_CN" {
      return (sameDay ? sameDayFormatter : otherDayFormatter).string(from: date)
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = localCalendar
    formatter.timeZone = timeZone
    formatter.dateStyle = sameDay ? .none : .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

enum HistoryPublishedTimestampFormatter {
  // ISO8601 解析器与 zh_CN 展示格式化器都缓存：列表每一行都要走这里，
  // 原来一次调用现建 2~3 个 formatter。ISO8601DateFormatter 线程安全；
  // DateFormatter 只读用法（只调 string(from:)）同样安全。
  private nonisolated(unsafe) static let standardISO = ISO8601DateFormatter()
  private nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter
  }()
  private static let defaultLocalized: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let compactDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "M/d"
    return formatter
  }()
  private static let compactYearDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy/M/d"
    return formatter
  }()
  private static let directoryDateTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter
  }()
  private static let gmtGregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  static func compactDate(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
    return (calendar.component(.year, from: date) == calendar.component(.year, from: now)
      ? compactDay : compactYearDay).string(from: date)
  }

  static func compactText(_ value: String, now: Date = Date()) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "^[·•|｜,，\\s]+|[·•|｜,，\\s]+$", with: "", options: .regularExpression)
    guard let date = standardISO.date(from: cleaned) ?? fractionalISO.date(from: cleaned) else {
      return text(cleaned)
    }
    return compactDate(date, now: now)
  }

  static func directoryCardStamp(
    published: String?,
    savedAtMilliseconds: Int64,
    now: Date = Date(),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    _ = now
    if let published = published?.trimmedNonEmpty {
      let cleaned = published.replacingOccurrences(
        of: "^[·•|｜,，\\s]+|[·•|｜,，\\s]+$",
        with: "",
        options: .regularExpression
      )
      if let date = standardISO.date(from: cleaned) ?? fractionalISO.date(from: cleaned) {
        return "发布于 \(dateTimeStamp(date, timeZone: timeZone))"
      }
      if let dateOnly = calendarDateOnly(cleaned) {
        return "发布于 \(dateOnly.year)年\(dateOnly.month)月\(dateOnly.day)日"
      }
      if let wallclock = wallclockStamp(cleaned) {
        return "发布于 \(wallclock)"
      }
      return "发布于 \(cleaned)"
    }
    let saved = Date(timeIntervalSince1970: Double(savedAtMilliseconds) / 1_000)
    return "保存于 \(dateTimeStamp(saved, timeZone: timeZone))"
  }

  private static func dateTimeStamp(_ date: Date, timeZone: TimeZone) -> String {
    if timeZone == TimeZone.autoupdatingCurrent {
      return directoryDateTime.string(from: date)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
  }

  private static func calendarDateOnly(_ value: String) -> (year: Int, month: Int, day: Int)? {
    guard value.count == 10 else { return nil }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var components = DateComponents()
    components.calendar = gmtGregorian
    components.timeZone = gmtGregorian.timeZone
    components.year = year
    components.month = month
    components.day = day
    guard components.isValidDate else { return nil }
    return (year, month, day)
  }

  /// Douyin wall-clock `yyyy-MM-dd HH:mm[:ss]` has no timezone; keep the digits.
  private static func wallclockStamp(_ value: String) -> String? {
    guard value.count == 16 || value.count == 19 else { return nil }
    let separator = value.index(value.startIndex, offsetBy: 10)
    guard value[separator] == " " else { return nil }
    guard let date = calendarDateOnly(String(value[..<separator])) else { return nil }
    let timeParts = value[value.index(after: separator)...]
      .split(separator: ":", omittingEmptySubsequences: false)
    let expected = value.count == 19 ? 3 : 2
    guard timeParts.count == expected,
          timeParts.allSatisfy({ $0.count == 2 && $0.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" } }),
          let hour = Int(timeParts[0]), let minute = Int(timeParts[1]),
          (0...23).contains(hour), (0...59).contains(minute)
    else { return nil }
    if expected == 3 {
      guard let second = Int(timeParts[2]), (0...59).contains(second) else { return nil }
    }
    return "\(date.year)年\(date.month)月\(date.day)日 \(twoDigits(hour)):\(twoDigits(minute))"
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  static func text(
    _ value: String?,
    calendar: Calendar = .autoupdatingCurrent,
    // The app's entire UI is Simplified Chinese but ships unlocalized, so an
    // autoupdating locale falls back to English ("Jul 22, 2026 at 03:47").
    // Pin zh_CN so dates read like the rest of the interface.
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    // 旧抓取可能存有抖音 DOM 的「· 」装饰前缀；展示层剥掉它兜底。
    let cleanedValue = value?
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "^[·•|｜,，\\s]+|[·•|｜,，\\s]+$", with: "", options: .regularExpression)
    guard let value = cleanedValue?.trimmedNonEmpty else { return "发布时间未获取" }
    if let dateOnly = calendarDateOnly(value) {
      return "\(dateOnly.year)年\(dateOnly.month)月\(dateOnly.day)日"
    }
    if let wallclock = wallclockStamp(value) { return wallclock }
    guard let date = standardISO.date(from: value) ?? fractionalISO.date(from: value) else { return value }
    if calendar == Calendar.autoupdatingCurrent,
       timeZone == TimeZone.autoupdatingCurrent,
       locale.identifier == "zh_CN" {
      return dateTimeStamp(date, timeZone: timeZone)
    }
    let localized = DateFormatter()
    localized.locale = locale
    localized.calendar = calendar
    localized.timeZone = timeZone
    localized.dateStyle = .medium
    localized.timeStyle = .short
    return localized.string(from: date)
  }
}

/// 列表行的时间：近的说"多久以前"，远的说日期。
///
/// 列表行原本占两排——"发布 2026年8月5日 14:37" 和 "创建 2026年8月5日"，
/// 加起来吃掉近一半行高，而它们是整行最次要的信息。合成一排的前提是
/// 把精度降下来：扫列表时"3 天前"就够判断新鲜度了，具体到分钟只有
/// 打开详情才有意义（详情页仍显示完整时间）。
///
/// 七天是分界：一周内人对"几天前"有直觉，超过一周就只剩"很久以前"，
/// 那时候日期反而更有用。
enum HistoryRelativeTime {
  // 列表滚动路径，formatter 缓存理由同 `HistoryTimestampFormatter`。
  private static let defaultTimeOfDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
  private static let defaultDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static func isDefault(_ locale: Locale, _ calendar: Calendar) -> Bool {
    locale.identifier == "zh_CN" && calendar == Calendar.autoupdatingCurrent
  }

  static func text(
    _ milliseconds: Int64,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = Locale(identifier: "zh_CN")
  ) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    // 按"日历天"算而不是按 24 小时：昨晚 23:00 和今早 08:00 差 9 小时，
    // 但人会说"昨天"，不会说"9 小时前"。
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case ..<0:
      // 未来时间通常是源站时区解析出的偏差，别显示"-2 天前"这种。
      return dayText(date, locale: locale, calendar: calendar)
    case 0:
      if isDefault(locale, calendar) { return "今天 \(defaultTimeOfDay.string(from: date))" }
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.dateFormat = "HH:mm"
      return "今天 \(formatter.string(from: date))"
    case 1: return "昨天"
    case 2...6: return "\(days) 天前"
    default: return dayText(date, locale: locale, calendar: calendar)
    }
  }

  private static func dayText(_ date: Date, locale: Locale, calendar: Calendar) -> String {
    if isDefault(locale, calendar) { return defaultDay.string(from: date) }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}
