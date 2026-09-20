import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore
import SwiftUI
import WebKit

enum DouyinProfileInputRoute: Equatable {
  case profile(sourceURL: URL, authorID: String)
  case shortLink(sourceURL: URL)

  static func parse(_ rawValue: String) -> DouyinProfileInputRoute? {
    guard let url = ExplicitWebLinkInput.singleURL(from: rawValue),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return nil }

    if host == "v.douyin.com" || host.hasSuffix(".v.douyin.com") {
      return .shortLink(sourceURL: url)
    }
    guard host == "douyin.com" || host.hasSuffix(".douyin.com"),
          let authorID = authorID(from: url)
    else { return nil }
    return .profile(sourceURL: normalizedProfileURL(authorID: authorID), authorID: authorID)
  }

  static func authorID(from url: URL) -> String? {
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count >= 2,
          components[0].lowercased() == "user"
    else { return nil }
    let authorID = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !authorID.isEmpty else { return nil }
    return authorID
  }

  private static func normalizedProfileURL(authorID: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.douyin.com"
    components.path = "/user/\(authorID)"
    return components.url!
  }

  var sourceURL: URL {
    switch self {
    case let .profile(sourceURL, _), let .shortLink(sourceURL): sourceURL
    }
  }
}

enum DouyinProfileWorkURL {
  static func canonical(_ url: URL) -> String? {
    guard DouyinProfileNavigationPolicy.allows(url),
          let host = url.host?.lowercased(),
          host == "douyin.com" || host.hasSuffix(".douyin.com")
    else { return nil }
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count >= 2 else { return nil }
    let kind = components[0].lowercased()
    let workID = components[1]
    guard (kind == "video" || kind == "note"),
          workID.count >= 10,
          workID.allSatisfy(\.isNumber)
    else { return nil }
    return "https://www.douyin.com/\(kind)/\(workID)"
  }

  static func workID(from canonicalURL: String) -> String? {
    URL(string: canonicalURL)?.pathComponents.last
  }
}

enum DouyinProfileNavigationPolicy {
  static func allows(_ url: URL?) -> Bool {
    guard let url,
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          SiteSessionProfile.douyin.isAllowedHost(url.host)
    else { return false }
    return true
  }
}

enum DouyinProfilePreviewResource {
  static let byteLimit = 2_000_000
  private static let resources: any SafeResourceFetching = ProxyAwareWebPageFetcher()

  static func admittedURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          ["douyinpic.com", "byteimg.com", "pstatp.com", "douyinstatic.com", "douyin.com", "iesdouyin.com"]
            .contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    else { return nil }
    do { try PublicWebURLPolicy(resolver: { _ in [] }).validateSyntax(url) }
    catch { return nil }
    return url
  }

  static func fetch(_ url: URL, using resources: any SafeResourceFetching = resources) async throws -> Data {
    guard admittedURL(url.absoluteString) != nil else { throw ManualLinkError.unsafeURL }
    // The existing transport validates DNS, the connected peer and every redirect.
    // Keep the same image-host boundary on redirects as on the initial DOM URL.
    let response = try await resources.fetchResource(.init(
      url: url,
      headers: ["Accept": "image/*", "Referer": "https://www.douyin.com/"],
      byteLimit: byteLimit,
      allowsRedirectTarget: { admittedURL($0.absoluteString) != nil }
    ))
    guard admittedURL(response.url.absoluteString) != nil else { throw ManualLinkError.unsafeURL }
    guard (200...299).contains(response.statusCode) else { throw ManualLinkError.responseStatus }
    guard response.contentType?.lowercased().hasPrefix("image/") == true else {
      throw ManualLinkError.unsupportedContentType
    }
    guard response.body.count <= byteLimit else { throw ManualLinkError.responseTooLarge }
    return response.body
  }
}

struct DouyinProfilePreviewImage: View {
  @Environment(\.appTheme) private var theme
  let url: URL?
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image { Image(nsImage: image).resizable().scaledToFill() }
      else { Rectangle().fill(theme.badge) }
    }
    .task(id: url) {
      image = nil
      guard let url, let data = try? await DouyinProfilePreviewResource.fetch(url),
            !Task.isCancelled else { return }
      image = NSImage(data: data)
    }
  }
}

struct DouyinProfileDOMCandidate: Codable, Equatable {
  let url: String
  let authorID: String
  let previewText: String?
  let coverURL: String?
  let publishedText: String?
  var likes: String? = nil
  var comments: String? = nil
  var collects: String? = nil
}

struct DouyinProfileDOMSnapshot: Codable, Equatable {
  let status: String
  let profileAuthorID: String?
  let profileName: String?
  let profileAvatarURL: String?
  let activeTab: String?
  let candidates: [DouyinProfileDOMCandidate]

  init(
    status: String,
    profileAuthorID: String?,
    profileName: String?,
    profileAvatarURL: String? = nil,
    activeTab: String?,
    candidates: [DouyinProfileDOMCandidate]
  ) {
    self.status = status
    self.profileAuthorID = profileAuthorID
    self.profileName = profileName
    self.profileAvatarURL = profileAvatarURL
    self.activeTab = activeTab
    self.candidates = candidates
  }
}

struct DouyinProfileImportCandidate: Identifiable, Equatable {
  let workID: String
  let authorID: String
  let canonicalURL: String
  let previewText: String?
  let coverURL: URL?
  let publishedText: String?
  let wasAlreadySaved: Bool
  var likes: String? = nil
  var comments: String? = nil
  var collects: String? = nil

  var id: String { workID }
}

/// One attempt per visible work per sheet; explicit retry is the only repeat path.
struct DouyinProfileVisibleMetricsQueue {
  private(set) var visibleIDs: Set<String> = []
  private(set) var attemptedIDs: Set<String> = []
  private(set) var activeID: String?
  private(set) var isStopped = false

  mutating func setVisible(_ id: String, _ visible: Bool) {
    guard !isStopped else { return }
    if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
  }

  mutating func next(in orderedIDs: [String]) -> String? {
    guard !isStopped, activeID == nil,
          let id = orderedIDs.first(where: { visibleIDs.contains($0) && !attemptedIDs.contains($0) }) else { return nil }
    attemptedIDs.insert(id)
    activeID = id
    return id
  }

  mutating func finish(_ id: String) {
    guard activeID == id else { return }
    activeID = nil
  }

  mutating func retry(_ id: String) {
    guard !isStopped, activeID != id, visibleIDs.contains(id) else { return }
    attemptedIDs.remove(id)
  }

  mutating func clearVisible() { visibleIDs.removeAll() }

  mutating func stop() {
    isStopped = true
    visibleIDs.removeAll()
    activeID = nil
  }
}

struct DouyinProfileWorkMetrics: Codable, Equatable {
  let status: String
  let workID: String?
  let likes: String?
  let comments: String?
  let collects: String?
}

/// Reads one requested public work at a time without disturbing the profile grid.
@MainActor
final class DouyinProfileMetricsReader: NSObject, ObservableObject, WKNavigationDelegate {
  @Published private(set) var readingID: String?
  @Published private(set) var messages: [String: String] = [:]
  private var task: Task<Void, Never>?
  private var webView: WKWebView?
  private var generation = 0

  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    if let readingID { messages[readingID] = "读取已取消，可重试" }
    readingID = nil
  }

  func read(_ candidate: DouyinProfileImportCandidate, dataStore: WKWebsiteDataStore,
            load: (WKWebView, URL) -> Void = { view, url in
              view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            }, receive: @escaping (DouyinProfileWorkMetrics) -> Void) {
    guard readingID == nil, let url = URL(string: candidate.canonicalURL),
          let canonical = DouyinProfileWorkURL.canonical(url),
          DouyinProfileWorkURL.workID(from: canonical) == candidate.workID else { return }
    generation += 1
    let request = generation
    let id = candidate.workID
    readingID = id
    messages[id] = nil
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = self
    webView = view
    load(view, url)
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var result: DouyinProfileWorkMetrics?
      var message = "暂未读取到数据，可重试"
      for _ in 0..<20 {
        do {
          try await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, request == self.generation else { return }
          guard let loadedURL = view.url, DouyinProfileWorkURL.canonical(loadedURL) == candidate.canonicalURL else { continue }
          let raw = try await view.evaluateJavaScript(Self.extractionJavaScript(workID: id))
          guard !Task.isCancelled, request == self.generation else { return }
          guard let json = raw as? String,
                let metrics = try? JSONDecoder().decode(DouyinProfileWorkMetrics.self, from: Data(json.utf8)) else { continue }
          switch metrics.status {
          case "ready":
            guard metrics.workID == id else { continue }
            result = metrics
            message = [metrics.likes, metrics.comments, metrics.collects].allSatisfy { $0 != nil }
              ? "数据已更新" : "已读取，部分数据未提供"
            if [metrics.likes, metrics.comments, metrics.collects].contains(where: { $0 == nil }) { continue }
          case "login": result = nil; message = "作品需要登录，请在“查看主页”登录后重试"
          case "verification": result = nil; message = "作品需要验证，请在“查看主页”完成后重试"
          case "wrong_work": result = nil; message = "页面作品不一致，未更新数据"
          default: continue
          }
          break
        } catch is CancellationError { return }
        catch { if Task.isCancelled || request != self.generation { return } }
      }
      guard !Task.isCancelled, request == self.generation else { return }
      if let result {
        if let finalURL = view.url, DouyinProfileWorkURL.canonical(finalURL) == candidate.canonicalURL { receive(result) }
        else { message = "页面作品不一致，未更新数据" }
      }
      self.messages[id] = message
      self.readingID = nil
      view.stopLoading()
      view.navigationDelegate = nil
      self.webView = nil
      self.task = nil
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    decisionHandler(DouyinProfileNavigationPolicy.allows(navigationAction.request.url) ? .allow : .cancel)
  }

  static func extractionJavaScript(workID: String) -> String {
    guard workID.count >= 10, workID.allSatisfy(\.isNumber) else { return "null" }
    return #"""
    (() => {
      const expectedID = "__WORK_ID__";
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = node => {
        for (let n = node; n; n = n.parentElement) {
          const style = getComputedStyle(n);
          if (n.hidden || n.getAttribute('aria-hidden') === 'true' || style.display === 'none'
              || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
        }
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const reply = (status, counts = {}) => JSON.stringify({status, workID:expectedID, likes:null, comments:null, collects:null, ...counts});
      const body = clean(document.body && document.body.innerText);
      if (/完成验证|安全验证|环境异常|人机验证/.test(body)
          || Array.from(document.querySelectorAll('[class*="captcha"], [id*="captcha"]')).some(visible)) return reply('verification');
      const path = location.pathname.match(/^\/(?:video|note)\/(\d{10,})/);
      if (!path || path[1] !== expectedID) return reply('wrong_work');
      const info = Array.from(document.querySelectorAll('[data-e2e="detail-video-info"][data-e2e-aweme-id]')).filter(visible);
      const players = Array.from(document.querySelectorAll('[data-e2e="player-container"]')).filter(visible);
      const player = players.find(n => n.classList.contains('video_' + expectedID));
      if (!info.some(n => n.getAttribute('data-e2e-aweme-id') === expectedID) || !player) {
        if (/登录后查看|登录即可查看|扫码登录/.test(body)) return reply('login');
        return reply(info.length ? 'wrong_work' : 'pending');
      }
      const selectors = ['[data-e2e="video-player-digg"]', '[data-e2e="feed-comment-icon"]', '[data-e2e="video-player-collect"]'];
      const number = value => /^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:万|亿|[kKmMwW])?\+?$/.test(value) ? value : null;
      const nodes = selectors.map(selector => {
        const matches = Array.from(player.querySelectorAll(selector));
        return matches.length === 1 ? matches[0] : null;
      });
      const semantic = nodes.map(node => node ? number(clean(node.textContent)) : null);
      const matchingInfo = info.find(n => n.getAttribute('data-e2e-aweme-id') === expectedID);
      const share = matchingInfo.querySelector('[data-e2e="video-share-icon-container"]');
      const toolbar = share?.parentElement;
      const cells = toolbar ? Array.from(toolbar.children) : [];
      // The current wide layout mirrors the three semantic controls in order immediately
      // before Share. Require the entire visible vector to match, never just a number's presence.
      const mirrors = cells.length === 4 && cells[3] === share ? cells.slice(0, 3).map(cell => {
        const spans = Array.from(cell.children).filter(node => node.tagName === 'SPAN' && visible(node));
        return spans.length === 1 ? number(clean(spans[0].innerText)) : null;
      }) : [];
      const mirrored = mirrors.length === 3 && semantic.every((value, index) => value !== null && value === mirrors[index]);
      const values = nodes.map((node, index) => node && (visible(node) || mirrored) ? semantic[index] : null);
      const counts = {likes:values[0], comments:values[1], collects:values[2]};
      return reply(Object.values(counts).some(value => value !== null) ? 'ready' : 'pending', counts);
    })()
    """#.replacingOccurrences(of: "__WORK_ID__", with: workID)
  }
}

enum DouyinProfileImportStopReason: Equatable {
  case user
  case perRoundBudget(Int)
  case visibleEnd
  case loginRequired
  case verificationRequired
  case worksTabRequired
  case platformChanged
  case navigationFailed

  var message: String {
    switch self {
    case .user:
      return "已暂停，可继续加载更多作品。"
    case let .perRoundBudget(count):
      return "本轮新增 \(count) 条，可继续加载。"
    case .visibleEnd:
      return "暂未发现更多作品，可继续加载。"
    case .loginRequired:
      return "请点击“查看主页”完成登录，再继续加载。"
    case .verificationRequired:
      return "请点击“查看主页”完成人机验证，再继续加载。"
    case .worksTabRequired:
      return "请点击“查看主页”，切换到“作品”后继续加载。"
    case .platformChanged:
      return "等待后仍未识别到主页作品列表，平台页面结构可能已变化。请重试或使用浏览器扩展保存单条作品。"
    case .navigationFailed:
      return "主页暂时无法打开，请检查链接或网络后重试。"
    }
  }
}

@MainActor
final class DouyinProfileImportViewModel: ObservableObject {
  enum Phase: Equatable {
    case input
    case loading
    case scanning
    case stopped(DouyinProfileImportStopReason)
    case failed(String)
  }

  enum ScanDirective: Equatable { case keepLoading, stop(DouyinProfileImportStopReason) }

  @Published var input = ""
  @Published private(set) var phase: Phase = .input
  @Published private(set) var candidates: [DouyinProfileImportCandidate] = []
  @Published private(set) var selectedIDs: Set<String> = []
  @Published private(set) var profileName: String?
  @Published private(set) var sourceURL: URL?
  @Published private(set) var navigationRequestID = 0
  @Published private(set) var scanRequestID = 0
  @Published var downloadsVideo = false
  @Published private(set) var saveMessage: String?

  private let alreadySaved: (String) -> Bool
  private let enqueue: ([String], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome
  private let ensureCreator: (String, String, String?) -> CreatorID?
  private let refreshCreatorName: (CreatorID, String?, String?) -> Void
  private let attachExisting: (CreatorID, [String]) -> Void
  private var profileAuthorID: String?
  private(set) var creatorID: CreatorID?
  private var consecutiveNoNewScreens = 0
  private var consecutiveMissingRoots = 0
  private var newItemsThisRound = 0

  static let perRoundBudget = 100
  static let noNewScreenLimit = 3
  static let missingRootLimit = 8

  init(
    alreadySaved: @escaping (String) -> Bool,
    enqueue: @escaping ([String], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome,
    ensureCreator: @escaping (String, String, String?) -> CreatorID? = { _, _, _ in nil },
    refreshCreatorName: @escaping (CreatorID, String?, String?) -> Void = { _, _, _ in },
    attachExisting: @escaping (CreatorID, [String]) -> Void = { _, _ in }
  ) {
    self.alreadySaved = alreadySaved
    self.enqueue = enqueue
    self.ensureCreator = ensureCreator
    self.refreshCreatorName = refreshCreatorName
    self.attachExisting = attachExisting
  }

  convenience init(manualLink: ManualLinkViewModel) {
    self.init(
      alreadySaved: { manualLink.containsProfileImportURL($0) },
      enqueue: { urls, downloads, creatorID in
        manualLink.enqueueProfileImport(canonicalURLs: urls, downloadsVideo: downloads, creatorID: creatorID)
      },
      ensureCreator: { authorID, profileURL, name in
        manualLink.ensureDouyinCreator(authorID: authorID, profileURL: profileURL, displayName: name)
      },
      refreshCreatorName: { id, name, avatar in
        manualLink.refreshDouyinCreator(creatorID: id, displayName: name, avatarURL: avatar)
      },
      attachExisting: { id, urls in
        manualLink.attachExistingCreatorWorks(creatorID: id, canonicalURLs: urls)
      }
    )
  }

  var validationMessage: String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, DouyinProfileInputRoute.parse(input) == nil else { return nil }
    return "请输入抖音博主主页分享文案、v.douyin.com 短链或完整 /user/ 主页链接。"
  }

  var canStart: Bool { DouyinProfileInputRoute.parse(input) != nil && phase != .loading }
  var isScanning: Bool { phase == .scanning }
  var selectedCount: Int { selectedIDs.count }
  var unsavedCandidateIDs: Set<String> {
    Set(candidates.lazy.filter { !$0.wasAlreadySaved }.map(\.id))
  }

  func start() {
    guard let route = DouyinProfileInputRoute.parse(input) else {
      phase = .failed("无法识别抖音博主主页链接。")
      return
    }
    candidates = []
    selectedIDs = []
    saveMessage = nil
    profileName = nil
    creatorID = nil
    profileAuthorID = {
      if case let .profile(_, authorID) = route { return authorID }
      return nil
    }()
    consecutiveNoNewScreens = 0
    consecutiveMissingRoots = 0
    newItemsThisRound = 0
    sourceURL = route.sourceURL
    bindCreatorIfNeeded()
    navigationRequestID += 1
    phase = .loading
  }

  private func bindCreatorIfNeeded() {
    guard creatorID == nil,
          let authorID = profileAuthorID,
          let sourceURL else { return }
    creatorID = ensureCreator(authorID, sourceURL.absoluteString, profileName)
  }

  func acceptNavigation(_ url: URL, navigationRequestID requestID: Int? = nil) {
    guard requestID == nil || requestID == navigationRequestID else { return }
    guard DouyinProfileNavigationPolicy.allows(url) else { return }
    switch phase {
    case .loading, .scanning, .stopped(.loginRequired), .stopped(.verificationRequired), .stopped(.worksTabRequired):
      break
    case .input, .stopped(_), .failed(_):
      return
    }
    guard let authorID = DouyinProfileInputRoute.authorID(from: url) else {
      if DouyinProfileWorkURL.canonical(url) != nil {
        phase = .failed("这是单条作品链接，请使用博主主页链接。")
      }
      return
    }
    if let profileAuthorID, profileAuthorID != authorID {
      phase = .failed("打开后的博主身份与输入主页不一致，已停止读取。")
      return
    }
    profileAuthorID = profileAuthorID ?? authorID
    if sourceURL == nil {
      sourceURL = DouyinProfileInputRoute.parse("https://www.douyin.com/user/\(authorID)")?.sourceURL
    }
    bindCreatorIfNeeded()
    beginScanRound()
  }

  func navigationStarted(navigationRequestID requestID: Int) {
    guard requestID == navigationRequestID else { return }
    if phase == .scanning {
      scanRequestID += 1
      phase = .loading
    }
  }

  func navigationFailed(navigationRequestID requestID: Int) {
    guard requestID == navigationRequestID else { return }
    switch phase {
    case .loading, .scanning,
         .stopped(.loginRequired), .stopped(.verificationRequired), .stopped(.worksTabRequired):
      phase = .stopped(.navigationFailed)
    case .input, .stopped(.user), .stopped(.perRoundBudget), .stopped(.visibleEnd),
         .stopped(.navigationFailed), .stopped(.platformChanged), .failed:
      return
    }
  }

  func scanFailed(scanRequestID requestID: Int) {
    guard requestID == scanRequestID, phase == .scanning else { return }
    phase = .stopped(.navigationFailed)
  }

  func stop() {
    guard isScanning || phase == .loading else { return }
    phase = .stopped(.user)
  }

  func continueLoading() {
    guard sourceURL != nil, profileAuthorID != nil else { return }
    beginScanRound()
  }

  private func beginScanRound() {
    consecutiveNoNewScreens = 0
    consecutiveMissingRoots = 0
    newItemsThisRound = 0
    phase = .scanning
    scanRequestID += 1
  }

  func merge(
    _ snapshot: DouyinProfileDOMSnapshot,
    scanRequestID requestID: Int? = nil
  ) -> ScanDirective {
    guard (requestID == nil || requestID == scanRequestID), phase == .scanning else {
      return .stop(.user)
    }
    switch snapshot.status {
    case "verification": return finish(.verificationRequired)
    case "login": return finish(.loginRequired)
    case "wrong_tab": return finish(.worksTabRequired)
    case "missing_root":
      consecutiveMissingRoots += 1
      return consecutiveMissingRoots >= Self.missingRootLimit ? finish(.platformChanged) : .keepLoading
    case "ready": consecutiveMissingRoots = 0
    default: return finish(.platformChanged)
    }

    guard let expectedAuthorID = profileAuthorID,
          snapshot.profileAuthorID == nil || snapshot.profileAuthorID == expectedAuthorID
    else {
      phase = .failed("页面中的博主身份与主页链接不一致，已停止读取。")
      return .stop(.navigationFailed)
    }
    if let name = snapshot.profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      profileName = name
    }
    let avatar = snapshot.profileAvatarURL.flatMap(DouyinProfilePreviewResource.admittedURL)?.absoluteString
    if let creatorID, profileName != nil || avatar != nil {
      refreshCreatorName(creatorID, profileName, avatar)
    }

    var indices = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.workID, $0.offset) })
    var additions = 0
    var existingURLs: [String] = []
    let remainingBudget = max(0, Self.perRoundBudget - newItemsThisRound)
    for item in snapshot.candidates where item.authorID == expectedAuthorID {
      guard let rawURL = URL(string: item.url),
            let canonicalURL = DouyinProfileWorkURL.canonical(rawURL),
            let workID = DouyinProfileWorkURL.workID(from: canonicalURL)
      else { continue }
      if let index = indices[workID] {
        // Virtualized cards can return with more data; absent values must not erase known counts.
        candidates[index].likes = item.likes?.nilIfTrimmedEmpty ?? candidates[index].likes
        candidates[index].comments = item.comments?.nilIfTrimmedEmpty ?? candidates[index].comments
        candidates[index].collects = item.collects?.nilIfTrimmedEmpty ?? candidates[index].collects
        continue
      }
      guard additions < remainingBudget else { continue }
      indices[workID] = candidates.count
      let saved = alreadySaved(canonicalURL)
      candidates.append(.init(
        workID: workID,
        authorID: expectedAuthorID,
        canonicalURL: canonicalURL,
        previewText: item.previewText?.nilIfTrimmedEmpty,
        coverURL: item.coverURL.flatMap(DouyinProfilePreviewResource.admittedURL),
        publishedText: item.publishedText?.nilIfTrimmedEmpty,
        wasAlreadySaved: saved,
        likes: item.likes?.nilIfTrimmedEmpty,
        comments: item.comments?.nilIfTrimmedEmpty,
        collects: item.collects?.nilIfTrimmedEmpty
      ))
      if saved { existingURLs.append(canonicalURL) }
      additions += 1
    }
    if let creatorID, !existingURLs.isEmpty {
      attachExisting(creatorID, existingURLs)
    }
    newItemsThisRound += additions
    consecutiveNoNewScreens = additions == 0 ? consecutiveNoNewScreens + 1 : 0

    if newItemsThisRound >= Self.perRoundBudget {
      return finish(.perRoundBudget(newItemsThisRound))
    }
    if consecutiveNoNewScreens >= Self.noNewScreenLimit {
      return finish(.visibleEnd)
    }
    return .keepLoading
  }

  private func finish(_ reason: DouyinProfileImportStopReason) -> ScanDirective {
    phase = .stopped(reason)
    return .stop(reason)
  }

  func updateMetrics(_ metrics: DouyinProfileWorkMetrics, expectedWorkID: String) {
    guard metrics.status == "ready", metrics.workID == expectedWorkID,
          let index = candidates.firstIndex(where: { $0.workID == expectedWorkID }) else { return }
    candidates[index].likes = metrics.likes?.nilIfTrimmedEmpty ?? candidates[index].likes
    candidates[index].comments = metrics.comments?.nilIfTrimmedEmpty ?? candidates[index].comments
    candidates[index].collects = metrics.collects?.nilIfTrimmedEmpty ?? candidates[index].collects
  }

  func toggleSelection(_ id: String) {
    guard unsavedCandidateIDs.contains(id) else { return }
    if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
  }

  func selectAllLoaded() { selectedIDs = unsavedCandidateIDs }
  func clearSelection() { selectedIDs.removeAll() }

  func saveSelected() {
    let selectedURLs = candidates
      .filter { selectedIDs.contains($0.id) && !$0.wasAlreadySaved }
      .map(\.canonicalURL)
    guard !selectedURLs.isEmpty else { return }
    let outcome = enqueue(selectedURLs, downloadsVideo, creatorID)
    saveMessage = "已加入保存队列 \(outcome.queued) 条，跳过 \(outcome.skipped) 条。失败项可在列表顶部单独重试。"
    selectedIDs.removeAll()
  }
}

private extension String {
  var nilIfTrimmedEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

struct DouyinProfileImportWebView: NSViewRepresentable {
  @ObservedObject var model: DouyinProfileImportViewModel
  let dataStore: WKWebsiteDataStore

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = false
    return view
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.model = model
    if context.coordinator.navigationRequestID != model.navigationRequestID,
       let sourceURL = model.sourceURL {
      context.coordinator.navigationRequestID = model.navigationRequestID
      context.coordinator.cancelScan()
      let navigation = webView.load(URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
      context.coordinator.trackNavigation(navigation, requestID: model.navigationRequestID)
    }
    if context.coordinator.scanRequestID != model.scanRequestID {
      context.coordinator.scanRequestID = model.scanRequestID
      if model.isScanning { context.coordinator.startScan(in: webView) }
    } else if !model.isScanning {
      context.coordinator.cancelScan()
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var model: DouyinProfileImportViewModel
    var navigationRequestID = -1
    var scanRequestID = -1
    private var scanTask: Task<Void, Never>?
    private var activeNavigation: WKNavigation?
    private let navigationRequests = NSMapTable<WKNavigation, NSNumber>.weakToStrongObjects()

    init(model: DouyinProfileImportViewModel) { self.model = model }

    deinit { scanTask?.cancel() }

    func cancelScan() {
      scanTask?.cancel()
      scanTask = nil
    }

    func startScan(in webView: WKWebView) {
      startScan { [weak webView] script in
        guard let webView else { throw CancellationError() }
        return try await webView.evaluateJavaScript(script)
      }
    }

    @discardableResult
    func startScan(evaluate: @escaping @MainActor (String) async throws -> Any?) -> Task<Void, Never> {
      cancelScan()
      let requestID = model.scanRequestID
      let navigationID = model.navigationRequestID
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        let isCurrent = {
          !Task.isCancelled && self.model.isScanning
            && requestID == self.model.scanRequestID
            && navigationID == self.model.navigationRequestID
        }
        while !Task.isCancelled, self.model.isScanning, requestID == self.model.scanRequestID {
          do {
            let result = try await evaluate(Self.extractionJavaScript)
            guard isCurrent() else { return }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8)
            else {
              self.model.scanFailed(scanRequestID: requestID)
              return
            }
            let snapshot = try JSONDecoder().decode(DouyinProfileDOMSnapshot.self, from: data)
            guard self.model.merge(snapshot, scanRequestID: requestID) == .keepLoading,
                  isCurrent() else { return }
            if snapshot.status == "ready" {
              _ = try await evaluate(Self.scrollJavaScript)
              guard isCurrent() else { return }
            }
            try await Task.sleep(for: .milliseconds(900))
            guard isCurrent() else { return }
          } catch is CancellationError {
            return
          } catch {
            guard isCurrent() else { return }
            self.model.scanFailed(scanRequestID: requestID)
            return
          }
        }
      }
      scanTask = task
      return task
    }

    func trackNavigation(_ navigation: WKNavigation?, requestID: Int) {
      guard let navigation else { return }
      navigationRequests.setObject(NSNumber(value: requestID), forKey: navigation)
      activeNavigation = navigation
    }

    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
      guard let navigation, navigation === activeNavigation else { return false }
      return navigationRequests.object(forKey: navigation)?.intValue == model.navigationRequestID
    }

    func finishNavigation(_ navigation: WKNavigation?, url: URL?) {
      guard isCurrentNavigation(navigation), let url else { return }
      model.acceptNavigation(url, navigationRequestID: model.navigationRequestID)
    }

    func failNavigation(_ navigation: WKNavigation?, error: any Error) {
      let failure = error as NSError
      guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
            isCurrentNavigation(navigation) else { return }
      model.navigationFailed(navigationRequestID: model.navigationRequestID)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(DouyinProfileNavigationPolicy.allows(navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      guard let navigation else { return }
      if let requestID = navigationRequests.object(forKey: navigation)?.intValue {
        guard requestID == model.navigationRequestID, navigation === activeNavigation else { return }
      } else {
        trackNavigation(navigation, requestID: model.navigationRequestID)
      }
      cancelScan()
      model.navigationStarted(navigationRequestID: model.navigationRequestID)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      finishNavigation(navigation, url: webView.url)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: any Error
    ) {
      failNavigation(navigation, error: error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      failNavigation(navigation, error: error)
    }

    static let extractionJavaScript = #"""
    (() => {
      const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
      const matchProfile = location.pathname.match(/^\/user\/([^/?#]+)/);
      const profileAuthorID = matchProfile ? decodeURIComponent(matchProfile[1]) : '';
      const bodyText = clean(document.body && document.body.innerText);
      const isVisible = (node) => {
        for (let current = node; current; current = current.parentElement) {
          const style = getComputedStyle(current);
          if (current.hidden || current.getAttribute('aria-hidden') === 'true'
              || style.display === 'none' || style.visibility === 'hidden'
              || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
        }
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const verification = /完成验证|安全验证|环境异常|人机验证/.test(bodyText)
        || Array.from(document.querySelectorAll('[class*="captcha"], [id*="captcha"]')).some(isVisible);
      if (verification) return JSON.stringify({status:'verification', profileAuthorID, profileName:null, profileAvatarURL:null, activeTab:null, candidates:[]});

      const selectedTab = Array.from(document.querySelectorAll('[role="tab"], [aria-selected="true"]'))
        .find(node => isVisible(node) && (node.getAttribute('aria-selected') === 'true' || /active|selected/.test(String(node.className || '').toLowerCase())));
      const activeTab = clean(selectedTab && selectedTab.textContent);
      if (activeTab && !/作品|投稿/.test(activeTab)) {
        return JSON.stringify({status:'wrong_tab', profileAuthorID, profileName:null, profileAvatarURL:null, activeTab, candidates:[]});
      }

      const nameNode = document.querySelector('[data-e2e="user-title"], [data-e2e="user-name"], h1');
      const titleMatch = String(document.title || '').match(/^(.+?)的抖音/);
      const profileName = clean(nameNode && nameNode.textContent) || (titleMatch && clean(titleMatch[1])) || null;
      const avatarNode = Array.from(document.querySelectorAll(
        '[data-e2e="user-avatar"] img, [data-e2e="user-info"] img, [data-e2e="user-detail"] img'
      )).find(node => isVisible(node) && !node.closest('[data-e2e="user-post-list"]'));
      const profileAvatarURL = avatarNode
        ? (avatarNode.currentSrc || avatarNode.getAttribute('src') || null)
        : null;
      // 真实主页把作品网格放在 `user-post-list`，页面没有 `<main>`；只读这个明确
      // 容器，才能排除侧栏推荐和“喜欢”列表里的其他作者作品。
      const postRoot = Array.from(document.querySelectorAll('[data-e2e="user-post-list"]')).find(isVisible);
      const anchors = postRoot
        ? Array.from(postRoot.querySelectorAll('a[href*="/video/"], a[href*="/note/"]'))
        : [];
      const candidates = [];
      const seen = new Set();
      for (const anchor of anchors) {
        if (!isVisible(anchor)) continue;
        const href = new URL(anchor.getAttribute('href') || '', location.href);
        const workMatch = href.pathname.match(/^\/(video|note)\/(\d{10,})/);
        if (!workMatch) continue;
        // Never let a generic ancestor resolve to the entire post list and mix neighboring works.
        const enclosingCard = anchor.closest('li, article');
        const card = enclosingCard && postRoot.contains(enclosingCard) ? enclosingCard : anchor;
        const cardWorkIDs = new Set(Array.from(card.querySelectorAll('a[href]')).map(node => {
          const match = new URL(node.getAttribute('href'), location.href).pathname.match(/^\/(?:video|note)\/(\d{10,})/);
          return match && match[1];
        }).filter(Boolean));
        const metricScope = cardWorkIDs.size > 1 ? anchor : card;
        const excluded = card.closest('aside, nav, footer, [data-e2e*="recommend"], [class*="recommend"], [data-e2e*="favorite"], [class*="favorite"]');
        if (excluded) continue;
        const authorHref = card.querySelector && card.querySelector('a[href*="/user/"]');
        const authorMatch = authorHref && new URL(authorHref.getAttribute('href') || '', location.href).pathname.match(/^\/user\/([^/?#]+)/);
        const authorID = authorMatch ? decodeURIComponent(authorMatch[1]) : profileAuthorID;
        if (!authorID || authorID !== profileAuthorID) continue;
        const key = `${workMatch[1]}:${workMatch[2]}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const image = card.querySelector && card.querySelector('img');
        const time = card.querySelector && card.querySelector('time, [data-e2e*="time"], [class*="time"]');
        const preview = clean((image && image.getAttribute('alt')) || (card && card.textContent));
        const coverURL = image && (image.currentSrc || image.getAttribute('src'));
        // Calibrated against the visible public profile card (2026-09-06).
        // Profile grids expose likes only; do not invent comments/collects from page totals.
        const likeNode = Array.from(metricScope.querySelectorAll('.author-card-user-video-like')).find(isVisible);
        const likeText = clean(likeNode && likeNode.textContent);
        const likes = /^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:万|亿|[kKmMwW])?\+?$/.test(likeText) ? likeText : null;
        candidates.push({
          url: `https://www.douyin.com/${workMatch[1]}/${workMatch[2]}`,
          authorID,
          previewText: preview || null,
          coverURL: coverURL || null,
          publishedText: clean(time && time.textContent) || null,
          likes,
          comments: null,
          collects: null
        });
      }
      const loginRequired = candidates.length === 0 && /登录后查看|登录即可查看|扫码登录/.test(bodyText);
      return JSON.stringify({
        status: loginRequired ? 'login' : (postRoot ? 'ready' : 'missing_root'),
        profileAuthorID,
        profileName,
        profileAvatarURL,
        activeTab: activeTab || null,
        candidates
      });
    })()
    """#

    private static let scrollJavaScript = #"""
    (() => {
      const root = document.querySelector('[data-e2e="user-post-list"]');
      let scroller = root;
      while (scroller && scroller !== document.body) {
        const style = getComputedStyle(scroller);
        if ((style.overflowY === 'auto' || style.overflowY === 'scroll')
            && scroller.scrollHeight > scroller.clientHeight) break;
        scroller = scroller.parentElement;
      }
      if (scroller && scroller !== document.body) {
        scroller.scrollBy({top: Math.max(scroller.clientHeight * 2, 1200), behavior: 'smooth'});
      } else {
        window.scrollBy({top: Math.max(window.innerHeight * 2, 1200), behavior: 'smooth'});
      }
      return true;
    })()
    """#
  }
}

struct DouyinProfileImportRequest: Identifiable, Equatable {
  let id: UUID
  let initialInput: String
  let autoStart: Bool

  static func blank() -> Self {
    .init(id: UUID(), initialInput: "", autoStart: false)
  }

  static func capture(profileURL: String) -> Self {
    .init(id: UUID(), initialInput: profileURL, autoStart: true)
  }
}

struct DouyinProfileImportSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @StateObject private var model: DouyinProfileImportViewModel
  @State private var showsHomepage = false
  @StateObject private var metricsReader = DouyinProfileMetricsReader()
  @State private var metricsQueue = DouyinProfileVisibleMetricsQueue()
  private let request: DouyinProfileImportRequest
  @State private var didApplyRequest = false

  init(manualLink: ManualLinkViewModel, request: DouyinProfileImportRequest) {
    let viewModel = DouyinProfileImportViewModel(manualLink: manualLink)
    if !request.initialInput.isEmpty {
      viewModel.input = request.initialInput
    }
    _model = StateObject(wrappedValue: viewModel)
    self.request = request
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.sourceURL == nil {
        inputPanel
      } else {
        VStack(spacing: 0) {
          discoveryHeader
          Divider()
          GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
              // Keep WebKit mounted at a stable desktop viewport even while the
              // loading sheet is compact, so lazy-loaded discovery is unaffected.
              DouyinProfileImportWebView(model: model, dataStore: SiteSessionController.douyin.dataStore)
                .frame(width: 960, height: 480)
                .allowsHitTesting(showsHomepage)
                .accessibilityHidden(!showsHomepage)
              if !showsHomepage {
                candidatePanel
                  .frame(width: geometry.size.width, height: geometry.size.height)
                  .background(theme.canvas)
              }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
          }
        }
      }
      if !model.candidates.isEmpty {
        Divider()
        footer
      }
    }
    .frame(width: showsHomepage || !model.candidates.isEmpty ? 960 : 640,
           height: sheetHeight, alignment: .top)
    .onChange(of: metricsReader.readingID) { previous, current in
      if let previous, current == nil {
        metricsQueue.finish(previous)
        readNextVisibleMetrics()
      }
    }
    .onChange(of: showsHomepage) { _, shown in
      if shown { metricsQueue.clearVisible() }
    }
    .id(request.id)
    .onAppear {
      guard !didApplyRequest else { return }
      didApplyRequest = true
      if model.input != request.initialInput {
        model.input = request.initialInput
      }
      if request.autoStart {
        model.start()
      }
    }
    .onDisappear { stopReading(); model.stop() }
  }

  private var sheetHeight: CGFloat {
    if showsHomepage { return 740 }
    if !model.candidates.isEmpty { return model.candidates.count <= 3 ? 600 : 740 }
    return model.sourceURL == nil ? 320 : 360
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("导入抖音博主内容").font(.headline)
        if !model.candidates.isEmpty {
          Text("选择想保存的作品，随时继续加载更多。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("关闭") { stopReading(); model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }

  private var inputPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("博主主页").font(.headline)
      TextField("粘贴主页链接或分享文案", text: $model.input)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("douyin-profile-import-input")
      if let validation = model.validationMessage {
        Label(validation, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(theme.danger)
      }
      Text("支持抖音主页链接和分享短链。")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("发现作品") { model.start() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canStart)
          .accessibilityIdentifier("douyin-profile-import-start")
      }
      .padding(.top, 8)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var discoveryHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.profileName ?? "抖音主页").font(.title3.weight(.semibold))
          Text("已发现 \(model.candidates.count) 条作品")
            .font(.callout).foregroundStyle(theme.secondaryText)
        }
        Spacer()
        if model.isScanning || model.phase == .loading {
          ProgressView().controlSize(.small)
          Text(model.isScanning ? "正在加载作品…" : "正在打开主页…")
            .font(.caption).foregroundStyle(theme.secondaryText)
        }
        if model.isScanning {
          Button("暂停加载", action: model.stop)
        } else if model.phase != .loading {
          Button("继续加载", action: model.continueLoading)
        }
        Button {
          showsHomepage.toggle()
        } label: {
          Label(showsHomepage ? "返回作品" : "查看主页",
                systemImage: showsHomepage ? "square.grid.2x2" : "globe")
        }
        .accessibilityIdentifier("douyin-profile-import-toggle-homepage")
      }
      if case let .stopped(reason) = model.phase {
        Label(reason.message, systemImage: "info.circle")
          .font(.caption).foregroundStyle(theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      } else if case let .failed(message) = model.phase {
        Label("\(message) 可点击“查看主页”检查。", systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(theme.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
  }

  private var candidatePanel: some View {
    ScrollView {
      if model.candidates.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "square.grid.2x2").font(.largeTitle)
          Text(model.phase == .loading || model.isScanning ? "作品加载后会显示在这里" : "还没有发现作品")
            .font(.headline)
          Text("如需登录或验证，请点击上方“查看主页”。")
            .font(.callout)
        }
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 12) {
          ForEach(model.candidates) { candidate in
            candidateCard(candidate)
              .onScrollVisibilityChange(threshold: 0.2) { visible in
                metricsQueue.setVisible(candidate.id, visible && !showsHomepage)
                readNextVisibleMetrics()
              }
              .onDisappear { metricsQueue.setVisible(candidate.id, false) }
          }
        }
        .padding(12)
      }
    }
    .accessibilityIdentifier("douyin-profile-import-candidates")
  }

  private func candidateCard(_ candidate: DouyinProfileImportCandidate) -> some View {
    let selected = model.selectedIDs.contains(candidate.id)
    return VStack(spacing: 0) {
      Button { model.toggleSelection(candidate.id) } label: {
      VStack(alignment: .leading, spacing: 0) {
        // The container fixes the crop independently of the source image dimensions.
        Rectangle().fill(theme.badge)
          .aspectRatio(3.0 / 2.0, contentMode: .fit)
          .overlay {
            GeometryReader { geometry in
              DouyinProfilePreviewImage(url: candidate.coverURL)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
          }
          .overlay(alignment: .topTrailing) {
            Image(systemName: candidate.wasAlreadySaved ? "checkmark.circle.fill" : (selected ? "checkmark.circle.fill" : "circle"))
              .font(.body)
              .foregroundStyle(candidate.wasAlreadySaved ? theme.success : theme.accent)
              .padding(4)
              .background(theme.card, in: Circle())
              .padding(8)
          }
        VStack(alignment: .leading, spacing: 8) {
          Text(displayTitle(for: candidate))
            .font(.caption.weight(.semibold))
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .foregroundStyle(theme.primaryText)
          HStack(spacing: 0) {
            metric("点赞", symbol: "heart", value: candidate.likes)
            metric("评论", symbol: "bubble.right", value: candidate.comments)
            metric("收藏", symbol: "bookmark", value: candidate.collects)
          }
          .padding(.vertical, 7)
          .background(theme.badge.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
          HStack {
            Text(candidate.wasAlreadySaved ? "已保存" : (selected ? "已选择" : "点击选择"))
            Spacer()
            if let published = candidate.publishedText { Text(published).lineLimit(1) }
          }
          .font(.caption).foregroundStyle(theme.secondaryText)
        }
        .padding(10)
      }
      }
      .buttonStyle(.plain)
      .disabled(candidate.wasAlreadySaved)
      .accessibilityLabel(displayTitle(for: candidate))
      .accessibilityValue("\(candidate.wasAlreadySaved ? "已保存" : (selected ? "已选择" : "未选择"))，点赞 \(candidate.likes ?? "未提供")，评论 \(candidate.comments ?? "未提供")，收藏 \(candidate.collects ?? "未提供")")
      HStack(spacing: 5) {
        if metricsReader.readingID == candidate.id {
          ProgressView().controlSize(.mini)
          Text("补全数据…").font(.caption2).foregroundStyle(theme.secondaryText)
          Spacer(minLength: 2)
          Button("取消") { metricsReader.cancel() }.font(.caption2)
        } else {
          let complete = hasCompleteMetrics(candidate)
          let message = metricsReader.messages[candidate.id]
          Text(complete ? "数据已完整" : (message ?? "等待自动补全"))
            .font(.caption2).foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .help(message ?? (complete ? "点赞、评论、收藏已读取" : "进入可见区域后自动补全评论和收藏"))
          Spacer(minLength: 2)
          if !complete, message != nil {
            Button {
              metricsQueue.retry(candidate.id)
              readNextVisibleMetrics()
            } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.plain)
              .font(.caption)
              .help("重试读取这条作品的数据")
              .accessibilityLabel("重试读取数据")
              .disabled(metricsReader.readingID != nil)
          } else if complete {
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(theme.success)
          }
        }
      }
      .frame(height: 20)
      .padding(.horizontal, 10).padding(.bottom, 8)
    }
    .background(theme.card)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: selected ? 2 : 1)
        .allowsHitTesting(false)
    }
  }

  private func hasCompleteMetrics(_ candidate: DouyinProfileImportCandidate) -> Bool {
    candidate.likes != nil && candidate.comments != nil && candidate.collects != nil
  }

  private func readNextVisibleMetrics() {
    guard !showsHomepage, metricsReader.readingID == nil else { return }
    let incomplete = model.candidates.filter { !hasCompleteMetrics($0) }
    guard let id = metricsQueue.next(in: incomplete.map(\.id)),
          let candidate = incomplete.first(where: { $0.id == id }) else { return }
    metricsReader.read(candidate, dataStore: SiteSessionController.douyin.dataStore) { metrics in
      model.updateMetrics(metrics, expectedWorkID: candidate.workID)
    }
  }

  private func stopReading() {
    metricsQueue.stop()
    metricsReader.cancel()
  }

  private func metric(_ label: String, symbol: String, value: String?) -> some View {
    VStack(spacing: 3) {
      Text(value ?? "—")
        .font(.callout.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(value == nil ? theme.secondaryText : theme.primaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Label(label, systemImage: symbol)
        .font(.caption2)
        .foregroundStyle(theme.secondaryText)
    }
    .frame(maxWidth: .infinity)
    .help(value == nil ? "尚未读取到这条作品的\(label)数据，— 不代表 0。" : "\(label)：\(value!)（页面显示值）")
  }

  private func displayTitle(for candidate: DouyinProfileImportCandidate) -> String {
    let title = candidate.previewText ?? "抖音作品 \(candidate.workID)"
    guard let author = model.profileName?.nilIfTrimmedEmpty else { return title }
    for separator in ["：", ":"] {
      let prefix = author + separator
      if title.hasPrefix(prefix), let trimmed = String(title.dropFirst(prefix.count)).nilIfTrimmedEmpty {
        return trimmed
      }
    }
    return title
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button("全选已加载", action: model.selectAllLoaded)
          .disabled(model.unsavedCandidateIDs.isEmpty)
        Button("清空", action: model.clearSelection)
          .disabled(model.selectedIDs.isEmpty)
        Text("已选 \(model.selectedCount) 条").font(.callout)
          .foregroundStyle(theme.secondaryText)
        Spacer(minLength: 12)
        Toggle("同时下载视频", isOn: $model.downloadsVideo)
          .toggleStyle(.checkbox)
        Button("保存所选 \(model.selectedCount) 条") { model.saveSelected() }
          .buttonStyle(.borderedProminent)
          .disabled(model.selectedIDs.isEmpty)
          .accessibilityIdentifier("douyin-profile-import-save")
      }
      Text(model.saveMessage ?? "可见卡片会自动补全评论和收藏；— 表示尚未读取到数据。保存后可在汲作中查看；总结和转写由你手动发起。")
        .font(.caption).foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
  }
}
