import AppKit
import SwiftUI

/// 内容列表的滚动条：总高度突变时，滑块平滑过渡到新的长短和位置。
///
/// macOS 的 SwiftUI List 底下是开着自动行高的 NSTableView，没滚到的行先按 28pt 估算，
/// 滚进视野量出真实高度（卡片 80–96pt）再改；翻页时一次又多出 50 行。于是滚动中整张表
/// 不停长高，滑块的长短、位置每一帧都在跳——Syc 看到的「滚动条卡顿掉帧」（2026-10-04
/// 实测：同样 103 行，滚 10 下总高从 6866 涨到 8129；翻页一次涨 1500 多）。
/// SwiftUI 那张表锁死了 `rowHeight`（设了不生效），估算值改不了，所以在显示这一层把
/// 跳变抹平：滑块朝目标值指数逼近（约 60ms 走完一半），平常滚动时跟手，拖滑块时不做平滑。
final class SmoothKnobScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  private var targetValue: Double = 0
  private var targetProportion: CGFloat = 0
  private var shownValue: Double = 0
  private var shownProportion: CGFloat = 0
  private var isTracking = false
  private var link: Timer?
  private var lastTick: CFTimeInterval = 0

  /// 每秒衰减常数：值越大越跟手。12 ≈ 半衰期 58ms。
  private static let responsiveness: Double = 12

  override var doubleValue: Double {
    get { super.doubleValue }
    set {
      targetValue = newValue
      guard !isTracking, shouldSmooth else { shownValue = newValue; super.doubleValue = newValue; return }
      startTicking()
    }
  }

  override var knobProportion: CGFloat {
    get { super.knobProportion }
    set {
      let jumped = abs(newValue - targetProportion) > 0.002
      targetProportion = newValue
      if jumped, !isTracking, shownProportion > 0 { startTicking() }
      else if link == nil { shownProportion = newValue; super.knobProportion = newValue }
    }
  }

  /// 只有长短还在过渡时才平滑位置；平常滚动（长短不变）位置直接跟手。
  private var shouldSmooth: Bool { link != nil }

  override func trackKnob(with event: NSEvent) {
    isTracking = true
    finish()
    super.trackKnob(with: event)
    isTracking = false
  }

  private func startTicking() {
    guard link == nil else { return }
    lastTick = CACurrentMediaTime()
    // 120Hz 计时器而不是 CADisplayLink：显示链路在窗口不在屏幕上时不回调，过渡会卡在半路。
    let link = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(link, forMode: .common)
    self.link = link
  }

  private func tick() {
    let now = CACurrentMediaTime()
    let dt = min(0.05, max(0.001, now - lastTick))
    lastTick = now
    let alpha = 1 - exp(-Self.responsiveness * dt)
    shownProportion += (targetProportion - shownProportion) * alpha
    shownValue += (targetValue - shownValue) * alpha
    super.knobProportion = shownProportion
    super.doubleValue = shownValue
    if abs(targetProportion - shownProportion) < 0.0005, abs(targetValue - shownValue) < 0.0005 {
      finish()
    }
  }

  private func finish() {
    link?.invalidate()
    link = nil
    shownProportion = targetProportion
    shownValue = targetValue
    super.knobProportion = targetProportion
    super.doubleValue = targetValue
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { finish() }
    super.viewWillMove(toWindow: newWindow)
  }
}

/// 把所在 List 的竖向滚动条换成 `SmoothKnobScroller`。挂在 List 的背景上。
struct SmoothKnobScrollerInstaller: NSViewRepresentable {
  final class ProbeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in self?.install() }
    }

    /// 背景和 List 不在同一条父子链上：在窗口里找框住这个探针的那个滚动容器。
    func install() {
      guard let window, let root = window.contentView else { return }
      let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
      var found: NSScrollView?
      func walk(_ view: NSView) {
        guard found == nil else { return }
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView,
           scroll.convert(scroll.bounds, to: nil).insetBy(dx: -2, dy: -2).contains(center) {
          found = scroll
          return
        }
        view.subviews.forEach(walk)
      }
      walk(root)
      guard let scroll = found, !(scroll.verticalScroller is SmoothKnobScroller) else { return }
      let style = scroll.scrollerStyle
      scroll.verticalScroller = SmoothKnobScroller()
      scroll.scrollerStyle = style
    }
  }

  func makeNSView(context: Context) -> ProbeView { ProbeView(frame: .zero) }
  func updateNSView(_ nsView: ProbeView, context: Context) { nsView.install() }
}
