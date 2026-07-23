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

  func present(_ url: URL) { self.url = url }
  func dismiss() { url = nil }
}

/// 内联图片视图：占位 → 后台解码 → 白色衬卡展示；双击进灯箱。
struct InlineArticleImageView: View {
  let url: URL
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 420, alignment: .leading)
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
    .padding(.bottom, 18)
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

/// 窗口内灯箱：点击图片外区域或 Esc 退出；触控板捏合与鼠标滚轮缩放；
/// 放大后可拖拽平移；双击在「适应窗口 ↔ 2x」之间切换。
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
            Text("双指捏合 / 滚轮缩放 · 拖拽平移 · 双击复位 · 点框外或 Esc 退出")
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
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if let image {
        let fitted = fittedSize(for: image.size, in: size)
        Image(nsImage: image)
          .resizable()
          .frame(width: fitted.width * scale, height: fitted.height * scale)
          .offset(offset)
          .gesture(
            DragGesture()
              .onChanged { value in
                offset = CGSize(
                  width: dragBase.width + value.translation.width,
                  height: dragBase.height + value.translation.height
                )
              }
              .onEnded { _ in dragBase = offset }
          )
          .onTapGesture(count: 2) { toggleZoom() }
          .accessibilityIdentifier("history-inline-image-lightbox-canvas")
      } else {
        ProgressView().controlSize(.large)
      }
      // 滚轮只在框内生效：作为透明 NSView 铺满画布，事件到不了框外。
      LightboxWheelZoomCatcher { delta in
        scale = clamped(scale * pow(1.003, delta))
        pinchBase = scale
      }
      .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .simultaneousGesture(
      MagnificationGesture()
        .onChanged { value in scale = clamped(pinchBase * value) }
        .onEnded { _ in pinchBase = scale }
    )
    .frame(width: size.width, height: size.height)
    .clipped()
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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

/// 框内滚轮缩放：视图自身不参与命中（不挡点击/拖拽/双击），但在窗口内
/// 挂局部滚轮监视器，只有光标落在本视图 frame 内才消费事件并缩放；
/// 光标在框外时事件原样放行，随视图离窗自动解绑。
private struct LightboxWheelZoomCatcher: NSViewRepresentable {
  let onZoom: (CGFloat) -> Void

  func makeNSView(context: Context) -> WheelCatcherView {
    let view = WheelCatcherView()
    view.onZoom = onZoom
    return view
  }

  func updateNSView(_ nsView: WheelCatcherView, context: Context) {
    nsView.onZoom = onZoom
  }

  final class WheelCatcherView: NSView {
    var onZoom: ((CGFloat) -> Void)?
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
        let delta = event.scrollingDeltaY
        if delta != 0 { self.onZoom?(delta) }
        return nil
      }
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
