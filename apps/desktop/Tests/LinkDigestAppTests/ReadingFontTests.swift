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

  // 行宽：偏好宽度跟着正文字号走；可用宽度上来后随列变宽，直到字号联动的绝对上限。
  // 固定 680pt 时把窗口拉宽两侧只剩空白，正文看起来越拉越窄。
  func testReadingColumnWidthScalesWithBodySize() {
    XCTAssertEqual(
      DesignTokens.Layout.readingMaxWidth(bodySize: ReadingFontSize.default),
      DesignTokens.Layout.readingMaxWidth,
      accuracy: 0.001,
      "默认字号的偏好宽度必须与旧基准逐像素一致"
    )
    XCTAssertEqual(
      DesignTokens.Layout.readingMaxWidth(bodySize: ReadingFontSize.maximum),
      DesignTokens.Layout.readingMaxWidth * ReadingFontSize.maximum / ReadingFontSize.default,
      accuracy: 0.001
    )
    XCTAssertEqual(
      DesignTokens.Layout.readingMaxWidth(bodySize: ReadingFontSize.minimum),
      DesignTokens.Layout.readingMaxWidth * ReadingFontSize.minimum / ReadingFontSize.default,
      accuracy: 0.001
    )
    // 越界字号走和渲染层同一条夹取，不会算出荒唐的行宽。
    XCTAssertEqual(
      DesignTokens.Layout.readingMaxWidth(bodySize: 999),
      DesignTokens.Layout.readingMaxWidth(bodySize: ReadingFontSize.maximum),
      accuracy: 0.001
    )
  }

  func testReadingColumnWidthGrowsWithAvailableWidthUpToFontScaledCeiling() {
    let body = ReadingFontSize.default
    let inset = DesignTokens.Layout.readingHorizontalInset * 2
    let preferred = DesignTokens.Layout.readingMaxWidth(bodySize: body)
    let ceiling = DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: body)

    // 首帧宽度未知：回退偏好，默认窗口观感不突变。
    XCTAssertEqual(
      DesignTokens.Layout.readingColumnMaxWidth(availableWidth: 0, bodySize: body),
      preferred,
      accuracy: 0.001
    )

    // 默认约 1200 窗口：详情列可用宽度通常窄于旧 680，列宽等于可用宽度。
    let defaultWindowDetail: CGFloat = 640
    XCTAssertEqual(
      DesignTokens.Layout.readingColumnMaxWidth(availableWidth: defaultWindowDetail, bodySize: body),
      defaultWindowDetail - inset,
      accuracy: 0.001,
      "默认窗口下应吃满可用宽度，与旧观感接近"
    )

    // 窗口明显拉宽：超过旧 680 后继续涨。
    let wideDetail: CGFloat = 952
    let wideColumn = DesignTokens.Layout.readingColumnMaxWidth(availableWidth: wideDetail, bodySize: body)
    XCTAssertEqual(wideColumn, wideDetail - inset, accuracy: 0.001)
    XCTAssertGreaterThan(wideColumn, preferred, "拉宽后正文必须可感知地宽于旧固定上限")

    // 4K 级超宽：停在绝对上限，不无限拉长行。
    XCTAssertEqual(
      DesignTokens.Layout.readingColumnMaxWidth(availableWidth: 3200, bodySize: body),
      ceiling,
      accuracy: 0.001
    )

    // 字号更大时绝对上限同比放宽。
    let largeCeiling = DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: ReadingFontSize.maximum)
    XCTAssertGreaterThan(largeCeiling, ceiling)
    XCTAssertEqual(
      DesignTokens.Layout.readingColumnMaxWidth(availableWidth: 3200, bodySize: ReadingFontSize.maximum),
      largeCeiling,
      accuracy: 0.001
    )
  }
}
