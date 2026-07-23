import AVKit
import SwiftUI
import WebKit

/// App 侧的 watch 链接解析（与扩展适配器同规则的轻量版）。
enum YouTubeWatchLink {
  static func videoID(from urlString: String) -> String? {
    guard let components = URLComponents(string: urlString) else { return nil }
    var host = (components.host ?? "").lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if host.hasPrefix("m.") { host.removeFirst(2) }
    let idPattern = "^[A-Za-z0-9_-]{6,20}$"
    func isValid(_ id: String) -> Bool {
      id.range(of: idPattern, options: .regularExpression) != nil
    }
    if host == "youtu.be" {
      let id = components.path.split(separator: "/").first.map(String.init) ?? ""
      return isValid(id) ? id : nil
    }
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
    if components.path == "/watch" {
      let id = components.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
      return isValid(id) ? id : nil
    }
    for prefix in ["/shorts/", "/live/"] where components.path.hasPrefix(prefix) {
      let id = String(components.path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? ""
      return isValid(id) ? id : nil
    }
    return nil
  }
}

/// YouTube 官方嵌入播放卡：不下载媒体、不注入脚本，联网时按官方 embed
/// 通道播放；导航被锁定在 embed 页面内，点开外链走系统浏览器由用户决定。
struct YouTubeEmbedPlayerCard: View {
  let videoID: String
  var hasCaptions: Bool = true
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 本卡正被影院 overlay 放大时，卡内不再渲染播放器（避免两份音频）。
  private var isInCinema: Bool { cinema.youTubeVideoID == videoID }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.callout.weight(.semibold))
        Text("YouTube 官方嵌入 · 联网播放")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("在浏览器打开") {
          if let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(.link)
        .font(.caption)
      }
      Group {
        if isInCinema {
          // 影院放大期间，卡内显示占位，播放器只存在于 overlay。
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.85))
            .overlay {
              VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
                Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
              }
            }
        } else {
          YouTubeEmbedWebView(videoID: videoID)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .onTapGesture(count: 2) { cinema.present(videoID: videoID) }
        }
      }
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .frame(maxWidth: 720)

      // 「放大」贴在视频正下方右侧：靠近播放器习惯位，又不遮挡 YouTube
      // 自带的底部控制条；与视频同一 720 宽度约束保证右缘对齐。
      if !isInCinema {
        HStack {
          Spacer()
          Button {
            cinema.present(videoID: videoID)
          } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("history-youtube-cinema")
        }
        .frame(maxWidth: 720)
      }

      // 无字幕视频：诚实说明，不再提供质量不达标的本机实时转写。
      // 高质量转写待第三方 API（发 URL + 服务器端 Whisper）的独立 Loop。
      if !hasCaptions {
        HStack(spacing: 8) {
          Image(systemName: "captions.bubble").foregroundStyle(.secondary)
          Text("此视频无字幕，暂无法提取文字。可在浏览器中打开观看。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    .onDisappear {
      // 卡片离屏（切换条目）：影院同视频先收掉，再释放池实例——
      // 否则池持有的 webview 会让音频在后台继续播放。
      if isInCinema { cinema.dismiss() }
      YouTubeEmbedWebViewPool.shared.release(videoID: videoID)
    }
  }
}

/// 窗口内视频「影院模式」放大：与图片灯箱同款——自己的框，不走坑多的
/// 原生全屏。不限来源的底层能力：YouTube embed 走共享 WKWebView，本机/
/// 流媒体视频直接移交 AVPlayer（引用类型，进度与声音天然连续）。
/// 全局单例状态，窗口级 overlay 渲染大画幅播放器。
@MainActor final class VideoCinemaController: ObservableObject {
  enum Content {
    case youTube(videoID: String)
    case player(AVPlayer, aspectRatio: CGFloat)
  }

  static let shared = VideoCinemaController()
  @Published var content: Content?

  var isPresented: Bool { content != nil }

  /// 正在影院放大的 YouTube 视频，供卡片切换成占位（避免两份播放器）。
  var youTubeVideoID: String? {
    if case let .youTube(videoID) = content { return videoID }
    return nil
  }

  func present(videoID: String) { content = .youTube(videoID: videoID) }

  func present(player: AVPlayer, aspectRatio: CGFloat) {
    content = .player(player, aspectRatio: aspectRatio > 0 ? aspectRatio : 16.0 / 9.0)
  }

  func isPresenting(player: AVPlayer?) -> Bool {
    if case let .player(current, _) = content { return current === player }
    return false
  }

  func dismiss() { content = nil }
}

struct VideoCinemaOverlay: View {
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 关闭按钮行占用的高度（22pt 图标 + 8pt 底距），参与可用高度计算。
  private let closeBarHeight: CGFloat = 30

  var body: some View {
    if let content = cinema.content {
      GeometryReader { proxy in
        // 手动算 fitted 尺寸：给播放器确定 frame（不依赖 GeometryReader
        // 首帧的 maxWidth/maxHeight），裁剪与描边直接贴在内容上而不是被
        // frame(maxWidth:maxHeight:) 撑大的外框上——边框悬空 bug 的根因。
        let aspectRatio: CGFloat = {
          if case let .player(_, ratio) = content { return ratio }
          return 16.0 / 9.0
        }()
        let fitted = Self.fittedSize(in: proxy.size, aspectRatio: aspectRatio, reservedTop: closeBarHeight)
        ZStack {
          // 点框外暗区退出。
          Color.black.opacity(0.72)
            .contentShape(Rectangle())
            .onTapGesture { cinema.dismiss() }

          VStack(spacing: 0) {
            HStack {
              Spacer()
              Button {
                cinema.dismiss()
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 22))
                  .foregroundStyle(.white.opacity(0.85))
              }
              .buttonStyle(.plain)
              .keyboardShortcut(.cancelAction)
              .padding(.bottom, 8)
              .accessibilityIdentifier("history-youtube-cinema-close")
            }
            .frame(width: fitted.width)
            Group {
              switch content {
              case let .youTube(videoID):
                YouTubeEmbedWebView(videoID: videoID)
              case let .player(player, _):
                VideoPlayer(player: player)
              }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
          }
        }
      }
      .transition(.opacity)
    }
  }

  /// 视频按自身宽高比 fit 进窗口可用区域：宽 92%、高 88%（先扣关闭按钮行）。
  static func fittedSize(in size: CGSize, aspectRatio: CGFloat, reservedTop: CGFloat) -> CGSize {
    let ratio = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
    let maxWidth = max(size.width * 0.92, 0)
    let maxHeight = max(size.height * 0.88 - reservedTop, 0)
    let width = min(maxWidth, maxHeight * ratio)
    return CGSize(width: max(width, 0), height: max(width / ratio, 0))
  }
}

/// 按 videoID 持有唯一的已加载 WKWebView：卡片与影院 overlay 之间搬移复用，
/// 不重复新建——零尺寸首帧 `loadHTMLString` 会渲染黑屏（影院黑屏 bug 根因），
/// 且单实例放大/还原时播放进度不丢。只保留当前视频一个实例，切换视频即释放。
@MainActor final class YouTubeEmbedWebViewPool {
  static let shared = YouTubeEmbedWebViewPool()

  /// delegate 必须一并强持有：WKWebView 对 navigationDelegate 是弱引用。
  private var current: (videoID: String, webView: WKWebView, delegate: YouTubeEmbedNavigationDelegate)?

  func webView(for videoID: String) -> WKWebView {
    if let current, current.videoID == videoID { return current.webView }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let delegate = YouTubeEmbedNavigationDelegate()
    // 非零初始 frame：保证首次加载不在零尺寸下渲染。
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
    webView.navigationDelegate = delegate
    webView.uiDelegate = delegate
    // 直接加载 embed URL 会因缺少来源页触发播放器错误 153；
    // 用带 baseURL 的宿主页包一层 iframe，播放器即获得合法文档来源。
    let html = """
    <!doctype html><html><head>
    <meta name="viewport" content="initial-scale=1">
    <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}iframe{width:100%;height:100%;border:0}</style>
    </head><body>
    <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?rel=0&playsinline=1"
      allow="encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
    </body></html>
    """
    webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    current = (videoID, webView, delegate)
    return webView
  }

  /// 释放指定视频的实例。卡片离屏且未在影院中时必须调用：池若继续持有，
  /// 正在播放的音频会在后台响个不停。
  func release(videoID: String) {
    guard current?.videoID == videoID else { return }
    current?.webView.removeFromSuperview()
    current = nil
  }
}

/// 承载官方 embed 的 WKWebView：非持久数据存储（不留 Cookie/缓存），
/// 主框架导航仅允许 embed 自身；任何跳出（视频标题/Logo/推荐）一律取消。
/// 视图本身只是容器，真正的 webview 由池按 videoID 复用、attach 时搬移进来；
/// 卡片与影院同一时刻只有一方渲染本视图（影院期间卡片显示占位）。
struct YouTubeEmbedWebView: NSViewRepresentable {
  let videoID: String

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    attachWebView(to: container)
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    attachWebView(to: nsView)
  }

  private func attachWebView(to container: NSView) {
    let webView = YouTubeEmbedWebViewPool.shared.webView(for: videoID)
    guard webView.superview !== container else { return }
    webView.removeFromSuperview()
    webView.frame = container.bounds
    webView.autoresizingMask = [.width, .height]
    container.addSubview(webView)
  }
}

/// 导航锁定：主框架仅允许 embed 自身，任何跳出与 window.open 一律拒绝。
/// 由池强持有（WKWebView 对 delegate 是弱引用）。
@MainActor final class YouTubeEmbedNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    // 子资源请求不经过这里；这里只约束 frame 级导航。
    guard navigationAction.targetFrame?.isMainFrame != false else {
      decisionHandler(.allow)
      return
    }
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let host = (url.host ?? "").lowercased()
    let allowedEmbedHosts = ["www.youtube-nocookie.com", "youtube-nocookie.com"]
    if url.scheme == "about" || (allowedEmbedHosts.contains(host) && url.path.hasPrefix("/embed/")) {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    // window.open 一律拒绝；embed 外的目的地由标题栏「在浏览器打开」承接。
    nil
  }
}
