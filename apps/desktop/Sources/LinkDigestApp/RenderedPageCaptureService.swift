import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore
import WebKit

/// App「添加链接」的主路径：在屏幕外的隐藏网页里打开链接，跑扩展同一份 `extract-page.js`。
///
/// - 登录态：有「站点登录」分区的站点（X、B 站、抖音、小红书、知乎）用对应分区，
///   其余站点用默认分区。不导入浏览器 Cookie，不调隐藏接口。
/// - 网页挂在屏幕外的无边框窗口里，否则 WebKit 当它不可见、节流计时器，懒加载不再往下走。
/// - 失败时由调用方回落到原来的 HTML 直读（`ManualLinkCaptureService`）。
@MainActor
protocol RenderedPageCapturing: AnyObject {
  func capture(url: URL) async throws -> CapturedDocument
}

@MainActor
final class RenderedPageCaptureService: NSObject, RenderedPageCapturing, WKNavigationDelegate {
  private var webView: WKWebView?
  private var window: NSWindow?
  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var timedOut = false
  /// 和「添加链接」原来的直读路径同一道门：本机、局域网、内网地址一律不去。
  /// AI 助手也能经 MCP 添加链接，不能让它借内置网页读到内网页面（2026-10-02）。
  /// 开着 VPN 时域名会解析成 fake-IP，照直读路径的规则放行。
  private let policy = PublicWebURLPolicy(asyncResolver: SystemHostResolver.asyncResolver(), allowsFakeIPPeers: true)
  private var scriptWorld: WKContentWorld = .defaultClient

  func capture(url: URL) async throws -> CapturedDocument {
    try await policy.validate(url)
    guard let script = RenderedPageExtraction.extractorScript(for: url) else { throw ManualLinkError.invalidPageResult }
    scriptWorld = RenderedPageExtraction.isYouTubeWatch(url) ? .page : .defaultClient
    defer { tearDown() }

    let configuration = WKWebViewConfiguration()
    if let rules = await PrivateNetworkContentRules.compiled() {
      configuration.userContentController.add(rules)
    }
    configuration.websiteDataStore = CommentFetchService.dataStore(for: url)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
    let view = WKWebView(frame: frame, configuration: configuration)
    // YouTube 认出「Chrome」后给的播放页在 Safari 内核里读不到字幕（文字记录面板），
    // 用内核自己的身份才拿得到（2026-10-02 实测：同一视频 3955 字 vs 14344 字）。
    view.customUserAgent = RenderedPageExtraction.isYouTubeWatch(url) ? nil : SiteSessionProfile.browserUserAgent
    view.navigationDelegate = self
    let host = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    host.isReleasedWhenClosed = false
    host.ignoresMouseEvents = true
    host.contentView = view
    host.orderBack(nil)
    webView = view
    window = host

    timedOut = false
    let timeout = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(75))
      guard !Task.isCancelled, let self else { return }
      self.timedOut = true
      self.tearDown()
    }
    defer { timeout.cancel() }
    do {
      try await withTaskCancellationHandler {
        try await load(url, in: view)
      } onCancel: {
        Task { @MainActor [weak self] in self?.tearDown() }
      }
      // 首屏出来后，前端渲染的正文常常还要再请求、再重绘一轮：等字数稳定了再取。
      try await Task.sleep(for: .seconds(1))
      _ = try? await evaluate(RenderedPageExtraction.settleBody, world: .defaultClient, in: view, limit: .seconds(12))
      var document = try await extract(script: script, url: url, in: view)
      if RenderedPageExtraction.shouldRetry(document, url: url) {
        try await Task.sleep(for: .seconds(2))
        if let second = try? await extract(script: script, url: url, in: view),
           second.characterCount > document.characterCount {
          document = second
        }
      }
      return document
    } catch {
      if timedOut { throw ManualLinkError.timedOut }
      if Task.isCancelled || error is CancellationError { throw ManualLinkError.cancelled }
      throw error
    }
  }

  private func extract(script: String, url: URL, in view: WKWebView) async throws -> CapturedDocument {
    guard !timedOut else { throw ManualLinkError.timedOut }
    _ = try? await evaluate(RenderedPageExtraction.lazyLoadScrollBody, world: .defaultClient, in: view, limit: .seconds(15))
    try await Task.sleep(for: .milliseconds(600))
    let raw = try await evaluate(
      RenderedPageExtraction.functionBody(script: script), world: scriptWorld, in: view, limit: .seconds(30)
    )
    guard let json = raw else { throw ManualLinkError.invalidPageResult }
    // 传用户要的原地址：最终停在哪由脚本结果里的地址说明，两者一比才认得出「被跳去登录页」。
    return try RenderedPageExtraction.document(json: json, requestedURL: url)
  }

  /// 在网页里跑一段脚本，最多等 `limit`。网页脚本不返回时（计时器被挂起、Promise 永不结束）
  /// `callAsyncJavaScript` 会一直等下去，而抓取队列是串行的：一条卡住，后面全停。
  private func evaluate(
    _ body: String,
    world: WKContentWorld,
    in view: WKWebView,
    limit: Duration
  ) async throws -> String? {
    let gate = ResumeOnce()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
      view.callAsyncJavaScript(body, arguments: [:], in: nil, in: world) { result in
        guard gate.claim() else { return }
        switch result {
        case let .success(value): continuation.resume(returning: value as? String)
        case let .failure(error): continuation.resume(throwing: error)
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: limit)
        guard gate.claim() else { return }
        continuation.resume(throwing: ManualLinkError.timedOut)
      }
    }
  }

  /// 等页面加载完；带视频、长连接的页面（头条）迟迟不报「加载完毕」，原来一直等到 50 秒
  /// 总超时、一个字都没取（2026-10-02 实测）。页面开始显示后最多再等 15 秒就开始提取。
  private func load(_ url: URL, in view: WKWebView) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      loadContinuation = continuation
      committed = false
      view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
  }

  private var committed = false

  nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      guard !committed else { return }
      committed = true
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(15))
        self?.finishLoad(.success(()))
      }
    }
  }

  private func finishLoad(_ result: Result<Void, Error>) {
    guard let continuation = loadContinuation else { return }
    loadContinuation = nil
    continuation.resume(with: result)
  }

  private func tearDown() {
    finishLoad(.failure(CancellationError()))
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    window?.contentView = nil
    window?.close()
    window = nil
  }

  nonisolated func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let target = navigationAction.request.url
    let allowed = CommentFetchService.allowsNavigation(to: target) && navigationAction.targetFrame != nil
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
    MainActor.assumeIsolated {
      guard allowed else { return decisionHandler(.cancel) }
      // 主页面每一跳（含服务端重定向）都重新过一遍地址门禁：公网页面跳去内网地址就停下。
      guard isMainFrame, let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
        return decisionHandler(.allow)
      }
      Task { @MainActor in
        do {
          try await self.policy.validate(target)
          decisionHandler(.allow)
        } catch {
          decisionHandler(.cancel)
          self.finishLoad(.failure(ManualLinkError.unsafeURL))
        }
      }
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated { finishLoad(.success(())) }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { finishLoad(.failure(ManualLinkError.network)) }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code == NSURLErrorCancelled { return }
    MainActor.assumeIsolated { finishLoad(.failure(ManualLinkError.network)) }
  }
}

/// 哪些链接走隐藏网页。已有专门适配器的来源（抖音、小红书、B 站、GitHub、公众号、X、
/// 直接的 .md 文件）保持原路——它们走的是平台公开接口，比渲染页更稳、更全。
enum RenderedPageCapturePolicy {
  static func prefersRendering(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    if url.path.lowercased().hasSuffix(".md") { return false }
    if isGitHubNotebook(url) || isGitHubRepositoryHome(url) { return true }
    let host = url.host?.lowercased() ?? ""
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
    let adapterHosts = [
      "douyin.com", "iesdouyin.com", "xiaohongshu.com", "xhslink.com", "xhslink.cn",
      "bilibili.com", "b23.tv", "github.com", "mp.weixin.qq.com",
    ]
    return !adapterHosts.contains(where: on)
  }

  /// GitHub 上的 .ipynb：扩展同款脚本会取公开 raw 文件转成 Markdown。GitHub 适配器只会把
  /// 整份 JSON 原样存下（2026-10-02 抓取完整度测试），所以这类链接不回落到直读。
  static func isGitHubNotebook(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    guard host == "github.com" || host == "www.github.com" else { return false }
    let parts = url.pathComponents.filter { $0 != "/" }
    return parts.count >= 5 && parts[2] == "blob" && url.path.lowercased().hasSuffix(".ipynb")
  }

  /// 仓库首页（README）也走隐藏网页：GitHub 接口给的是原始 Markdown 混 HTML，阅读页里引用式
  /// 链接没解析、列表预览露出 `<p> <img…`；扩展从渲染好的页面取，两条路这样才一致（2026-10-02）。
  /// 渲染失败时照旧回落到 GitHub 接口。
  static func isGitHubRepositoryHome(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    guard host == "github.com" || host == "www.github.com" else { return false }
    return url.pathComponents.filter { $0 != "/" }.count == 2
  }

  static func allowsDirectFallback(_ url: URL) -> Bool { !isGitHubNotebook(url) }
}

/// 回调和计时器谁先到谁算数，另一个直接忽略。
@MainActor
private final class ResumeOnce {
  private var claimed = false

  func claim() -> Bool {
    guard !claimed else { return false }
    claimed = true
    return true
  }
}

/// 内置网页里所有直接指向本机、局域网 IP 的请求（页面、内嵌网页、图片、脚本）一律拦下。
/// 只认地址字面，所以和主页面的解析门禁互补：解析到内网的域名由门禁拦，内网 IP 字面由这里拦。
/// WebKit 的规则正则不支持「或」，一个网段一条。
@MainActor
enum PrivateNetworkContentRules {
  private static var cached: WKContentRuleList?
  private static var attempted = false

  static let encodedRules: String = {
    let prefixes = [
      "localhost[:/]", "localhost$", "127\\\\.", "0\\\\.", "10\\\\.", "169\\\\.254\\\\.", "192\\\\.168\\\\.",
      "172\\\\.1[6-9]\\\\.", "172\\\\.2[0-9]\\\\.", "172\\\\.3[01]\\\\.",
      "100\\\\.6[4-9]\\\\.", "100\\\\.[7-9][0-9]\\\\.", "100\\\\.1[01][0-9]\\\\.", "100\\\\.12[0-7]\\\\.",
      "\\\\[",
    ]
    let rules = prefixes.map { prefix in
      #"{"trigger":{"url-filter":"^[a-z]+://"# + prefix + #""},"action":{"type":"block"}}"#
    }
    return "[" + rules.joined(separator: ",") + "]"
  }()

  static func compiled() async -> WKContentRuleList? {
    if let cached { return cached }
    guard !attempted else { return nil }
    attempted = true
    let list = try? await WKContentRuleListStore.default()?.compileContentRuleList(
      forIdentifier: "linkdigest.rendered-capture.private-network",
      encodedContentRuleList: encodedRules
    )
    cached = list
    return list
  }
}
