import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore
import SwiftUI
import WebKit

enum DouyinProfileInputRoute: Equatable {
  case profile(platform: ProfileImportPlatform, sourceURL: URL, authorID: String)
  case shortLink(platform: ProfileImportPlatform, sourceURL: URL)

  static func parse(_ rawValue: String) -> DouyinProfileInputRoute? {
    ProfileImportPlatform.parse(rawValue)
  }

  var platform: ProfileImportPlatform {
    switch self {
    case let .profile(platform, _, _), let .shortLink(platform, _): platform
    }
  }

  var sourceURL: URL {
    switch self {
    case let .profile(_, sourceURL, _), let .shortLink(_, sourceURL): sourceURL
    }
  }

  var persistentURL: URL {
    switch self {
    case let .profile(platform, _, authorID):
      platform.canonicalProfileURL(authorID: authorID)
    case let .shortLink(_, sourceURL):
      sourceURL
    }
  }
}

enum DouyinProfileWorkURL {
  static func canonical(_ url: URL) -> String? {
    guard ProfileImportPlatform.fromWorkURL(url) == .douyin else { return nil }
    let components = url.pathComponents.filter { $0 != "/" }
    let kind: String
    let workID: String
    if components.count >= 2, ["video", "note"].contains(components[0].lowercased()) {
      kind = components[0].lowercased()
      workID = components[1]
    } else if components.count >= 3,
              components[0].lowercased() == "share",
              ["video", "note"].contains(components[1].lowercased()) {
      kind = components[1].lowercased()
      workID = components[2]
    } else {
      return nil
    }
    guard workID.count >= 10, workID.allSatisfy(\.isNumber) else { return nil }
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

/// Card and directory covers: named platform CDNs only. Redirects must stay
/// in the same platform family so an admitted start URL cannot hop onto an
/// unrelated public CDN. Remote fetch still rejects private/loopback hosts.
enum GalleryCoverAdmission {
  static func admittedURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          isAllowedHost(host)
    else { return nil }
    do { try PublicWebURLPolicy(resolver: { _ in [] }).validateSyntax(url) }
    catch { return nil }
    return url
  }

  static func isAllowedHost(_ host: String) -> Bool {
    platformFamily(for: host) != nil
  }

  static func allowsRedirect(from start: URL, to target: URL) -> Bool {
    guard let admittedStart = admittedURL(start.absoluteString),
          let admittedTarget = admittedURL(target.absoluteString),
          let startHost = admittedStart.host?.lowercased(),
          let targetHost = admittedTarget.host?.lowercased(),
          let startFamily = platformFamily(for: startHost),
          startFamily == platformFamily(for: targetHost)
    else { return false }
    return true
  }

  static func platformFamily(for host: String) -> String? {
    if host == "mmbiz.qpic.cn" { return "wechat" }
    if matches(host, ["douyinpic.com", "byteimg.com", "pstatp.com", "douyinstatic.com", "douyin.com", "iesdouyin.com"]) {
      return "douyin"
    }
    if matches(host, ["xhscdn.com", "xiaohongshu.com"]) { return "xiaohongshu" }
    if matches(host, ["hdslb.com", "bilibili.com"]) { return "bilibili" }
    if matches(host, ["twimg.com"]) { return "x" }
    if matches(host, ["ytimg.com", "youtube.com"]) { return "youtube" }
    if host == "raw.githubusercontent.com"
      || host == "user-images.githubusercontent.com"
      || matches(host, ["githubusercontent.com", "githubassets.com", "github.com"])
    { return "github" }
    if matches(host, ["redd.it", "redditmedia.com", "redditstatic.com", "reddit.com"]) { return "reddit" }
    if matches(host, ["substackcdn.com", "substack.com"]) { return "substack" }
    if host == "linux.do" || host.hasSuffix(".linux.do")
      || matches(host, ["ldstatic.com", "discourse-cdn.com", "discourse.org", "uscardforum.com"])
    { return "discourse" }
    if matches(host, ["medium.com"]) { return "medium" }
    return nil
  }

  private static func matches(_ host: String, _ suffixes: [String]) -> Bool {
    suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}

enum DouyinProfilePreviewResource {
  static let byteLimit = 2_000_000
  private static let resources: any SafeResourceFetching = ProxyAwareWebPageFetcher()

  static func admittedURL(_ value: String) -> URL? {
    GalleryCoverAdmission.admittedURL(value)
  }

  private static func imageReferer(_ url: URL) -> String {
    let host = url.host?.lowercased() ?? ""
    if host == "mmbiz.qpic.cn" { return "https://mp.weixin.qq.com/" }
    if host.hasSuffix("xhscdn.com") || host.hasSuffix("xiaohongshu.com") {
      return "https://www.xiaohongshu.com/"
    }
    if host.hasSuffix("hdslb.com") || host.hasSuffix("bilibili.com") {
      return "https://www.bilibili.com/"
    }
    if host.hasSuffix("twimg.com") { return "https://x.com/" }
    if host.hasSuffix("ytimg.com") || host.hasSuffix("youtube.com") {
      return "https://www.youtube.com/"
    }
    if host.hasSuffix("githubusercontent.com") || host.hasSuffix("githubassets.com")
      || host.hasSuffix("github.com")
    {
      return "https://github.com/"
    }
    if host.hasSuffix("redd.it") || host.hasSuffix("reddit.com")
      || host.hasSuffix("redditmedia.com") || host.hasSuffix("redditstatic.com")
    {
      return "https://www.reddit.com/"
    }
    if host.hasSuffix("substackcdn.com") || host.hasSuffix("substack.com") {
      return "https://substack.com/"
    }
    if host == "linux.do" || host.hasSuffix(".linux.do") || host.hasSuffix("ldstatic.com") {
      return "https://linux.do/"
    }
    if host == "uscardforum.com" || host.hasSuffix(".uscardforum.com") {
      return "https://uscardforum.com/"
    }
    if host.hasSuffix("medium.com") { return "https://medium.com/" }
    if host.hasSuffix("douyinpic.com") || host.hasSuffix("byteimg.com")
      || host.hasSuffix("pstatp.com") || host.hasSuffix("douyinstatic.com")
      || host.hasSuffix("douyin.com") || host.hasSuffix("iesdouyin.com")
    {
      return "https://www.douyin.com/"
    }
    return "https://\(host)/"
  }

  static func fetch(_ url: URL, using resources: any SafeResourceFetching = resources) async throws -> Data {
    guard admittedURL(url.absoluteString) != nil else { throw ManualLinkError.unsafeURL }
    // The existing transport validates DNS, the connected peer and every redirect.
    // Keep the same image-host boundary on redirects as on the initial DOM URL.
    let response = try await resources.fetchResource(.init(
      url: url,
      headers: ["Accept": "image/*", "Referer": imageReferer(url)],
      byteLimit: byteLimit,
      allowsRedirectTarget: { GalleryCoverAdmission.allowsRedirect(from: url, to: $0) }
    ))
    guard GalleryCoverAdmission.allowsRedirect(from: url, to: response.url) else { throw ManualLinkError.unsafeURL }
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
  var previewText: String? = nil
  var thumbnailLoader: WorkThumbnailLoader = .shared
  @State private var image: NSImage?
  @State private var failed = false
  @State private var retryID = 0

  var body: some View {
    ZStack {
      Rectangle().fill(theme.badge)
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else if url == nil {
        Text(HistoryRowProjection.sanitizedDirectoryPreview(previewText, isSummary: false) ?? "无封面图片")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
          .lineLimit(6)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(10)
      } else if failed {
        VStack(spacing: 4) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 14, weight: .semibold))
          Text("重试")
            .themedFont(.caption2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { retryID += 1 }
        .foregroundStyle(theme.secondaryText)
        .help("图片加载失败，点击重试")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图片加载失败，点击重试")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { retryID += 1 }
        .accessibilityIdentifier("profile-preview-image-retry")
      } else {
        Text("封面加载中")
          .themedFont(.caption2)
          .foregroundStyle(theme.secondaryText)
      }
    }
    .contentShape(Rectangle())
    .task(id: "\(url?.absoluteString ?? "")#\(retryID)") {
      image = nil
      failed = false
      guard let url else { return }
      do {
        let thumbnail = try await thumbnailLoader.image(url: url)
        guard !Task.isCancelled else { return }
        image = NSImage(cgImage: thumbnail.image, size: .zero)
      } catch {
        if !Task.isCancelled { failed = true }
      }
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
  var metricsSource: String? = nil
  var metricsReadAt: String? = nil
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
  var previewText: String?
  var coverURL: URL?
  var publishedText: String?
  let wasAlreadySaved: Bool
  var likes: String? = nil
  var comments: String? = nil
  var collects: String? = nil
  var metricsSource: String? = nil
  var metricsReadAt: String? = nil

  var id: String { workID }
}

/// One attempt per visible work per sheet; explicit retry is the only repeat path.
struct DouyinProfileVisibleMetricsQueue {
  private(set) var visibleIDs: Set<String> = []
  private(set) var attemptedIDs: Set<String> = []
  private(set) var activeID: String?
  private(set) var isStopped = false
  private(set) var isPaused = false

  mutating func setVisible(_ id: String, _ visible: Bool) {
    guard !isStopped else { return }
    if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
  }

  mutating func next(in orderedIDs: [String]) -> String? {
    guard !isStopped, !isPaused, activeID == nil,
          let id = orderedIDs.first(where: { visibleIDs.contains($0) && !attemptedIDs.contains($0) }) else { return nil }
    attemptedIDs.insert(id)
    activeID = id
    return id
  }

  mutating func pause() { isPaused = true }
  mutating func resume() { guard !isStopped else { return }; isPaused = false }

  mutating func finish(_ id: String) {
    guard activeID == id else { return }
    activeID = nil
  }

  mutating func retry(_ id: String) {
    guard !isStopped, activeID != id, visibleIDs.contains(id) else { return }
    isPaused = false
    attemptedIDs.remove(id)
  }

  mutating func clearVisible() { visibleIDs.removeAll() }

  mutating func stop() {
    isStopped = true
    isPaused = false
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
  var source: String? = nil
  var readAt: String? = nil
  var authorID: String? = nil
}

/// Reads one requested public work at a time without disturbing the profile grid.
@MainActor
final class DouyinProfileMetricsReader: NSObject, ObservableObject, WKNavigationDelegate {
  @Published private(set) var readingID: String?
  @Published private(set) var messages: [String: String] = [:]
  @Published private(set) var accessLimit: String?
  private var task: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var webView: WKWebView?
  private var generation = 0
  private var cache: DouyinProfileMetricsCache

  override init() {
    cache = DouyinProfileMetricsCache()
    super.init()
  }

  init(cache: DouyinProfileMetricsCache) {
    self.cache = cache
    super.init()
  }

  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    if let readingID { messages[readingID] = "读取已取消，可重试" }
    readingID = nil
  }

  func read(_ candidate: DouyinProfileImportCandidate, dataStore: WKWebsiteDataStore,
            deadlineSeconds: TimeInterval = DouyinProfileMetricsCapture.detailDeadlineSeconds,
            load: (WKWebView, URL) -> Void = { view, url in
              view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            }, receive: @escaping (DouyinProfileWorkMetrics) -> Void) {
    guard readingID == nil, let url = URL(string: candidate.canonicalURL),
          let canonical = DouyinProfileWorkURL.canonical(url),
          DouyinProfileWorkURL.workID(from: canonical) == candidate.workID else { return }
    generation += 1
    let request = generation
    let id = candidate.workID
    let authorID = candidate.authorID
    readingID = id
    messages[id] = nil
    accessLimit = nil
    let seed = cache.lookup(workID: id, authorID: authorID)
    if let cached = seed {
      receive(.init(
        status: "ready",
        workID: id,
        likes: cached.likes,
        comments: cached.comments,
        collects: cached.collects,
        source: cached.source,
        readAt: cached.observedAt,
        authorID: authorID
      ))
      if cached.isComplete {
        messages[id] = "数据已更新"
        readingID = nil
        return
      }
      messages[id] = DouyinProfileMetricsCapture.partialMessage
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.userContentController.addUserScript(DouyinProfileMetricsCapture.documentStartUserScript())
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = self
    webView = view
    load(view, url)
    // This task runs independently of evaluateJavaScript. A page that never
    // answers must release the queue, and any late result loses its generation.
    timeoutTask = Task { @MainActor [weak self, weak view] in
      do { try await Task.sleep(for: .seconds(max(0, deadlineSeconds))) }
      catch { return }
      guard let self, !Task.isCancelled, request == self.generation else { return }
      self.generation += 1
      self.task?.cancel()
      self.task = nil
      view?.stopLoading()
      view?.navigationDelegate = nil
      self.webView = nil
      self.messages[id] = self.cache.lookup(workID: id, authorID: authorID) == nil
        ? "读取超时，可重试" : "仍有未读取项，可重试"
      self.readingID = nil
      self.timeoutTask = nil
    }
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var delivered = seed != nil
      var accumulated = seed
      var result: DouyinProfileWorkMetrics?
      var message = seed == nil ? "暂未读取到数据，可重试" : DouyinProfileMetricsCapture.partialMessage
      let deadline = Date().addingTimeInterval(deadlineSeconds)
      while Date() < deadline {
        do {
          try await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, request == self.generation else { return }
          guard Date() < deadline else { break }
          guard let loadedURL = view.url, DouyinProfileWorkURL.canonical(loadedURL) == candidate.canonicalURL else { continue }
          let raw = try await view.evaluateJavaScript(
            DouyinProfileMetricsCapture.detailExtractionJavaScript(workID: id, authorID: authorID)
          )
          guard !Task.isCancelled, request == self.generation else { return }
          guard let json = raw as? String,
                let metrics = try? JSONDecoder().decode(DouyinProfileWorkMetrics.self, from: Data(json.utf8)) else { continue }
          switch metrics.status {
          case "ready":
            guard metrics.workID == id else { continue }
            let merged = DouyinProfileMetricsCapture.merging(
              accumulated,
              with: .init(
                workID: id,
                authorID: authorID,
                likes: metrics.likes,
                comments: metrics.comments,
                collects: metrics.collects,
                observedAt: metrics.readAt ?? ISO8601DateFormatter().string(from: Date()),
                source: metrics.source ?? DouyinProfileMetricsSource.detailDOM
              )
            )
            accumulated = merged
            result = .init(
              status: "ready",
              workID: id,
              likes: merged.likes,
              comments: merged.comments,
              collects: merged.collects,
              source: merged.source,
              readAt: merged.observedAt,
              authorID: authorID
            )
            if request == self.generation, let result {
              receive(result)
              delivered = true
              self.cache.store(merged)
            }
            message = merged.isComplete ? "数据已更新" : DouyinProfileMetricsCapture.partialMessage
            if merged.isComplete { break }
            continue
          case "login":
            if request == self.generation { receive(metrics) }
            result = nil
            message = "作品需要登录，请在“查看主页”登录后重试"
            self.accessLimit = "login"
          case "verification":
            if request == self.generation { receive(metrics) }
            result = nil
            message = "作品需要验证，请在“查看主页”完成后重试"
            self.accessLimit = "verification"
          case "rate_limit":
            if request == self.generation { receive(metrics) }
            result = nil
            message = "访问过于频繁，已暂停自动读取，稍后可重试"
            self.accessLimit = "rate_limit"
          case "wrong_work": result = nil; message = "页面作品不一致，未更新数据"
          default: continue
          }
          break
        } catch is CancellationError { return }
        catch { if Task.isCancelled || request != self.generation { return } }
      }
      guard !Task.isCancelled, request == self.generation else { return }
      if let result {
        if let finalURL = view.url, DouyinProfileWorkURL.canonical(finalURL) == candidate.canonicalURL {
          if !delivered { receive(result) }
        } else { message = "页面作品不一致，未更新数据" }
      }
      self.timeoutTask?.cancel()
      self.timeoutTask = nil
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

  static func extractionJavaScript(workID: String, authorID: String = "") -> String {
    DouyinProfileMetricsCapture.detailExtractionJavaScript(workID: workID, authorID: authorID)
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
  case browserExtension

  var message: String {
    switch self {
    case .user:
      return "已暂停，可继续加载更多作品。"
    case let .perRoundBudget(count):
      return "本轮新增 \(count) 条，可继续加载。"
    case .visibleEnd:
      return "暂未发现更多作品，可继续加载。"
    case .loginRequired:
      return "当前平台需要登录。可点「登录」使用本机会话，完成后会继续当前主页，不必重新粘贴。"
    case .verificationRequired:
      return "请点击“查看主页”完成人机验证，再继续加载。"
    case .worksTabRequired:
      return "请点击“查看主页”，切换到本人作品／投稿列表后继续加载。"
    case .platformChanged:
      return "等待后仍未识别到主页作品列表，平台页面结构可能已变化。请重试或使用浏览器扩展保存单条作品。"
    case .navigationFailed:
      return "主页暂时无法打开，请检查链接或网络后重试。"
    case .browserExtension:
      return "这些作品来自浏览器扩展，尚未保存，也不会自动总结。更多作品请在浏览器向下滚动后，再点一次汲作扩展。"
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
  enum DiscoverySource: Equatable { case embeddedWebKit, browserExtension }

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
  @Published private(set) var resolvedPlatform: ProfileImportPlatform?
  @Published private(set) var discoverySource: DiscoverySource = .embeddedWebKit

  var currentAuthorID: String? { profileAuthorID }
  var isBrowserSourced: Bool { discoverySource == .browserExtension }

  var platform: ProfileImportPlatform {
    resolvedPlatform
      ?? sourceURL.flatMap(ProfileImportPlatform.fromProfileURL)
      ?? sourceURL.flatMap(ProfileImportPlatform.fromShortLink)
      ?? ProfileImportPlatform.parse(input)?.platform
      ?? .douyin
  }
  var dataStore: WKWebsiteDataStore { platform.session.dataStore }
  // Signed access URLs live only for this discovery session, never in returned MCP data.
  private var accessURLs: [String: String] = [:]
  func captureURL(for candidate: DouyinProfileImportCandidate) -> String {
    accessURLs[candidate.canonicalURL] ?? candidate.canonicalURL
  }
  private let alreadySaved: (String) -> Bool
  private let enqueue: ([String], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome
  private let enqueueCandidates: (([ProfileImportCandidateSeed], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome)?
  private let ensureCreator: (String, String, String?) -> CreatorID?
  private let refreshCreatorName: (CreatorID, String?, String?) -> Void
  private let attachExisting: (CreatorID, [String]) -> Void
  private var profileAuthorID: String?
  private(set) var creatorID: CreatorID?
  private var consecutiveNoNewScreens = 0
  private var consecutiveMissingRoots = 0
  private var newItemsThisRound = 0
  private var lastHeaderRefresh: String?

  static let perRoundBudget = 100
  static let noNewScreenLimit = 3
  static let initialEmptyScreenLimit = 20
  static let missingRootLimit = 8

  init(
    alreadySaved: @escaping (String) -> Bool,
    enqueue: @escaping ([String], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome,
    enqueueCandidates: (([ProfileImportCandidateSeed], Bool, CreatorID?) -> ManualLinkViewModel.ProfileImportEnqueueOutcome)? = nil,
    ensureCreator: @escaping (String, String, String?) -> CreatorID? = { _, _, _ in nil },
    refreshCreatorName: @escaping (CreatorID, String?, String?) -> Void = { _, _, _ in },
    attachExisting: @escaping (CreatorID, [String]) -> Void = { _, _ in }
  ) {
    self.alreadySaved = alreadySaved
    self.enqueue = enqueue
    self.enqueueCandidates = enqueueCandidates
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
      enqueueCandidates: { candidates, downloads, creatorID in
        manualLink.enqueueProfileImport(candidates: candidates, downloadsVideo: downloads, creatorID: creatorID)
      },
      ensureCreator: { authorID, profileURL, name in
        manualLink.ensureProfileCreator(authorID: authorID, profileURL: profileURL, displayName: name)
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
    guard !trimmed.isEmpty, ProfileImportPlatform.parse(input) == nil else { return nil }
    return "请输入一个抖音、小红书、X 或 B 站主页链接或分享文案。支持常见手机主页地址和短链；短链若打开后是单条作品，请改用单条保存。"
  }

  var canStart: Bool { ProfileImportPlatform.parse(input) != nil && phase != .loading }
  var isScanning: Bool { phase == .scanning }
  var selectedCount: Int { selectedIDs.count }
  var unsavedCandidateIDs: Set<String> {
    Set(candidates.lazy.filter { !$0.wasAlreadySaved }.map(\.id))
  }
  var incompleteMetricIDs: [String] {
    candidates.filter { $0.likes == nil || $0.comments == nil || $0.collects == nil }.map(\.id)
  }

  func start() {
    guard let route = ProfileImportPlatform.parse(input) else {
      phase = .failed("无法识别博主主页。请使用抖音、小红书、X 或 B 站主页链接、分享文案或短链。")
      return
    }
    candidates = []
    accessURLs = [:]
    selectedIDs = []
    saveMessage = nil
    profileName = nil
    creatorID = nil
    discoverySource = .embeddedWebKit
    resolvedPlatform = route.platform
    profileAuthorID = {
      if case let .profile(_, _, authorID) = route { return authorID }
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
    guard creatorID == nil, let authorID = profileAuthorID else { return }
    let persisted = sourceURL.flatMap { url in
      platform.authorID(url).map { platform.canonicalProfileURL(authorID: $0).absoluteString }
    } ?? platform.canonicalProfileURL(authorID: authorID).absoluteString
    creatorID = ensureCreator(authorID, persisted, profileName)
  }

  func acceptNavigation(_ url: URL, navigationRequestID requestID: Int? = nil) {
    guard discoverySource != .browserExtension else { return }
    guard requestID == nil || requestID == navigationRequestID else { return }
    guard platform.allowsNavigation(url) else {
      rejectDisallowedNavigation(url)
      return
    }
    switch phase {
    case .loading, .scanning, .stopped(.loginRequired), .stopped(.verificationRequired), .stopped(.worksTabRequired):
      break
    case .input, .stopped(_), .failed(_):
      return
    }
    if let landed = ProfileImportPlatform.fromProfileURL(url), landed != platform {
      phase = .failed("打开后的站点与当前平台不一致，已停止。")
      return
    }
    if let landedShort = ProfileImportPlatform.fromShortLink(url), landedShort != platform {
      phase = .failed("打开后的站点与当前平台不一致，已停止。")
      return
    }
    guard let authorID = platform.authorID(url) else {
      if platform != .douyin,
         url.path.lowercased().range(of: "login|signin|passport", options: .regularExpression) != nil {
        phase = .stopped(.loginRequired)
        return
      }
      if ProfileImportPlatform.fromWorkURL(url) != nil {
        phase = .failed("这是单条作品链接，请改用单条保存入口，不能当作博主主页导入。")
      }
      return
    }
    if let profileAuthorID, profileAuthorID != authorID {
      phase = .failed("打开后的博主身份与输入主页不一致，已停止读取。")
      return
    }
    profileAuthorID = profileAuthorID ?? authorID
    let next = platform.navigationProfileURL(authorID: authorID, retaining: url)
    let needsCanonicalLoad = Self.needsCanonicalNavigation(from: url, to: next)
    sourceURL = next
    bindCreatorIfNeeded()
    if needsCanonicalLoad {
      navigationRequestID += 1
      phase = .loading
      return
    }
    beginScanRound()
  }

  static func needsCanonicalNavigation(from landed: URL, to target: URL) -> Bool {
    func normalized(_ url: URL) -> (String, String) {
      var host = (url.host ?? "").lowercased()
      if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
      var path = url.path
      while path.count > 1, path.hasSuffix("/") { path.removeLast() }
      return (host, path)
    }
    return normalized(landed) != normalized(target)
  }

  func rejectDisallowedNavigation(_ url: URL?) {
    guard discoverySource != .browserExtension else { return }
    switch phase {
    case .loading, .scanning, .stopped(.loginRequired), .stopped(.verificationRequired), .stopped(.worksTabRequired):
      if let url, ProfileImportPlatform.fromWorkURL(url) != nil {
        phase = .failed("这是单条作品链接，请改用单条保存入口，不能当作博主主页导入。")
      } else {
        phase = .failed("打开后的地址离开了当前平台，已停止。")
      }
    case .input, .stopped(_), .failed(_):
      return
    }
  }

  func reloadCurrentHomepage() {
    guard sourceURL != nil else { return }
    if discoverySource == .browserExtension {
      saveMessage = "请在浏览器刷新该主页后，再点一次汲作扩展。"
      return
    }
    consecutiveNoNewScreens = 0
    consecutiveMissingRoots = 0
    newItemsThisRound = 0
    saveMessage = nil
    navigationRequestID += 1
    phase = .loading
  }

  func navigationStarted(navigationRequestID requestID: Int) {
    guard discoverySource != .browserExtension else { return }
    guard requestID == navigationRequestID else { return }
    if phase == .scanning {
      scanRequestID += 1
      phase = .loading
    }
  }

  func navigationFailed(navigationRequestID requestID: Int) {
    guard discoverySource != .browserExtension else { return }
    guard requestID == navigationRequestID else { return }
    switch phase {
    case .loading, .scanning,
         .stopped(.loginRequired), .stopped(.verificationRequired), .stopped(.worksTabRequired):
      phase = .stopped(.navigationFailed)
    case .input, .stopped(.user), .stopped(.perRoundBudget), .stopped(.visibleEnd),
         .stopped(.navigationFailed), .stopped(.platformChanged), .stopped(.browserExtension), .failed:
      return
    }
  }

  func scanFailed(scanRequestID requestID: Int) {
    guard discoverySource != .browserExtension else { return }
    guard requestID == scanRequestID, phase == .scanning else { return }
    phase = .stopped(.navigationFailed)
  }

  func stop() {
    guard isScanning || phase == .loading else { return }
    phase = .stopped(.user)
  }

  func continueLoading() {
    guard sourceURL != nil, profileAuthorID != nil else { return }
    if discoverySource == .browserExtension {
      saveMessage = "请在浏览器继续向下滚动该主页，再点一次汲作扩展。不会自动保存或总结。"
      return
    }
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
    guard discoverySource != .browserExtension else { return .stop(.browserExtension) }
    guard (requestID == nil || requestID == scanRequestID), phase == .scanning else {
      return .stop(.user)
    }
    switch snapshot.status {
    case "verification":
      // Captcha pages return empty header fields. Do not write nulls over a
      // previously saved name or avatar.
      return finish(.verificationRequired)
    case "login":
      applyVisibleProfileMetadata(snapshot)
      return finish(.loginRequired)
    case "wrong_tab":
      applyVisibleProfileMetadata(snapshot)
      return finish(.worksTabRequired)
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
    applyVisibleProfileMetadata(snapshot)

    var updatedCandidates = candidates
    var indices = Dictionary(uniqueKeysWithValues: updatedCandidates.enumerated().map { ($0.element.workID, $0.offset) })
    var additions = 0
    var existingURLs: [String] = []
    let remainingBudget = max(0, Self.perRoundBudget - newItemsThisRound)
    for item in snapshot.candidates where item.authorID == expectedAuthorID {
      guard let rawURL = URL(string: item.url),
            ProfileImportPlatform.fromWorkURL(rawURL) == platform,
            let canonicalURL = ProfileImportPlatform.canonicalWork(rawURL),
            let workID = DouyinProfileWorkURL.workID(from: canonicalURL)
      else { continue }
      accessURLs[canonicalURL] = rawURL.absoluteString
      if let index = indices[workID] {
        // Virtualized cards and later list responses can add counts; nil must not erase known values.
        applyMetrics(item, to: &updatedCandidates[index])
        // Lazy image URLs can arrive on a later scan; never freeze an empty first cover.
        if let cover = item.coverURL.flatMap(DouyinProfilePreviewResource.admittedURL) {
          updatedCandidates[index].coverURL = cover
        }
        if let text = item.previewText?.nilIfTrimmedEmpty { updatedCandidates[index].previewText = text }
        if let date = item.publishedText?.nilIfTrimmedEmpty { updatedCandidates[index].publishedText = date }
        continue
      }
      guard additions < remainingBudget else { continue }
      indices[workID] = updatedCandidates.count
      let saved = alreadySaved(canonicalURL)
      updatedCandidates.append(.init(
        workID: workID,
        authorID: expectedAuthorID,
        canonicalURL: canonicalURL,
        previewText: item.previewText?.nilIfTrimmedEmpty,
        coverURL: item.coverURL.flatMap(DouyinProfilePreviewResource.admittedURL),
        publishedText: item.publishedText?.nilIfTrimmedEmpty,
        wasAlreadySaved: saved,
        likes: item.likes?.nilIfTrimmedEmpty,
        comments: item.comments?.nilIfTrimmedEmpty,
        collects: item.collects?.nilIfTrimmedEmpty,
        metricsSource: item.metricsSource?.nilIfTrimmedEmpty,
        metricsReadAt: item.metricsReadAt?.nilIfTrimmedEmpty
      ))
      if saved { existingURLs.append(canonicalURL) }
      additions += 1
    }
    if updatedCandidates != candidates { candidates = updatedCandidates }
    if let creatorID, !existingURLs.isEmpty {
      attachExisting(creatorID, existingURLs)
    }
    newItemsThisRound += additions
    consecutiveNoNewScreens = additions == 0 ? consecutiveNoNewScreens + 1 : 0

    if newItemsThisRound >= Self.perRoundBudget {
      return finish(.perRoundBudget(newItemsThisRound))
    }
    let emptyLimit = candidates.isEmpty ? Self.initialEmptyScreenLimit : Self.noNewScreenLimit
    if consecutiveNoNewScreens >= emptyLimit {
      return finish(.visibleEnd)
    }
    return .keepLoading
  }

  private func finish(_ reason: DouyinProfileImportStopReason) -> ScanDirective {
    phase = .stopped(reason)
    return .stop(reason)
  }

  /// Saves a legally visible public header even when the works list is blocked.
  /// Nil name/avatar are skipped so an earlier real header is not erased.
  private func applyVisibleProfileMetadata(_ snapshot: DouyinProfileDOMSnapshot) {
    guard let expectedAuthorID = profileAuthorID,
          snapshot.profileAuthorID == nil || snapshot.profileAuthorID == expectedAuthorID
    else { return }
    if let name = snapshot.profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
       CreatorDisplay.isResolvedDisplayName(name, authorID: expectedAuthorID), profileName != name {
      profileName = name
    }
    let avatar = snapshot.profileAvatarURL.flatMap(DouyinProfilePreviewResource.admittedURL)?.absoluteString
    guard let creatorID, profileName != nil || avatar != nil else { return }
    let signature = "\(creatorID.rawValue)\n\(profileName ?? "")\n\(avatar ?? "")"
    guard signature != lastHeaderRefresh else { return }
    lastHeaderRefresh = signature
    refreshCreatorName(creatorID, profileName, avatar)
  }

  func updateMetrics(_ metrics: DouyinProfileWorkMetrics, expectedWorkID: String) {
    guard metrics.status == "ready", metrics.workID == expectedWorkID,
          let index = candidates.firstIndex(where: { $0.workID == expectedWorkID }) else { return }
    if let authorID = metrics.authorID, !authorID.isEmpty, authorID != candidates[index].authorID { return }
    applyMetrics(
      DouyinProfileDOMCandidate(
        url: candidates[index].canonicalURL,
        authorID: candidates[index].authorID,
        previewText: nil,
        coverURL: nil,
        publishedText: nil,
        likes: metrics.likes,
        comments: metrics.comments,
        collects: metrics.collects,
        metricsSource: metrics.source,
        metricsReadAt: metrics.readAt
      ),
      to: &candidates[index]
    )
  }

  /// Existing cards keep identity/order; later list or detail counts fill missing fields in place.
  private func applyMetrics(_ item: DouyinProfileDOMCandidate, to candidate: inout DouyinProfileImportCandidate) {
    let previousLikes = candidate.likes
    let previousComments = candidate.comments
    let previousCollects = candidate.collects
    candidate.likes = item.likes?.nilIfTrimmedEmpty ?? candidate.likes
    candidate.comments = item.comments?.nilIfTrimmedEmpty ?? candidate.comments
    candidate.collects = item.collects?.nilIfTrimmedEmpty ?? candidate.collects
    if candidate.likes != previousLikes || candidate.comments != previousComments || candidate.collects != previousCollects {
      candidate.metricsSource = item.metricsSource?.nilIfTrimmedEmpty ?? candidate.metricsSource
      candidate.metricsReadAt = item.metricsReadAt?.nilIfTrimmedEmpty ?? candidate.metricsReadAt
    }
  }

  func toggleSelection(_ id: String) {
    guard unsavedCandidateIDs.contains(id) else { return }
    if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
  }

  func selectAllLoaded() { selectedIDs = unsavedCandidateIDs }
  func clearSelection() { selectedIDs.removeAll() }

  @discardableResult
  func saveSelected() -> Int {
    let selected = candidates.filter { selectedIDs.contains($0.id) && !$0.wasAlreadySaved }
    guard !selected.isEmpty else { return 0 }
    if discoverySource == .browserExtension { bindCreatorIfNeeded() }
    let outcome: ManualLinkViewModel.ProfileImportEnqueueOutcome
    if let enqueueCandidates {
      let seeds = selected.map { candidate in
        ProfileImportCandidateSeed(
          workID: candidate.workID,
          authorID: candidate.authorID,
          canonicalURL: candidate.canonicalURL,
          captureURL: captureURL(for: candidate),
          previewText: candidate.previewText,
          coverURL: candidate.coverURL?.absoluteString,
          publishedText: candidate.publishedText,
          likes: candidate.likes,
          comments: candidate.comments,
          collects: candidate.collects
        )
      }
      outcome = enqueueCandidates(seeds, downloadsVideo, creatorID)
    } else {
      outcome = enqueue(selected.map { captureURL(for: $0) }, downloadsVideo, creatorID)
    }
    saveMessage = "已加入保存队列 \(outcome.queued) 条，跳过 \(outcome.skipped) 条。失败项可在抓取卡片上单独重试。"
    selectedIDs.removeAll()
    return outcome.queued
  }

  func presentExternalCandidates(_ request: XProfileCandidatesRequest) {
    resolvedPlatform = .x
    input = request.profileURL
    profileAuthorID = request.authorID
    sourceURL = URL(string: request.profileURL)
    if CreatorDisplay.isResolvedDisplayName(request.profileName, authorID: request.authorID) {
      profileName = request.profileName
    }
    candidates = []
    selectedIDs = []
    accessURLs = [:]
    saveMessage = nil
    creatorID = nil
    enterBrowserExtensionSource()
    bindCreatorIfNeeded()
    applyExternalProfileMetadata(request)
    appendExternalItems(request.items, authorID: request.authorID)
  }

  @discardableResult
  func mergeExternalCandidates(_ request: XProfileCandidatesRequest) -> Bool {
    guard platform == .x else { return false }
    let expectedAuthor = profileAuthorID ?? Self.parsedXAuthorID(from: input)
    guard expectedAuthor == request.authorID else { return false }
    if profileAuthorID == nil {
      profileAuthorID = request.authorID
    }
    resolvedPlatform = .x
    if sourceURL == nil {
      sourceURL = URL(string: request.profileURL)
    }
    if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      input = request.profileURL
    }
    enterBrowserExtensionSource()
    if CreatorDisplay.isResolvedDisplayName(request.profileName, authorID: request.authorID) {
      profileName = request.profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    bindCreatorIfNeeded()
    applyExternalProfileMetadata(request)
    appendExternalItems(request.items, authorID: request.authorID)
    return true
  }

  func prepareForBrowserHandoff() {
    guard let route = ProfileImportPlatform.parse(input), route.platform == .x else {
      guard platform == .x, profileAuthorID != nil else { return }
      enterBrowserExtensionSource()
      return
    }
    if case let .profile(_, url, authorID) = route {
      if profileAuthorID == nil { profileAuthorID = authorID }
      if sourceURL == nil { sourceURL = url }
      resolvedPlatform = .x
    }
    enterBrowserExtensionSource()
  }

  private func enterBrowserExtensionSource() {
    discoverySource = .browserExtension
    scanRequestID += 1
    phase = .stopped(.browserExtension)
  }

  func openCurrentProfileInBrowser() {
    prepareForBrowserHandoff()
    guard let sourceURL = sourceURL ?? ProfileImportPlatform.parse(input)?.sourceURL else { return }
    if !NSWorkspace.shared.open(sourceURL) {
      saveMessage = "未能打开默认浏览器，请检查系统设置后重试。"
    }
  }

  static func parsedXAuthorID(from input: String) -> String? {
    guard case let .profile(platform, _, authorID) = ProfileImportPlatform.parse(input), platform == .x else {
      return nil
    }
    return authorID
  }

  private func applyExternalProfileMetadata(_ request: XProfileCandidatesRequest) {
    guard let expectedAuthorID = profileAuthorID, expectedAuthorID == request.authorID else { return }
    if let name = request.profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
       CreatorDisplay.isResolvedDisplayName(name, authorID: expectedAuthorID) {
      profileName = name
    }
    let avatar = XProfileCandidatesRequest.admittedAvatarURL(request.profileAvatarURL)
      .flatMap(DouyinProfilePreviewResource.admittedURL)?.absoluteString
    guard let creatorID, profileName != nil || avatar != nil else { return }
    refreshCreatorName(creatorID, profileName, avatar)
  }

  private func appendExternalItems(_ items: [XProfileCandidatesRequest.Item], authorID: String) {
    var indices = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.workID, $0.offset) })
    var existingURLs: [String] = []
    for item in items {
      if indices[item.id] != nil { continue }
      let saved = alreadySaved(item.url)
      indices[item.id] = candidates.count
      candidates.append(.init(
        workID: item.id,
        authorID: authorID,
        canonicalURL: item.url,
        previewText: item.previewText,
        coverURL: nil,
        publishedText: item.publishedText,
        wasAlreadySaved: saved
      ))
      if saved { existingURLs.append(item.url) }
    }
    if let creatorID, !existingURLs.isEmpty {
      attachExisting(creatorID, existingURLs)
    }
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
    if model.platform == .douyin {
      configuration.userContentController.addUserScript(DouyinProfileMetricsCapture.documentStartUserScript())
    }
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = false
    return view
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.model = model
    if model.discoverySource == .browserExtension {
      context.coordinator.cancelScan()
      return
    }
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
            let result = try await evaluate(self.model.platform == .douyin ? Self.extractionJavaScript : self.model.platform.discoveryScript)
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
            if snapshot.status == "ready", !self.model.candidates.isEmpty {
              _ = try await evaluate(self.model.platform == .douyin ? Self.scrollJavaScript : self.model.platform.advanceScript)
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
      let url = navigationAction.request.url
      if model.platform.allowsNavigation(url) {
        decisionHandler(.allow)
        return
      }
      if navigationAction.targetFrame?.isMainFrame != false {
        model.rejectDisallowedNavigation(url)
      }
      decisionHandler(.cancel)
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

      const nameNode = document.querySelector('[data-e2e="user-title"], [data-e2e="user-name"]');
      const titleMatch = String(document.title || '').match(/^(.+?)的抖音/);
      let profileName = clean(nameNode && nameNode.textContent) || (titleMatch && clean(titleMatch[1])) || null;
      if (profileName && profileAuthorID && profileName.replace(/^@/, '').toLowerCase() === String(profileAuthorID).toLowerCase()) profileName = null;
      const avatarNode = Array.from(document.querySelectorAll(
        '[data-e2e="user-avatar"] img, [data-e2e="user-info"] img, [data-e2e="user-detail"] img'
      )).find(node => isVisible(node) && !node.closest('[data-e2e="user-post-list"], aside, nav, [class*="recommend"]'));
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
        const likeNode = Array.from(metricScope.querySelectorAll('.author-card-user-video-like')).find(isVisible);
        const likeText = clean(likeNode && likeNode.textContent);
        let likes = /^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:万|亿|[kKmMwW])?\+?$/.test(likeText) ? likeText : null;
        let comments = null;
        let collects = null;
        let metricsSource = likes ? 'homepage_dom' : null;
        let metricsReadAt = null;
        const captured = (window.__linkdigestAwemeStats || {})[workMatch[2]];
        if (captured && captured.authorID === authorID) {
          if (captured.likes != null) likes = captured.likes;
          if (captured.comments != null) comments = captured.comments;
          if (captured.collects != null) collects = captured.collects;
          metricsSource = captured.source || 'homepage_list';
          metricsReadAt = captured.observedAt || null;
        }
        candidates.push({
          url: `https://www.douyin.com/${workMatch[1]}/${workMatch[2]}`,
          authorID,
          previewText: preview || null,
          coverURL: coverURL || null,
          publishedText: clean(time && time.textContent) || null,
          likes,
          comments,
          collects,
          metricsSource,
          metricsReadAt
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
  @ObservedObject private var manualLink: ManualLinkViewModel
  @ObservedObject private var xSession = SiteSessionController.x
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  @State private var showsHomepage = false
  @State private var workSort: WorkSortOrder = .original
  @State private var sortReferenceDate = Date()
  @State private var presentedLoginPlatform: ProfileImportPlatform?
  @StateObject private var metricsReader = DouyinProfileMetricsReader()
  @State private var metricsQueue = DouyinProfileVisibleMetricsQueue()
  private let request: DouyinProfileImportRequest
  private let onQueued: (CreatorID) -> Void
  @State private var didApplyRequest = false

  init(manualLink: ManualLinkViewModel, request: DouyinProfileImportRequest,
       onQueued: @escaping (CreatorID) -> Void = { _ in }) {
    let viewModel = DouyinProfileImportViewModel(manualLink: manualLink)
    if !request.initialInput.isEmpty {
      viewModel.input = request.initialInput
    }
    _model = StateObject(wrappedValue: viewModel)
    _manualLink = ObservedObject(wrappedValue: manualLink)
    self.request = request
    self.onQueued = onQueued
  }

  init(external model: DouyinProfileImportViewModel, manualLink: ManualLinkViewModel,
       onQueued: @escaping (CreatorID) -> Void = { _ in }) {
    _model = StateObject(wrappedValue: model)
    _manualLink = ObservedObject(wrappedValue: manualLink)
    self.request = .init(id: UUID(), initialInput: model.input, autoStart: false)
    self.onQueued = onQueued
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
              if model.discoverySource != .browserExtension {
                DouyinProfileImportWebView(model: model, dataStore: model.dataStore)
                  .id(model.platform)
                  .frame(width: 960, height: 480)
                  .allowsHitTesting(showsHomepage)
                  .accessibilityHidden(!showsHomepage)
              }
              if !showsHomepage || model.discoverySource == .browserExtension {
                candidatePanel(availableWidth: geometry.size.width)
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
    .background(theme.card)
    .onChange(of: metricsReader.readingID) { previous, current in
      if let previous, current == nil {
        metricsQueue.finish(previous)
        readNextVisibleMetrics()
      }
    }
    .onChange(of: metricsReader.accessLimit) { _, limit in
      if DouyinProfileMetricsCapture.pausesAutomaticReading(limit) {
        metricsQueue.pause()
      }
    }
    .onChange(of: showsHomepage) { _, shown in
      if shown { metricsQueue.clearVisible() }
    }
    .id(request.id)
    .onAppear {
      manualLink.attachVisibleProfileImport(model)
      guard !didApplyRequest else { return }
      didApplyRequest = true
      if model.input != request.initialInput {
        model.input = request.initialInput
      }
      Task { await refreshVisibleSession() }
      if model.discoverySource == .browserExtension { return }
      if request.autoStart {
        model.start()
      }
    }
    .onChange(of: model.platform) { _, _ in
      Task { await refreshVisibleSession() }
    }
    .onChange(of: sessionPlatform) { _, _ in
      Task { await refreshVisibleSession() }
    }
    .alert(
      "要换成另一个主页吗？",
      isPresented: Binding(
        get: { manualLink.browserProfileImportConflict != nil },
        set: { if !$0 { manualLink.cancelIncomingBrowserProfile() } }
      )
    ) {
      browserProfileConflictButtons(incoming: manualLink.browserProfileImportConflict?.incoming)
    } message: {
      Text(manualLink.browserProfileImportConflict?.message ?? "")
    }
    .sheet(item: $presentedLoginPlatform, onDismiss: {
      Task {
        await refreshVisibleSession()
        if model.sourceURL != nil {
          model.reloadCurrentHomepage()
        }
      }
    }) { platform in
      SiteLoginSheet(session: session(for: platform))
    }
    .onDisappear {
      stopReading()
      model.stop()
      manualLink.detachVisibleProfileImport(model)
    }
  }

  @ViewBuilder
  private func browserProfileConflictButtons(incoming: XProfileCandidatesRequest?) -> some View {
    Button("保留当前勾选") { manualLink.cancelIncomingBrowserProfile() }
    Button("换成新主页", role: .destructive) {
      if let incoming { manualLink.replaceIncomingBrowserProfile(incoming) }
    }
  }

  private var sessionPlatform: ProfileImportPlatform? {
    if model.sourceURL != nil { return model.resolvedPlatform ?? model.platform }
    return ProfileImportPlatform.parse(model.input)?.platform
  }

  private func session(for platform: ProfileImportPlatform) -> SiteSessionController {
    switch platform {
    case .x: xSession
    case .bilibili: bilibiliSession
    case .douyin: douyinSession
    case .xiaohongshu: xiaohongshuSession
    }
  }

  private func refreshVisibleSession() async {
    if let platform = sessionPlatform {
      await session(for: platform).refreshStatus()
    }
  }

  private var sheetHeight: CGFloat {
    if showsHomepage { return 740 }
    if !model.candidates.isEmpty { return model.candidates.count <= 3 ? 560 : 720 }
    return model.sourceURL == nil ? 320 : 300
  }

  private var stageTitle: String {
    if model.sourceURL == nil { return "1. 输入主页" }
    if model.candidates.isEmpty { return "2. 发现作品" }
    return "3. 选择作品"
  }

  private var stageProgressLine: String? {
    if model.sourceURL == nil { return nil }
    if model.isScanning { return "进度：正在加载更多作品…" }
    if model.phase == .loading { return "进度：正在打开主页…" }
    if case .stopped = model.phase {
      return "进度：已暂停 · 已发现 \(model.candidates.count) 条"
    }
    if case .failed = model.phase { return "进度：发现失败，可重试或查看主页" }
    if model.candidates.isEmpty { return "进度：等待作品出现" }
    if model.saveMessage != nil {
      return "进度：已发现 \(model.candidates.count) 条 · 下方显示最近保存结果"
    }
    return "进度：已发现 \(model.candidates.count) 条，可继续加载或保存"
  }

  private var selectionSummary: String {
    let loaded = model.candidates.count
    let alreadySaved = model.candidates.filter(\.wasAlreadySaved).count
    let selectable = model.unsavedCandidateIDs.count
    return "已选 \(model.selectedCount) / 可保存 \(selectable)（已加载 \(loaded)，其中已保存 \(alreadySaved)）"
  }

  private var header: some View {
    HStack(alignment: .top, spacing: DesignTokens.Space.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text("导入博主内容")
          .themedFont(.headline)
        Text(stageTitle)
          .themedFont(.callout, weight: .medium)
          .foregroundStyle(theme.secondaryText)
        if let stageProgressLine {
          Text(stageProgressLine)
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: DesignTokens.Space.sm)
      Button("关闭") { stopReading(); model.stop(); dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, DesignTokens.Space.lg)
    .padding(.vertical, DesignTokens.Space.md)
  }

  private var inputPanel: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("粘贴博主主页链接或分享文案")
        .themedFont(.callout, weight: .medium)
      TextField("主页链接或分享文案", text: $model.input)
        .textFieldStyle(.roundedBorder)
        .onSubmit { if model.canStart { model.start() } }
        .accessibilityIdentifier("douyin-profile-import-input")
      if let validation = model.validationMessage {
        Label(validation, systemImage: "exclamationmark.triangle.fill")
          .themedFont(.caption)
          .foregroundStyle(theme.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("支持主页链接、分享文案、常见手机主页和短链。")
        .themedFont(.caption)
        .foregroundStyle(.secondary)
      sessionStatusRow
      if model.canStart, model.platform == .x {
        Text("也可以使用浏览器中的登录：打开主页后，点击汲作扩展读取作品。")
          .themedFont(.caption).foregroundStyle(.secondary)
      }
      HStack {
        if model.canStart, model.platform == .x {
          Button("在浏览器读取") { model.openCurrentProfileInBrowser() }
            .accessibilityIdentifier("profile-import-browser-start")
        }
        Spacer(minLength: 0)
        Button("发现作品") { model.start() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canStart)
          .accessibilityIdentifier("douyin-profile-import-start")
      }
    }
    .padding(.horizontal, DesignTokens.Space.lg)
    .padding(.vertical, DesignTokens.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var discoveryHeader: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: DesignTokens.Space.md) {
          discoveryIdentity
          Spacer(minLength: DesignTokens.Space.sm)
          discoveryControls
        }
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          discoveryIdentity
          discoveryControls
        }
      }
      sessionStatusRow
      if case let .stopped(reason) = model.phase {
        Label(reason.message, systemImage: "info.circle")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      } else if case let .failed(message) = model.phase {
        Label("\(message) 可点击「查看主页」检查后重试。", systemImage: "exclamationmark.triangle.fill")
          .themedFont(.caption)
          .foregroundStyle(theme.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, DesignTokens.Space.md)
    .padding(.vertical, DesignTokens.Space.sm)
  }

  @ViewBuilder
  private var sessionStatusRow: some View {
    if model.isBrowserSourced {
      Text("来源：浏览器扩展 · 已收到作品清单；浏览器登录与 App 内登录独立。")
        .themedFont(.caption).foregroundStyle(theme.secondaryText)
        .accessibilityIdentifier("profile-import-browser-source")
    } else if let platform = sessionPlatform {
      let current = session(for: platform)
      HStack(spacing: DesignTokens.Space.sm) {
        Text(platform.displayName)
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
        Text(current.isLoggedIn ? "登录已保存" : "未登录")
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(current.isLoggedIn ? theme.success : theme.secondaryText)
          .accessibilityIdentifier("profile-import-session-status")
        Spacer(minLength: 0)
        Button("管理登录") {
          presentedLoginPlatform = platform
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("profile-import-session-login")
      }
    }
  }

  private var discoveryIdentity: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
      Text(model.profileName ?? "\(model.platform.displayName)主页")
        .themedFont(.title3, weight: .semibold)
        .fixedSize(horizontal: false, vertical: true)
      Text("已发现 \(model.candidates.count) 条作品")
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
    }
  }

  private var discoveryControls: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      if model.isScanning || model.phase == .loading {
        ProgressView().controlSize(.small)
        Text(model.isScanning ? "正在加载…" : "正在打开…")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
          .lineLimit(1)
      }
      if model.discoverySource == .browserExtension {
        Button("在浏览器打开当前主页", action: model.openCurrentProfileInBrowser)
          .accessibilityIdentifier("douyin-profile-import-open-browser")
        Button("继续加载", action: model.continueLoading)
      } else {
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
        if model.platform == .x {
          Button("在浏览器读取", action: model.openCurrentProfileInBrowser)
            .accessibilityIdentifier("profile-import-browser-start")
        }
      }
    }
  }

  private func candidatePanel(availableWidth: CGFloat) -> some View {
    let columns = CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)
    return ScrollView {
      if model.candidates.isEmpty {
        VStack(spacing: DesignTokens.Space.sm) {
          Image(systemName: "square.grid.2x2")
            .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
          if model.phase == .loading || model.isScanning {
            Text("正在发现作品")
              .themedFont(.headline)
            Text("作品出现后会显示在这里。")
              .themedFont(.callout)
          } else if case .failed = model.phase {
            Text("发现失败")
              .themedFont(.headline)
            Text("请查看上方说明，或打开主页后重试。")
              .themedFont(.callout)
          } else {
            Text("还没有发现作品")
              .themedFont(.headline)
            Text("如需登录或验证，请点击上方「查看主页」。")
              .themedFont(.callout)
          }
        }
        .foregroundStyle(theme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Space.xl)
        .padding(.horizontal, DesignTokens.Space.lg)
      } else {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: CreatorDirectoryChrome.xGridSpacing, alignment: .top),
            count: columns
          ),
          spacing: CreatorDirectoryChrome.xGridSpacing
        ) {
          ForEach(workSort.sorted(model.candidates, likes: { $0.likes }, published: { $0.publishedText }, referenceDate: sortReferenceDate)) { candidate in
            candidateCard(candidate)
              .onScrollVisibilityChange(threshold: 0.2) { visible in
                metricsQueue.setVisible(candidate.id, visible && !showsHomepage)
                readNextVisibleMetrics()
              }
              .onDisappear { metricsQueue.setVisible(candidate.id, false) }
          }
        }
        .padding(DesignTokens.Space.md)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack {
        Text("仅排序已加载 \(model.candidates.count) 条")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
        Spacer()
        Picker("排序", selection: $workSort) {
          ForEach(WorkSortOrder.allCases) { Text($0.title).tag($0) }
        }
        .frame(width: 220)
        .accessibilityIdentifier("profile-import-work-sort")
        .help("缺失数据排最后；月日按本次读取时最近的该日期排列。只改变展示，不改变勾选或保存顺序。")
      }
      .padding(.horizontal, DesignTokens.Space.md)
      .padding(.vertical, 8)
      .background(theme.canvas)
    }
    .accessibilityIdentifier("douyin-profile-import-candidates")
  }

  private func candidateCard(_ candidate: DouyinProfileImportCandidate) -> some View {
    let selected = model.selectedIDs.contains(candidate.id)
    let unread = CreatorWorkMetricLayout.displayValue(nil).accessibility
    return Button { model.toggleSelection(candidate.id) } label: {
      CreatorWorkCardShell(theme: theme, highlight: selected) {
      CreatorWorkCardCoverSlot {
        DouyinProfilePreviewImage(url: candidate.coverURL, previewText: candidate.previewText)
          .overlay(alignment: .topTrailing) {
            Image(systemName: candidate.wasAlreadySaved ? "checkmark.circle.fill" : (selected ? "checkmark.circle.fill" : "circle"))
              .font(.body)
              .foregroundStyle(candidate.wasAlreadySaved ? theme.success : theme.accent)
              .padding(4)
              .background(theme.card, in: Circle())
              .padding(8)
              .accessibilityHidden(true)
          }
      }
    } text: {
      VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
        CreatorWorkCardTextHeader(
          title: displayTitle(for: candidate),
          dateText: candidate.publishedText?.nilIfTrimmedEmpty ?? "发布时间待获取",
          theme: theme
        )
        CreatorWorkMetricStrip(host: model.platform.host, theme: theme, values: { slot in
          switch slot {
          case .likes: candidate.likes
          case .comments: candidate.comments
          case .collects: candidate.collects
          case .shares, .views: nil
          }
        }, helpSuffix: "选择导入")
      }
    }
    }
    .buttonStyle(.plain)
    .disabled(candidate.wasAlreadySaved)
    .overlay(alignment: .topLeading) {
      GeometryReader { geometry in
        candidateMetricsStatusOverlay(candidate)
          .frame(width: geometry.size.width,
                 height: geometry.size.width / CreatorWorkCardLayout.coverAspect,
                 alignment: .bottomLeading)
      }
    }
    .accessibilityLabel(displayTitle(for: candidate))
    .accessibilityValue("\(candidate.wasAlreadySaved ? "已保存" : (selected ? "已选择" : "未选择"))，点赞 \(candidate.likes ?? unread)，评论 \(candidate.comments ?? unread)，收藏 \(candidate.collects ?? unread)")
  }

  @ViewBuilder
  private func candidateMetricsStatusOverlay(_ candidate: DouyinProfileImportCandidate) -> some View {
    if model.platform == .douyin {
      let complete = hasCompleteMetrics(candidate)
      let message = metricsReader.messages[candidate.id]
      HStack(spacing: 5) {
        if metricsReader.readingID == candidate.id {
          ProgressView().controlSize(.mini)
          Text("补全数据…")
          Button("取消") { metricsReader.cancel() }
            .buttonStyle(.plain)
            .accessibilityLabel("取消补全数据")
        } else {
          Text(complete ? "数据已完整" : (message ?? "等待主页列表数据"))
            .lineLimit(1)
            .help(metricsHelp(candidate, complete: complete, message: message))
          if !complete, message != nil {
            Button {
              metricsQueue.retry(candidate.id)
              readNextVisibleMetrics()
            } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.plain)
              .help("重试读取这条作品的数据")
              .accessibilityLabel("重试读取数据")
              .disabled(metricsReader.readingID != nil)
          } else if complete {
            Image(systemName: "checkmark").foregroundStyle(theme.success)
          }
        }
      }
      .themedFont(.caption2)
      .foregroundStyle(theme.secondaryText)
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(6)
    }
  }

  private func hasCompleteMetrics(_ candidate: DouyinProfileImportCandidate) -> Bool {
    candidate.likes != nil && candidate.comments != nil && candidate.collects != nil
  }

  private func metricsHelp(_ candidate: DouyinProfileImportCandidate, complete: Bool, message: String?) -> String {
    let source: String
    switch candidate.metricsSource {
    case DouyinProfileMetricsSource.homepageList: source = "来源：主页已加载列表"
    case DouyinProfileMetricsSource.homepageDOM: source = "来源：主页卡片"
    case DouyinProfileMetricsSource.detailList, DouyinProfileMetricsSource.detailStructured: source = "来源：作品页数据"
    case DouyinProfileMetricsSource.detailDOM: source = "来源：作品页"
    default: source = complete ? "点赞、评论、收藏已读取" : "主页列表到达后会补全；缺字段才打开作品页"
    }
    if let readAt = candidate.metricsReadAt?.nilIfTrimmedEmpty {
      return "\(source) · 读取于 \(readAt)"
    }
    return message ?? source
  }

  private func readNextVisibleMetrics() {
    guard model.platform == .douyin, !showsHomepage, metricsReader.readingID == nil else { return }
    guard !model.isScanning, model.phase != .loading else { return }
    guard !metricsQueue.isPaused else { return }
    let incomplete = model.candidates.filter { !hasCompleteMetrics($0) }
    guard let id = metricsQueue.next(in: incomplete.map(\.id)),
          let candidate = incomplete.first(where: { $0.id == id }) else { return }
    metricsReader.read(candidate, dataStore: SiteSessionController.douyin.dataStore) { metrics in
      if DouyinProfileMetricsCapture.pausesAutomaticReading(metrics.status) {
        metricsQueue.pause()
      }
      model.updateMetrics(metrics, expectedWorkID: candidate.workID)
    }
    // A complete cache hit finishes synchronously; SwiftUI may coalesce
    // nil -> id -> nil and never deliver the readingID onChange.
    if metricsReader.readingID == nil {
      metricsQueue.finish(id)
      Task { @MainActor in readNextVisibleMetrics() }
    }
  }

  private func stopReading() {
    metricsQueue.stop()
    metricsReader.cancel()
  }

  private func displayTitle(for candidate: DouyinProfileImportCandidate) -> String {
    let title = candidate.previewText ?? "作品 \(candidate.workID)"
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
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DesignTokens.Space.sm) {
          selectionControls
          Spacer(minLength: DesignTokens.Space.md)
          saveControls
        }
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          selectionControls
          saveControls
        }
      }
      Text(selectionSummary)
        .themedFont(.callout, weight: .medium)
        .foregroundStyle(theme.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("douyin-profile-import-selection-summary")
      Text(model.saveMessage ?? "互动数据仅显示页面可确认的值；— 表示尚未读取到数据。保存后可在汲作中查看；总结和转写由你手动发起。")
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("douyin-profile-import-save-result")
    }
    .padding(DesignTokens.Space.md)
  }

  private var selectionControls: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      Button("全选已加载", action: model.selectAllLoaded)
        .disabled(model.unsavedCandidateIDs.isEmpty)
      Button("清空选择", action: model.clearSelection)
        .disabled(model.selectedIDs.isEmpty)
    }
  }

  private var saveControls: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      Toggle("同时下载视频", isOn: $model.downloadsVideo)
        .toggleStyle(.checkbox)
      Button("保存所选 \(model.selectedCount) 条") {
        guard model.saveSelected() > 0, let creatorID = model.creatorID else { return }
        stopReading()
        model.stop()
        onQueued(creatorID)
        dismiss()
      }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedIDs.isEmpty)
        .accessibilityIdentifier("douyin-profile-import-save")
    }
  }
}
