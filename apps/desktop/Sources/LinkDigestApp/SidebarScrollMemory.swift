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

  /// 分组刚换 id 时，列表会先报一个不高于可视区的文档高度。这时去夹最大偏移，
  /// 会把原来的位置写成 0，内容排完也不回来（2026-10-11 复测：来源从 314 跳到 497，
  /// 正好是约 183pt 的偏移被清掉）。原来的内容比窗口高、现在文档还没高过可视区，就先别写。
  static func shouldWaitForSectionLayout(
    previousOffset: CGFloat,
    documentHeight: CGFloat,
    viewportHeight: CGFloat,
    previousDocumentHeight: CGFloat
  ) -> Bool {
    guard previousOffset > 1 else { return false }
    guard previousDocumentHeight > viewportHeight + 1 else { return false }
    return documentHeight <= viewportHeight + 1
  }
}

/// 侧栏重建前后保持滚动位置。
///
/// 侧栏会整张重建：进「全部博主」这类两栏页面时换了一张。重建后滚动回到顶上，
/// 在侧栏底部点开「全部博主」，刚点的东西反而看不见（2026-10-04 走查）。
/// 所以一直记着侧栏滚到哪儿，新侧栏一挂上就还原。分组展开 / 收起不走这里。
@MainActor
final class SidebarScrollMemory: ObservableObject {
  /// 展开 / 收起分组后，为了让点中的那一行留在原来的屏幕位置，列表底部要补的一截留白。
  /// 收起分组会让文档变短：如果原来的滚动偏移超出新的滚动范围，系统只能把内容夹回去，
  /// 点的那一行就跟着跳。这里由我们自己补够滚动范围（`navigationRail` 把它加到
  /// `contentMargins(.bottom:)`），偏移就能原样留住。用户往上滚、不再需要时自动收回。
  @Published private(set) var sectionSlack: CGFloat = 0
  private weak var scrollView: NSScrollView?
  private var observer: NSObjectProtocol?
  private var lastOffset: CGFloat = 0
  /// 按住分组前的文档高度。用来分辨「列表还没排完」和「收起后真的短于窗口」。
  private var isHoldingSection = false
  private var holdPinQueued = false
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

  /// 收起或展开分组前调用。
  ///
  /// 分组换 id 时 `List` 会把这一组拆了重排，文档高度会掉一截，滚动偏移也就可能超出新的
  /// 范围。以前的做法是「把偏移钉住、夹回新范围」：`min(旧偏移, 文档高度 - 可视高度)`。
  /// 文档变短时这一夹就把内容整块往上挪，点的那一行跟着跳（2026-10-11 实库：来源从 314
  /// 跳到 497，差 183pt 正好是偏移被清掉）。现在改成由我们决定停在哪：偏移保持点击前的位置，
  /// 不够的滚动范围用底部留白 `sectionSlack` 补出来，点中的行屏幕位置不变；用户往上滚、
  /// 留白不再需要时自动收回。展开出来的内容往下长、留白用不上，偏移也照旧不动。
  func holdVisibleOffset() {
    guard let scrollView else { return }
    lastOffset = scrollView.contentView.bounds.origin.y
    pendingReveal = nil
    isRestoring = true
    isHoldingSection = true
    snapshotGeneration += 1
    let generation = snapshotGeneration
    // 布局分几拍落定（分组换 id → 行删掉 → 文档高度变 → 留白生效）。每一拍都重算留白、
    // 滚回点击前的偏移；最后一拍才松手。
    let pin = { [weak self] in self?.pinHeldOffset(generation: generation) }
    DispatchQueue.main.async { pin() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pin() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pin() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pin() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
      guard let self, self.snapshotGeneration == generation else { return }
      self.pinHeldOffset(generation: generation)
      self.isRestoring = false
      self.isHoldingSection = false
    }
  }

  /// 把点击前的偏移留住：直接滚到目标；如果被新的滚动范围挡住（滚不到那么远），
  /// 记下差多少，下一拍把等量的底部留白补上再试，直到真的落在原位。
  private func pinHeldOffset(generation: Int) {
    guard snapshotGeneration == generation, let scrollView else { return }
    let clip = scrollView.contentView
    if abs(clip.bounds.origin.y - lastOffset) > 0.5 {
      clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: lastOffset))
      scrollView.reflectScrolledClipView(clip)
    }
    let reached = clip.bounds.origin.y
    let shortfall = lastOffset - reached
    if shortfall > 0.5 {
      sectionSlack += shortfall
    }
  }

  /// 用户自己滚动后，把不再需要的底部留白收回。只收到「当前偏移刚好还能站住」为止，
  /// 收的过程不会让偏移改变。
  private func shrinkSlackIfSafe() {
    guard sectionSlack > 0.5, let scrollView else { return }
    let clip = scrollView.contentView
    let documentHeight = scrollView.documentView?.frame.height ?? 0
    // 当前偏移之外还剩多少可滚动的余量（含我们补的留白）。
    let spare = documentHeight + scrollView.contentInsets.bottom - clip.bounds.height - lastOffset
    guard spare > 0.5 else { return }
    let reduce = min(sectionSlack, spare)
    sectionSlack -= reduce
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
    if sectionSlack != 0 { sectionSlack = 0 }
    let clip = newScrollView.contentView
    clip.postsBoundsChangedNotifications = true
    observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
    ) { [weak self, weak clip] _ in
      MainActor.assumeIsolated {
        guard let self, let clip else { return }
        if self.isRestoring {
          if self.isHoldingSection { self.queueHoldPin() }
          return
        }
        self.lastOffset = clip.bounds.origin.y
        self.shrinkSlackIfSafe()
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

  /// 列表在按住期间又自己滚了，就再按一次。已经在目标上就不再滚，避免来回触发。
  private func queueHoldPin() {
    guard !holdPinQueued else { return }
    holdPinQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.holdPinQueued = false
      guard self.isHoldingSection else { return }
      self.pinHeldOffset(generation: self.snapshotGeneration)
    }
  }

  private func scroll(_ scrollView: NSScrollView, to offset: CGFloat) {
    let clip = scrollView.contentView
    let documentHeight = scrollView.documentView?.frame.height ?? 0
    let maxOffset = max(0, documentHeight + sectionSlack - clip.bounds.height)
    let target = min(max(0, offset), maxOffset)
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
