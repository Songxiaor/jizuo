import AppKit
import SwiftUI

/// 什么时候该把侧栏滚回记住的位置。
///
/// 展开或收起分组不滚。以前点「视图」会把整张侧栏按新 id 重建，接着按旧偏移滚回去，
/// 过一会儿再按新长出来的高度推一次，侧栏来回跳（2026-10-10）。
/// 换掉整张侧栏（进「全部博主」）仍要还原，否则会停在顶上。
enum SidebarScrollRestore {
  enum Cause {
    case sectionToggle
    case sidebarReplacement
  }

  static func shouldRestore(_ cause: Cause) -> Bool {
    switch cause {
    case .sectionToggle: false
    case .sidebarReplacement: true
    }
  }

  /// 收起分组后该停在哪。内容还比窗口高时停在原来的偏移，点的标题不动。
  /// 内容已经短于窗口时最大偏移是 0，停在顶部是滚动范围被压短，不是被拉回去。
  static func offsetAfterSectionToggle(previous: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    let maxOffset = max(0, documentHeight - viewportHeight)
    return min(max(0, previous), maxOffset)
  }

  /// 换侧栏后，让同一行回到原来的屏幕高度。
  ///
  /// AppKit 窗口坐标向上增大。滚动偏移增加时，内容在屏幕上往上走，这一行的窗口坐标也增大。
  /// 进「全部博主」后各行大约低 26–31pt：新列表的可视区域和三栏侧栏不在同一高度，
  /// 原样套用旧偏移就会全体下移。按这一行的窗口坐标把偏移补上，不靠一个固定的点数。
  static func offsetToHoldRow(
    currentOffset: CGFloat,
    rowWindowY: CGFloat,
    desiredWindowY: CGFloat,
    documentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let adjusted = currentOffset + (desiredWindowY - rowWindowY)
    return offsetAfterSectionToggle(
      previous: adjusted,
      documentHeight: documentHeight,
      viewportHeight: viewportHeight
    )
  }
}

/// 侧栏里能认出来的一行，用来在两张列表之间对位置。
struct SidebarVisibleRow: Equatable {
  var id: String
  var distanceFromClipCenter: CGFloat
  var windowY: CGFloat
}

enum SidebarRowAnchor {
  /// 可视区里最靠近中间的那一行。靠边的行换页时容易被裁掉，中间更稳。
  static func choose(_ rows: [SidebarVisibleRow]) -> SidebarVisibleRow? {
    rows.min { lhs, rhs in
      if lhs.distanceFromClipCenter != rhs.distanceFromClipCenter {
        return lhs.distanceFromClipCenter < rhs.distanceFromClipCenter
      }
      return lhs.id < rhs.id
    }
  }

  @MainActor
  static func capture(in scrollView: NSScrollView) -> SidebarVisibleRow? {
    guard let document = scrollView.documentView else { return nil }
    let clip = scrollView.contentView
    let visible = clip.bounds
    var rows: [SidebarVisibleRow] = []
    func visit(_ view: NSView) {
      let id = view.accessibilityIdentifier()
      if !id.isEmpty, id.hasPrefix("history-navigation-"), view.bounds.height > 1 {
        let inClip = view.convert(view.bounds, to: clip)
        if visible.intersects(inClip) {
          rows.append(SidebarVisibleRow(
            id: id,
            distanceFromClipCenter: abs(inClip.midY - visible.midY),
            windowY: view.convert(view.bounds, to: nil).minY
          ))
        }
      }
      for child in view.subviews { visit(child) }
    }
    visit(document)
    return choose(rows)
  }

  @MainActor
  static func windowY(of identifier: String, in scrollView: NSScrollView) -> CGFloat? {
    guard let document = scrollView.documentView else { return nil }
    var found: CGFloat?
    func visit(_ view: NSView) {
      if found == nil, view.accessibilityIdentifier() == identifier {
        found = view.convert(view.bounds, to: nil).minY
        return
      }
      for child in view.subviews where found == nil { visit(child) }
    }
    visit(document)
    return found
  }
}

/// 侧栏重建前后保持滚动位置。
///
/// 侧栏会整张重建：进「全部博主」这类两栏页面时换了一张。重建后滚动回到顶上，
/// 在侧栏底部点开「全部博主」，刚点的东西反而看不见（2026-10-04 走查）。
/// 所以一直记着侧栏滚到哪儿，新侧栏一挂上就还原。分组展开 / 收起不走这里。
@MainActor
final class SidebarScrollMemory {
  private weak var scrollView: NSScrollView?
  private var observer: NSObjectProtocol?
  private var lastOffset: CGFloat = 0
  /// 换侧栏前，可视区里某一行在屏幕上的高度。新列表套用旧偏移后按它校正。
  private var anchoredRow: SidebarVisibleRow?
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
    anchoredRow = SidebarRowAnchor.capture(in: scrollView)
    isRestoring = true
    snapshotGeneration += 1
    let generation = snapshotGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.snapshotGeneration == generation, !self.isAwaitingRestore else { return }
      self.isRestoring = false
    }
  }

  /// 收起或展开分组前调用。列表有时会自己滚回 0（2026-10-11：滚离顶部后收起「来源」，
  /// 「全部」回到 148）。内容还比窗口高时把原来的偏移按回去；已经短于窗口就停在 0。
  /// 不按新长出来的高度再推一次，那是点「视图」来回跳的原因。
  func holdVisibleOffset() {
    guard let scrollView else { return }
    lastOffset = scrollView.contentView.bounds.origin.y
    pendingReveal = nil
    isRestoring = true
    snapshotGeneration += 1
    let generation = snapshotGeneration
    let pin = { [weak self] in
      guard let self, self.snapshotGeneration == generation, let scrollView = self.scrollView else { return }
      self.scroll(scrollView, to: self.lastOffset)
    }
    DispatchQueue.main.async(execute: pin)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      pin()
      guard let self, self.snapshotGeneration == generation else { return }
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
      self.holdAnchoredRow(in: scrollView)
      self.lastOffset = scrollView.contentView.bounds.origin.y
    }
  }

  /// 旧偏移先落到新列表上，再按锚点那一行的屏幕高度修正。找不到那一行就保持旧偏移。
  private func holdAnchoredRow(in scrollView: NSScrollView) {
    guard let anchoredRow, let rowWindowY = SidebarRowAnchor.windowY(of: anchoredRow.id, in: scrollView) else { return }
    let clip = scrollView.contentView
    let target = SidebarScrollRestore.offsetToHoldRow(
      currentOffset: clip.bounds.origin.y,
      rowWindowY: rowWindowY,
      desiredWindowY: anchoredRow.windowY,
      documentHeight: scrollView.documentView?.frame.height ?? 0,
      viewportHeight: clip.bounds.height
    )
    scroll(scrollView, to: target)
  }

  private func scroll(_ scrollView: NSScrollView, to offset: CGFloat) {
    let clip = scrollView.contentView
    let documentHeight = scrollView.documentView?.frame.height ?? 0
    let target = SidebarScrollRestore.offsetAfterSectionToggle(
      previous: offset,
      documentHeight: documentHeight,
      viewportHeight: clip.bounds.height
    )
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
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
