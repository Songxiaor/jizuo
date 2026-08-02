import Foundation

/// 每天什么时候自动出一次选题。
///
/// 「定时」在这里的含义很有限:App 开着的时候，到点了跑一次。
/// 不装后台守护、不注册 launchd——那是另一个量级的东西(要处理权限、
/// 卸载残留、App 没在跑时结果往哪放)，而这个功能的价值是
/// 「早上打开就已经有了」，App 开着跑就能做到。
public struct TopicSchedule: Sendable, Equatable, Codable {
  public var isEnabled: Bool
  /// 本地时间的小时与分钟。
  public var hour: Int
  public var minute: Int

  public init(isEnabled: Bool = false, hour: Int = 9, minute: Int = 0) {
    self.isEnabled = isEnabled
    self.hour = min(23, max(0, hour))
    self.minute = min(59, max(0, minute))
  }

  public static let `default` = TopicSchedule()

  /// 现在该跑吗?
  ///
  /// 判据是「今天的触发点已经过了，而今天还没跑过」，不是「此刻正好是 9:00」。
  /// 后者要求 App 恰好在那一分钟开着——用户十点才开电脑就永远等不到，
  /// 而他要的正是「打开就已经有了」。
  ///
  /// - Parameter lastRun: 上次跑的时刻。从没跑过传 nil。
  public func shouldRun(
    now: Date, lastRun: Date?, calendar: Calendar = .current
  ) -> Bool {
    guard isEnabled else { return false }
    guard let trigger = calendar.date(
      bySettingHour: hour, minute: minute, second: 0, of: now
    ) else { return false }
    guard now >= trigger else { return false }
    guard let lastRun else { return true }
    // 上次就在今天的触发点之后跑过 —— 今天这一次已经完成了。
    return lastRun < trigger
  }

  // MARK: - 存取

  public static let storageKey = "workbench.topics.schedule"
  public static let lastRunKey = "workbench.topics.lastRunAt"

  public func encoded() -> String {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  public static func decoded(from raw: String) -> TopicSchedule {
    guard let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(TopicSchedule.self, from: data)
    else { return .default }
    return value
  }

  public var displayTime: String {
    String(format: "%02d:%02d", hour, minute)
  }
}
