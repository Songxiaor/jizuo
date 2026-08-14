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
  @ObservedObject private var diagnostics = YouTubeEmbedDiagnostics.shared
  /// 封面优先：用户点过播放才创建 WKWebView。
  ///
  /// 以前卡片一渲染就冷启动一个无缓存的 WKWebView（非持久存储是隐私取舍，
  /// 不能改），YouTube 播放器整套 JS 每次重新下载，「正在加载嵌入播放器…」
  /// 一转好几秒；切走条目即释放，切回来又是一遍。封面图只有几十 KB 且有
  /// 内存 + 系统 URLCache 两层缓存，显示是即时的；播放器的加载成本推迟到
  /// 用户真的要看的那一刻。条目切换（本卡离屏）后状态归零，回来重新是封面，
  /// 不会有看不见的播放器在后台出声。
  @State private var isPlayerRequested = false

  /// 本卡正被影院 overlay 放大时，卡内不再渲染播放器（避免两份音频）。
  private var isInCinema: Bool { cinema.youTubeVideoID == videoID }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.callout.weight(.semibold))
        Text("YouTube 官方嵌入 · 联网播放")
          .font(.caption)
          .appSecondaryText()
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
          RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .fill(Color.black.opacity(0.85))
            .overlay {
              VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
                Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
              }
            }
        } else if !isPlayerRequested {
          YouTubeEmbedPosterView(videoID: videoID) { isPlayerRequested = true }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        } else {
          YouTubeEmbedWebView(videoID: videoID)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            // 加载没成功时，用可读的一行字盖住那个纯白框——空白本身不携带任何信息。
            .overlay {
              if let message = diagnostics.status[videoID] {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                  .fill(Color.black.opacity(0.88))
                  .overlay {
                    VStack(spacing: 8) {
                      Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.75))
                      Text(message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                    }
                  }
                  .accessibilityIdentifier("history-youtube-embed-diagnostic")
              }
            }
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
            .appSecondaryText()
          Spacer()
        }
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    .onDisappear {
      // 卡片离屏（切换条目）：影院同视频先收掉，再释放池实例——
      // 否则池持有的 webview 会让音频在后台继续播放。
      if isInCinema { cinema.dismiss() }
      YouTubeEmbedWebViewPool.shared.release(videoID: videoID)
    }
  }
}

/// 视频封面 + 播放按钮（lite-embed 模式的前半张脸）。
///
/// 点它才创建真正的播放器。封面即时可见，回答了「这条是什么视频」；
/// 加载播放器的几秒网络成本只在用户明确要看时才付。
private struct YouTubeEmbedPosterView: View {
  let videoID: String
  let onPlay: () -> Void
  @State private var thumbnail: NSImage?

  var body: some View {
    Button(action: onPlay) {
      Color.black
        .overlay {
          if let thumbnail {
            Image(nsImage: thumbnail)
              .resizable()
              // hqdefault 是 4:3（自带上下黑边），fill 进 16:9 框正好裁掉黑边；
              // maxresdefault 本身 16:9，fill 等于原样铺满。
              .scaledToFill()
          }
        }
        .overlay {
          VStack(spacing: 8) {
            Image(systemName: "play.circle.fill")
              .font(.system(size: 52))
              .foregroundStyle(.white.opacity(0.92))
              .shadow(color: .black.opacity(0.45), radius: 10)
            Text("点击加载播放器")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.85))
              .shadow(color: .black.opacity(0.5), radius: 4)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.appPlain)
    .accessibilityLabel("播放视频")
    .accessibilityIdentifier("history-youtube-poster")
    .task(id: videoID) {
      thumbnail = await YouTubeThumbnailLoader.image(for: videoID)
    }
  }
}

/// 封面图加载：maxresdefault 优先（16:9 高清，部分视频没有），失败落回
/// hqdefault（一定存在，4:3 带黑边，由视图层 fill 裁掉）。内存缓存之外，
/// URLSession.shared 自带的 URLCache 还提供磁盘层，重开条目即时显示。
/// 只取公开封面图，不带任何身份信息。
@MainActor enum YouTubeThumbnailLoader {
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  static func image(for videoID: String) async -> NSImage? {
    if let hit = images.object(forKey: videoID as NSString) { return hit }
    for variant in ["maxresdefault", "hqdefault"] {
      guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(variant).jpg"),
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let decoded = NSImage(data: data)
      else { continue }
      images.setObject(decoded, forKey: videoID as NSString)
      return decoded
    }
    return nil
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
  @ObservedObject private var diagnostics = YouTubeEmbedDiagnostics.shared

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
              .buttonStyle(.appPlain)
              .keyboardShortcut(.cancelAction)
              .padding(.bottom, 8)
              .accessibilityIdentifier("history-youtube-cinema-close")
            }
            .frame(width: fitted.width)
            Group {
              switch content {
              case let .youTube(videoID):
                YouTubeEmbedWebView(videoID: videoID, role: .cinema)
                  // 影院这条路径此前没有任何状态显示，所以搬移失败时只剩一个
                  // 空框——位置和边框都对，内容却是透明的，看不出是哪一环断了。
                  .overlay {
                    if let message = diagnostics.status[videoID] {
                      Color.black.opacity(0.88)
                        .overlay {
                          VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                              .font(.title2)
                              .foregroundStyle(.white.opacity(0.75))
                            Text(message)
                              .font(.caption)
                              .foregroundStyle(.white.opacity(0.85))
                              .multilineTextAlignment(.center)
                              .textSelection(.enabled)
                              .padding(.horizontal, 24)
                          }
                        }
                        .accessibilityIdentifier("history-youtube-cinema-diagnostic")
                    }
                  }
              case let .player(player, _):
                VideoPlayer(player: player)
              }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
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

/// 嵌入播放的诊断面。
///
/// 这张卡出问题时的表现是「一片空白」——没有报错、没有日志、没有任何可读状态，
/// 而白色恰恰说明宿主页没渲染（HTML 里 `background` 写死了 `#000`，加载成功至少是黑的）。
/// 空白的可能来源至少有三种，光看代码分不出来：宿主页没加载、加载失败被静默吞掉、
/// 或者容器里根本没挂上 webview（池的 release 与 attach 抢顺序）。所以把这三种
/// 分别记成人能读的一行字，直接显示在卡上。
@MainActor final class YouTubeEmbedDiagnostics: ObservableObject {
  static let shared = YouTubeEmbedDiagnostics()

  /// videoID → 当前状态。nil 表示已正常加载完成，卡片不显示任何覆盖层。
  @Published private(set) var status: [String: String] = [:]

  func record(_ videoID: String, _ message: String) { status[videoID] = message }
  func clear(_ videoID: String) { status.removeValue(forKey: videoID) }

}

/// 按 videoID 持有唯一的已加载 WKWebView：卡片与影院 overlay 之间搬移复用，
/// 不重复新建——零尺寸首帧 `loadHTMLString` 会渲染黑屏（影院黑屏 bug 根因），
/// 且单实例放大/还原时播放进度不丢。只保留当前视频一个实例，切换视频即释放。
@MainActor final class YouTubeEmbedWebViewPool {
  static let shared = YouTubeEmbedWebViewPool()

  /// delegate 必须一并强持有：WKWebView 对 navigationDelegate 是弱引用。
  private typealias Entry = (webView: WKWebView, delegate: YouTubeEmbedNavigationDelegate)

  /// 按 videoID 存。
  ///
  /// 原来是单槽：另一个视频的卡片一渲染就会把当前实例挤掉。挤掉的那个若正被
  /// 影院持有，它仍在屏幕上播放，但池已经不再跟踪它——之后 `release` 找不到，
  /// 关掉影院后音频会在后台一直响，而且没有任何入口能停下它。
  /// 实测轨迹里就有别的 videoID 的卡片在离屏渲染，这条路是真的会走到。
  private var entries: [String: Entry] = [:]

  func webView(for videoID: String) -> WKWebView {
    if let existing = entries[videoID] { return existing.webView }
    // 新建之前先收掉用不着的：既不是本视频、也不是影院正持有的，一律释放。
    // 这样常驻上限是 2（影院一个 + 当前卡片一个），不会随浏览无限增长。
    let cinemaHeld = VideoCinemaController.shared.youTubeVideoID
    for (id, entry) in entries where id != videoID && id != cinemaHeld {
      entry.webView.removeFromSuperview()
      entries.removeValue(forKey: id)
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // 空集合 = 允许 autoplay。播放器创建只发生在用户手势之后（封面点击 /
    // 「放大」按钮），embed URL 里的 autoplay=1 是在兑现那次点击——否则用户
    // 点完封面还要在 YouTube 控件上再点一次播放。用户手势这道门由封面层
    // （isPlayerRequested）把守，不再依赖 WebKit 的媒体手势策略。
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let delegate = YouTubeEmbedNavigationDelegate(videoID: videoID)
    YouTubeEmbedDiagnostics.shared.record(videoID, "正在加载嵌入播放器…")
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
    <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?rel=0&playsinline=1&autoplay=1"
      allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
    </body></html>
    """
    webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    entries[videoID] = (webView, delegate)
    return webView
  }

  /// 释放指定视频的实例。卡片离屏且未在影院中时必须调用：池若继续持有，
  /// 正在播放的音频会在后台响个不停。
  func release(videoID: String) {
    // 影院还在放这个视频就不能释放：卡片离屏（切换条目、详情重建）会走到这里，
    // 释放掉正在放大播放的实例等于把影院画面抽空。
    guard VideoCinemaController.shared.youTubeVideoID != videoID else { return }
    guard let entry = entries.removeValue(forKey: videoID) else { return }
    entry.webView.removeFromSuperview()
    YouTubeEmbedDiagnostics.shared.clear(videoID)
  }
}

/// 承载官方 embed 的 WKWebView：非持久数据存储（不留 Cookie/缓存），
/// 主框架导航仅允许 embed 自身；任何跳出（视频标题/Logo/推荐）一律取消。
/// 视图本身只是容器，真正的 webview 由池按 videoID 复用、attach 时搬移进来；
/// 卡片与影院同一时刻只有一方渲染本视图（影院期间卡片显示占位）。
struct YouTubeEmbedWebView: NSViewRepresentable {
  /// 调用方身份。两边的容器长得一样，出问题时画面上分不出是谁抢走了 webview。
  enum Role: String { case card, cinema }

  let videoID: String
  var role: Role = .card

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    attachWebView(to: container)
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    attachWebView(to: nsView)
  }

  private func attachWebView(to container: NSView) {
    // 影院正在放这个视频时，卡片一律不抢。
    //
    // 卡片在影院期间本来就只渲染占位、不该走到这里，但视图重建（card.make）会在
    // 判定生效前先跑一次 attach。一个 webview 被两棵视图树争用，结果是谁最后
    // attach 谁拿到——实测轨迹就是 cinema → card → cinema → card 的拉锯，
    // 最后落在卡片那个 0×0 且尚未入窗的容器上，影院就成了空框。
    // 这里必须按角色定优先级，不能指望调用方的渲染顺序。
    if role == .card, VideoCinemaController.shared.youTubeVideoID == videoID { return }
    let webView = YouTubeEmbedWebViewPool.shared.webView(for: videoID)
    guard webView.superview !== container else { return }
    webView.removeFromSuperview()
    // 用约束而不是 frame + autoresizingMask。
    //
    // 这个 webview 会在卡片和影院 overlay 之间来回搬，而 SwiftUI 给出的容器
    // 首帧尺寸经常是 0（GeometryReader 第一帧、overlay 刚插入时都是）。
    // autoresizingMask 按**差量**调整边距，从 0 尺寸起步搬过去，后续的尺寸变化
    // 不一定能把它拉回正确大小——表现是一个位置和边框都对、但内容完全空的框，
    // 而且不报任何错。约束是绝对关系，不受首帧尺寸影响。
    webView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      webView.topAnchor.constraint(equalTo: container.topAnchor),
      webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    // 挂载后容器仍是空的，就说明有人在 attach 之后把它摘走了（池的 release 与
    // attach 抢顺序）。这一路不会报错，只会留下一个空框。
    if container.subviews.isEmpty {
      YouTubeEmbedDiagnostics.shared.record(videoID, "播放器已被挂载后立刻移除（容器为空）。")
    }
  }
}

/// 主框架导航判定。抽成纯函数是因为它有两个方向的失败模式，且都不报错：
/// 收紧一格，宿主页自己被拦，WebKit 静默不发失败回调，只留一个白框；
/// 放宽一格，这个没有地址栏的卡片就变成了自由浏览器。
enum YouTubeEmbedNavigationPolicy {
  private static let allowedHosts: Set<String> = ["www.youtube-nocookie.com", "youtube-nocookie.com"]

  static func allowsMainFrame(url: URL) -> Bool {
    // WebKit 在初始化阶段会走 about:blank。
    if url.scheme == "about" { return true }
    guard allowedHosts.contains((url.host ?? "").lowercased()) else { return false }
    // 空 path / "/" 是 `loadHTMLString(_:baseURL:)` 的宿主页；`/embed/` 是 iframe。
    // 其余路径（/watch、登录跳转、推荐位）一律拦掉。
    return url.path.isEmpty || url.path == "/" || url.path.hasPrefix("/embed/")
  }
}

/// 导航锁定：主框架仅允许 embed 自身，任何跳出与 window.open 一律拒绝。
/// 由池强持有（WKWebView 对 delegate 是弱引用）。
@MainActor final class YouTubeEmbedNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
  private let videoID: String

  init(videoID: String) {
    self.videoID = videoID
    super.init()
  }

  // —— 以下四个回调此前一个都没实现，所以任何加载失败都是静默的。 ——

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // 宿主页加载完成。iframe 内部的播放器错误（比如 153）不会走到这里，
    // 但至少能把「宿主页都没起来」和「宿主页起来了、播放器有问题」分开。
    YouTubeEmbedDiagnostics.shared.clear(videoID)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    let code = (error as NSError).code
    YouTubeEmbedDiagnostics.shared.record(
      // secret-hygiene:reviewed code 是 NSError.code 整数（WebKit 载入失败码），
      // 不是 provider 返回的文本。
      videoID, "嵌入页未能开始加载（\(code)）：\(error.localizedDescription)")  // secret-hygiene:reviewed
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    YouTubeEmbedDiagnostics.shared.record(videoID, "嵌入页加载中断：\(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // Web 内容进程崩溃后 webview 会变成永久空白，且不会有任何其它回调。
    YouTubeEmbedDiagnostics.shared.record(videoID, "网页内容进程已退出，播放器需要重新载入。")
  }

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
    guard YouTubeEmbedNavigationPolicy.allowsMainFrame(url: url) else {
      // 拦截也要留痕：白名单收得过紧和收得过松，症状完全不同，但都无声。
      YouTubeEmbedDiagnostics.shared.record(
        videoID,
        "导航被白名单拦下：\(url.host ?? "?")\(url.path.isEmpty ? "（无路径）" : url.path)")
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
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
