import Foundation
import LinkDigestCore
import WebKit

struct WeChatPollingGeneration {
  private(set) var value: UInt64 = 0

  mutating func navigationStarted() {
    value &+= 1
  }

  func isCurrent(_ token: UInt64) -> Bool {
    token == value
  }
}

/// Loads one public WeChat article in a hidden, throwaway WKWebView. The
/// service object is reusable, but every call creates and destroys its own
/// process pool, non-persistent data store, and web view.
@MainActor
public final class WeChatWKWebViewCaptureService: WeChatWebCapturing {
  private let now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    try WeChatWebCapturePolicy.validateNavigationURL(url)
    let session = WeChatWKWebViewCaptureSession(url: url, now: now)
    return try await withTaskCancellationHandler {
      try await session.run()
    } onCancel: {
      Task { @MainActor in session.cancel() }
    }
  }

  static func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // WKProcessPool 与 plugInsEnabled 自 macOS 12/10.15 起为无效 no-op，
    // 隔离由 nonPersistent 数据存储承担，不再设置弃用 API。
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    return configuration
  }
}

@MainActor
final class WeChatWKWebViewCaptureSession: NSObject, WKNavigationDelegate, WKUIDelegate {
  private static let timeout: Duration = .seconds(20)
  private static let pollInterval: Duration = .milliseconds(200)

  /// No JavaScript result is evaluated as code. Swift validates every value
  /// before it can cross into the capture document.
  private static let extractionJavaScript = #"""
  (() => {
    // Space collapsing must not touch fenced code lines, or captured code
    // indentation is destroyed.
    const normalize = (value) => {
      const lines = String(value || '')
        .replace(/\u00a0/g, ' ')
        .replace(/\r\n/g, '\n')
        .replace(/[ \t]+\n/g, '\n')
        .split('\n');
      let inFence = false;
      const kept = lines.map((line) => {
        if (/^\s*`{3,}/.test(line)) { inFence = !inFence; return line; }
        return inFence ? line : line.replace(/[ \t]{2,}/g, ' ');
      });
      return kept.join('\n').replace(/\n{3,}/g, '\n\n').trim();
    };
    const content = document.querySelector('#js_content');
    const titleNode = document.querySelector('#activity-name');
    const ogTitle = document.querySelector('meta[property="og:title"]');
    // WeChat ships the article inside `style="visibility: hidden; opacity: 0"`
    // and only reveals it later. `innerText` honours CSS visibility and returns
    // "" for a hidden subtree, so reading it polled an empty string until the
    // 20s deadline even though the body was present the whole time.
    // `textContent` ignores rendering, which is what a scraper wants.
    // Paragraph structure is recovered from the block elements below.
    const imageURL = (image) => String(image.getAttribute('data-src') || image.getAttribute('src') || '').trim();
    // 章节编号上的装饰 GIF 挂在 aria-hidden 容器里，和数字叠在同一格。
    // 写进正文会变成一张张小图，再被阅读器并成图集。
    const isDecorativeImage = (image, root) => {
      let node = image;
      while (node && node !== root) {
        if (node.getAttribute && node.getAttribute('aria-hidden') === 'true') return true;
        node = node.parentElement;
      }
      return false;
    };
    // A TreeWalker preserves the page's DOM order. Text nodes and image markers
    // are emitted in-place rather than bolting a gallery onto the article end.
    // WeChat code-snippet renders one <code> per line; joining them restores
    // the block. Other <pre> keep their own newlines in textContent.
    const fencedCode = (pre) => {
      const codes = Array.from(pre.children).filter((child) => child.tagName === 'CODE');
      const raw = codes.length > 1
        ? codes.map((line) => String(line.textContent || '').replace(/\n+$/g, '')).join('\n')
        : String(pre.textContent || '');
      const cleaned = raw.replace(/\r\n/g, '\n').replace(/^\n+|\n+$/g, '');
      if (!cleaned.trim()) return '';
      const longest = Math.max(0, ...(cleaned.match(/`+/g) || []).map((run) => run.length));
      const fence = '`'.repeat(Math.max(3, longest + 1));
      return '\n\n' + fence + '\n' + cleaned + '\n' + fence + '\n\n';
    };
    const blockText = (node) => {
      if (!node) return '';
      const blockNames = new Set(['P', 'SECTION', 'DIV', 'LI', 'H1', 'H2', 'H3', 'H4', 'BLOCKQUOTE']);
      const parts = [];
      const walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      let current;
      let skipRoot = null;
      while ((current = walker.nextNode())) {
        // A subsumed subtree (code block / line-number rail) must not leak
        // its text nodes into the prose stream.
        if (skipRoot) {
          if (skipRoot.contains(current)) continue;
          skipRoot = null;
        }
        if (current.nodeType === Node.TEXT_NODE) {
          parts.push(current.nodeValue || '');
        } else if (current.tagName === 'PRE') {
          parts.push(fencedCode(current));
          skipRoot = current;
        } else if (current.tagName === 'UL' && /code-snippet__line-index/.test(String(current.className || ''))) {
          skipRoot = current; // WeChat code line numbers are chrome, not content.
        } else if (current.tagName === 'IMG') {
          if (isDecorativeImage(current, node)) continue;
          const url = imageURL(current);
          if (url) parts.push('\n\n![](' + url + ')\n\n');
        } else if (blockNames.has(current.tagName)) {
          parts.push('\n\n');
        }
      }
      return parts.join('');
    };
    const images = [];
    const seenImages = new Set();
    if (content) for (const image of content.querySelectorAll('img')) {
      if (isDecorativeImage(image, content)) continue;
      const url = imageURL(image);
      if (url && !seenImages.has(url)) { seenImages.add(url); images.push(url); }
    }
    const nicknameNode = document.querySelector('#js_name, .profile_nickname, .profile_meta_value');
    const nickname = String(window.nickname || (nicknameNode && nicknameNode.textContent) || '');
    const author = String((document.querySelector('#js_author_name') || {}).textContent || '');
    const ct = String(window.ct || '').trim();
    const ctSeconds = /^\d{9,12}$/.test(ct) ? Number(ct) : NaN;
    const publishedAt = Number.isFinite(ctSeconds)
      ? new Date(ctSeconds * 1000).toISOString()
      : String((document.querySelector('#publish_time') || {}).textContent || '');
    const cover = String((document.querySelector('meta[property="og:image"]') || {}).content || '');
    return {
      title: normalize((titleNode && titleNode.textContent) || (ogTitle && ogTitle.content) || document.title),
      text: normalize(blockText(content)),
      images,
      coverImage: normalize(cover),
      accountName: normalize(nickname),
      author: normalize(author),
      publishedAt: normalize(publishedAt)
    };
  })()
  """#

  /// Test seam: the extraction script is a correctness-critical constant.
  static var extractionJavaScriptForTesting: String { extractionJavaScript }

  private static let verificationSnapshotJavaScript = #"""
  (() => {
    const normalize = (value) => String(value || '')
      .replace(/\u00a0/g, ' ')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .replace(/[ \t]{2,}/g, ' ')
      .trim();
    return { title: '', text: normalize(document.body && document.body.innerText), images: [] };
  })()
  """#

  private let initialURL: URL
  private let now: @Sendable () -> Date
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<CapturedDocument, Error>?
  private var timeoutTask: Task<Void, Never>?
  private var pollingTask: Task<Void, Never>?
  private var isFinished = false
  private var pageDidFinish = false
  private var completedEmptyReadinessCheck = false
  private var pollingGeneration = WeChatPollingGeneration()

  init(url: URL, now: @escaping @Sendable () -> Date) {
    initialURL = url
    self.now = now
    let view = WKWebView(frame: .zero, configuration: WeChatWKWebViewCaptureService.makeConfiguration())
    webView = view
    super.init()
    view.navigationDelegate = self
    view.uiDelegate = self
  }

  func run() async throws -> CapturedDocument {
    try await withCheckedThrowingContinuation { continuation in
      guard !Task.isCancelled, let webView else {
        continuation.resume(throwing: ManualLinkError.cancelled)
        return
      }
      self.continuation = continuation
      timeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.timeout)
        guard let self, !Task.isCancelled else { return }
        self.finish(.failure(WeChatWebCapturePolicy.deadlineFailure(
          pageDidFinish: self.pageDidFinish,
          completedEmptyReadinessCheck: self.completedEmptyReadinessCheck
        )))
      }
      var request = URLRequest(
        url: initialURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 20
      )
      request.httpShouldHandleCookies = false
      webView.load(request)
    }
  }

  func cancel() {
    finish(.failure(ManualLinkError.cancelled))
  }

  private func beginPollingIfNeeded(generation: UInt64) {
    guard pollingTask == nil, !isFinished else { return }
    pollingTask = Task { @MainActor [weak self] in
      await self?.pollUntilReady(generation: generation)
    }
  }

  private func pollUntilReady(generation: UInt64) async {
    do {
      guard pollingGeneration.isCurrent(generation) else { return }
      guard let webView, let finalURL = webView.url else {
        throw ManualLinkError.invalidPageResult
      }
      try WeChatWebCapturePolicy.validateNavigationURL(finalURL)

      guard let verificationRaw = try await webView.evaluateJavaScript(Self.verificationSnapshotJavaScript) else {
        throw ManualLinkError.invalidPageResult
      }
      guard pollingGeneration.isCurrent(generation) else { return }
      let verification = try WeChatWebCapturePolicy.validateJavaScriptResult(
        verificationRaw,
        allowEmptyText: true
      )
      if VerificationPagePolicy.matches(url: finalURL, extractedText: verification.text) {
        throw ManualLinkError.verificationRequired
      }

      while !Task.isCancelled, !isFinished, pollingGeneration.isCurrent(generation) {
        guard let currentURL = webView.url else { throw ManualLinkError.invalidPageResult }
        try WeChatWebCapturePolicy.validateNavigationURL(currentURL)
        guard let raw = try await webView.evaluateJavaScript(Self.extractionJavaScript) else {
          throw ManualLinkError.invalidPageResult
        }
        guard pollingGeneration.isCurrent(generation) else { return }
        let extracted = try WeChatWebCapturePolicy.validateJavaScriptResult(raw, allowEmptyText: true)
        if extracted.text.isEmpty {
          completedEmptyReadinessCheck = true
          try await Task.sleep(for: Self.pollInterval)
          continue
        }
        if VerificationPagePolicy.matches(url: currentURL, extractedText: extracted.text) {
          throw ManualLinkError.verificationRequired
        }
        let timestamp = ISO8601DateFormatter().string(from: now())
        let document = CapturedDocument(
          createdAt: timestamp,
          idempotencyKey: "manual-wechat:\(UUID().uuidString.lowercased())",
          origin: .manualLink,
          url: currentURL.absoluteString,
          title: extracted.title,
          platform: "wechat",
          method: "wkwebview_inline_js",
          text: Self.markdownBody(from: extracted),
          completeness: "best_effort",
          capturedAt: timestamp,
          sourceLabel: "手动链接（公众号内置网页）"
        )
        do {
          try CapturedDocumentValidator.validate(document)
        } catch let error as CapturedDocumentValidationError {
          switch error {
          case .emptyContent: throw ManualLinkError.emptyContent
          case .contentTooLarge: throw ManualLinkError.responseTooLarge
          case .invalidURL, .countMismatch, .invalidTimestamp:
            throw ManualLinkError.invalidPageResult
          }
        }
        finish(.success(document))
        return
      }
    } catch let error as ManualLinkError {
      guard pollingGeneration.isCurrent(generation), !isFinished else { return }
      finish(.failure(error))
    } catch is CancellationError {
      // A same-host client navigation deliberately cancels the previous poll
      // generation. User cancellation already finishes the whole session via
      // the outer cancellation handler, so a polling cancellation is silent.
      return
    } catch {
      guard pollingGeneration.isCurrent(generation), !isFinished else { return }
      finish(.failure(ManualLinkError.invalidPageResult))
    }
  }

  private static func markdownBody(from extracted: WeChatExtractedPage) -> String {
    func yamlString(_ value: String) -> String {
      "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ") + "\""
    }
    var frontmatter: [String] = []
    if let account = extracted.accountName { frontmatter.append("account_name: \(yamlString(account))") }
    if let author = extracted.author { frontmatter.append("author: \(yamlString(author))") }
    if let published = extracted.publishedAt { frontmatter.append("published: \(yamlString(published))") }
    if let cover = extracted.coverImage { frontmatter.append("cover_image: \(yamlString(cover))") }
    guard !frontmatter.isEmpty else { return extracted.text }
    return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(extracted.text)"
  }

  private func finish(_ result: Result<CapturedDocument, Error>) {
    guard !isFinished else { return }
    isFinished = true
    timeoutTask?.cancel()
    timeoutTask = nil
    pollingTask?.cancel()
    pollingTask = nil
    if let webView {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
    }
    webView = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard !isFinished else { return }
    pageDidFinish = false
    completedEmptyReadinessCheck = false
    pollingGeneration.navigationStarted()
    pollingTask?.cancel()
    pollingTask = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isFinished else { return }
    pageDidFinish = true
    beginPollingIfNeeded(generation: pollingGeneration.value)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(.failure(ManualLinkError.network))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finish(.failure(ManualLinkError.network))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    // 新窗口（targetFrame == nil）与站外子框架一律静默拦截；
    // 只有主框架离开 mp.weixin.qq.com 才终止整页捕获。
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
    switch WeChatWebCapturePolicy.navigationDecision(
      url: navigationAction.request.url,
      isMainFrame: isMainFrame
    ) {
    case .allow where navigationAction.targetFrame != nil:
      decisionHandler(.allow)
    case .allow, .blockSilently:
      decisionHandler(.cancel)
    case .failCapture:
      decisionHandler(.cancel)
      finish(.failure(ManualLinkError.webHostNotAllowed))
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    switch WeChatWebCapturePolicy.navigationDecision(
      url: navigationResponse.response.url,
      isMainFrame: navigationResponse.isForMainFrame
    ) {
    case .allow:
      decisionHandler(.allow)
    case .blockSilently:
      decisionHandler(.cancel)
    case .failCapture:
      decisionHandler(.cancel)
      finish(.failure(ManualLinkError.webHostNotAllowed))
    }
  }

  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }
}
