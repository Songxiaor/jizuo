import XCTest
import SwiftUI
@testable import LinkDigestApp

/// 工序印（2026-09-28）：每枚印的纹样和字形都能画出来，来历说明照实写。
final class SealMarkTests: XCTestCase {
  func testEveryGlyphHasAnOutlineAndAMotifInsideTheFrame() throws {
    for glyph in SealMark.Glyph.allCases {
      let outline = try XCTUnwrap(SealGeometry.unitGlyphPath(glyph.rawValue), "\(glyph.rawValue) 取不到字形")
      let bounds = outline.boundingRect
      XCTAssertEqual(bounds.midX, 50, accuracy: 0.5, "\(glyph.rawValue) 应居中")
      XCTAssertLessThanOrEqual(max(bounds.width, bounds.height), 50.5)
      let motif = SealMotifs.elements(for: glyph)
      XCTAssertFalse(motif.isEmpty, "\(glyph.rawValue) 没有纹样")
      for element in motif {
        let rect = element.path(unit: 1).boundingRect
        XCTAssertFalse(rect.isEmpty && rect.width == 0 && rect.height == 0, "\(glyph.rawValue) 有一笔纹样是空的")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 100, height: 100).insetBy(dx: -1, dy: -1).contains(rect), "\(glyph.rawValue) 的纹样出了印框")
      }
    }
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

  func testInkSpecksAreStablePerGlyph() {
    XCTAssertEqual(SealGeometry.specks(seed: 25688).map(\.x), SealGeometry.specks(seed: 25688).map(\.x), "同一个字每次撒的点一样")
    XCTAssertNotEqual(SealGeometry.specks(seed: 25688).map(\.x), SealGeometry.specks(seed: 25991).map(\.x))
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
