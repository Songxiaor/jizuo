import Foundation
import XCTest
@testable import LinkDigestCore

/// 定时触发。
///
/// 判据是「今天的触发点已经过了，而今天还没跑过」，不是「此刻正好是 9:00」。
/// 这个区别是整个功能成不成立的关键：后者要求 App 恰好在那一分钟开着，
/// 用户十点才开电脑就永远等不到，而他要的正是「打开就已经有了」。
final class TopicScheduleTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(
      year: 2026, month: 8, day: day, hour: hour, minute: minute
    ))!
  }

  private let schedule = TopicSchedule(isEnabled: true, hour: 9, minute: 0)

  func testDisabledNeverRuns() {
    let off = TopicSchedule(isEnabled: false, hour: 9, minute: 0)
    XCTAssertFalse(off.shouldRun(now: date(2, 18), lastRun: nil, calendar: calendar))
  }

  /// 还没到点。
  func testDoesNotRunBeforeTheTriggerTime() {
    XCTAssertFalse(schedule.shouldRun(now: date(2, 8), lastRun: nil, calendar: calendar))
  }

  /// 十点才开电脑 —— 照样要跑。这是这个设计存在的理由。
  func testRunsWhenOpenedAfterTheTriggerTime() {
    XCTAssertTrue(
      schedule.shouldRun(now: date(2, 10), lastRun: nil, calendar: calendar),
      "错过那一分钟就不跑的话，这个功能对晚开电脑的人等于不存在"
    )
  }

  /// 今天跑过了就不再跑。
  func testDoesNotRunTwiceInOneDay() {
    XCTAssertFalse(
      schedule.shouldRun(now: date(2, 15), lastRun: date(2, 9, 1), calendar: calendar)
    )
  }

  /// 昨天跑过不算今天跑过。
  func testYesterdaysRunDoesNotCountForToday() {
    XCTAssertTrue(
      schedule.shouldRun(now: date(2, 10), lastRun: date(1, 9, 1), calendar: calendar)
    )
  }

  /// 今天触发点**之前**跑过（比如用户手动点了「出选题」）——
  /// 定时那一次照跑。
  ///
  /// 手动跑一次不该顶掉当天的自动那次：用户八点半手动出了一批，
  /// 九点的自动那批是基于不同素材窗口的，不是重复。
  func testAManualRunBeforeTheTriggerDoesNotSkipToday() {
    XCTAssertTrue(
      schedule.shouldRun(now: date(2, 10), lastRun: date(2, 8, 30), calendar: calendar)
    )
  }

  /// 正好在触发点那一刻。
  func testRunsExactlyAtTheTriggerTime() {
    XCTAssertTrue(schedule.shouldRun(now: date(2, 9, 0), lastRun: nil, calendar: calendar))
  }

  // MARK: - 存取

  func testRoundTrips() {
    let schedule = TopicSchedule(isEnabled: true, hour: 7, minute: 30)
    XCTAssertEqual(TopicSchedule.decoded(from: schedule.encoded()), schedule)
  }

  func testEmptyOrCorruptStorageDecodesToDefault() {
    XCTAssertEqual(TopicSchedule.decoded(from: ""), .default)
    XCTAssertEqual(TopicSchedule.decoded(from: "{坏的"), .default)
  }

  /// 默认关着。
  ///
  /// 自动跑会花掉用户的订阅额度。默认开启等于替他做了一个花钱的决定。
  func testDefaultIsOff() {
    XCTAssertFalse(TopicSchedule.default.isEnabled)
  }

  /// 越界的时间被夹住，不会产生跑不掉的配置。
  func testOutOfRangeTimesAreClamped() {
    let weird = TopicSchedule(isEnabled: true, hour: 99, minute: -5)
    XCTAssertEqual(weird.hour, 23)
    XCTAssertEqual(weird.minute, 0)
    XCTAssertEqual(weird.displayTime, "23:00")
  }

  func testDisplayTimeIsPadded() {
    XCTAssertEqual(TopicSchedule(isEnabled: true, hour: 7, minute: 5).displayTime, "07:05")
  }
}
