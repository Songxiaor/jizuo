import XCTest

/// 列表行做轻（2026-11-24 列表滑动采样：行视图创建约占主线程三分之一）。
/// 这些是结构约束，回退了不会报错、只会悄悄变慢，所以用源码断言守住。
final class UIReadingHistoryRowLightnessTests: XCTestCase {
  private var row: String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/UIReadingHistoryRow.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  func testSelectionStyleMountedOnEveryRow() {
    // 选中样式要在 AppKit 改选中状态前就配好：只挂在选中行会让首次选中先闪一帧系统蓝底。
    XCTAssertTrue(row.contains(".background(UIReadingListSelectionStyle(usesSystemSelection: theme.isNative))"))
    XCTAssertFalse(row.contains("if isSelected { UIReadingListSelectionStyle("))
    // 挂载点紧跟在行底色之后、不在任何 if 分支里（无条件修饰链）。
    if let r = row.range(of: ".background(UIReadingListSelectionStyle(usesSystemSelection: theme.isNative))") {
      let before = row[..<r.lowerBound].suffix(400)
      XCTAssertTrue(before.contains(".fill(rowBackground)\n      }\n    }\n"), "选中样式必须挂在行的无条件修饰链上")
    }
  }

  func testSavedTimeFormattedOncePerRow() {
    XCTAssertEqual(row.components(separatedBy: "HistoryListFinding.compactSavedTime(").count - 1, 1)
    // 无图标、显示日期时补回原来空图标组带来的 4pt。
    XCTAssertTrue(row.contains(".padding(.trailing, !hasStatusIcons && showsSavedTime ? DesignTokens.Space.xs : 0)"))
  }

  func testRowBackgroundOnlyWhenSelectedOrHovered() {
    XCTAssertTrue(row.contains("if isSelected || isHovering {\n        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)\n          .fill(rowBackground)"))
  }

  func testFaviconWrappedOnlyWhenStatusShapeShown() {
    XCTAssertTrue(row.contains("if theme.encodesStatusByShape {\n      ZStack(alignment: .bottomTrailing) {"))
  }

  func testHoverActionsStillSwitchInSameFrame() {
    // c09a0a30 修的悬停按钮叠字：做轻时不能丢。
    // 顺序也要守住：.animation(nil) 必须在 overlay 之后，按钮才不继承行级悬停动画。
    let opacity = row.range(of: ".opacity(showsHoverActions ? 0 : 1)")
    let overlay = row.range(of: ".overlay(alignment: .trailing) { hoverActions }")
    if let opacity, let overlay { XCTAssertLessThan(opacity.lowerBound, overlay.lowerBound, "opacity 在 overlay 之前，否则按钮会一起被隐藏") }
    XCTAssertNotNil(opacity)
    let noAnim = row.range(of: ".animation(nil, value: showsHoverActions)")
    XCTAssertNotNil(overlay); XCTAssertNotNil(noAnim)
    if let overlay, let noAnim { XCTAssertLessThan(overlay.lowerBound, noAnim.lowerBound) }
  }
}
