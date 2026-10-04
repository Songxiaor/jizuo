import AppKit
import SwiftUI

/// 侧栏重建前后保持滚动位置。
///
/// 侧栏会整张重建：分组展开 / 收起时按新 id 重建（macOS 侧栏 List 对后插入的行不刷新，见
/// `navigationSectionsLayoutKey`），进「全部博主」这类两栏页面时也换了一张。重建后滚动回到
/// 顶上：在侧栏底部点开「博主」「标签」或点「全部博主」，侧栏一下跳回顶部，刚点的东西反而
/// 看不见（2026-10-04 走查）。所以一直记着侧栏滚到哪儿，新侧栏一挂上就还原。
@MainActor
final class SidebarScrollMemory {
  private weak var scrollView: NSScrollView?
  private var observer: NSObjectProtocol?
  private var lastOffset: CGFloat = 0
  private var hasAttached = false
  /// 新侧栏刚挂上、还没还原时，它自己报的「滚到 0」不能记成用户的位置。
  private var isRestoring = false
  private var pendingReveal: (documentHeight: CGFloat, headerInViewport: CGFloat?)?
  private var snapshotGeneration = 0
  /// 新侧栏已挂上、还原还没做完。
  private var isAwaitingRestore = false

  /// 点侧栏里的项目时调用：这一下可能让侧栏整张换掉。把当前位置定住，旧侧栏拆掉时
  /// 自己报的「滚到 0」不再覆盖它（实测从侧栏底部点「全部博主」，位置就这样丢了）。
  /// 半秒内没换侧栏就解冻，照常记用户的滚动。
  func snapshot() {
    guard let scrollView else { return }
    lastOffset = scrollView.contentView.bounds.origin.y
    isRestoring = true
    snapshotGeneration += 1
    let generation = snapshotGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.snapshotGeneration == generation, !self.isAwaitingRestore else { return }
      self.isRestoring = false
    }
  }

  /// 点分组标题时调用。`expanding`：这次是展开（新内容出现在标题下方）。
  func remember(expanding: Bool) {
    guard let scrollView else { return }
    snapshot()
    let clip = scrollView.contentView
    guard expanding else {
      pendingReveal = nil
      return
    }
    // 点的那个标题在可视区里的高度：鼠标就在它上面。
    var headerInViewport: CGFloat?
    if let window = scrollView.window {
      let point = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      if clip.bounds.contains(point) { headerInViewport = point.y - clip.bounds.origin.y }
    }
    pendingReveal = (scrollView.documentView?.frame.height ?? 0, headerInViewport)
  }

  func attach(_ newScrollView: NSScrollView) {
    guard newScrollView !== scrollView else { return }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    scrollView = newScrollView
    let clip = newScrollView.contentView
    clip.postsBoundsChangedNotifications = true
    observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
    ) { [weak self, weak clip] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isRestoring, let clip else { return }
        self.lastOffset = clip.bounds.origin.y
      }
    }
    // 启动时第一张侧栏不还原：那时还没有「上次的位置」，启动另有露出选中平台的逻辑。
    guard hasAttached else {
      hasAttached = true
      return
    }
    isRestoring = true
    isAwaitingRestore = true
    // 等这一轮布局把行都排好再还原。
    DispatchQueue.main.async { [weak self] in self?.restore() }
  }

  private func restore() {
    guard let scrollView else {
      isRestoring = false
      isAwaitingRestore = false
      return
    }
    let base = lastOffset
    let reveal = pendingReveal
    pendingReveal = nil
    scrollView.documentView?.layoutSubtreeIfNeeded()
    scroll(scrollView, to: base)
    // 新侧栏的行要过一小会儿才排完：刚挂上时文档高度偏小，上面这一下会被截在半路
    // （实测从侧栏底部点「全部博主」只还原到离顶 44pt）。等一下按排好的高度再落一次。
    // 展开时顺带让一让，把新出来的行尽量露出来，但点的标题不能被推出顶端：在侧栏底部
    // 点开「标签」，原位不动的话标签全在可视区下面，看起来像没反应。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak scrollView] in
      guard let self else { return }
      defer {
        self.isRestoring = false
        self.isAwaitingRestore = false
      }
      guard let scrollView, scrollView === self.scrollView else { return }
      var target = base
      if let reveal {
        let clip = scrollView.contentView
        let grown = max(0, (scrollView.documentView?.frame.height ?? 0) - reveal.documentHeight)
        let headroom = max(0, (reveal.headerInViewport ?? clip.bounds.height / 2) - 36)
        target += min(grown, headroom)
      }
      self.scroll(scrollView, to: target)
      self.lastOffset = scrollView.contentView.bounds.origin.y
    }
  }

  private func scroll(_ scrollView: NSScrollView, to offset: CGFloat) {
    let clip = scrollView.contentView
    let documentHeight = scrollView.documentView?.frame.height ?? 0
    let maxOffset = max(0, documentHeight - clip.bounds.height)
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, offset), maxOffset)))
    scrollView.reflectScrolledClipView(clip)
  }
}

/// 放在侧栏第一行后面：重建出的新侧栏一挂上窗口，就交给 `SidebarScrollMemory` 还原位置。
struct SidebarScrollProbe: NSViewRepresentable {
  let memory: SidebarScrollMemory

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.memory = memory
    return view
  }

  func updateNSView(_ view: ProbeView, context: Context) {
    view.memory = memory
  }

  final class ProbeView: NSView {
    weak var memory: SidebarScrollMemory?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil, let scrollView = enclosingScrollView else { return }
      memory?.attach(scrollView)
    }
  }
}
