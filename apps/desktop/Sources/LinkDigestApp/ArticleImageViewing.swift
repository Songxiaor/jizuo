import AppKit
import ImageIO
import LinkDigestAdapters
import SwiftUI

/// 阅读区内联图片的解码缓存。此前每次渲染都在主线程同步
/// `NSImage(contentsOf:)`，26 张大图的文章要卡几十秒；现在后台解码、
/// 按阅读列宽下采样并进 NSCache，滚动往返零重复解码。
enum InlineImageMemoryCache {
  // NSCache 本身线程安全；Swift 并发检查无法证明，故显式标注。
  nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = 256 * 1024 * 1024
    return cache
  }()

  static func image(for url: URL) -> NSImage? {
    cache.object(forKey: url.path as NSString)
  }

  static func store(_ image: NSImage, for url: URL) {
    let cost = Int(image.size.width * image.size.height * 4)
    cache.setObject(image, forKey: url.path as NSString, cost: cost)
  }

  /// CGImageSource 缩略下采样：解码成本与目标尺寸挂钩，而不是原图分辨率。
  static func loadDownsampled(at url: URL, maxPixelSize: CGFloat = 1600) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }
}

/// 全局唯一的图片灯箱状态：任何阅读区图片双击后在窗口内放大展示。
@MainActor final class InlineImageLightboxController: ObservableObject {
  static let shared = InlineImageLightboxController()
  @Published var url: URL?
  /// 已知文本的图（如本地渲染的脑图）：「识别文字」直接秒回这份文本，
  /// 不对大位图跑 Vision OCR。
  @Published private(set) var preparedText: String?

  func present(_ url: URL, preparedText: String? = nil) {
    self.preparedText = preparedText
    self.url = url
  }

  func dismiss() {
    url = nil
    preparedText = nil
  }
}

/// 内联图片视图：占位 → 后台解码 → 白色衬卡展示；双击进灯箱。
/// 连续图片的自适应画廊：阅读区宽就排两列，窄就退回一列。每格保持图片自身
/// 比例、不裁切，所以混排横竖图时两列会参差——那是有意的，宁可参差也不切画面。
struct InlineArticleGalleryView: View {
  let urls: [URL]

  /// 单列最小宽度。阅读区满宽（约 600）时排得下两列，窗口收窄即退回一列。
  private static let minimumColumnWidth: CGFloat = 240

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: Self.minimumColumnWidth), spacing: 12, alignment: .top)],
      alignment: .leading,
      spacing: 12
    ) {
      ForEach(urls, id: \.path) { url in
        InlineArticleImageView(url: url, layout: .gallery)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 18)
    .accessibilityIdentifier("history-content-inline-gallery")
  }
}

struct InlineArticleImageView: View {
  /// 独立成段的插图按自身比例定尺寸；画廊里的格子改由列宽定宽、高度随比例走。
  enum Layout { case standalone, gallery }

  let url: URL
  var layout: Layout = .standalone
  @State private var image: NSImage?

  /// 竖图（9:16）按这个高度算出的宽度约 315，在阅读区里看得清又不占满一屏。
  private static let maximumHeight: CGFloat = 560

  /// 衬卡必须贴合图片本身的比例，所以尺寸不能交给弹性 frame：`maxHeight` 会把
  /// 整块可用宽度都占住，竖图右边那片空白就是这么来的。`aspectRatio` 让视图自带
  /// 比例，宽高上限只做封顶，横图仍旧被阅读区宽度约束、表现不变。
  private static func aspectRatio(of image: NSImage) -> CGFloat {
    let ratio = image.size.width / max(image.size.height, 1)
    return ratio.isFinite && ratio > 0 ? ratio : 1
  }

  /// 单张插图的宽度上限：不超过按高度算出的值，也**不超过图片自身的宽度**。
  ///
  /// `.resizable()` 会把图片拉伸到给定的 frame，所以没有这条上限时，一张
  /// 128×128 的微信表情会被放大到 560×560——放大 4.4 倍，糊成一整屏。
  /// 正文配图普遍 800～1080 宽，不受影响。
  ///
  /// 判据是「图片自身有多大」而不是「它是不是表情」：按 URL 或域名识别表情要
  /// 一个站一个站加，而且换个图床就失效；尺寸是图片自带的事实。
  private static func standaloneMaximumWidth(of image: NSImage) -> CGFloat {
    let ratio = aspectRatio(of: image)
    let byHeight = maximumHeight * ratio
    let intrinsic = image.size.width
    guard intrinsic.isFinite, intrinsic > 0 else { return byHeight }
    return min(byHeight, intrinsic)
  }

  /// 供测试调用；尺寸规则是纯函数，不必为它启一个视图。
  static func standaloneMaximumWidthForTesting(of image: NSImage) -> CGFloat {
    standaloneMaximumWidth(of: image)
  }

  var body: some View {
    Group {
      if let image {
        let ratio = Self.aspectRatio(of: image)
        Image(nsImage: image)
          .resizable()
          .aspectRatio(ratio, contentMode: .fit)
          // 画廊里宽度由列宽决定、高度随比例走；独立插图才用比例算自己的上限。
          .frame(
            maxWidth: layout == .gallery ? .infinity : Self.standaloneMaximumWidth(of: image),
            maxHeight: layout == .gallery ? nil : min(Self.maximumHeight, image.size.height)
          )
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .padding(8)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.primary.opacity(0.12), lineWidth: 1)
          )
          .onTapGesture(count: 2) { InlineImageLightboxController.shared.present(url) }
          .contextMenu {
            Button {
              InlineImageLightboxController.shared.present(url)
            } label: { Label("放大查看", systemImage: "plus.magnifyingglass") }
            Button {
              MarkdownInlineImageActions.saveImage(at: url)
            } label: { Label("存储图片为…", systemImage: "square.and.arrow.down") }
            Button {
              if let full = NSImage(contentsOf: url) { MarkdownInlineImageActions.copyImage(full) }
            } label: { Label("拷贝图片", systemImage: "doc.on.doc") }
          }
          .help("双击放大查看")
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.primary.opacity(0.05))
          .frame(maxWidth: 480)
          .frame(height: 180)
          .overlay(ProgressView().controlSize(.small))
          .task { await load() }
      }
    }
    // 卡片收窄后与正文、标题共用同一条左边界，不在阅读流里飘。
    .frame(maxWidth: .infinity, alignment: .leading)
    // 画廊的行距由网格 spacing 统一给，格子自己不再加尾距。
    .padding(.bottom, layout == .gallery ? 0 : 18)
    .accessibilityIdentifier("history-content-inline-image")
  }

  private func load() async {
    if let cached = InlineImageMemoryCache.image(for: url) {
      image = cached
      return
    }
    let target = url
    let loaded = await Task.detached(priority: .userInitiated) {
      InlineImageMemoryCache.loadDownsampled(at: target)
    }.value
    guard let loaded else { return }
    InlineImageMemoryCache.store(loaded, for: target)
    image = loaded
  }
}

/// 窗口内灯箱：点击图片外区域或 Esc 退出；触控板两指滑动平移、捏合缩放
/// （鼠标滚轮与 ⌘/⌥+滚动仍为缩放）；也可拖拽平移；双击在「适应窗口 ↔ 2x」
/// 之间切换。
struct InlineImageLightboxOverlay: View {
  @ObservedObject private var controller = InlineImageLightboxController.shared

  var body: some View {
    if let url = controller.url {
      InlineImageLightboxCanvas(url: url)
        .transition(.opacity)
    }
  }
}

private struct InlineImageLightboxCanvas: View {
  let url: URL
  @State private var image: NSImage?
  @State private var scale: CGFloat = 1
  @State private var pinchBase: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var dragBase: CGSize = .zero
  /// 单图 OCR：与详情页「图片文字识别」同一 Apple Vision 本机管线。
  @State private var recognition: RecognitionState = .idle

  enum RecognitionState: Equatable {
    case idle
    case running
    case done(String)
    case failed(String)
  }

  private let minScale: CGFloat = 0.5
  private let maxScale: CGFloat = 8

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        // 点击框外暗色区域即退出——主流灯箱行为。
        Color.black.opacity(0.55)
          .contentShape(Rectangle())
          .onTapGesture { InlineImageLightboxController.shared.dismiss() }

        // 带边框的查看框：图片、手势与滚轮都被裁剪限制在框内。
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            canvas(in: CGSize(
              width: proxy.size.width * 0.86 * (showsRecognizedText ? 0.62 : 1),
              height: proxy.size.height * 0.84 - 44
            ))
            if showsRecognizedText {
              Divider()
              recognizedTextPanel
                .frame(width: proxy.size.width * 0.86 * 0.38)
            }
          }
          Divider()
          HStack {
            Text("双指滑动平移 · 双指捏合缩放 · 双击复位 · 点框外或 Esc 退出")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            recognizeButton
            Button {
              MarkdownInlineImageActions.saveImage(at: url)
            } label: { Label("存储为…", systemImage: "square.and.arrow.down") }
              .accessibilityIdentifier("history-inline-image-lightbox-save")
            Button("完成") { InlineImageLightboxController.shared.dismiss() }
              .keyboardShortcut(.cancelAction)
              .accessibilityIdentifier("history-inline-image-lightbox-close")
          }
          .padding(.horizontal, 12)
          .frame(height: 44)
          .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: proxy.size.width * 0.86, height: proxy.size.height * 0.84)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 8)
      }
    }
    .task(id: url) { await loadFullImage() }
  }

  @ViewBuilder private func canvas(in size: CGSize) -> some View {
    // 图片当前的显示尺寸，平移边界由它和画布尺寸共同决定。
    let fitted = image.map { fittedSize(for: $0.size, in: size) } ?? .zero
    let content = CGSize(width: fitted.width * scale, height: fitted.height * scale)
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if let image {
        Image(nsImage: image)
          .resizable()
          .frame(width: content.width, height: content.height)
          .offset(offset)
          .gesture(
            DragGesture()
              .onChanged { value in
                offset = LightboxPanBounds.clamp(
                  CGSize(
                    width: dragBase.width + value.translation.width,
                    height: dragBase.height + value.translation.height
                  ),
                  contentSize: content, containerSize: size
                )
              }
              .onEnded { _ in dragBase = offset }
          )
          .onTapGesture(count: 2) { toggleZoom() }
          .accessibilityIdentifier("history-inline-image-lightbox-canvas")
      } else {
        ProgressView().controlSize(.large)
      }
      // 滚动只在框内生效：作为透明 NSView 铺满画布，事件到不了框外。
      LightboxScrollGestureCatcher { intent in
        switch intent {
        case let .pan(delta):
          offset = LightboxPanBounds.clamp(
            CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
            contentSize: content, containerSize: size
          )
          // 同步给拖拽的基准，否则下一次按住拖会跳回滑动之前的位置。
          dragBase = offset
        case let .zoom(delta):
          scale = clamped(scale * pow(1.003, delta))
          pinchBase = scale
          reclampOffset(fitted: fitted, container: size)
        }
      }
      .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .simultaneousGesture(
      MagnificationGesture()
        .onChanged { value in
          scale = clamped(pinchBase * value)
          reclampOffset(fitted: fitted, container: size)
        }
        .onEnded { _ in pinchBase = scale }
    )
    .frame(width: size.width, height: size.height)
    .clipped()
  }

  /// 缩小会让可平移的范围一起缩小，原先合法的位置可能就越界了，所以每次改完
  /// 缩放都要把位置拉回边界内——否则缩小时图会停在画布外，留下一片空白。
  private func reclampOffset(fitted: CGSize, container: CGSize) {
    offset = LightboxPanBounds.clamp(
      offset,
      contentSize: CGSize(width: fitted.width * scale, height: fitted.height * scale),
      containerSize: container
    )
    dragBase = offset
  }

  private func fittedSize(for imageSize: NSSize, in container: CGSize) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0 else { return container }
    let available = CGSize(width: container.width - 24, height: container.height - 24)
    let ratio = min(available.width / imageSize.width, available.height / imageSize.height, 1)
    return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
  }

  private func clamped(_ value: CGFloat) -> CGFloat { min(max(value, minScale), maxScale) }

  private func toggleZoom() {
    if scale > 1.01 || abs(offset.width) > 1 || abs(offset.height) > 1 {
      scale = 1; pinchBase = 1; offset = .zero; dragBase = .zero
    } else {
      scale = 2; pinchBase = 2
    }
  }

  private func loadFullImage() async {
    let target = url
    let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: target) }.value
    image = loaded
  }

  // MARK: - 识别文字（Apple Vision 本机 OCR）

  private var showsRecognizedText: Bool {
    if case .done = recognition { return true }
    if case .failed = recognition { return true }
    return false
  }

  @ViewBuilder private var recognizeButton: some View {
    switch recognition {
    case .idle:
      Button {
        recognizeText()
      } label: { Label("识别文字", systemImage: "text.viewfinder") }
        .help("Apple Vision 本机处理，图片不会上传。")
        .accessibilityIdentifier("history-inline-image-lightbox-recognize")
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("识别中…").font(.caption).foregroundStyle(.secondary)
      }
    case .done, .failed:
      Button {
        recognition = .idle
      } label: { Label("收起文字", systemImage: "text.viewfinder") }
        .accessibilityIdentifier("history-inline-image-lightbox-recognize-dismiss")
    }
  }

  @ViewBuilder private var recognizedTextPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("识别文字")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if case let .done(text) = recognition {
          Button {
            CopyFeedbackController.shared.copy(text)
          } label: { Label("拷贝全部", systemImage: "doc.on.doc") }
            .controlSize(.small)
            .accessibilityIdentifier("history-inline-image-lightbox-copy-text")
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 34)
      Divider()
      ScrollView {
        switch recognition {
        case let .done(text):
          Text(text)
            .font(.system(size: 12.5))
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .accessibilityIdentifier("history-inline-image-lightbox-recognized-text")
        case let .failed(message):
          Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(12)
        default:
          EmptyView()
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func recognizeText() {
    // 本地渲染图（脑图）自带文本：秒回，不跑几十秒的 Vision 大图 OCR。
    if let prepared = InlineImageLightboxController.shared.preparedText {
      recognition = .done(prepared)
      return
    }
    recognition = .running
    let target = url
    Task {
      do {
        // 与详情页 OCR 相同的识别器与语言集；单图、本机、零网络。
        let text = try await AppleVisionTextRecognizer().recognizeText(
          in: [target],
          languages: ["zh-Hans", "zh-Hant", "en-US"]
        )
        recognition = .done(text)
      } catch {
        recognition = .failed("未识别到文字，或图片无法读取。")
      }
    }
  }
}

/// 一次滚动事件在灯箱里代表什么动作。
enum LightboxScrollIntent: Equatable {
  case pan(CGSize)
  case zoom(CGFloat)
}

/// 平移的边界。
///
/// 平移原来完全不设限，能把图一路滑出画布，只剩一片空白，而且没有任何提示告诉你
/// 图去哪了——只能靠双击复位找回来。
///
/// 规则按轴独立判断，取的是「图的边缘不会离开画布内部」：
/// - 图比画布**大**：可以拖，但最多拖到图的边缘与画布边缘对齐，范围是
///   ±(图 − 画布)/2。这样画布里永远填满图，不会露出背景。
/// - 图比画布**小**（缩小了，或本来就小）：没有可看的多余部分，位置锁定在居中，
///   免得把一张小图推到角落里。
enum LightboxPanBounds {
  static func clamp(_ offset: CGSize, contentSize: CGSize, containerSize: CGSize) -> CGSize {
    CGSize(
      width: clampAxis(offset.width, content: contentSize.width, container: containerSize.width),
      height: clampAxis(offset.height, content: contentSize.height, container: containerSize.height)
    )
  }

  static func clampAxis(_ value: CGFloat, content: CGFloat, container: CGFloat) -> CGFloat {
    let slack = max(0, (content - container) / 2)
    return min(max(value, -slack), slack)
  }
}

/// 把一次滚动事件判成平移还是缩放。
///
/// 原来**所有** `scrollWheel` 事件一律当缩放，于是触控板上不管往哪个方向滑，
/// 图都只会放大缩小，没法看大图的其它部分。macOS 上这两件事本来就由不同的输入
/// 表达，只是都从 `scrollWheel` 这一个入口进来：
///
/// - **触控板两指滑动** → `hasPreciseScrollingDeltas == true`，这是「移动内容」，
///   系统级语义就是滚动；Preview、Photos 都按平移处理。
/// - **触控板捏合** → 根本不是滚动事件，走 `magnify`，由 `MagnificationGesture`
///   单独接，不经过这里。
/// - **鼠标滚轮** → `hasPreciseScrollingDeltas == false`。鼠标没有捏合，滚轮是它
///   唯一能表达缩放的方式，所以这一路保持缩放，不能一起改掉。
/// - **Command / Option + 滚动** → 全平台通用的「强制缩放」，触控板用户也能用。
///
/// 抽成纯函数是因为判断本身才是容易错的地方，而构造真实 `NSEvent` 来测不划算。
func lightboxScrollIntent(
  hasPreciseScrollingDeltas: Bool,
  modifiers: NSEvent.ModifierFlags,
  deltaX: CGFloat,
  deltaY: CGFloat
) -> LightboxScrollIntent? {
  let wantsZoom = modifiers.contains(.command) || modifiers.contains(.option)
  if wantsZoom || !hasPreciseScrollingDeltas {
    guard deltaY != 0 else { return nil }
    return .zoom(deltaY)
  }
  guard deltaX != 0 || deltaY != 0 else { return nil }
  // 方向直接采用系统给的增量：「自然滚动」开关已经体现在里面，图跟着手指走。
  return .pan(CGSize(width: deltaX, height: deltaY))
}

/// 框内滚动手势：视图自身不参与命中（不挡点击/拖拽/双击），但在窗口内挂局部
/// 滚轮监视器，只有光标落在本视图 frame 内才消费事件；光标在框外时事件原样
/// 放行，随视图离窗自动解绑。
private struct LightboxScrollGestureCatcher: NSViewRepresentable {
  let onIntent: (LightboxScrollIntent) -> Void

  func makeNSView(context: Context) -> WheelCatcherView {
    let view = WheelCatcherView()
    view.onIntent = onIntent
    return view
  }

  func updateNSView(_ nsView: WheelCatcherView, context: Context) {
    nsView.onIntent = onIntent
  }

  final class WheelCatcherView: NSView {
    var onIntent: ((LightboxScrollIntent) -> Void)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        removeMonitor()
      } else {
        installMonitor()
      }
    }

    private func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        let pointInSelf = self.convert(event.locationInWindow, from: nil)
        guard self.bounds.contains(pointInSelf) else { return event }
        guard let intent = lightboxScrollIntent(
          hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
          modifiers: event.modifierFlags,
          deltaX: event.scrollingDeltaX,
          deltaY: event.scrollingDeltaY
        ) else { return nil }
        self.onIntent?(intent)
        return nil
      }
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
