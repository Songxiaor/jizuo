import AppKit
import Foundation
import LinkDigestCore
import WebKit

/// App 内读评论：在隐藏网页里打开原文，运行与扩展同一份 `extract-comments.js`。
///
/// - 登录态：X、B 站、抖音、小红书复用「站点登录」的分区（`SiteSessionController`），
///   其余站点用默认分区。不导入浏览器 Cookie，不调隐藏接口。
/// - 网页挂在一个屏幕外的无边框窗口里：不在窗口里的 WKWebView 会被 WebKit 当成
///   不可见而节流计时器，懒加载的评论区就不再往下加载。
@MainActor
final class CommentFetchService: NSObject, WKNavigationDelegate {
  enum FetchError: LocalizedError, Equatable {
    case unsupported
    case scriptMissing
    case loadFailed
    case timedOut
    case unreadable

    var errorDescription: String? {
      switch self {
      case .unsupported: "这个来源暂不支持读取评论。"
      case .scriptMissing: "评论读取组件缺失，请重新安装汲作。"
      case .loadFailed: "原文页面打不开，请检查网络后重试。"
      case .timedOut: "读取评论超时。页面可能需要登录，或网络较慢，可重试。"
      case .unreadable: "页面已打开，但没有读到评论。可能需要先在「设置 → 站点登录」登录该网站。"
      }
    }
  }

  private var webView: WKWebView?
  private var window: NSWindow?
  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var timedOut = false

  static func dataStore(for url: URL) -> WKWebsiteDataStore {
    let host = url.host?.lowercased() ?? ""
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
    if on("x.com") || on("twitter.com") { return SiteSessionController.x.dataStore }
    if on("bilibili.com") { return SiteSessionController.bilibili.dataStore }
    if on("douyin.com") { return SiteSessionController.douyin.dataStore }
    if on("xiaohongshu.com") { return SiteSessionController.xiaohongshu.dataStore }
    return .default()
  }

  func fetch(url: URL, limit: Int, timeoutSeconds: Double = 60) async throws -> CommentCollection {
    guard CommentCapture.platform(for: url) != nil else { throw FetchError.unsupported }
    guard let script = CommentCapture.collectorScript() else { throw FetchError.scriptMissing }
    defer { tearDown() }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = Self.dataStore(for: url)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
    let view = WKWebView(frame: frame, configuration: configuration)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
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
    // 超时就把网页拆掉：加载等待会以取消结束，不会有迟到的结果写回。
    let timeout = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(timeoutSeconds))
      guard !Task.isCancelled, let self else { return }
      self.timedOut = true
      self.tearDown()
    }
    defer { timeout.cancel() }
    do {
      try await load(url, in: view)
      // 首屏渲染后评论区通常还要再请求一轮。
      try await Task.sleep(for: .seconds(2.5))
      guard !timedOut else { throw FetchError.timedOut }
      let body = CommentCapture.collectorFunctionBody(script: script, limit: limit)
      let raw = try await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
      guard let json = raw as? String, let collection = CommentCapture.decodeCollection(json: json) else {
        throw FetchError.unreadable
      }
      return collection
    } catch {
      if timedOut { throw FetchError.timedOut }
      if error is FetchError || error is CancellationError { throw error }
      throw FetchError.unreadable
    }
  }

  func cancel() { tearDown() }

  private func load(_ url: URL, in view: WKWebView) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      loadContinuation = continuation
      view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
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

  /// 只放行网页本身需要的地址。抖音等页面会探测 `bitbrowser://` 之类的私有协议，
  /// 放任的话系统会弹「未设定用来打开 URL 的应用程序」——隐藏网页不能打扰用户。
  nonisolated static func allowsNavigation(to url: URL?) -> Bool {
    guard let scheme = url?.scheme?.lowercased() else { return true }
    return ["http", "https", "about", "data", "blob"].contains(scheme)
  }

  nonisolated func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let allowed = Self.allowsNavigation(to: navigationAction.request.url)
      && navigationAction.targetFrame != nil
    MainActor.assumeIsolated { decisionHandler(allowed ? .allow : .cancel) }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated { finishLoad(.success(())) }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { finishLoad(.failure(FetchError.loadFailed)) }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    // 站点跳转（302 到登录页等）会以取消结束上一个导航，不算失败。
    if (error as NSError).code == NSURLErrorCancelled { return }
    MainActor.assumeIsolated { finishLoad(.failure(FetchError.loadFailed)) }
  }
}
