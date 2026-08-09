import AppKit
import SwiftUI

/// 窗口级分栏细线。SwiftUI 栏内容物理上止于工具栏下缘，`ignoresSafeArea`
/// 也无法把 1pt 边界画进工具栏区域；本视图叠在窗口 contentView 的父层
/// （覆盖标题栏/工具栏），按 `NSSplitView` 当前分栏位置画全高细线，
/// 与 Notes 的全高分栏边界一致。不参与命中测试，不改变分栏拖动交互。
final class ColumnDividerOverlayView: NSView {
  weak var trackedSplitView: NSSplitView? {
    didSet { needsDisplay = true }
  }

  var lineColor: NSColor = .clear {
    didSet { needsDisplay = true }
  }

  private var observers: [NSObjectProtocol] = []

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// deinit 在 Swift 并发下不能触碰 MainActor 状态；观察者随窗口离开时解绑。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { removeObservers() }
  }

  func refreshObservation() {
    removeObservers()
    guard let splitView = trackedSplitView else { return }
    let center = NotificationCenter.default
    // `queue: .main` is NotificationCenter's execution guarantee; make that
    // guarantee explicit before touching AppKit state from its Sendable block.
    observers.append(center.addObserver(
      forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.needsDisplay = true }
    })
    observers.append(center.addObserver(
      forName: NSView.frameDidChangeNotification, object: splitView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.needsDisplay = true }
    })
  }

  private func removeObservers() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let splitView = trackedSplitView, splitView.window === window else { return }
    let columns = splitView.arrangedSubviews
      .filter { !$0.isHidden && $0.frame.width > 1 }
      .sorted { $0.frame.minX < $1.frame.minX }
    guard columns.count > 1 else { return }
    lineColor.setFill()
    // 精确覆盖每个 divider 缝隙：把系统深色分栏线整条盖成主题细线色，
    // 两条边界因此粗细与颜色完全一致，不会出现「细线 + 系统线」叠影。
    for (column, next) in zip(columns, columns.dropFirst()) {
      let gap = next.frame.minX - column.frame.maxX
      let originX = convert(NSPoint(x: column.frame.maxX, y: 0), from: splitView).x
      NSRect(x: originX.rounded(), y: 0, width: max(1, gap), height: bounds.height).fill()
    }
  }
}

/// 把窗口级细线接进 SwiftUI：作为零尺寸探针挂在 NavigationSplitView 下，
/// 找到宿主窗口与其 NSSplitView 后，在窗口框架层安装/更新/移除 overlay。
struct WindowColumnDividerInstaller: NSViewRepresentable {
  /// nil 表示当前主题不需要自定义细线（系统玻璃主题走原生分栏外观）。
  let lineColor: NSColor?

  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async { Self.sync(probe: probe, lineColor: lineColor) }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { Self.sync(probe: nsView, lineColor: lineColor) }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    existingOverlay(in: nsView.window)?.removeFromSuperview()
  }

  private static func sync(probe: NSView, lineColor: NSColor?) {
    guard let window = probe.window, let contentView = window.contentView,
          let frameView = contentView.superview
    else { return }
    if let split = splitView(in: contentView) {
      applyIndependentColumnHoldingPriorities(split)
    }
    guard let lineColor else {
      existingOverlay(in: window)?.removeFromSuperview()
      return
    }
    let overlay = existingOverlay(in: window) ?? {
      let created = ColumnDividerOverlayView(frame: frameView.bounds)
      created.autoresizingMask = [.width, .height]
      return created
    }()
    // 保持置顶：标题栏容器与工具栏背景层可能后插，
    // 细线必须盖在它们之上才能贯通到窗口顶。
    if overlay.superview !== frameView || frameView.subviews.last !== overlay {
      overlay.removeFromSuperview()
      overlay.frame = frameView.bounds
      frameView.addSubview(overlay)
    }
    overlay.lineColor = lineColor
    overlay.trackedSplitView = splitView(in: contentView)
    overlay.refreshObservation()
    overlay.needsDisplay = true
  }

  /// 三栏 holding priority 从左到右递减：左目录栏最“硬”，拖动右侧分隔线
  /// 时多出的宽度只在中栏与详情间分配，不再连带拖动左栏；每条分隔线
  /// 因此只调节自己两侧的栏。对所有主题生效（行为问题与配色无关）。
  ///
  /// 必须走 `NSSplitViewController.splitViewItems` 这条受支持路径；
  /// 直接调用 `NSSplitView.setHoldingPriority(_:forSubviewAt:)` 会在
  /// SwiftUI 托管的 split view 上触发 AppKit 断言并崩溃（已实测）。
  private static func applyIndependentColumnHoldingPriorities(_ split: NSSplitView) {
    guard let controller = split.delegate as? NSSplitViewController else { return }
    let items = controller.splitViewItems
    guard items.count >= 2 else { return }
    for (index, item) in items.enumerated() {
      item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270 - Float(index) * 10)
    }
  }

  private static func existingOverlay(in window: NSWindow?) -> ColumnDividerOverlayView? {
    guard let frameView = window?.contentView?.superview else { return nil }
    return frameView.subviews.compactMap { $0 as? ColumnDividerOverlayView }.first
  }

  private static func splitView(in root: NSView) -> NSSplitView? {
    var queue: [NSView] = [root]
    while !queue.isEmpty {
      let view = queue.removeFirst()
      if let split = view as? NSSplitView { return split }
      queue.append(contentsOf: view.subviews)
    }
    return nil
  }
}
