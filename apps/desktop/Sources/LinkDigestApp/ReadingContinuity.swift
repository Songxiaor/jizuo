import AppKit
import Foundation
import LinkDigestCore
import SwiftUI

/// 阅读位置只保存 0...1 的比例，不依赖窗口尺寸或正文像素高度。
///
/// ## 它从 UserDefaults 搬进了数据库
///
/// 旧实现把每一条的阅读位置写在 `reading.position.v1.<id>` 这个键下。三个后果：
/// 删掉记录那条键永远留着（没有任何一处会清，键单调堆积）；备份和导出都带不走
/// 它（换台电脑，所有进度归零）；以及它和它描述的那条内容分属两个存储，谁也
/// 保证不了一致。
///
/// 现在落在 `reading_progress` 表（Migration023），外键 `ON DELETE CASCADE`——
/// 记录真删时进度跟着走，不再需要任何清扫器。
///
/// 对外的接口形状原样保留：调用方仍然只是 `progress(for:)` / `save(_:for:)`，
/// 主界面那边一个字都不用改。
enum ReadingPositionStore {
  static let legacyPrefix = "reading.position.v1."

  /// 库还没就绪时（冷启动的头几百毫秒）退回这里。
  ///
  /// 不直接返回 0：那会让「打开得早一点」变成「进度被清零」——而清零之后
  /// 用户滚一下，0 就被写回库里，旧位置真的没了。缓存住上次读到的值，
  /// 库接上之前至少不制造错误数据。
  @MainActor private static var pendingWrites: [TaskID: Double] = [:]

  @MainActor private static var history: HistoryApplicationService?

  /// 由 App 在历史就绪后接上。在此之前所有读写都留在内存里。
  @MainActor static func configure(history: HistoryApplicationService?) {
    self.history = history
    guard let history else { return }
    migrateLegacyDefaultsIfNeeded(history: history)
    // 库接上之前攒下的写入补上去，别丢。
    let pending = pendingWrites
    pendingWrites.removeAll()
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    for (taskID, value) in pending {
      try? history.saveReadingPosition(value, taskID: taskID, updatedAtMilliseconds: now)
    }
  }

  @MainActor static func progress(for identity: String) -> Double {
    guard let taskID = TaskID(identity) else { return 0 }
    if let pending = pendingWrites[taskID] { return pending }
    return history?.readingPosition(taskID: taskID) ?? 0
  }

  @MainActor static func save(_ progress: Double, for identity: String) {
    guard let taskID = TaskID(identity) else { return }
    let clamped = min(max(progress, 0), 1)
    guard let history else {
      pendingWrites[taskID] = clamped
      return
    }
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    try? history.saveReadingPosition(clamped, taskID: taskID, updatedAtMilliseconds: now)
  }

  /// 首次接上库时，把 UserDefaults 里的旧进度一次性搬进来，然后删掉旧键。
  ///
  /// 搬完就删，不留双写：留着的话「哪一边是真的」就成了一个永远要回答的问题，
  /// 而两边一旦不一致，用户看到的是进度自己跳回去。
  ///
  /// 单条搬迁失败（比如那条记录已经不在了）不影响其它条，也照样删键——那条
  /// 键本来就是无主的，正是这次要清掉的东西。
  @MainActor static func migrateLegacyDefaultsIfNeeded(
    history: HistoryApplicationService,
    defaults: UserDefaults = .standard
  ) {
    let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(legacyPrefix) }
    guard !legacyKeys.isEmpty else { return }
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    for key in legacyKeys {
      let identity = String(key.dropFirst(legacyPrefix.count))
      if let taskID = TaskID(identity) {
        let value = min(max(defaults.double(forKey: key), 0), 1)
        if value > 0 {
          try? history.saveReadingPosition(value, taskID: taskID, updatedAtMilliseconds: now)
        }
      }
      defaults.removeObject(forKey: key)
    }
  }
}

enum ReadingCitationFormatter {
  static func format(selection: String, title: String, sourceURL: String) -> String {
    let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quote.isEmpty else { return "" }
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let attribution = cleanTitle.isEmpty ? "来源" : "《\(cleanTitle)》"
    return "\(quote)\n\n—— \(attribution)\n\(sourceURL)"
  }
}

enum SummaryCitationMatcher {
  static func exactQuotes(summary: String, source: String) -> [String] {
    let sourceBody = MarkdownPresentation.plainTextPresentation(source)
    var seen = Set<String>()
    return MarkdownPresentation.blocks(from: MarkdownPresentation.sanitized(summary)).compactMap { block in
      guard case let .quote(_, raw) = block else { return nil }
      let quote = MarkdownPresentation.plainTextPresentation(raw)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard quote.count >= 8, sourceBody.contains(quote), seen.insert(quote).inserted else { return nil }
      return quote
    }
  }
}

/// 阅读进度的独立发布通道。
///
/// 详情页只用它显示一个小百分比标签，但进度曾写进详情视图的 @State：
/// 每个滚动事件（惯性滚动时每秒可达 60-120 次）都会重求值整个详情页，
/// 评论区几百行跟着 diff——长文滚动因此持续掉帧。标签单独成叶子观察
/// 这里，滚动就只剩一次小文本重绘。
@MainActor
final class ReadingProgressModel: ObservableObject {
  @Published private(set) var percent: Int = 0

  func setPercent(_ value: Int) {
    if percent != value {
      percent = value
    }
  }
}

/// 长正文「收起」时把按钮留在原处（2026-10-07 Syc：点收起卡一下、跳回视频那一屏）。
///
/// 原来收起后带动画滚到这一层开头：正文一下短了几千点，滚动区先被压到页面能滚到的最底，
/// 动画再从那里起步，看起来就是卡一下再跳走。按钮下面的笔记、页脚收起前后不变，所以只要
/// 保持「视口底边到页面底边」的距离，按钮就停在鼠标底下、变成「展开全文」。
/// 页面高度在排版里变的那一刻就校正（frameDidChange 同步回调），不留一帧跳动；
/// 正文的估算高度随后还会修正几次，短时间内跟着校正。
@MainActor
final class ReadingScrollKeeper: NSObject {
  weak var scrollView: NSScrollView?
  /// 正文表头（页签那一行）里的探针，用来算「表头在页面里的位置」。
  weak var sectionAnchor: NSView?
  /// 保持期间要守住的位置：页面变高变矮都按它重新校正。nil 表示没在保持。
  private var holdTarget: HoldTarget?
  private var observedDocument: NSView?
  private var expiry: DispatchWorkItem?
  /// 这一条里各页签（含「译文对应」的层）各自读到的位置，按页面坐标记。
  /// 只在这一条里有效：换一条清空，窗口宽度变了也只是近似，切回来时按页面高度夹住。
  private var sectionOffsets: [String: CGFloat] = [:]
  static let holdDuration: TimeInterval = 0.6

  private enum HoldTarget {
    case distanceFromBottom(CGFloat)
    case offset(CGFloat)
  }

  /// 回到最顶上，和整页新建时的位置一样。滚动区伸到工具栏底下，最顶上是「负的顶部内边距」，不是 0。
  func scrollToTop() {
    guard let scroll = scrollView else { return }
    stop()
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: -scroll.contentInsets.top))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func keepDistanceFromBottom() {
    guard let scroll = scrollView, let document = scroll.documentView else { return }
    hold(.distanceFromBottom(document.frame.height - scroll.contentView.bounds.minY))
  }

  /// 换了一条：上一条各页签的位置作废。
  func resetSections() {
    sectionOffsets.removeAll()
  }

  /// 切页签之前记下当前页签读到哪里、表头是不是已经滚过去了。必须在改状态**之前**调：
  /// 改完之后页面高度一变，滚动区已经被夹到新页面的最底下，记下的就不是读者的位置了。
  func leaveSection(_ key: String) {
    guard let scroll = scrollView else { return }
    let offset = scroll.contentView.bounds.minY
    sectionOffsets[key] = offset
    offsetOnLeave = offset
    if let headerTop = sectionHeaderTop(in: scroll) {
      headerPassedOnLeave = offset + scroll.contentInsets.top > headerTop + 1
    }
  }

  /// 切到另一个页签（文案 / 转写稿 / 译文，或「译文对应」里的层）之后定位置
  /// （2026-10-16 Syc：点文案、转写稿，不管读到哪都跳回首屏）。
  ///
  /// 原来什么都不做：正文从长换短，页面一下矮了几千点，滚动区被夹到最底，看上去就是
  /// 跳回了视频那一屏；再切回来，原来读到的地方也没了。现在：
  /// - 这个页签读过：回到上次读到的地方；
  /// - 没读过、切换前读者已经滚过了表头：把表头放到视口最上面，新内容从第一行开始；
  /// - 表头还在视野里：守住点之前的位置。正文换掉的那一下页面会先变矮再长回来，
  ///   不守的话会被夹回视频那一屏（2026-10-16 Syc 截图：点「译文对应」的转写稿，跳到视频）。
  /// 不是点页签切过来的（比如生成完自动跳页）：不动。
  func enterSection(_ key: String) {
    defer {
      headerPassedOnLeave = false
      offsetOnLeave = nil
    }
    guard let scroll = scrollView else { return }
    if let saved = sectionOffsets[key] {
      hold(.offset(saved))
    } else if headerPassedOnLeave, let headerTop = sectionHeaderTop(in: scroll) {
      hold(.offset(headerTop - scroll.contentInsets.top))
    } else if let offsetOnLeave {
      hold(.offset(offsetOnLeave))
    }
  }

  private var headerPassedOnLeave = false
  private var offsetOnLeave: CGFloat?

  /// 表头是不是已经滚出滚动区顶边（该由吸顶副本接手）。还没接上滚动区或表头时返回 nil。
  /// 和详情页 `onGeometryChange` 的判断同一条线（表头在滚动区坐标里 minY < 0），两边才不会各说各的。
  func isHeaderScrolledPast() -> Bool? {
    guard let scroll = scrollView, let headerTop = sectionHeaderTop(in: scroll) else { return nil }
    return scroll.contentView.bounds.minY > headerTop
  }

  private func sectionHeaderTop(in scroll: NSScrollView) -> CGFloat? {
    guard let anchor = sectionAnchor, let document = scroll.documentView,
          anchor.window != nil, anchor.isDescendant(of: document) else { return nil }
    let rect = anchor.convert(anchor.bounds, to: document)
    return document.isFlipped ? rect.minY : document.bounds.height - rect.maxY
  }

  private func hold(_ target: HoldTarget) {
    guard let scroll = scrollView, let document = scroll.documentView else { return }
    stop()
    holdTarget = target
    observedDocument = document
    document.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(documentFrameChanged(_:)),
      name: NSView.frameDidChangeNotification, object: document
    )
    apply()
    let work = DispatchWorkItem { [weak self] in
      self?.apply()
      self?.stop()
    }
    expiry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
  }

  @objc private func documentFrameChanged(_: Notification) { apply() }

  private func apply() {
    guard let holdTarget, let scroll = scrollView, let document = scroll.documentView else { return }
    let top = -scroll.contentInsets.top
    let maximum = max(top, document.frame.height - scroll.contentView.bounds.height)
    let wanted: CGFloat = switch holdTarget {
    case let .distanceFromBottom(distance): document.frame.height - distance
    case let .offset(offset): offset
    }
    let target = min(max(top, wanted), maximum)
    guard abs(scroll.contentView.bounds.minY - target) > 0.5 else { return }
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func stop() {
    if let observedDocument {
      NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedDocument)
    }
    observedDocument = nil
    holdTarget = nil
    expiry?.cancel()
    expiry = nil
  }
}

/// 挂在正文表头（页签那一行）背后，告诉 `ReadingScrollKeeper` 表头在哪。
struct ReadingSectionAnchorProbe: NSViewRepresentable {
  let keeper: ReadingScrollKeeper

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    keeper.sectionAnchor = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    if keeper.sectionAnchor !== view { keeper.sectionAnchor = view }
  }
}

/// 放在阅读区 ScrollView **里面**，替 `ReadingScrollKeeper` 找到外层 NSScrollView。
/// 挂在 ScrollView 外面（background）往上找不到它。
struct ReadingScrollKeeperProbe: NSViewRepresentable {
  let keeper: ReadingScrollKeeper

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.keeper = keeper
    return view
  }

  func updateNSView(_ view: ProbeView, context: Context) {
    view.keeper = keeper
    view.bind()
  }

  final class ProbeView: NSView {
    weak var keeper: ReadingScrollKeeper?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      bind()
    }

    func bind() {
      guard let keeper, let scroll = enclosingScrollView else { return }
      if keeper.scrollView !== scroll { keeper.scrollView = scroll }
    }
  }
}

/// 观察 SwiftUI 外层 NSScrollView：离开时持续保存，重新打开同一条时恢复。
@MainActor
struct ReadingScrollContinuity: NSViewRepresentable {
  let identity: String
  let progress: ReadingProgressModel

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ view: ProbeView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.attach(from: view)
  }

  /// 视图拆掉（关掉详情、关窗口）时，最后一次位置不能丢在防抖里。
  static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
    coordinator.flushPendingSave()
  }

  @MainActor final class ProbeView: NSView {
    weak var coordinator: Coordinator?
    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.coordinator?.attach(from: self)
      }
    }
  }

  @MainActor final class Coordinator: NSObject {
    var parent: ReadingScrollContinuity
    private weak var scrollView: NSScrollView?
    private var activeIdentity: String?
    private var isRestoring = false
    /// 还没落库的位置。滚动中只记下来，停下约半秒再写一次：写库是主线程上的
    /// 同步事务，后台正在导入或同步时它要排队，原来每滚过 1% 就写一次，滑动会
    /// 被这些等待卡住。
    private var pendingSave: (identity: String, value: Double)?
    private var pendingSaveWork: DispatchWorkItem?
    static let saveDebounce: TimeInterval = 0.5

    init(parent: ReadingScrollContinuity) { self.parent = parent }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func scheduleSave(_ value: Double) {
      pendingSave = (parent.identity, value)
      pendingSaveWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
      pendingSaveWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    func flushPendingSave() {
      pendingSaveWork?.cancel()
      pendingSaveWork = nil
      guard let pending = pendingSave else { return }
      pendingSave = nil
      ReadingPositionStore.save(pending.value, for: pending.identity)
    }

    func attach(from view: NSView) {
      var ancestor = view.superview
      while ancestor != nil, !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
      guard let scroll = ancestor as? NSScrollView else { return }
      if scrollView !== scroll {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(boundsChanged(_:)),
          name: NSView.boundsDidChangeNotification,
          object: scroll.contentView
        )
      }
      guard activeIdentity != parent.identity else { return }
      // 换到另一条之前，把上一条还没落库的位置写掉。
      flushPendingSave()
      // 先停掉记录、回到顶部，再恢复这一条自己的位置。详情页不随条目重建，原来上一条的
      // 滚动偏移会带过来，换条瞬间的滚动事件又被记成了新这一条的进度——没读过的条目
      // 下次打开也停在中间、标题被卷走（2026-10-03 Syc 走查）。
      endRestore()
      isRestoring = true
      scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 0))
      scroll.reflectScrolledClipView(scroll.contentView)
      activeIdentity = parent.identity
      restore(in: scroll)
    }

    static let snapToTopThreshold: CGFloat = 120

    /// 恢复期间守住的比例。新的一条刚换上时正文还在排版（展开的长转写、文字引擎的估高
    /// 会连着改几次页面高度），只在两拍之后按当时的高度算一次，页面再长高就停在了
    /// 半路（2026-10-16 实测：存的是 60%，切回来停在 6%）。现在在一小段时间里跟着页面
    /// 高度重算，读者一动滚轮就放手。
    private var restoreFraction: Double?
    private var restoreDocument: NSView?
    private var restoreExpiry: DispatchWorkItem?
    static let restoreHoldDuration: TimeInterval = 1.0

    private func restore(in scroll: NSScrollView) {
      let stored = ReadingPositionStore.progress(for: parent.identity)
      let percent = Int((stored * 100).rounded())
      parent.progress.setPercent(percent)
      endRestore()
      isRestoring = true
      restoreFraction = stored
      if let document = scroll.documentView {
        restoreDocument = document
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
          self, selector: #selector(restoreDocumentChanged(_:)),
          name: NSView.frameDidChangeNotification, object: document
        )
      }
      NotificationCenter.default.addObserver(
        self, selector: #selector(liveScrollStarted(_:)),
        name: NSScrollView.willStartLiveScrollNotification, object: scroll
      )
      // 等新内容排好版再算位置：同一轮里文档高度还是上一条的。
      DispatchQueue.main.async { [weak self] in
        DispatchQueue.main.async { [weak self] in self?.applyRestore() }
      }
      let work = DispatchWorkItem { [weak self] in
        self?.applyRestore()
        self?.endRestore()
      }
      restoreExpiry = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreHoldDuration, execute: work)
    }

    private func applyRestore() {
      guard let stored = restoreFraction, let scroll = scrollView, let document = scroll.documentView else { return }
      let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      // 只往下看了一点点（标题还没完全滚走）就当没读：按比例恢复会停在标题被
      // 切掉半截的位置，像排版错了（2026-10-01 走查，窄窗口更明显）。
      var target = stored * maximum
      if target < Self.snapToTopThreshold { target = 0 }
      guard abs(scroll.contentView.bounds.minY - target) > 0.5 else { return }
      scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target))
      scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func endRestore() {
      restoreExpiry?.cancel()
      restoreExpiry = nil
      if let restoreDocument {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: restoreDocument)
      }
      NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
      restoreDocument = nil
      restoreFraction = nil
      isRestoring = false
    }

    @objc private func restoreDocumentChanged(_: Notification) { applyRestore() }

    @objc private func liveScrollStarted(_: Notification) { endRestore() }

    @objc private func boundsChanged(_: Notification) {
      // 恢复期间别处（换条目时的「回到顶部」）又把位置挪走了：拉回来。
      if restoreFraction != nil {
        applyRestore()
        return
      }
      didScroll()
    }

    private func didScroll() {
      guard !isRestoring, let scroll = scrollView, let document = scroll.documentView else { return }
      let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      let value = maximum > 0 ? min(max(scroll.contentView.bounds.minY / maximum, 0), 1) : 0
      // 标签只显示整数百分比：更新叶子模型（小重绘）。
      parent.progress.setPercent(Int((value * 100).rounded()))
      // 存停下来的确切位置。原来只在跨过整数百分比时记一次，长转写加评论有几万点高，
      // 1% 就是半屏，切走再回来差出半屏（2026-10-17 走查）。写库仍由防抖管：停下约半秒写一次。
      scheduleSave(value)
    }
  }
}
