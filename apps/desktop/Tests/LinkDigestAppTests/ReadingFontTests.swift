import XCTest
@testable import LinkDigestApp

final class ReadingFontTests: XCTestCase {
  // 目录只收自带中文字形的家族。放开这条限制，纸质主题那个「每个标点后裂开
  // 一道缝」的缺陷就会以「用户自己选的」形式回来。
  func testCatalogOnlyOffersFamiliesThatCanDrawChinese() {
    let families = ReadingFontCatalog.cjkCapableFamilies()
    XCTAssertFalse(families.isEmpty)
    for family in families {
      XCTAssertTrue(
        ReadingFontCatalog.supportsCJK(family),
        "\(family) 没有中文字形，不该出现在阅读字体列表里"
      )
    }
    // New York / Georgia 这类只有拉丁字形的必须被挡在外面。
    for latinOnly in ["New York", "Georgia", "Times New Roman", "Helvetica"] {
      XCTAssertFalse(families.contains(latinOnly), "\(latinOnly) 不该出现在列表里")
    }
  }

  func testCatalogIsSortedAndDeduplicated() {
    let families = ReadingFontCatalog.cjkCapableFamilies()
    XCTAssertEqual(families, families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    XCTAssertEqual(Set(families).count, families.count)
  }

  // 旧的「衬线」存的是 New York 的意图，但用户当初选的是「衬线」这个效果。
  // 迁到中文衬线（宋体）才符合意图；迁到 New York 等于把缺陷保留下来。
  func testLegacyStoredValuesMigrateToCJKCapableFamilies() {
    XCTAssertEqual(ReadingFontSelection(storedValue: "serif"), .family("Songti SC"))
    XCTAssertEqual(ReadingFontSelection(storedValue: "sansSerif"), .family("PingFang SC"))
    XCTAssertEqual(ReadingFontSelection(storedValue: "songti"), .family("Songti SC"))
    XCTAssertEqual(ReadingFontSelection(storedValue: "kaiti"), .family("Kaiti SC"))
    XCTAssertEqual(ReadingFontSelection(storedValue: "theme"), .theme)
    XCTAssertEqual(ReadingFontSelection(storedValue: ""), .theme)
  }

  func testSelectionRoundTripsThroughStorage() {
    for selection: ReadingFontSelection in [.theme, .family("PingFang SC"), .family("Kaiti SC")] {
      XCTAssertEqual(ReadingFontSelection(storedValue: selection.storedValue), selection)
    }
  }

  // 「跟随主题」是默认值，也正是撞出这个 bug 的那条路径：两个主题都必须解析到
  // 自带中文字形的家族。
  func testThemeSelectionResolvesToCJKCapableFamilyOnBothThemes() {
    for editorial in [true, false] {
      let resolved = ReadingFontSelection.theme.resolved(
        usesEditorialReadingTypography: editorial,
        bodySize: ReadingFontSize.default
      )
      guard case let .named(family) = resolved.face else {
        return XCTFail("跟随主题必须落到具名中文字体，而不是 system design")
      }
      XCTAssertTrue(ReadingFontCatalog.supportsCJK(family), "\(family) 没有中文字形")
    }
  }

  func testBodySizeIsClampedIntoRange() {
    XCTAssertEqual(ResolvedReadingFont(face: .sans, bodySize: 999).bodySize, ReadingFontSize.maximum)
    XCTAssertEqual(ResolvedReadingFont(face: .sans, bodySize: 1).bodySize, ReadingFontSize.minimum)
    XCTAssertEqual(ResolvedReadingFont(face: .sans, bodySize: -5).bodySize, ReadingFontSize.default)
    XCTAssertEqual(ResolvedReadingFont(face: .sans, bodySize: .nan).bodySize, ReadingFontSize.default)
  }

  // 标题必须跟着正文一起缩放，否则 24pt 正文配 23pt 一级标题，层级会塌掉。
  func testHeadingSizesScaleWithBodySize() {
    let base = ResolvedReadingFont(face: .sans, bodySize: ReadingFontSize.default)
    XCTAssertEqual(base.scaledSize(23), 23, accuracy: 0.001)

    let large = ResolvedReadingFont(face: .sans, bodySize: ReadingFontSize.maximum)
    XCTAssertGreaterThan(large.scaledSize(23), large.bodySize)
    XCTAssertEqual(
      large.scaledSize(23) / large.bodySize,
      23 / ReadingFontSize.default,
      accuracy: 0.001,
      "标题与正文的比例必须保持不变"
    )
  }
}
