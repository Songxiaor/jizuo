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
    guard let date = standardISO.date(from: value) ?? fractionalISO.date(from: value) else { return value }
    if calendar == Calendar.autoupdatingCurrent,
       timeZone == TimeZone.autoupdatingCurrent,
       locale.identifier == "zh_CN" {
      return defaultLocalized.string(from: date)
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
