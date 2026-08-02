import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 选题板的日期标签。
///
/// 板上多数时候只关心今天和昨天，写成日期反而要多想一步。
final class TopicBoardDayLabelTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return calendar
  }

  private func label(daysAgo: Int, now: Date = Date()) -> String {
    let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    return TopicBoardView.dayLabel(
      TopicCandidate.dayStart(of: date, calendar: calendar), now: now, calendar: calendar
    )
  }

  func testTodayAndYesterdayReadAsWords() {
    XCTAssertEqual(label(daysAgo: 0), "今天")
    XCTAssertEqual(label(daysAgo: 1), "昨天")
  }

  func testOlderDaysUseADate() {
    let older = label(daysAgo: 5)
    XCTAssertNotEqual(older, "今天")
    XCTAssertNotEqual(older, "昨天")
    XCTAssertTrue(older.contains("月"))
  }

  /// 跨年的那些要带上年份，否则「1月3日」分不清是今年还是去年。
  func testEarlierYearsCarryTheYear() {
    let now = try? XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))
    )
    guard let now else { return XCTFail("造不出日期") }
    let lastYear = try? XCTUnwrap(
      calendar.date(from: DateComponents(year: 2025, month: 1, day: 3))
    )
    guard let lastYear else { return XCTFail("造不出日期") }
    let text = TopicBoardView.dayLabel(
      TopicCandidate.dayStart(of: lastYear, calendar: calendar), now: now, calendar: calendar
    )
    XCTAssertTrue(text.contains("2025"), "跨年的日期没带年份：\(text)")
  }

  func testSameYearOmitsTheYear() {
    let now = try? XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2)))
    let earlier = try? XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 3)))
    guard let now, let earlier else { return XCTFail("造不出日期") }
    let text = TopicBoardView.dayLabel(
      TopicCandidate.dayStart(of: earlier, calendar: calendar), now: now, calendar: calendar
    )
    XCTAssertFalse(text.contains("2026"), "同一年不必带年份：\(text)")
  }
}
