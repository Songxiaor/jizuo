import AppKit
import SwiftUI

/// 细、浅灰、圆角、无轨道底的滚动条。
///
/// 系统默认滚动条在浅色背景上是深灰的，滚动时更深，在纸质主题的米黄画布上显得
/// 又黑又粗。只把 `scrollerStyle` 改成 overlay 不够——那只改了「是否常驻」，
/// 颜色和粗细还是系统的。要达到参考标准（浅灰细条、圆角、不画轨道）必须自绘 knob。
final class SubtleScroller: NSScroller {
  /// 不声明这个，AppKit 不会把它用在 overlay 样式上，自绘会被整个跳过。
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  /// 条子总宽。knob 还会在此基础上左右各缩 `knobInset`，所以实际可见宽度更细。
  private static let trackWidth: CGFloat = 11
  private static let knobInset: CGFloat = 3.5

  override class func scrollerWidth(
    for controlSize: NSControl.ControlSize,
    scrollerStyle: NSScroller.Style
  ) -> CGFloat {
    trackWidth
  }

  override func drawKnob() {
    let slot = rect(for: .knob)
    guard slot.height > 0, slot.width > 0 else { return }
    let knob = slot.insetBy(dx: Self.knobInset, dy: 2)
    guard knob.width > 0, knob.height > 0 else { return }
    // tertiaryLabelColor 会跟随浅色/深色主题，比写死灰值稳。
    NSColor.tertiaryLabelColor.setFill()
    NSBezierPath(
      roundedRect: knob,
      xRadius: knob.width / 2,
      yRadius: knob.width / 2
    ).fill()
  }

  /// 参考标准里没有轨道底色，空实现即可。
  override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}
}

/// 把所在滚动容器换成 `SubtleScroller`。
///
/// SwiftUI 的 `ScrollView` 不暴露滚动条外观，只能拿到底层 `NSScrollView` 去换。
/// 用一个零尺寸探针视图靠 `enclosingScrollView` 往上找容器——不引入第三方
/// introspect 库的前提下这是唯一稳的做法。
///
/// 时机是这里最容易错的地方：`makeNSView` 返回时探针还没挂进视图树，
/// `enclosingScrollView` 恒为 nil，当场设等于什么都没做，而且不会报任何错。
private struct SubtleScrollerProbe: NSViewRepresentable {
  final class ProbeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    func apply() {
      guard let scrollView = enclosingScrollView else { return }
      scrollView.scrollerStyle = .overlay
      if !(scrollView.verticalScroller is SubtleScroller) {
        scrollView.verticalScroller = SubtleScroller()
      }
      if !(scrollView.horizontalScroller is SubtleScroller) {
        scrollView.horizontalScroller = SubtleScroller()
      }
      scrollView.autohidesScrollers = true
    }
  }

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView(frame: .zero)
    // viewDidMoveToWindow 覆盖大多数情况；这一轮兜住「已在窗口里但层级尚未稳定」。
    DispatchQueue.main.async { view.apply() }
    return view
  }

  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.apply()
  }
}

extension View {
  /// 让所在滚动容器使用细浅灰滚动条。放在 `ScrollView` 的内容里。
  func subtleScrollers() -> some View {
    overlay(alignment: .topLeading) {
      SubtleScrollerProbe()
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
  }
}
