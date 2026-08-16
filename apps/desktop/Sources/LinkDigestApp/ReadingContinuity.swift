import AppKit
import SwiftUI

/// 阅读位置只保存 0...1 的比例，不依赖窗口尺寸或正文像素高度。
enum ReadingPositionStore {
  private static let prefix = "reading.position.v1."

  static func progress(for identity: String, defaults: UserDefaults = .standard) -> Double {
    min(max(defaults.double(forKey: prefix + identity), 0), 1)
  }

  static func save(_ progress: Double, for identity: String, defaults: UserDefaults = .standard) {
    defaults.set(min(max(progress, 0), 1), forKey: prefix + identity)
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
      guard case let .quote(raw) = block else { return nil }
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
