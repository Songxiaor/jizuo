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

  func testSelectionStyleViewOnlyOnSelectedRow() {
    XCTAssertTrue(row.contains("if isSelected { UIReadingListSelectionStyle(usesSystemSelection: theme.isNative) }"))
    XCTAssertFalse(row.contains(".background(UIReadingListSelectionStyle("), "每一行都嵌原生视图会让滑动时多建一个 AppKit 视图")
  }

  func testRowBackgroundOnlyWhenSelectedOrHovered() {
    XCTAssertTrue(row.contains("if isSelected || isHovering {\n        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)\n          .fill(rowBackground)"))
  }

  func testFaviconWrappedOnlyWhenStatusShapeShown() {
    XCTAssertTrue(row.contains("if theme.encodesStatusByShape {\n      ZStack(alignment: .bottomTrailing) {"))
  }

  func testHoverActionsStillSwitchInSameFrame() {
    // c09a0a30 修的悬停按钮叠字：做轻时不能丢。
    XCTAssertTrue(row.contains(".overlay(alignment: .trailing) { hoverActions }"))
    XCTAssertTrue(row.contains(".animation(nil, value: showsHoverActions)"))
  }
}
