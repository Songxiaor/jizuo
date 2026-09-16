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
    /// 上次持久化的整数百分比：写入按显示粒度量化，一整页滚动最多百来次，
    /// 而不是每个滚动事件都写一次 UserDefaults。
    private var lastPersistedPercent: Int?

    init(parent: ReadingScrollContinuity) { self.parent = parent }

    deinit { NotificationCenter.default.removeObserver(self) }

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
      activeIdentity = parent.identity
      lastPersistedPercent = nil
      restore(in: scroll)
    }

    private func restore(in scroll: NSScrollView) {
      let stored = ReadingPositionStore.progress(for: parent.identity)
      let percent = Int((stored * 100).rounded())
      parent.progress.setPercent(percent)
      lastPersistedPercent = percent
      isRestoring = true
      DispatchQueue.main.async { [weak self, weak scroll] in
        guard let self, let scroll, let document = scroll.documentView else { return }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: stored * maximum))
        scroll.reflectScrolledClipView(scroll.contentView)
        self.isRestoring = false
      }
    }

    @objc private func boundsChanged(_: Notification) { didScroll() }

    private func didScroll() {
      guard !isRestoring, let scroll = scrollView, let document = scroll.documentView else { return }
      let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
      let value = maximum > 0 ? min(max(scroll.contentView.bounds.minY / maximum, 0), 1) : 0
      // 标签只显示整数百分比：更新叶子模型（小重绘），持久化按同一粒度量化。
      let percent = Int((value * 100).rounded())
      parent.progress.setPercent(percent)
      guard percent != lastPersistedPercent else { return }
      lastPersistedPercent = percent
      ReadingPositionStore.save(value, for: parent.identity)
    }
  }
}
