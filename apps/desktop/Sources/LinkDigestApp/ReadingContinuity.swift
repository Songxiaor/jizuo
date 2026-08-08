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

/// 观察 SwiftUI 外层 NSScrollView：离开时持续保存，重新打开同一条时恢复。
@MainActor
struct ReadingScrollContinuity: NSViewRepresentable {
  let identity: String
  @Binding var progress: Double

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
      restore(in: scroll)
    }

    private func restore(in scroll: NSScrollView) {
      let stored = ReadingPositionStore.progress(for: parent.identity)
      parent.progress = stored
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
      parent.progress = value
      ReadingPositionStore.save(value, for: parent.identity)
    }
  }
}
