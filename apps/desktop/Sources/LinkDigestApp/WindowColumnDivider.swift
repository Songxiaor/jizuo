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
    // 细线住在自己的子窗口里，**不随父窗口自动移动或缩放**，位置和大小都要自己跟。
    // 漏掉这一段的表现是：窗口一拖或一改大小，细线就停在原地。
    if let parent = window?.parent {
      for name in [
        NSWindow.didResizeNotification,
        NSWindow.didMoveNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
      ] {
        observers.append(center.addObserver(
          forName: name, object: parent, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.syncFrameToParentWindow() }
        })
      }
    }
  }

  /// 把子窗口贴回父窗口当前的 frame。
  func syncFrameToParentWindow() {
    guard let window, let parent = window.parent else { return }
    window.setFrame(parent.frame, display: true)
    frame = NSRect(origin: .zero, size: window.frame.size)
    needsDisplay = true
  }

  private func removeObservers() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let splitView = trackedSplitView, splitView.window === window?.parent else { return }
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

/// 细线所在的窗口。
///
/// 原来这条线是作为**子视图**挂进 `NSThemeFrame`（`contentView.superview`）的：
/// 那是唯一能画到工具栏之上的位置。代价是 AppKit 每次启动都记一条
/// `adding an unknown subview`，紧跟其后是一条 SwiftUI 的
/// `NSHostingView is being laid out reentrantly`（**该次布局被跳过**）——
/// 两个都指向同一件事：往主题框里塞了 AppKit 不认识的视图。
///
/// 改成同尺寸的无边框子窗口之后，细线仍然是窗口级的（照样贯通工具栏），
/// 但不再有任何外来视图进入主题框。
final class ColumnDividerOverlayWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
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
    teardown(in: nsView.window)
  }

  private static func sync(probe: NSView, lineColor: NSColor?) {
    guard let window = probe.window, let contentView = window.contentView else { return }
    if let split = splitView(in: contentView) {
      applyIndependentColumnHoldingPriorities(split)
    }
    guard let lineColor else {
      teardown(in: window)
      return
    }

    let overlayWindow = existingOverlayWindow(for: window) ?? {
      let created = ColumnDividerOverlayWindow(
        contentRect: window.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      // 只是一层画上去的线：不透明、点不到、没阴影，也不占窗口循环。
      created.isOpaque = false
      created.backgroundColor = .clear
      created.hasShadow = false
      created.ignoresMouseEvents = true
      created.collectionBehavior = [.fullScreenAuxiliary, .stationary]
      created.contentView = ColumnDividerOverlayView(
        frame: NSRect(origin: .zero, size: window.frame.size)
      )
      window.addChildWindow(created, ordered: .above)
      return created
    }()

    guard let overlay = overlayWindow.contentView as? ColumnDividerOverlayView else { return }
    overlayWindow.setFrame(window.frame, display: false)
    overlay.frame = NSRect(origin: .zero, size: window.frame.size)

    // 切主题时 SwiftUI 会连着刷很多次；颜色和分栏都没变就不动 overlay，
    // 否则每次都重挂观察者、重画细线，分栏缝隙跟着一闪一闪。
    let split = splitView(in: contentView)
    guard overlay.lineColor != lineColor || overlay.trackedSplitView !== split else { return }
    overlay.lineColor = lineColor
    overlay.trackedSplitView = split
    overlay.refreshObservation()
    overlay.needsDisplay = true
  }

  private static func teardown(in window: NSWindow?) {
    guard let window else { return }
    // `childWindows` 在 Swift 里是可选的（ObjC 侧可空），空数组兜底。
    for child in window.childWindows ?? [] where child is ColumnDividerOverlayWindow {
      window.removeChildWindow(child)
      child.orderOut(nil)
    }
  }

  private static func existingOverlayWindow(for window: NSWindow) -> ColumnDividerOverlayWindow? {
    (window.childWindows ?? []).first { $0 is ColumnDividerOverlayWindow } as? ColumnDividerOverlayWindow
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
      let priority = NSLayoutConstraint.Priority(rawValue: 270 - Float(index) * 10)
      // 只在真的不一样时才写。`holdingPriority` 是**布局**属性：赋一次值就会让
      // 分栏重新布局一次，而 `sync()` 会在每次主题/状态变化（包括启动那一拍）
      // 被调到——重复写同一个值等于在 SwiftUI 自己的布局周期里反复插队。
      // 实测这就是启动时那条 `NSHostingView is being laid out reentrantly` 的来源。
      if item.holdingPriority != priority { item.holdingPriority = priority }
    }
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
