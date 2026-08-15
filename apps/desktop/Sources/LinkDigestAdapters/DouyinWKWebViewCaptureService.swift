import Foundation
import LinkDigestCore
import WebKit

/// Rendered fallback for a manually submitted Douyin URL.
///
/// 公开 HTML 先走适配器。图文桌面页往往只是空 SPA，这里用设置里同一份
/// 抖音登录分区去渲染当前作品，再只读这一条的标题、正文和正片图。
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
  // Video fallback stays under the playback-refresh budget. Note share
  // pages need longer for the mobile SPA to hydrate gallery images.
  private static let videoTimeout: Duration = .seconds(20)
  private static let noteTimeout: Duration = .seconds(35)
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
        const match = url.pathname.match(/\/(?:video|note|share\/video|share\/note)\/(\d{8,25})(?:\/|$)/);
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
        if (/play_addr|playAddr|playApi|url_list|urlList|aweme_images|image_post|tplv-dy-aweme-images/.test(snippet)) {
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
        const match = url.pathname.match(/\/(?:video|note|share\/video|share\/note)\/(\d{8,25})(?:\/|$)/);
        awemeID = match && match[1] ? match[1] : '';
      }
    } catch (_) {}
    if (!awemeID) return { status: 'loading' };
    let pathLooksLikeNote = false;
    try { pathLooksLikeNote = /\/(?:share\/)?note\//.test(new URL(href).pathname); } catch (_) {}

    // Canonical note pages moved their caption out of the legacy video-desc
    // nodes. The classes are hashed, but the exact /note/{id} route plus the
    // caption row immediately before “发布时间” gives us an identity-locked
    // structure. Keep the scan bounded because this panel also owns a related
    // feed below the current item.
    let dedicatedNoteMetadata = null;
    try {
      const url = new URL(href);
      const host = url.hostname.toLowerCase();
      const itemValues = ['modal_id', 'aweme_id', 'item_id', 'video_id', 'group_id']
        .flatMap((key) => url.searchParams.getAll(key));
      const exactRoute = (host === 'douyin.com' || host.endsWith('.douyin.com'))
        && url.pathname === `/note/${awemeID}`
        && itemValues.every((value) => value === awemeID);
      const detail = exactRoute && document.querySelector("[data-e2e='note-detail']");
      const timeCandidates = detail && detail.querySelectorAll('span,time');
      if (timeCandidates && timeCandidates.length <= 1000) {
        for (const node of timeCandidates) {
          const publishedText = normalize(node.textContent);
          if (!/^发布时间[:：]\s*\d/u.test(publishedText)) continue;
          const captionNode = node.parentElement && node.parentElement.previousElementSibling;
          const caption = normalize(captionNode && captionNode.textContent)
            .replace(/(?:…|\.{3})?\s*展开\s*$/u, '')
            .trim();
          if (caption.length < 2 || caption.length > 5000 || /发布时间[:：]/u.test(caption)) continue;
          const authorBlock = node.parentElement
            && node.parentElement.parentElement
            && node.parentElement.parentElement.parentElement
            && node.parentElement.parentElement.parentElement.previousElementSibling;
          const authorLinks = authorBlock ? authorBlock.querySelectorAll("a[href*='/user/']") : [];
          let noteAuthor = '';
          if (authorLinks.length <= 20) {
            for (const link of authorLinks) {
              const candidate = normalize(link.textContent);
              if (candidate) { noteAuthor = candidate; break; }
            }
          }
          dedicatedNoteMetadata = {
            caption,
            author: noteAuthor,
            publishedAt: publishedText.replace(/^发布时间[:：]\s*/u, '').trim()
          };
          break;
        }
      }
    } catch (_) {}

    const bodyText = normalize(document.body && document.body.innerText).slice(0, 20000);
    const titleNode = document.querySelector('h1');
    const ogTitle = document.querySelector("meta[property='og:title']");
    const cleanTitle = (value) => normalize(value)
      .replace(/\s*[-_|｜]\s*抖音\s*$/u, '')
      .replace(/\s+-\s+抖音.*$/u, '')
      .trim();
    const stripTrailingHashtags = (value) => {
      const stripped = normalize(value)
        .replace(/\s+#\s*$/u, '')
        .replace(/(?<![0-9A-Za-z])(?:\s*#[^\s#]+)+\s*$/u, '')
        .trim();
      return stripped || normalize(value);
    };
    const title = stripTrailingHashtags(cleanTitle(
      (dedicatedNoteMetadata && dedicatedNoteMetadata.caption)
      || (titleNode && titleNode.textContent)
      || (ogTitle && ogTitle.getAttribute('content'))
      || document.title
    ));

    const verification = /请完成安全验证|滑动验证|异常访问|验证码|登录后继续/.test(bodyText);
    const placeholderTitle = !title || title === '抖音';
    if (placeholderTitle && !pathLooksLikeNote) {
      return { status: verification ? 'verification' : 'loading' };
    }

    const descriptionNode = document.querySelector(
      "[data-e2e='video-desc'],[data-e2e='browse-video-desc'],[data-e2e='video-desc-content'],[class*='video-info-detail']"
    );
    const ogDescription = document.querySelector("meta[property='og:description']");
    const description = normalize(
      (dedicatedNoteMetadata && dedicatedNoteMetadata.caption)
      || (descriptionNode && descriptionNode.textContent)
      || (ogDescription && ogDescription.getAttribute('content'))
      || ''
    ).replace(/(?:…|\.{3})?\s*展开$/u, '').trim();

    const cleanAuthor = (raw) => {
      let value = normalize(raw)
        .replace(/(?:官方|企业|个人|机构)?认证(?:徽章|信息|标识)?/gu, '')
        .replace(/已认证/gu, '')
        .trim();
      const carriesProfileCounters = /(?:粉丝|获赞)\s*[\d.,]+\s*[万千亿]?/u.test(value);
      if (carriesProfileCounters) {
        value = value.replace(/(?:已(?:关注)?|关注)\s*$/u, '').trim();
      }
      let previous = '';
      while (value && value !== previous) {
        previous = value;
        value = value
          .replace(/(?:粉丝|获赞|关注|作品|喜欢|朋友)\s*[\d.,]*\s*[万千亿]?\s*$/u, '')
          .trim();
      }
      return value;
    };
    let author = cleanAuthor(dedicatedNoteMetadata && dedicatedNoteMetadata.author);
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

    let publishedAt = normalize(dedicatedNoteMetadata && dedicatedNoteMetadata.publishedAt);
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
      return /play_addr|playAddr|playApi|url_list|urlList|aweme_images|image_post|tplv-dy-aweme-images/.test(snippet) ? snippet : '';
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

    const imageURLs = [];
    const galleryURL = (raw) => {
      const trimmed = String(raw || '').trim();
      if (!trimmed || trimmed.length > 2048) return '';
      try {
        const parsed = new URL(trimmed, href);
        if (parsed.protocol !== 'https:') return '';
        const host = parsed.hostname.toLowerCase();
        if (host !== 'douyinpic.com' && !host.endsWith('.douyinpic.com')) return '';
        const isGalleryImage = parsed.searchParams.get('biz_tag') === 'aweme_images'
          || /tplv-dy-aweme-images/.test(parsed.pathname);
        return isGalleryImage ? parsed.href : '';
      } catch (_) {
        return '';
      }
    };
    const maximumGallery = 35;
    const add = (raw) => {
      if (imageURLs.length >= maximumGallery) return;
      const url = galleryURL(raw);
      if (url && !imageURLs.includes(url)) imageURLs.push(url);
    };
    const nodes = document.querySelectorAll('img');
    if (nodes.length <= 1000) {
      for (const node of nodes) {
        if (imageURLs.length >= maximumGallery) break;
        add(node.getAttribute('src'));
        add(node.getAttribute('data-src'));
        add(node.getAttribute('data-original'));
        add(node.currentSrc);
        const srcset = node.getAttribute('srcset') || node.getAttribute('data-srcset');
        if (srcset) add(srcset.split(',')[0] && srcset.split(',')[0].trim().split(/\s+/)[0]);
      }
    }
    const styled = document.querySelectorAll('[style*="douyinpic.com"]');
    if (styled.length <= 200) {
      for (const node of styled) {
        if (imageURLs.length >= maximumGallery) break;
        const background = String(node.getAttribute('style') || '');
        const match = background.match(/url\((['"]?)(https:[^'")]+)\1\)/);
        if (match) add(match[2]);
      }
    }
    if (placeholderTitle && imageURLs.length === 0) {
      return { status: verification ? 'verification' : 'loading' };
    }
    const resolvedTitle = placeholderTitle ? (imageURLs.length > 0 ? '抖音图文' : title) : title;
    const isImagePost = imageURLs.length > 0;
    const canonicalKind = (pathLooksLikeNote || isImagePost) ? 'note' : 'video';

    return {
      status: 'ready',
      awemeID,
      canonicalURL: `https://www.douyin.com/${canonicalKind}/${awemeID}`,
      title: resolvedTitle,
      description,
      author,
      publishedAt,
      videoURL: isImagePost ? '' : videoURL,
      coverURL,
      imageURLs,
      stateSnippet: isImagePost ? '' : stateSnippet,
      ...(durationSeconds && !isImagePost ? { durationSeconds } : {}),
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
    // 图文和视频共用设置里的抖音登录分区。隔离成 nonPersistent 等于把已登录
    // 会话丢掉，桌面 `/note/` 只会剩下空 SPA，最后被误报成「请用扩展」。
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
        try? await Task.sleep(for: self?.captureTimeout ?? Self.noteTimeout)
        guard let self, !Task.isCancelled else { return }
        self.finishAtDeadline()
      }
      var request = URLRequest(
        url: DouyinURL.renderedCaptureURL(from: initialURL),
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
      )
      request.httpShouldHandleCookies = true
      webView.load(request)
    }
  }

  private var captureTimeout: Duration {
    if DouyinURL.awemeID(from: initialURL) != nil, !DouyinURL.isNotePath(initialURL) {
      return Self.videoTimeout
    }
    return Self.noteTimeout
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
    if DouyinWebCapturePolicy.isSessionNavigationURL(currentURL) {
      return .notReady
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
    if page.imageURLs.isEmpty,
       let stateSnippet = dictionary["stateSnippet"] as? String,
       !stateSnippet.isEmpty {
      let gallery = DouyinPageParser.parseGalleryImageURLs(
        stateSnippet,
        pageURL: page.canonicalURL
      )
      if !gallery.isEmpty {
        page = DouyinRenderedPage(
          awemeID: page.awemeID,
          canonicalURL: page.canonicalURL,
          title: page.title,
          description: page.description,
          author: page.author,
          publishedAt: page.publishedAt,
          videoURL: nil,
          coverURL: page.coverURL,
          durationSeconds: nil,
          imageURLs: gallery
        )
      } else if page.videoURL == nil,
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
          durationSeconds: page.durationSeconds ?? parsed.durationSeconds,
          imageURLs: page.imageURLs
        )
      }
    }
    latestReadyPage = page
    // `/note/` 在首轮渲染时可能先挂一个用于轮播控制的 video 元素，正片图稍后才
    // 进入 DOM。不能因为这个占位播放器已有 URL 就提前把图文当视频保存，否则
    // 移动端分享短链会只留下配文、丢掉全部图片。继续轮询到图集出现；截止时仍无图
    // 则沿用下面的明确降级，不写入半成品。
    if DouyinURL.isNotePath(page.canonicalURL), page.imageURLs.isEmpty {
      return .notReady
    }
    return .ready(page)
  }

  private func finishAtDeadline() {
    guard !isFinished else { return }
    guard let page = latestReadyPage else {
      finish(.failure(ManualLinkError.extensionCaptureRequired))
      return
    }
    do {
      // 图文帖如果截止时还没有正片图，不要把「只有标题」的壳存进去。
      // 视频帖仍保留标题作者，播放刷新会说明没有可播源。
      if DouyinURL.isNotePath(page.canonicalURL), page.imageURLs.isEmpty {
        finish(.failure(ManualLinkError.extensionCaptureRequired))
        return
      }
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
    let isImagePost = !page.imageURLs.isEmpty
    var metadata = ["aweme_id: \(yaml(page.awemeID))"]
    if let author = page.author { metadata.insert("author: \(yaml(author))", at: 0) }
    if let published = page.publishedAt { metadata.append("published: \(yaml(published))") }
    if isImagePost { metadata.append("content_kind: images") }
    var body = "# \(page.title)"
    if let description = page.description,
       description.caseInsensitiveCompare(page.title) != .orderedSame {
      let suffix: String? = description.hasPrefix(page.title)
        ? String(description.dropFirst(page.title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
      let suffixIsOnlyTopics = suffix.map { value in
        let parts = value.split(whereSeparator: \.isWhitespace)
        return !parts.isEmpty && parts.allSatisfy { $0.hasPrefix("#") && $0.count > 1 }
      } ?? false
      body += "\n\n\(suffixIsOnlyTopics ? suffix! : description)"
    }
    if isImagePost {
      let gallery = page.imageURLs
        .map { "![](\($0.absoluteString))" }
        .joined(separator: "\n\n")
      if !gallery.isEmpty {
        body += "\n\n\(gallery)"
      }
    }
    let text = "---\n\(metadata.joined(separator: "\n"))\n---\n\n\(body)"
    let timestamp = ISO8601DateFormatter().string(from: now())
    let media = (!isImagePost ? page.videoURL : nil).map {
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
      sourceLabel: isImagePost ? "手动链接（抖音图文）" : "手动链接（抖音渲染页面）",
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
      finish(.failure(ManualLinkError.extensionCaptureRequired))
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
      finish(.failure(ManualLinkError.extensionCaptureRequired))
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
