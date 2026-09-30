import XCTest
import SwiftUI
@testable import LinkDigestApp

/// 工序印（2026-09-28）与明式印文（2026-09-30）：每枚印的篆字都能画出来、铺满印面又不出框，来历说明照实写。
final class SealMarkTests: XCTestCase {
  func testEveryGlyphFillsTheFaceInsideTheFrame() throws {
    let face = CGRect(x: 6, y: 6, width: 88, height: 88)
    for key in SealMark.Glyph.allCases.map(\.rawValue) + ["brand-zuo", "brand-ji"] {
      let outline = try XCTUnwrap(SealGeometry.unitPath(key), "\(key) 取不到字形")
      let bounds = outline.boundingRect
      XCTAssertTrue(face.contains(bounds), "\(key) 的字出了印框：\(bounds)")
      XCTAssertGreaterThan(bounds.height, 60, "\(key) 应铺满印面高度")
    }
    // 两字印古法右起：「汲」在右半，「作」在左半。
    XCTAssertGreaterThan(try XCTUnwrap(SealGeometry.unitPath("brand-ji")).boundingRect.minX, 50)
    XCTAssertLessThan(try XCTUnwrap(SealGeometry.unitPath("brand-zuo")).boundingRect.maxX, 50)
  }

  func testSVGPathHandlesRelativeCurvesAndArcs() {
    let quarter = SVGPath.parse("M80 89 A9 9 0 0 1 89 80").boundingRect
    XCTAssertEqual(quarter.minX, 80, accuracy: 0.5)
    XCTAssertEqual(quarter.minY, 80, accuracy: 0.5)
    let wave = SVGPath.parse("M10 90 q6.5 -8 13 0 q6.5 -8 13 0").boundingRect
    XCTAssertEqual(wave.maxX, 36, accuracy: 0.01)
    let smooth = SVGPath.parse("M11 15 c5 -7 12 -7 15 -1 s10 7 15 1").boundingRect
    XCTAssertEqual(smooth.maxX, 41, accuracy: 0.01)
  }

  func testProvenanceOnlySaysWhatIsRecorded() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 11, minute: 2))!
    XCTAssertEqual(ProcessStepRecord(step: .summary, date: date, note: "DeepSeek v4 Flash").provenance, "摘 · 总结 · 9月28日 11:02 · DeepSeek v4 Flash")
    XCTAssertEqual(ProcessStepRecord(step: .proof, date: date, note: nil).provenance, "校 · 校对 · 9月28日 11:02")
    XCTAssertEqual(ProcessStepRecord(step: .comments, date: nil, note: nil).provenance, "评 · 评论 · 已做")
    XCTAssertEqual(ProcessStepRecord.shortFormat(date, now: date), "11:02")
    XCTAssertEqual(ProcessStepRecord.shortFormat(date, now: date.addingTimeInterval(86_400 * 3)), "9月28日")
  }
}
