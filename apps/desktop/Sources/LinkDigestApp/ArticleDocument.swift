import AppKit
import SwiftUI

/// 整篇文章排进一个 TextKit 2 文字视图时，图片、表格、代码块这些「嵌在文字里的块」（2026-10-07 滑动性能第二批）。
///
/// 原来文章按章节和图片切成几十个文字视图，中间夹着 SwiftUI 的图片、表格；新引擎每滑一步，
/// 每个文字视图都要重算一遍自己的可见区域，长文偶尔顿一下几十毫秒。现在整篇只有一个文字视图，
/// 块按原样复用 SwiftUI 视图，嵌在文字里；新引擎只给滑到附近的块建视图（原型 120 万字、
/// 约 1200 个块只建了 46 个，仍是 118 帧/秒）。
@MainActor
final class HostedBlockAttachment: NSTextAttachment {
  enum Width {
    /// 用整栏宽：图片、视频、表格、代码块、评论都和正文同一条左右边缘。
    case full
    /// 固定大小，可以挂到文字左边的页边上（章节折叠的小三角）。
    case fixed(CGSize, offset: CGPoint)
  }

  let width: Width
  private let makeView: @MainActor () -> AnyView
  private var controller: NSHostingController<AnyView>?
  private var measured: (width: CGFloat, height: CGFloat)?
  /// 内容高度变了（图片加载完、展开了提示框）：交给文字引擎重排这一处。
  var onSizeInvalidated: (() -> Void)?

  init(width: Width, makeView: @escaping @MainActor () -> AnyView) {
    self.width = width
    self.makeView = makeView
    super.init(data: nil, ofType: nil)
  }

  nonisolated required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func hostingController() -> NSHostingController<AnyView> {
    if let controller { return controller }
    let ref = MainThreadRef(object: self)
    // 块按自己的自然高度排（竖向不受外框限制），高度一变就报上来：图片加载完从占位的
    // 16:9 变成真实比例、展开了提示框，都要让文字引擎重排这一处（2026-10-07 实测：
    // 只靠 preferredContentSize 收不到，图片上下空出一大截）。
    let root = AnyView(
      makeView()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
          ref.object?.contentHeightChanged(height)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    )
    let created = NSHostingController(rootView: root)
    created.sizingOptions = []
    controller = created
    return created
  }

  func host() -> NSView { hostingController().view }

  func height(forWidth width: CGFloat) -> CGFloat {
    if let measured, abs(measured.width - width) < 0.5 { return measured.height }
    let size = hostingController().sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    let height = ceil(max(1, size.height))
    measured = (width, height)
    return height
  }

  private func contentHeightChanged(_ height: CGFloat) {
    guard let measured, height > 0 else { return }
    let rounded = ceil(height)
    guard abs(rounded - measured.height) > 0.5 else { return }
    self.measured = (measured.width, rounded)
    onSizeInvalidated?()
  }

  /// 这个块在给定行宽下占多大。文字引擎有两条路来问尺寸：视图建好之后问 provider，
  /// 屏幕外还没建视图时直接问附件本身——两条路必须给同一个答案，否则屏幕外的块按默认尺寸估，
  /// 目录跳转按估算位置算落点、停偏几节（2026-10-07 检查）。
  func bounds(proposedWidth: CGFloat, indent: CGFloat) -> CGRect {
    let available = max(40, proposedWidth - max(0, indent))
    let rect: CGRect = switch width {
    case let .fixed(size, offset):
      CGRect(origin: offset, size: size)
    case .full:
      CGRect(x: 0, y: 0, width: available, height: height(forWidth: available))
    }
    // 两条路问尺寸都要把视图框跟上：只走附件这条时视图框停在 0，评论区占着位置却画不出来
    //（2026-10-07 检查：X、抖音的评论整块不见）。
    if let view = controller?.view, view.frame.size != rect.size {
      view.setFrameSize(rect.size)
    }
    return rect
  }

  nonisolated override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: CGRect,
    position: CGPoint
  ) -> CGRect {
    let ref = MainThreadRef(object: self)
    let width = proposedLineFragment.width
    let indent = position.x
    return MainActor.assumeIsolated {
      ref.object?.bounds(proposedWidth: width, indent: indent) ?? .zero
    }
  }

  nonisolated override func viewProvider(
    for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    // 文字引擎在主线程上要视图；系统的 provider 类型不能跨线程传，所以借一个局部变量带出来。
    nonisolated(unsafe) var provider: NSTextAttachmentViewProvider?
    nonisolated(unsafe) let parentView = parentView
    nonisolated(unsafe) let textContainer = textContainer
    nonisolated(unsafe) let location = location
    let ref = MainThreadRef(object: self)
    MainActor.assumeIsolated {
      provider = ref.object?.makeProvider(parentView: parentView, location: location, textContainer: textContainer)
    }
    return provider
  }

  private func makeProvider(
    parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider {
    let provider = HostedBlockViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
    // 必须为 true（2026-10-07 实测）：为 false 时文字引擎不理会 attachmentBounds，给每个块套一个
    // 默认的 32pt 宽——大图被压成 31pt 的小灰条、折叠小三角把标题推开 12pt。为 true 时引擎以
    // 视图框为准，并且每次排版都先来问 attachmentBounds：在那里把框改成算好的尺寸（见下）。
    provider.tracksTextAttachmentViewBounds = true
    // 交出去之前就把视图建好：文字引擎排这一行时视图要是还没建，就先画系统默认的小文件图标，
    // 留在折叠小三角底下（2026-10-09 走查：滚到第一屏以下的标题旁、边翻边看新出的标题旁都是小纸片）。
    // 不能改成给附件一张空图——那样引擎只画图、不再放视图，正文里的图和小三角全没了（当天实测）。
    provider.loadView()
    return provider
  }
}

/// 只在主线程上用（文字引擎在主线程排版）。
@MainActor
final class HostedBlockViewProvider: NSTextAttachmentViewProvider {
  nonisolated override func loadView() {
    let ref = MainThreadRef(object: self)
    MainActor.assumeIsolated {
      guard let self = ref.object, let attachment = self.textAttachment as? HostedBlockAttachment else { return }
      let location = self.location
      let providerRef = MainThreadRef(object: self)
      attachment.onSizeInvalidated = {
        guard let manager = providerRef.object?.textLayoutManager,
              let range = NSTextRange(location: location, end: manager.location(location, offsetBy: 1))
        else { return }
        // 排版过程中不能就地改，下一拍再让引擎重排这一处。
        DispatchQueue.main.async { manager.invalidateLayout(for: range) }
      }
      self.view = attachment.host()
    }
  }

  nonisolated override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: CGRect,
    position: CGPoint
  ) -> CGRect {
    let ref = MainThreadRef(object: self)
    return MainActor.assumeIsolated {
      guard let provider = ref.object,
            let attachment = provider.textAttachment as? HostedBlockAttachment else { return .zero }
      // 卡片段落首行缩进了页边那 20pt：文字引擎给的是整行宽，缩进单独放在 position.x 里。
      let rect = attachment.bounds(proposedWidth: proposedLineFragment.width, indent: position.x)
      // 引擎以视图框为准：宽度变了（拖动阅读区、窗口缩放）、内容变高了，都在这里把框跟上。
      if let view = provider.view, view.frame.size != rect.size {
        view.setFrameSize(rect.size)
      }
      return rect
    }
  }
}

/// 把主线程对象带进主线程闭包：文字引擎的回调声明成「任意线程」，实际都在主线程上调。
private struct MainThreadRef<Object: AnyObject>: @unchecked Sendable {
  weak var object: Object?
}

/// 拼好的整篇文章：富文本 + 每个章节标题在全文里的字符位置（目录跳转用）。
struct ArticleDocument {
  let text: NSAttributedString
  /// 键是章节锚点的块序号（和原来 `ScopedReadingAnchor.block` 同一个编号）。
  let anchors: [Int: Int]
}

/// 文章没变就拿回同一份：文字视图按实例同一性短路，不会重设正文。
@MainActor
final class ArticleDocumentCache {
  private var key: AnyHashable?
  private var document: ArticleDocument?
  /// 最近拼好的那份（目录跳转查章节位置用）。
  var current: ArticleDocument? { document }

  /// 上一份文章里的嵌入块，按内容分组。正文变了要重拼时，内容没变的图片、折叠小三角原样拿回来：
  /// 新建一个块要重新加载图片、从占位高度跳到真实高度，边翻边看时每译完一行就整页闪一下
  ///（2026-10-09 Syc 截图：图片变空白、标题旁冒出系统默认的小文件图标）。
  private var previousBlocks: [String: [HostedBlockAttachment]] = [:]
  private var buildingBlocks: [String: [HostedBlockAttachment]] = [:]
  private var blockScope: AnyHashable?

  /// - Parameter reuseScope: 块的样子取决于的外部条件（字体、配色、外观…）；变了就不复用旧块。
  func document(for key: AnyHashable, reuseScope: AnyHashable? = nil, build: () -> ArticleDocument) -> ArticleDocument {
    if let document, self.key == key { return document }
    if blockScope != reuseScope { previousBlocks = [:] }
    blockScope = reuseScope
    buildingBlocks = [:]
    let built = build()
    previousBlocks = buildingBlocks
    buildingBlocks = [:]
    self.key = key
    document = built
    return built
  }

  /// 拼文章时要一个块：上一份里有同样内容的就拿回那一个（同内容出现多次按先后对应），没有才新建。
  func block(reuseKey: String, make: () -> HostedBlockAttachment) -> HostedBlockAttachment {
    let attachment: HostedBlockAttachment
    if var candidates = previousBlocks[reuseKey], !candidates.isEmpty {
      attachment = candidates.removeFirst()
      previousBlocks[reuseKey] = candidates
    } else {
      attachment = make()
    }
    buildingBlocks[reuseKey, default: []].append(attachment)
    return attachment
  }
}

/// 目录跳转：滚到正文里某个字符位置。
struct ReadingScrollRequest: Equatable {
  let characterOffset: Int
  let token: UUID
}

/// 往左多伸出一段、但对外只占给定宽度的容器：外层的对齐和居中不受影响。
struct LeadingBleed: ViewModifier {
  let amount: CGFloat

  func body(content: Content) -> some View {
    LeadingBleedLayout(amount: amount) { content }
  }
}

private struct LeadingBleedLayout: Layout {
  let amount: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let width = proposal.width
    let size = subview.sizeThatFits(ProposedViewSize(width: width.map { $0 + amount }, height: proposal.height))
    return CGSize(width: width ?? max(0, size.width - amount), height: size.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(
      at: CGPoint(x: bounds.minX - amount, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width + amount, height: bounds.height)
    )
  }

  // 对齐参考线不往里问：里面的视图往左伸出了一截，按它算会把外层带偏。
  func explicitAlignment(
    of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGFloat? { nil }
}
