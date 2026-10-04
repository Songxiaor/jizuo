import AppKit
import XCTest
@testable import LinkDigestApp

/// 内容列表总高度突变时，滑块平滑过渡；平常滚动跟手（2026-10-04「滚动条卡顿掉帧」）。
@MainActor
final class SmoothKnobScrollerTests: XCTestCase {
  private func makeScroller() -> (NSWindow, SmoothKnobScroller) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroller = SmoothKnobScroller(frame: NSRect(x: 180, y: 0, width: 15, height: 400))
    window.contentView?.addSubview(scroller)
    scroller.knobProportion = 0.5
    scroller.doubleValue = 0.2
    return (window, scroller)
  }

  func testSteadyScrollingFollowsImmediately() {
    let (window, scroller) = makeScroller()
    defer { window.close() }
    scroller.doubleValue = 0.35
    XCTAssertEqual(scroller.doubleValue, 0.35, accuracy: 0.0001, "长短不变时位置直接跟手")
  }

  func testHeightJumpEasesInsteadOfSnapping() {
    let (window, scroller) = makeScroller()
    defer { window.close() }
    scroller.knobProportion = 0.3
    scroller.doubleValue = 0.1
    XCTAssertGreaterThan(scroller.knobProportion, 0.45, "总高突变那一帧不该直接跳到新长短")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertGreaterThan(scroller.knobProportion, 0.3, "过渡中：还没走到终点")
    XCTAssertLessThan(scroller.knobProportion, 0.5, "过渡中：已经离开起点")
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    XCTAssertEqual(scroller.knobProportion, 0.3, accuracy: 0.005, "过渡在半秒内走完")
    XCTAssertEqual(scroller.doubleValue, 0.1, accuracy: 0.005)
  }
}
