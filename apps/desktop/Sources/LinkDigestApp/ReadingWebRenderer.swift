import AppKit
import LinkDigestCore
import WebKit

/// 阅读区的离屏排版器：把数学公式、Mermaid 流程图、html 代码块排成图片，
/// 正文里按图片显示（2026-09-24 对齐 Tolaria）。
///
/// ## 为什么排成图片，而不是每处嵌一个网页
///
/// 一篇论文可能有上百个行内公式。每处一个 WKWebView，打开文章就要起上百个网页、
/// 滑动时它们各自抢滚轮。这里全 App 只用一个藏在屏幕外的网页，逐个排版、截图、
/// 按内容缓存；正文里行内公式是文本附件，整段公式和流程图是普通图片，滚动和选择都
/// 不受影响。
///
/// ## 安全
///
/// - 公式和流程图的页面只加载随 App 打包的 KaTeX / Mermaid，页面 CSP 禁止任何网络请求；
/// - html 代码块用另一个网页排版：页面脚本关闭，同样用 CSP 禁止联网，只取一张静态截图；
/// - 截图之外，网页不在任何地方露出，也不接收输入。
@MainActor
final class ReadingWebRenderer: NSObject, ObservableObject {
  static let shared = ReadingWebRenderer()

  enum Kind: Hashable {
    case inlineMath
    case blockMath
    case mermaid
    case html
  }

  struct Request: Hashable {
    let kind: Kind
    let source: String
    /// 文字颜色（十六进制）。深浅主题各排一份。
    let color: String
    let fontSize: CGFloat
    let isDark: Bool
    /// html 代码块按阅读列宽排版。
    let width: CGFloat
  }

  struct Rendered {
    let image: NSImage
    let size: CGSize
    /// 行内公式基线以下的高度，用来和正文对齐。
    let descent: CGFloat
  }

  enum Outcome {
    case rendered(Rendered)
    case failed(String)
  }

  /// 有新结果排好时加一。正文视图观察它，重新组装时把占位换成图片。
  @Published private(set) var generation = 0

  private var results: [Request: Outcome] = [:]
  private var pending: [Request] = []
  private var queued = Set<Request>()
  private var isPumping = false

  private var window: NSWindow?
  private var mathView: WKWebView?
  private var mathPageReady = false
  private var htmlView: WKWebView?
  private var navigationWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

  /// 已经排好的结果；还没排的会进队列，排好后 `generation` 变化。
  func outcome(for request: Request) -> Outcome? {
    if let result = results[request] { return result }
    guard !queued.contains(request) else { return nil }
    queued.insert(request)
    pending.append(request)
    pump()
    return nil
  }

  private func pump() {
    guard !isPumping else { return }
    isPumping = true
    Task { @MainActor in
      var finished = 0
      while !pending.isEmpty {
        let request = pending.removeFirst()
        let outcome = await render(request)
        if results.count > 2_000 { results.removeAll() }
        results[request] = outcome
        queued.remove(request)
        finished += 1
        // 一篇文章几十个公式时攒一批再通知，免得正文一个公式重排一次。
        if pending.isEmpty || finished % 12 == 0 { generation += 1 }
      }
      isPumping = false
    }
  }

  private func render(_ request: Request) async -> Outcome {
    switch request.kind {
    case .inlineMath, .blockMath, .mermaid:
      return await renderInMathPage(request)
    case .html:
      return await renderHTML(request)
    }
  }

  // MARK: - 公式与流程图

  private func renderInMathPage(_ request: Request) async -> Outcome {
    guard let view = await readyMathView() else { return .failed("排版组件没加载成功，关掉这条内容再打开试试") }
    let script: String
    let arguments: [String: Any]
    switch request.kind {
    case .mermaid:
      script = "return await renderMermaid(source, dark, font)"
      arguments = ["source": request.source, "dark": request.isDark, "font": "-apple-system, PingFang SC, sans-serif"]
    default:
      script = "return renderMath(source, display, color, size)"
      arguments = [
        "source": request.source,
        "display": request.kind == .blockMath,
        "color": request.color,
        "size": Double(request.fontSize),
      ]
    }
    let value: Any?
    do {
      value = try await view.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    } catch {
      // 系统原始报错只进日志；括号里给人看的只说原因和下一步（2026-10-01）。
      AppLog.error(.media, "reading_render_script_failed", code: "READING_RENDER_FAILED", ["error": String(describing: error)])
      return .failed("排版组件出错了，关掉这条内容再打开试试")
    }
    guard let metrics = value as? [String: Any] else { return .failed("排版组件没有回应，关掉这条内容再打开试试") }
    if let message = metrics["error"] as? String {
      // 公式/流程图库的原始报错是英文解析信息，进日志；界面只提示检查写法。
      AppLog.notice(.media, "reading_render_source_rejected", ["error": message])
      return .failed("有写法没认出来，请检查原文")
    }
    let width = (metrics["width"] as? Double) ?? 0
    let height = (metrics["height"] as? Double) ?? 0
    guard width > 0, height > 0 else { return .failed("里面没有内容") }
    let descent = (metrics["descent"] as? Double) ?? 0
    guard let image = await snapshot(view, size: CGSize(width: width, height: height)) else {
      return .failed("没能生成图片，关掉这条内容再打开试试")
    }
    return .rendered(Rendered(image: image, size: CGSize(width: width, height: height), descent: descent))
  }

  private func readyMathView() async -> WKWebView? {
    if let mathView, mathPageReady { return mathView }
    guard let pageURL = ReadingWebResources.rendererURL else { return nil }
    let view = makeWebView(allowsScripts: true)
    mathView = view
    view.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    await waitForNavigation(of: view)
    mathPageReady = true
    return view
  }

  // MARK: - html 代码块

  private func renderHTML(_ request: Request) async -> Outcome {
    let view: WKWebView
    if let htmlView {
      view = htmlView
    } else {
      view = makeWebView(allowsScripts: false)
      htmlView = view
    }
    view.frame.size.width = request.width
    let document = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    <style>html,body{margin:0;padding:12px;background:\(request.isDark ? "#1e1e1e" : "#ffffff");color:\(request.color);font:14px -apple-system,PingFang SC,sans-serif;}</style>
    </head><body><div id="jizuo-root">\(request.source)</div></body></html>
    """
    view.loadHTMLString(document, baseURL: nil)
    await waitForNavigation(of: view)
    // 量内容本身的高度：页面高度等于网页视图的高度，内容再短也是满屏。
    let height = (try? await view.evaluateJavaScript(
      "Math.ceil(document.getElementById('jizuo-root').getBoundingClientRect().bottom + 12)"
    )) as? Double ?? 0
    let clamped = min(max(height, 40), 2_400)
    guard let image = await snapshot(view, size: CGSize(width: request.width, height: clamped)) else {
      return .failed("没能生成图片，关掉这条内容再打开试试")
    }
    return .rendered(Rendered(image: image, size: CGSize(width: request.width, height: clamped), descent: 0))
  }

  // MARK: - 共用

  private func makeWebView(allowsScripts: Bool) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_600, height: 2_400), configuration: configuration)
    view.navigationDelegate = self
    // 透明底：截出来的图直接叠在阅读区背景上。
    view.setValue(false, forKey: "drawsBackground")
    hostWindow().contentView?.addSubview(view)
    return view
  }

  /// 截图要求网页挂在窗口里。窗口放在屏幕外、不进窗口菜单、不抢焦点。
  private func hostWindow() -> NSWindow {
    if let window { return window }
    let window = NSWindow(
      contentRect: CGRect(x: -30_000, y: -30_000, width: 1_600, height: 2_400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
    window.backgroundColor = .clear
    window.isOpaque = false
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.orderBack(nil)
    self.window = window
    return window
  }

  private func snapshot(_ view: WKWebView, size: CGSize) async -> NSImage? {
    let needed = CGSize(width: max(view.frame.width, size.width + 8), height: max(view.frame.height, size.height + 8))
    if needed != view.frame.size {
      view.frame.size = needed
      window?.setContentSize(CGSize(width: max(needed.width, 1_600), height: max(needed.height, 2_400)))
    }
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(origin: .zero, size: size)
    configuration.afterScreenUpdates = true
    return try? await view.takeSnapshot(configuration: configuration)
  }

  private func waitForNavigation(of view: WKWebView) async {
    // 网页一直不回话也不能把整条队列卡死：10 秒后当它结束。
    Task { @MainActor [weak self, weak view] in
      try? await Task.sleep(for: .seconds(10))
      if let view { self?.finishNavigation(view) }
    }
    await withCheckedContinuation { continuation in
      navigationWaiters[ObjectIdentifier(view)] = continuation
    }
  }

  fileprivate func finishNavigation(_ view: WKWebView) {
    navigationWaiters.removeValue(forKey: ObjectIdentifier(view))?.resume()
  }
}

extension ReadingWebRenderer: WKNavigationDelegate {
  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated { finishNavigation(webView) }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { finishNavigation(webView) }
  }

  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated { finishNavigation(webView) }
  }

  /// 排版页和 html 代码块都不允许跳转到任何别的地址。
  nonisolated func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    let policy: WKNavigationActionPolicy = scheme == "file" || scheme == "about" || scheme == nil ? .allow : .cancel
    MainActor.assumeIsolated { decisionHandler(policy) }
  }
}

extension NSColor {
  /// `#RRGGBB`，给网页排版用。
  var readingHex: String {
    let color = usingColorSpace(.sRGB) ?? self
    return String(
      format: "#%02X%02X%02X",
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded())
    )
  }
}
