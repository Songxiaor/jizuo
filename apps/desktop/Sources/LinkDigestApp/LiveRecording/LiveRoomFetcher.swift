import Foundation
import LinkDigestCore
import WebKit

enum LiveRoomFetchError: Error, Equatable {
  /// 页面能打开，但没有可拉的流：按已下播处理。
  case ended
  /// 网络、HTTP 或页面解析失败：可以重试。
  case unavailable
  /// 抖音要求人机验证。继续自动重试只会一直撞验证码，应该停下来告诉用户。
  case verificationRequired
}

/// 小红书页面一次探测的结论。
enum XiaohongshuLiveRoomVerdict: Equatable {
  /// 页面里有可拉流地址。
  case live
  /// 明确下播：页面文案写着已结束，或房间状态明确不是 2（直播中）。
  case ended
  /// 还没有地址，也没有下播证据：可能还在加载，也可能撞上风控页 / 登录页，应该退避重试。
  case retry
}

@MainActor
protocol LiveRoomFetching {
  func fetchRoom(
    platform: LiveRecordingPlatform,
    pageURL: String,
    userAgent: String,
    referer: String
  ) async throws -> DouyinLiveRoom
}

/// 断线续录时重新读直播间页面。走公开页面直读，不带 Cookie，也不调隐藏接口；
/// 请求头与扩展一致（UA + Referer），为平台以后收紧校验留余地。
struct DouyinLiveRoomFetcher: LiveRoomFetching {
  var session: URLSession = .shared
  var timeout: TimeInterval = 20

  func fetchRoom(
    platform: LiveRecordingPlatform,
    pageURL: String,
    userAgent: String,
    referer: String
  ) async throws -> DouyinLiveRoom {
    guard platform == .douyin else { throw LiveRoomFetchError.unavailable }
    guard let url = URL(string: pageURL) else { throw LiveRoomFetchError.unavailable }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(referer, forHTTPHeaderField: "Referer")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw LiveRoomFetchError.unavailable
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw LiveRoomFetchError.unavailable
    }
    guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
      throw LiveRoomFetchError.unavailable
    }
    if let room = DouyinLivePageParser.parse(html: html, pageURL: pageURL) {
      return room
    }
    // 读不到流有两种情况，不能混为一谈：
    // - 房间数据还在、只是没有可拉的流 → 真下播；
    // - 页面只有一个空壳/风控页（几百 KB 变几 KB）→ 网络或限流，应该重试。
    let looksLikeRoomData = html.contains("\"stream_url\"") || html.contains("\"web_stream_url\"")
    let endedMarker = html.contains("直播已结束") || html.contains("主播已下播") || html.contains("未开播")
    if looksLikeRoomData || endedMarker {
      throw LiveRoomFetchError.ended
    }
    if Self.isVerificationPage(html) { throw LiveRoomFetchError.verificationRequired }
    throw LiveRoomFetchError.unavailable
  }

  static func isVerificationPage(_ html: String) -> Bool {
    // 正常直播间页面也带一次 "captcha"（风控 SDK 配置），不能用它当判据。
    html.contains("验证码中间页") || html.contains("sec_sdk_build")
  }
}

/// 用汲作自己的隐藏网页读直播间。和「添加链接」同一条思路：真实浏览器内核
/// 会带着站点自己下发的 Cookie / 风控状态，直读 HTTP 在连续请求后容易被拦成
/// 几 KB 的空壳（2026-11-11 实测）。
@MainActor
final class WebViewLiveRoomFetcher: NSObject, LiveRoomFetching, WKNavigationDelegate {
  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var finished = false
  private var webView: WKWebView?
  private var window: NSWindow?

  func fetchRoom(
    platform: LiveRecordingPlatform,
    pageURL: String,
    userAgent: String,
    referer: String
  ) async throws -> DouyinLiveRoom {
    guard let url = URL(string: pageURL) else { throw LiveRoomFetchError.unavailable }
    defer { tearDown() }
    try await load(url, userAgent: userAgent)
    if platform == .xiaohongshu {
      return try await readXiaohongshuRoom(pageURL: pageURL)
    }
    // didFinish 只代表「第一张页面到了」；风控挑战页也会触发它。真正有房间数据
    // 往往还要再等一两秒，所以轮询到出现 stream_url 或播放器请求为止。
    var html = ""
    var resources: [String] = []
    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
      if let payload = await snapshotPage() {
        html = payload.html
        resources = payload.resources
        let hasRoomData = html.contains("\"stream_url\"")
          || html.contains("\"web_stream_url\"")
          || html.contains("直播已结束")
          || html.contains("主播已下播")
          || resources.contains { $0.contains(".m3u8") || $0.contains(".flv") }
        if hasRoomData { break }
      }
      try? await Task.sleep(for: .milliseconds(700))
    }
    NSLog("live-fetcher: html payload=\(html.count)")
    guard !html.isEmpty else { throw LiveRoomFetchError.unavailable }
    if let room = DouyinLivePageParser.parse(html: html, pageURL: pageURL, resourceURLs: resources) {
      return room
    }
    let looksLikeRoomData = html.contains("\"stream_url\"") || html.contains("\"web_stream_url\"")
    let endedMarker = html.contains("直播已结束") || html.contains("主播已下播") || html.contains("未开播")
    if looksLikeRoomData || endedMarker { throw LiveRoomFetchError.ended }
    if DouyinLiveRoomFetcher.isVerificationPage(html) { throw LiveRoomFetchError.verificationRequired }
    throw LiveRoomFetchError.unavailable
  }

  /// 小红书：`pullConfig` 在页面跑起来约 6 秒后才填好，轮询到有地址为止。
  private func readXiaohongshuRoom(pageURL: String) async throws -> DouyinLiveRoom {
    let script = """
      (() => {
        const r = window.__INITIAL_STATE__?.liveStream?.roomData?._rawValue?.roomInfo;
        return JSON.stringify({
          pull: typeof r?.pullConfig === 'string' ? r.pullConfig : '',
          flv: typeof r?.deeplink?.flvUrl === 'string' ? r.deeplink.flvUrl : '',
          name: (() => {
            const h = r?.host;
            if (typeof h === 'string') return h;
            if (h && typeof h === 'object') {
              const value = h.nickname ?? h.nick_name ?? h.name ?? r?.host_name;
              if (typeof value === 'string') return value;
            }
            return typeof r?.host_name === 'string' ? r.host_name : '';
          })(),
          title: document.title || '',
          hasRoom: !!r,
          status: typeof r?.status === 'number' ? r.status : null,
          ended: (() => {
            const text = document.body ? document.body.innerText : '';
            return text.includes('直播已结束') || text.includes('主播已下播') || text.includes('暂未开播');
          })()
        });
      })()
      """
    var pulled = ""
    var fallbackFLV = ""
    var anchorName: String?
    var title: String?
    var hasStreamURL = false
    var verdict = XiaohongshuLiveRoomVerdict.retry
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if let view = webView {
        let evaluated = try? await view.evaluateJavaScript(script)
        if let raw = evaluated as? String,
         let data = raw.data(using: .utf8),
         let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
          pulled = (payload["pull"] as? String) ?? ""
          fallbackFLV = (payload["flv"] as? String) ?? ""
          anchorName = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          title = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          hasStreamURL = !pulled.isEmpty || !fallbackFLV.isEmpty
          verdict = Self.xiaohongshuVerdict(
            hasStreamURL: hasStreamURL,
            status: (payload["status"] as? NSNumber)?.intValue,
            endedText: (payload["ended"] as? Bool) ?? false
          )
          if verdict == .ended { throw LiveRoomFetchError.ended }
          if !pulled.isEmpty || !fallbackFLV.isEmpty {
            if let room = XiaohongshuLivePageParser.room(
              pullConfig: pulled,
              pageURL: pageURL,
              anchorName: anchorName,
              title: title,
              fallbackFLVURL: fallbackFLV.isEmpty ? nil : fallbackFLV
            ) {
              return room
            }
          }
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
    if let room = XiaohongshuLivePageParser.room(
      pullConfig: pulled,
      pageURL: pageURL,
      anchorName: anchorName,
      title: title,
      fallbackFLVURL: fallbackFLV.isEmpty ? nil : fallbackFLV
    ) {
      return room
    }
    // 有 roomInfo 但没有地址不等于下播：页面可能还没跑完、或者撞上了风控/登录页。
    // 只有明确看到「已结束」文案、或房间状态明确不是 2，才按下播收尾；其余都重试。
    throw verdict == .ended ? LiveRoomFetchError.ended : LiveRoomFetchError.unavailable
  }

  /// 小红书下播判定只认两件事：地址有没有，以及下播证据够不够硬。
  /// 「有 roomInfo」本身不算证据——风控页、登录页、还没加载完的播放器都可能带着房间对象。
  static func xiaohongshuVerdict(
    hasStreamURL: Bool,
    status: Int?,
    endedText: Bool
  ) -> XiaohongshuLiveRoomVerdict {
    if hasStreamURL { return .live }
    if endedText { return .ended }
    if let status, status != 2 { return .ended }
    return .retry
  }

  private func snapshotPage() async -> (html: String, resources: [String])? {
    let script = """
      JSON.stringify({
        html: document.documentElement.outerHTML,
        resources: (() => {
          try { return performance.getEntriesByType('resource').map((e) => e.name); }
          catch (_) { return []; }
        })()
      })
      """
    guard let view = webView else { return nil }
    let evaluated: Any?
    do {
      evaluated = try await view.evaluateJavaScript(script)
    } catch {
      return nil
    }
    guard let raw = evaluated as? String,
          let data = raw.data(using: .utf8),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let html = payload["html"] as? String
    else { return nil }
    return (html, (payload["resources"] as? [String]) ?? [])
  }

  private func load(_ url: URL, userAgent: String) async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    HiddenWebPage.prepare(configuration)
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
    let view = WKWebView(frame: frame, configuration: configuration)
    view.customUserAgent = userAgent
    view.navigationDelegate = self
    let host = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    host.isReleasedWhenClosed = false
    host.ignoresMouseEvents = true
    host.contentView = view
    host.orderBack(nil)
    webView = view
    window = host
    finished = false

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      loadContinuation = continuation
      view.load(URLRequest(url: url, timeoutInterval: 25))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(25))
        self?.finish(.failure(LiveRoomFetchError.unavailable))
      }
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !finished else { return }
    finished = true
    let continuation = loadContinuation
    loadContinuation = nil
    continuation?.resume(with: result)
  }

  private func tearDown() {
    webView?.navigationDelegate = nil
    webView?.stopLoading()
    window?.orderOut(nil)
    webView = nil
    window = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    NSLog("live-fetcher: didFinish \(webView.url?.absoluteString ?? "-")")
    finish(.success(()))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    NSLog("live-fetcher: didFail \(error)")
    finish(.failure(LiveRoomFetchError.unavailable))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    NSLog("live-fetcher: didFailProvisional \(error)")
    finish(.failure(LiveRoomFetchError.unavailable))
  }
}

/// 先走隐藏网页（带站点自己的会话），拿不到再退回 HTTP 直读。
struct FallbackLiveRoomFetcher: LiveRoomFetching {
  let web: WebViewLiveRoomFetcher
  let direct: DouyinLiveRoomFetcher

  init(web: WebViewLiveRoomFetcher = WebViewLiveRoomFetcher(), direct: DouyinLiveRoomFetcher = DouyinLiveRoomFetcher()) {
    self.web = web
    self.direct = direct
  }

  func fetchRoom(
    platform: LiveRecordingPlatform,
    pageURL: String,
    userAgent: String,
    referer: String
  ) async throws -> DouyinLiveRoom {
    if platform == .xiaohongshu {
      return try await web.fetchRoom(
        platform: platform, pageURL: pageURL, userAgent: userAgent, referer: referer
      )
    }
    do {
      return try await web.fetchRoom(
        platform: platform, pageURL: pageURL, userAgent: userAgent, referer: referer
      )
    } catch LiveRoomFetchError.unavailable {
      return try await direct.fetchRoom(
        platform: platform, pageURL: pageURL, userAgent: userAgent, referer: referer
      )
    }
  }
}
