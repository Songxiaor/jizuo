import Foundation
import LinkDigestCore
import WebKit

/// Rendered fallback for a manually submitted Douyin URL.
///
/// The ordinary adapter still gets first chance to use public HTML. When that
/// HTML is only a client-rendered shell, this service loads the same URL in the
/// App's isolated Douyin WebKit partition and reads only the current item.
@MainActor
public final class DouyinWKWebViewCaptureService: DouyinWebCapturing {
  private let dataStore: WKWebsiteDataStore
  private let userAgent: String
  private let now: @Sendable () -> Date

  public init(
    dataStore: WKWebsiteDataStore,
    userAgent: String,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.dataStore = dataStore
    self.userAgent = userAgent
    self.now = now
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    try DouyinWebCapturePolicy.validateNavigationURL(url)
    let session = DouyinWKWebViewCaptureSession(
      initialURL: url,
      dataStore: dataStore,
      userAgent: userAgent,
      now: now
    )
    return try await withTaskCancellationHandler {
      try await session.run()
    } onCancel: {
      Task { @MainActor in session.cancel() }
    }
  }
}

@MainActor
private final class DouyinWKWebViewCaptureSession: NSObject, WKNavigationDelegate, WKUIDelegate {
  // The playback controller gives refresh 25 seconds. Finish this inner
  // capture first so it can report a precise no-playable-source result.
  private static let timeout: Duration = .seconds(20)
  private static let pollInterval: Duration = .milliseconds(250)

  /// Installed before page scripts. It observes only responses already loaded
  /// by the dedicated Douyin page and retains one bounded in-memory window
  /// around that page's exact aweme id. Nothing is logged or persisted.
  private static let currentAwemeResponseJavaScript = #"""
  (() => {
    if (window.__linkdigestResponseObserverInstalled) return;
    window.__linkdigestResponseObserverInstalled = true;
    window.__linkdigestCapturedAwemeState = '';

    const currentID = () => {
      try {
        const url = new URL(document.location.href);
        for (const key of ['modal_id', 'aweme_id', 'item_id', 'video_id', 'group_id']) {
          const value = url.searchParams.get(key);
          if (/^\d{8,25}$/.test(value || '')) return value;
        }
        const match = url.pathname.match(/\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$)/);
        return match && match[1] ? match[1] : '';
      } catch (_) { return ''; }
    };
    const retainCurrent = (raw) => {
      try {
        const value = String(raw || '');
        const id = currentID();
        if (!id || value.length > 8000000) return;
        const hit = value.indexOf(id);
        if (hit < 0) return;
        const lower = Math.max(0, hit - 119000);
        const upper = Math.min(value.length, hit + id.length + 119000);
        const snippet = value.slice(lower, upper);
        if (/play_addr|playAddr|playApi|url_list|urlList/.test(snippet)) {
          window.__linkdigestCapturedAwemeState = snippet;
        }
      } catch (_) {}
    };

    const originalFetch = window.fetch;
    if (typeof originalFetch === 'function') {
      window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const type = String(response.headers.get('content-type') || '').toLowerCase();
          const length = Number(response.headers.get('content-length') || 0);
          if ((type.includes('json') || type.includes('text')) && (!length || length <= 8000000)) {
            response.clone().text().then(retainCurrent).catch(() => {});
          }
        } catch (_) {}
        return response;
      };
    }

    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(...args) {
      this.__linkdigestObservedRequest = true;
      return originalOpen.apply(this, args);
    };
    XMLHttpRequest.prototype.send = function(...args) {
      if (this.__linkdigestObservedRequest) {
        this.addEventListener('load', function() {
          try {
            if (!this.responseType || this.responseType === 'text') {
              retainCurrent(this.responseText);
            }
          } catch (_) {}
        }, { once: true });
      }
      return originalSend.apply(this, args);
    };
  })();
  """#

  /// This intentionally does not walk `document.body` for capture text.
  /// Body text is consulted only for a bounded verification marker and the
  /// dedicated page's `发布时间` label.
  private static let extractionJavaScript = #"""
  (() => {
    const normalize = (value) => String(value || '')
      .replace(/\u00a0/g, ' ')
      .replace(/[ \t\r\n]+/g, ' ')
      .trim();
    const href = String(document.location.href || '');
    let awemeID = '';
    try {
      const url = new URL(href);
      for (const key of ['modal_id', 'aweme_id', 'item_id', 'video_id', 'group_id']) {
        const value = url.searchParams.get(key);
        if (/^\d{8,25}$/.test(value || '')) { awemeID = value; break; }
      }
      if (!awemeID) {
        const match = url.pathname.match(/\/(?:video|note|share\/video)\/(\d{8,25})(?:\/|$)/);
        awemeID = match && match[1] ? match[1] : '';
      }
    } catch (_) {}
    if (!awemeID) return { status: 'loading' };

    const bodyText = normalize(document.body && document.body.innerText).slice(0, 20000);
    const titleNode = document.querySelector('h1');
    const ogTitle = document.querySelector("meta[property='og:title']");
    const cleanTitle = (value) => normalize(value)
      .replace(/\s*[-_|｜]\s*抖音\s*$/u, '')
      .replace(/\s+-\s+抖音.*$/u, '')
      .trim();
    const title = cleanTitle(
      (titleNode && titleNode.textContent)
      || (ogTitle && ogTitle.getAttribute('content'))
      || document.title
    );

    const verification = /请完成安全验证|滑动验证|异常访问|验证码|登录后继续/.test(bodyText);
    if (!title || title === '抖音') {
      return { status: verification ? 'verification' : 'loading' };
    }

    const descriptionNode = document.querySelector(
      "[data-e2e='video-desc'],[data-e2e='browse-video-desc'],[data-e2e='video-desc-content'],[class*='video-info-detail']"
    );
    const ogDescription = document.querySelector("meta[property='og:description']");
    const description = normalize(
      (descriptionNode && descriptionNode.textContent)
      || (ogDescription && ogDescription.getAttribute('content'))
      || ''
    ).replace(/(?:…|\.{3})?\s*展开$/u, '').trim();

    const cleanAuthor = (value) => normalize(value)
      .replace(/(?:官方|企业|个人|机构)?认证(?:徽章|信息|标识)?/gu, '')
      .replace(/(?:粉丝|获赞|关注|作品|喜欢|朋友)\s*[\d.,]*\s*[万千亿]?\s*$/u, '')
      .trim();
    let author = '';
    for (const selector of [
      "[data-e2e='feed-video-nickname']",
      "[data-e2e='video-author-info-nickname']",
      "[data-e2e='user-info']"
    ]) {
      const node = document.querySelector(selector);
      author = cleanAuthor(node && node.textContent);
      if (author) break;
    }
    if (!author) {
      const userLinks = Array.from(document.querySelectorAll("a[href*='/user/']"));
      const link = userLinks.find((candidate) => {
        const raw = String(candidate.getAttribute('href') || '');
        const text = cleanAuthor(candidate.textContent);
        return text && !/\/user\/self(?:[/?#]|$)/.test(raw);
      });
      author = cleanAuthor(link && link.textContent);
    }

    let publishedAt = '';
    const publishedNode = document.querySelector(
      "[data-e2e*='publish'],[data-e2e*='create-time'],[class*='publish-time'],[class*='create-time'],time[datetime]"
    );
    if (publishedNode) {
      publishedAt = normalize(
        publishedNode.getAttribute('datetime') || publishedNode.textContent
      );
    }
    if (!publishedAt) {
      const match = bodyText.match(/发布时间[:：]\s*([0-9]{4}[-/.年][^\s]{1,20}(?:\s+[0-9]{1,2}:[0-9]{2})?)/u);
      publishedAt = normalize(match && match[1]);
    }

    const viewWidth = window.innerWidth || 0;
    const viewHeight = window.innerHeight || 0;
    const videos = Array.from(document.querySelectorAll('video')).slice(0, 100);
    let selectedVideo = null;
    let bestArea = -1;
    for (const video of videos) {
      const rect = video.getBoundingClientRect();
      const width = Math.max(0, Math.min(rect.right, viewWidth) - Math.max(rect.left, 0));
      const height = Math.max(0, Math.min(rect.bottom, viewHeight) - Math.max(rect.top, 0));
      const area = width * height;
      if (area > bestArea) { bestArea = area; selectedVideo = video; }
    }
    let videoURL = '';
    let coverURL = '';
    let durationSeconds = null;
    if (selectedVideo) {
      // Initializing the dedicated player muted lets WebKit request its source
      // without ever producing hidden audio.
      try {
        selectedVideo.muted = true;
        selectedVideo.defaultMuted = true;
        selectedVideo.volume = 0;
        selectedVideo.setAttribute('muted', '');
        const playback = selectedVideo.play();
        if (playback && typeof playback.catch === 'function') playback.catch(() => {});
      } catch (_) {}
      const sourceNode = selectedVideo.querySelector('source');
      const source = normalize(
        selectedVideo.currentSrc
        || selectedVideo.src
        || selectedVideo.getAttribute('src')
        || (sourceNode && sourceNode.getAttribute('src'))
      );
      try {
        const parsed = new URL(source, href);
        if (parsed.protocol === 'https:') videoURL = parsed.href;
      } catch (_) {}
      try {
        const parsedCover = new URL(normalize(selectedVideo.poster), href);
        if (parsedCover.protocol === 'https:') coverURL = parsedCover.href;
      } catch (_) {}
      const duration = Number(selectedVideo.duration);
      if (Number.isFinite(duration) && duration > 0) durationSeconds = duration;
    }

    // The visible player sometimes switches to blob/MSE. The current aweme's
    // rendered state still contains its signed HTTPS source, so return only a
    // bounded window around this exact id for Swift-side validation.
    let stateSnippet = '';
    const boundedSnippet = (raw) => {
      const value = String(raw || '');
      const hit = value.indexOf(awemeID);
      if (hit < 0) return '';
      const lower = Math.max(0, hit - 119000);
      const upper = Math.min(value.length, hit + awemeID.length + 119000);
      const snippet = value.slice(lower, upper);
      return /play_addr|playAddr|playApi|url_list|urlList/.test(snippet) ? snippet : '';
    };
    for (const candidate of [
      window.__linkdigestCapturedAwemeState,
      window._ROUTER_DATA,
      window._SSR_HYDRATED_DATA,
      window.__INITIAL_STATE__,
      window.__NEXT_DATA__,
      window.__SSR_DATA__
    ]) {
      if (!candidate || stateSnippet) continue;
      try { stateSnippet = boundedSnippet(JSON.stringify(candidate)); } catch (_) {}
    }
    if (!stateSnippet) {
      for (const script of Array.from(document.scripts).slice(0, 200)) {
        stateSnippet = boundedSnippet(script.textContent);
        if (stateSnippet) break;
      }
    }

    return {
      status: 'ready',
      awemeID,
      canonicalURL: `https://www.douyin.com/video/${awemeID}`,
      title,
      description,
      author,
      publishedAt,
      videoURL,
      coverURL,
      stateSnippet,
      ...(durationSeconds ? { durationSeconds } : {}),
      videoElementCount: videos.length
    };
  })()
  """#

  private let initialURL: URL
  private let now: @Sendable () -> Date
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<CapturedDocument, Error>?
  private var timeoutTask: Task<Void, Never>?
  private var pollingTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var latestReadyPage: DouyinRenderedPage?
  private var isFinished = false

  init(
    initialURL: URL,
    dataStore: WKWebsiteDataStore,
    userAgent: String,
    now: @escaping @Sendable () -> Date
  ) {
    self.initialURL = initialURL
    self.now = now
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.currentAwemeResponseJavaScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    let view = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
      configuration: configuration
    )
    view.customUserAgent = userAgent
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
        self.finishAtDeadline()
      }
      var request = URLRequest(
        url: initialURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
      )
      request.httpShouldHandleCookies = true
      webView.load(request)
    }
  }

  func cancel() {
    finish(.failure(ManualLinkError.cancelled))
  }

  private func beginPolling(generation token: UInt64) {
    guard pollingTask == nil, !isFinished else { return }
    pollingTask = Task { @MainActor [weak self] in
      await self?.poll(generation: token)
    }
  }

  private func poll(generation token: UInt64) async {
    do {
      let captured = try await DouyinCaptureWait.waitForPlayableMedia(
        pollInterval: Self.pollInterval,
        isCancelled: { [weak self] in
          guard let self else { return true }
          return Task.isCancelled || self.isFinished || token != self.generation
        },
        sleep: { try await Task.sleep(for: $0) },
        poll: { [weak self] in
          guard let self else { return .notReady }
          return try await self.pollOnce()
        }
      )
      guard let captured, token == generation, !isFinished else { return }
      finish(.success(try makeDocument(from: captured)))
    } catch let error as ManualLinkError {
      guard token == generation, !isFinished else { return }
      finish(.failure(error))
    } catch is CancellationError {
      return
    } catch {
      guard token == generation, !isFinished else { return }
      finish(.failure(ManualLinkError.invalidPageResult))
    }
  }

  /// 单次读取渲染页。返回 `.ready` 时同步记下 `latestReadyPage`，
  /// 供截止时间到达后保留标题与作者。
  private func pollOnce() async throws -> DouyinCaptureWait.PollOutcome {
    guard let webView, let currentURL = webView.url else {
      throw ManualLinkError.invalidPageResult
    }
    try DouyinWebCapturePolicy.validateNavigationURL(currentURL)
    guard let raw = try await webView.evaluateJavaScript(Self.extractionJavaScript),
          let dictionary = raw as? [String: Any],
          let status = dictionary["status"] as? String
    else { throw ManualLinkError.invalidPageResult }

    if status == "verification" {
      throw ManualLinkError.verificationRequired
    }
    guard status == "ready" else { return .notReady }

    var page = try DouyinWebCapturePolicy.validateJavaScriptResult(dictionary)
    if page.videoURL == nil,
       let stateSnippet = dictionary["stateSnippet"] as? String,
       let parsed = DouyinPageParser.parseStateSnippet(
         stateSnippet,
         pageURL: page.canonicalURL
       ) {
      page = DouyinRenderedPage(
        awemeID: page.awemeID,
        canonicalURL: page.canonicalURL,
        title: page.title,
        description: page.description,
        author: page.author,
        publishedAt: page.publishedAt,
        videoURL: parsed.videoURL,
        coverURL: page.coverURL ?? parsed.coverURL,
        durationSeconds: page.durationSeconds ?? parsed.durationSeconds
      )
    }
    latestReadyPage = page
    return .ready(page)
  }

  private func finishAtDeadline() {
    guard !isFinished else { return }
    guard let page = latestReadyPage else {
      finish(.failure(ManualLinkError.extensionCaptureRequired))
      return
    }
    do {
      // Manual capture still keeps the useful title/author after the bounded
      // wait. Playback refresh checks `media` and reports no playable source.
      finish(.success(try makeDocument(from: page)))
    } catch let error as ManualLinkError {
      finish(.failure(error))
    } catch {
      finish(.failure(ManualLinkError.invalidPageResult))
    }
  }

  private func makeDocument(from page: DouyinRenderedPage) throws -> CapturedDocument {
    func yaml(_ value: String) -> String {
      "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ") + "\""
    }
    var metadata = ["aweme_id: \(yaml(page.awemeID))"]
    if let author = page.author { metadata.insert("author: \(yaml(author))", at: 0) }
    if let published = page.publishedAt { metadata.append("published: \(yaml(published))") }
    var body = "# \(page.title)"
    if let description = page.description,
       description.caseInsensitiveCompare(page.title) != .orderedSame {
      body += "\n\n\(description)"
    }
    let text = "---\n\(metadata.joined(separator: "\n"))\n---\n\n\(body)"
    let timestamp = ISO8601DateFormatter().string(from: now())
    let media = page.videoURL.map {
      CaptureMedia(
        platform: "douyin",
        videoURL: $0.absoluteString,
        coverURL: page.coverURL?.absoluteString,
        durationSeconds: page.durationSeconds,
        author: page.author
      )
    }
    let document = CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual-douyin-rendered:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: page.canonicalURL.absoluteString,
      title: page.title,
      platform: "douyin",
      method: "douyin_rendered_webkit",
      text: text,
      completeness: "best_effort",
      capturedAt: timestamp,
      sourceLabel: "手动链接（抖音渲染页面）",
      media: media
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
    return document
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
    generation &+= 1
    latestReadyPage = nil
    pollingTask?.cancel()
    pollingTask = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isFinished else { return }
    beginPolling(generation: generation)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    finish(.failure(ManualLinkError.network))
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    finish(.failure(ManualLinkError.network))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
    switch DouyinWebCapturePolicy.navigationDecision(
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
    switch DouyinWebCapturePolicy.navigationDecision(
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
    completionHandler: @escaping @MainActor @Sendable (
      URLSession.AuthChallengeDisposition,
      URLCredential?
    ) -> Void
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
