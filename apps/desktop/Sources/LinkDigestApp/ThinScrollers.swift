import AppKit
import SwiftUI

/// 把所在滚动容器的滚动条改成细的浮层样式。
///
/// SwiftUI 的 `ScrollView` 不暴露滚动条粗细，只能拿到底层的 `NSScrollView` 去设：
/// - `scrollerStyle = .overlay`：浮在内容上、不用时淡出，而不是常驻占一条宽度。
///   系统「始终显示滚动条」开着时默认会给 legacy 样式，这里按 App 自己的选择覆盖。
/// - `controlSize = .small`：`NSScroller` 的宽度跟随 controlSize，small 明显更细。
///
/// 用一个零尺寸的探针视图放进滚动区里，靠 `enclosingScrollView` 往上找容器——
/// 这是不引入第三方 introspect 库的前提下唯一稳的做法。
///
/// 设置必须延到下一轮 runloop：`makeNSView` 返回时这个 view 还没被挂进视图树，
/// `enclosingScrollView` 恒为 nil，当场设等于什么都没做。
private struct ThinScrollerProbe: NSViewRepresentable {
  final class ProbeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      applyThinScrollers()
    }

    func applyThinScrollers() {
      guard let scrollView = enclosingScrollView else { return }
      scrollView.scrollerStyle = .overlay
      scrollView.verticalScroller?.controlSize = .small
      scrollView.horizontalScroller?.controlSize = .small
      // 细滚动条浮在内容上时不该再额外占一条边距。
      scrollView.autohidesScrollers = true
    }
  }

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView(frame: .zero)
    // 视图树挂载完成后再找容器；viewDidMoveToWindow 覆盖大多数情况，
    // 这一轮兜住「已经在窗口里但层级还没稳定」的边角。
    DispatchQueue.main.async { view.applyThinScrollers() }
    return view
  }

  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.applyThinScrollers()
  }
}

extension View {
  /// 让所在滚动容器使用细的浮层滚动条。放在 `ScrollView` 的内容里。
  func thinScrollers() -> some View {
    overlay(alignment: .topLeading) {
      ThinScrollerProbe()
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
  }
}
