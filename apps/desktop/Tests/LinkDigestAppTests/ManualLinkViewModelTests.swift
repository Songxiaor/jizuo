import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
@testable import LinkDigestCore

private actor ManualVMCommitGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func enterAndWaitForRelease() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    waiters.forEach { $0.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitForEntry() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    guard !released else { return }
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private final class ManualVMBlockingCommit: @unchecked Sendable {
  private let gate: ManualVMCommitGate

  init(gate: ManualVMCommitGate) { self.gate = gate }

  func block() {
    let released = DispatchSemaphore(value: 0)
    Task.detached { [gate] in
      await gate.enterAndWaitForRelease()
      released.signal()
    }
    released.wait()
  }
}

private final class ManualVMWriteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

private final class ManualVMRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let lock = NSLock()
  private let blockingCommit: ManualVMBlockingCommit?
  private var accepted: [CapturedDocument] = []
  private var existingCanonicalURLs: Set<String>
  private var canonicalLookupCount = 0
  private var canonicalLookupFailure: RepositoryFailure?
  init(blockingCommit: ManualVMBlockingCommit? = nil, existingCanonicalURLs: Set<String> = []) {
    self.blockingCommit = blockingCommit
    self.existingCanonicalURLs = existingCanonicalURLs
  }
  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    blockingCommit?.block()
    lock.withLock { accepted.append(command.document) }
    return .init(taskID: TaskID(), snapshotID: ContentSnapshotID(), taskWasCreated: true, snapshotWasCreated: true, deliveryWasReplayed: false)
  }
  var acceptedDocuments: [CapturedDocument] { lock.withLock { accepted } }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws { throw RepositoryFailure.invalidInput }
  func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw RepositoryFailure.invalidInput }
  func finishRun(_: FinishRunCommand) throws { throw RepositoryFailure.invalidInput }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func containsCanonicalURL(_ canonicalURL: CanonicalURL) throws -> Bool {
    try lock.withLock {
      canonicalLookupCount += 1
      if let canonicalLookupFailure { throw canonicalLookupFailure }
      return existingCanonicalURLs.contains(canonicalURL.value)
    }
  }
  var lookupCount: Int { lock.withLock { canonicalLookupCount } }
  func addCanonicalURL(_ value: String) { _ = lock.withLock { existingCanonicalURLs.insert(value) } }
  func failCanonicalLookup(with failure: RepositoryFailure) { lock.withLock { canonicalLookupFailure = failure } }
  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage { throw RepositoryFailure.notFound }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.notFound }
}

private final class ManualVMClipboard: ClipboardReading, @unchecked Sendable {
  private var value: String?; private let lock = NSLock(); private var count = 0
  init(_ value: String?) { self.value = value }
  func string() -> String? { lock.withLock { count += 1 }; return value }
  var reads: Int { lock.withLock { count } }
  func set(_ value: String?) { lock.withLock { self.value = value } }
}

private struct ManualVMFetcher: WebPageFetcher {
  func fetch(url: URL) async throws -> WebPageFetchResult {
    .init(url: url, html: "<article>Manual view model fixture has enough article words to be extracted.</article>", contentType: "text/html")
  }
}

private final class ManualVMTrackingFetcher: WebPageFetcher, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URL] = []

  func fetch(url: URL) async throws -> WebPageFetchResult {
    lock.withLock { values.append(url) }
    return .init(
      url: url,
      html: "<article>Generic server route keeps its existing extraction behavior.</article>",
      contentType: "text/html"
    )
  }

  var fetchedURLs: [URL] { lock.withLock { values } }
}

private struct ManualVMDouyinShellAdapter: SourceAdapting {
  func takesOwnership(of url: URL) -> Bool { DouyinURL.matches(url) }
  func capture(url _: URL) async throws -> CapturedDocument {
    throw ManualLinkError.extensionCaptureRequired
  }
}

@MainActor
private final class ManualVMDouyinCapture: DouyinWebCapturing {
  private(set) var capturedURLs: [URL] = []

  func capture(url: URL) async throws -> CapturedDocument {
    capturedURLs.append(url)
    return CapturedDocument(
      createdAt: "2026-07-27T00:00:00Z",
      origin: .manualLink,
      url: "https://www.douyin.com/video/7661288207509769506",
      title: "食伤生财真相：盲派讲透",
      platform: "douyin",
      method: "douyin_rendered_webkit",
      text: """
        ---
        author: "青山言"
        aweme_id: "7661288207509769506"
        ---

        # 食伤生财真相：盲派讲透
        """,
      completeness: "best_effort",
      capturedAt: "2026-07-27T00:00:00Z",
      sourceLabel: "fixture"
    )
  }
}

@MainActor
private final class ManualVMWeChatCapture: WeChatWebCapturing {
  private(set) var capturedURLs: [URL] = []
  private let result: CapturedDocument?

  init(result: CapturedDocument? = nil) { self.result = result }

  func capture(url: URL) async throws -> CapturedDocument {
    capturedURLs.append(url)
    if let result { return result }
    return CapturedDocument(
      createdAt: "2026-07-21T00:00:00Z",
      origin: .manualLink,
      url: url.absoluteString,
      title: "WeChat fixture",
      platform: "wechat",
      method: "wkwebview_inline_js",
      text: "Rendered WeChat fixture body.",
      completeness: "best_effort",
      capturedAt: "2026-07-21T00:00:00Z",
      sourceLabel: "手动链接（公众号内置网页）"
    )
  }
}

private final class ManualVMGitHubResource: SafeResourceFetching, @unchecked Sendable {
  private let values: [String: SafeResourceResponse]
  init(_ values: [String: SafeResourceResponse]) { self.values = values }
  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    values[request.url.absoluteString] ?? .init(url: request.url, statusCode: 404, contentType: "application/json", body: Data())
  }
}

private actor ManualVMSink {
  private(set) var values: [CurrentCapture] = []
  private var valueWaiters: [CheckedContinuation<[CurrentCapture], Never>] = []

  func receive(_ value: CurrentCapture) {
    values.append(value)
    let waiters = valueWaiters
    valueWaiters.removeAll()
    waiters.forEach { $0.resume(returning: values) }
  }

  func waitForValues(count: Int) async -> [CurrentCapture] {
    guard values.count < count else { return values }
    return await withCheckedContinuation { valueWaiters.append($0) }
  }

  func snapshot() -> [CurrentCapture] { values }
}

@MainActor
final class ManualLinkViewModelTests: XCTestCase {
  /// The whole point of the feature is "copy a link in WeChat, come back here".
  /// On macOS that app switch does not move `scenePhase`, so wiring the check to
  /// scenePhase alone made the banner fire once at launch and never again —
  /// which is exactly how it shipped and failed. App activation must re-check
  /// even though scenePhase never left `.active`.
  func testReturningToTheAppRechecksTheClipboardEvenWhenScenePhaseNeverChanged() {
    let clipboard = ManualVMClipboard("https://example.test/first")
    let model = makeModel(clipboard: clipboard)

    model.handleScenePhase(.active)
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/first")

    // User leaves, copies something else, comes back. scenePhase stays .active.
    model.ignoreClipboardSuggestion()
    clipboard.set("https://example.test/second")
    model.handleApplicationDidBecomeActive()

    XCTAssertEqual(clipboard.reads, 2, "Activation must trigger a fresh read")
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/second")
  }

  func testActivationStillDropsNonURLClipboardWithoutPublishingIt() {
    let clipboard = ManualVMClipboard("我的验证码是 482913，请勿告诉他人")
    let model = makeModel(clipboard: clipboard)

    model.handleApplicationDidBecomeActive()

    XCTAssertNil(model.clipboardSuggestion, "Non-URL clipboard text must never surface")
    XCTAssertEqual(model.input, "")
    XCTAssertEqual(model.state, .idle)
  }

  func testActiveSceneReadsOnceAndDropsNonHTTPSClipboardWithoutPublishingIt() {
    let clipboard = ManualVMClipboard("https://Example.test/article#private")
    let model = makeModel(clipboard: clipboard)

    model.handleScenePhase(.active)
    model.handleScenePhase(.active)

    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/article")
    XCTAssertEqual(model.clipboardSuggestion?.host, "example.test")
    XCTAssertEqual(model.input, "")
    XCTAssertEqual(model.state, .idle)

    model.handleScenePhase(.background)
    clipboard.set("http://example.test/private")
    model.handleScenePhase(.active)
    XCTAssertEqual(clipboard.reads, 2)
    XCTAssertNil(model.clipboardSuggestion)
    XCTAssertEqual(model.input, "")
    XCTAssertEqual(model.state, .idle)
  }

  func testIgnoreResetsWhenClipboardChangesAndHistoryCanonicalMatchNeverPrompts() {
    let clipboard = ManualVMClipboard("https://example.test/first")
    let repository = ManualVMRepository(existingCanonicalURLs: ["https://example.test/already"])
    let model = makeModel(clipboard: clipboard, repository: repository)

    model.handleScenePhase(.active)
    model.ignoreClipboardSuggestion()
    XCTAssertNil(model.clipboardSuggestion)

    model.handleScenePhase(.background)
    clipboard.set("https://example.test/second")
    model.handleScenePhase(.active)
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/second")

    model.handleScenePhase(.background)
    clipboard.set("https://example.test/first")
    model.handleScenePhase(.active)
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/first")

    model.handleScenePhase(.background)
    clipboard.set("https://EXAMPLE.test/already#fragment")
    model.handleScenePhase(.active)
    XCTAssertNil(model.clipboardSuggestion)
    XCTAssertGreaterThanOrEqual(repository.lookupCount, 3)
  }

  func testIgnoreSurvivesBackgroundAndActiveWithoutASecondLookupForUnchangedClipboard() {
    let clipboard = ManualVMClipboard("https://example.test/first")
    let repository = ManualVMRepository()
    let model = makeModel(clipboard: clipboard, repository: repository)
    model.handleScenePhase(.active)
    model.ignoreClipboardSuggestion()
    XCTAssertEqual(repository.lookupCount, 1)

    model.handleScenePhase(.background)
    model.handleScenePhase(.active)
    XCTAssertEqual(clipboard.reads, 2)
    XCTAssertEqual(repository.lookupCount, 1)
    XCTAssertNil(model.clipboardSuggestion)
  }

  func testLookupFailureAndSensitiveClipboardTextFailClosedWithoutPublishingOrWriting() {
    let failingClipboard = ManualVMClipboard("https://example.test/private")
    let failingRepository = ManualVMRepository()
    failingRepository.failCanonicalLookup(with: .unavailable)
    let failingModel = makeModel(clipboard: failingClipboard, repository: failingRepository)
    failingModel.handleScenePhase(.active)
    XCTAssertEqual(failingClipboard.reads, 1)
    XCTAssertEqual(failingRepository.lookupCount, 1)
    XCTAssertNil(failingModel.clipboardSuggestion)
    XCTAssertEqual(failingModel.input, "")
    XCTAssertNil(failingModel.errorMessage)
    XCTAssertTrue(failingRepository.acceptedDocuments.isEmpty)

    let sensitiveClipboard = ManualVMClipboard("验证码 840193 password=not-a-url")
    let sensitiveRepository = ManualVMRepository()
    let sensitiveModel = makeModel(clipboard: sensitiveClipboard, repository: sensitiveRepository)
    sensitiveModel.handleScenePhase(.active)
    XCTAssertEqual(sensitiveClipboard.reads, 1)
    XCTAssertEqual(sensitiveRepository.lookupCount, 0)
    XCTAssertNil(sensitiveModel.clipboardSuggestion)
    XCTAssertEqual(sensitiveModel.input, "")
    XCTAssertNil(sensitiveModel.errorMessage)
    XCTAssertTrue(sensitiveRepository.acceptedDocuments.isEmpty)
  }

  func testActiveBeforeConfigureDefersExactLookupWithoutSecondClipboardRead() {
    let clipboard = ManualVMClipboard("https://example.test/deferred")
    let repository = ManualVMRepository()
    let model = ManualLinkViewModel(captureService: .init(fetcher: ManualVMFetcher()), clipboard: clipboard)
    model.handleScenePhase(.active)
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(repository.lookupCount, 0)
    XCTAssertNil(model.clipboardSuggestion)

    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { _ in })
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(repository.lookupCount, 1)
    XCTAssertEqual(model.clipboardSuggestion?.canonicalURL, "https://example.test/deferred")
  }

  func testCaptureRechecksHistoryAndDoesNotFetchWhenSuggestionBecameExisting() {
    let clipboard = ManualVMClipboard("https://mp.weixin.qq.com/s/late-history")
    let genericFetcher = ManualVMTrackingFetcher()
    let weChatCapture = ManualVMWeChatCapture()
    let repository = ManualVMRepository()
    let model = ManualLinkViewModel(captureService: .init(fetcher: genericFetcher), weChatCapture: weChatCapture, clipboard: clipboard)
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { _ in })
    model.handleScenePhase(.active)
    repository.addCanonicalURL("https://mp.weixin.qq.com/s/late-history")

    model.captureClipboardSuggestion()
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertNil(model.clipboardSuggestion)
    XCTAssertEqual(model.input, "")
    XCTAssertFalse(model.isPresented)
    XCTAssertTrue(weChatCapture.capturedURLs.isEmpty)
    XCTAssertTrue(genericFetcher.fetchedURLs.isEmpty)
    XCTAssertTrue(repository.acceptedDocuments.isEmpty)
  }

  func testCaptureRecheckFailureDismissesSuggestionWithoutClipboardReadOrCapture() {
    let clipboard = ManualVMClipboard("https://mp.weixin.qq.com/s/recheck-failure")
    let genericFetcher = ManualVMTrackingFetcher()
    let weChatCapture = ManualVMWeChatCapture()
    let repository = ManualVMRepository()
    let model = ManualLinkViewModel(captureService: .init(fetcher: genericFetcher), weChatCapture: weChatCapture, clipboard: clipboard)
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { _ in })
    model.handleScenePhase(.active)
    XCTAssertNotNil(model.clipboardSuggestion)
    repository.failCanonicalLookup(with: .unavailable)

    model.captureClipboardSuggestion()
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertNil(model.clipboardSuggestion)
    XCTAssertEqual(model.input, "")
    XCTAssertEqual(model.state, .idle)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isPresented)
    XCTAssertTrue(weChatCapture.capturedURLs.isEmpty)
    XCTAssertTrue(genericFetcher.fetchedURLs.isEmpty)
    XCTAssertTrue(repository.acceptedDocuments.isEmpty)
  }

  func testClipboardSuggestionCaptureDoesNotReadAgainAndUsesExistingWeChatAndGenericRoutes() async {
    let clipboard = ManualVMClipboard("https://mp.weixin.qq.com/s/rendered")
    let genericFetcher = ManualVMTrackingFetcher()
    let weChatCapture = ManualVMWeChatCapture()
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(captureService: .init(fetcher: genericFetcher), weChatCapture: weChatCapture, clipboard: clipboard)
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { await sink.receive($0) })

    model.handleScenePhase(.active)
    model.captureClipboardSuggestion()
    _ = await sink.waitForValues(count: 1)
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(weChatCapture.capturedURLs.map(\.absoluteString), ["https://mp.weixin.qq.com/s/rendered"])
    XCTAssertTrue(genericFetcher.fetchedURLs.isEmpty)
    for _ in 0..<100 where model.isBusy { await Task.yield() }
    XCTAssertFalse(model.isBusy)

    model.handleScenePhase(.background)
    clipboard.set("https://example.test/article")
    model.handleScenePhase(.active)
    model.captureClipboardSuggestion()
    _ = await sink.waitForValues(count: 2)
    XCTAssertEqual(clipboard.reads, 2)
    XCTAssertEqual(genericFetcher.fetchedURLs.map(\.absoluteString), ["https://example.test/article"])
  }

  func testWeChatUsesRenderedBackendWhileOtherHostsKeepGenericFetcher() async {
    let genericFetcher = ManualVMTrackingFetcher()
    let weChatCapture = ManualVMWeChatCapture()
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(
      captureService: .init(fetcher: genericFetcher),
      weChatCapture: weChatCapture,
      clipboard: ManualVMClipboard(nil)
    )
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    model.open()
    model.input = "https://mp.weixin.qq.com/s/rendered"
    model.submit()
    _ = await sink.waitForValues(count: 1)
    XCTAssertEqual(weChatCapture.capturedURLs.map(\.absoluteString), ["https://mp.weixin.qq.com/s/rendered"])
    XCTAssertTrue(genericFetcher.fetchedURLs.isEmpty)
    XCTAssertEqual(repository.acceptedDocuments.first?.method, "wkwebview_inline_js")

    model.open()
    model.input = "https://example.test/article"
    model.submit()
    _ = await sink.waitForValues(count: 2)
    XCTAssertEqual(genericFetcher.fetchedURLs.map(\.absoluteString), ["https://example.test/article"])
    XCTAssertEqual(weChatCapture.capturedURLs.count, 1)
  }

  func testWeChatFetchingUsesMinimalProgressMessage() {
    let model = makeModel(clipboard: ManualVMClipboard(nil))
    model.input = "https://mp.weixin.qq.com/s/article"
    XCTAssertEqual(model.fetchingMessage, "正在抓取…")
    model.input = "https://example.test/article"
    XCTAssertEqual(model.fetchingMessage, "正在安全读取网页…")
  }

  func testRemoteImageStagingKeepsSubstantiveWeChatArticlesWithEmbeddedVideo() {
    let article = capturedDocument(
      platform: "wechat",
      text: "公众号正文有足够的实质内容，并且包含一张正文图片和一个内嵌视频。这里继续补充真实段落，用于确认文章主体不是封面或视频海报。",
      hasMedia: true
    )
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.allows(article))
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(platform: "wechat", text: "短文", hasMedia: true)))
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(
      platform: "wechat",
      text: "![](https://mmbiz.qpic.cn/mmbiz_jpg/this-is-a-very-long-image-only-cdn-path/640?wx_fmt=jpeg)",
      hasMedia: true
    )))
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(platform: "douyin", text: article.text, hasMedia: true)))
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(platform: "generic", text: article.text, hasMedia: true)))
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(platform: "generic", text: article.text, hasMedia: false)))

    // 抖音图文帖（无视频 media，正文内联 douyinpic 图片）应放行图片下载；
    // 抖音视频帖或纯文字帖不放行。
    let imagePost = capturedDocument(
      platform: "douyin",
      text: "# 韩系穿搭合集\n\n今天分享几套 OOTD。\n\n![](https://p3-sign.douyinpic.com/tos-cn-i-0813c001/abc.webp?x=1)\n\n![](https://p6-sign.douyinpic.com/tos-cn-i-0813c001/def.webp?y=2)",
      hasMedia: false
    )
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.allows(imagePost))
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.isDouyinImagePost(imagePost))
    // 图文帖有视频 media 时不算图文帖。
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(
      platform: "douyin", text: imagePost.text, hasMedia: true
    )))
    // 抖音纯文字帖（无 douyinpic 图片）不放行。
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.allows(capturedDocument(
      platform: "douyin", text: "# 视频标题\n\n一段文案", hasMedia: false
    )))

    // X 帖子的正文图片（含引用配图）来自 pbs.twimg.com，即使帖子带视频也要下载。
    let xWithVideoAndImage = capturedDocument(
      platform: "x",
      text: "正文\n\n![](https://pbs.twimg.com/media/abc.jpg)",
      hasMedia: true
    )
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.allows(xWithVideoAndImage))
    XCTAssertTrue(RemoteMarkdownImageStagingPolicy.isXPostWithBodyImages(xWithVideoAndImage))
    // 纯文字 X 帖子（无图）走原有分支：无 media 时仍放行、有 media 时不放行。
    XCTAssertFalse(RemoteMarkdownImageStagingPolicy.isXPostWithBodyImages(
      capturedDocument(platform: "x", text: "只有文字", hasMedia: true)
    ))
  }

  func testWeChatImageFailureIsFailOpenAndStillCommitsArticle() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-wechat-manual.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = CapturedDocument(
      createdAt: "2026-07-21T00:00:00Z",
      origin: .manualLink,
      url: "https://mp.weixin.qq.com/s/article",
      title: "Fixture",
      platform: "wechat",
      method: "wkwebview_inline_js",
      text: "---\naccount_name: \"公众号\"\ncover_image: \"https://mmbiz.qpic.cn/cover.png\"\n---\n\n这是一段足够长的公众号正文，用来确认图片下载失败时仍然可以保存文章本身，而不是把增强资源当作正文入库的前置条件。\n\n![](https://mmbiz.qpic.cn/body.png)",
      completeness: "best_effort",
      capturedAt: "2026-07-21T00:00:00Z",
      sourceLabel: "fixture"
    )
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(
      captureService: .init(fetcher: ManualVMFetcher()),
      weChatCapture: ManualVMWeChatCapture(result: document),
      clipboard: ManualVMClipboard(nil),
      imageCache: GitHubREADMEImageCache(applicationSupportRoot: root),
      imageResources: ManualVMGitHubResource([:])
    )
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { await sink.receive($0) })
    model.open(); model.input = document.url; model.submit()
    _ = await sink.waitForValues(count: 1)
    XCTAssertEqual(repository.acceptedDocuments.count, 1)
    XCTAssertEqual(repository.acceptedDocuments.first?.text, document.text)
  }

  func testClipboardIsReadOnlyOnExplicitClickAndInvalidValueShowsSafeError() {
    let clipboard = ManualVMClipboard("not a URL")
    let model = makeModel(clipboard: clipboard)
    XCTAssertEqual(clipboard.reads, 0)
    model.open()
    XCTAssertEqual(clipboard.reads, 0)
    model.readClipboardAndOpen()
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.errorMessage, "剪贴板里的内容不是有效网页链接。")
  }

  func testExplicitClipboardReadExtractsTheSingleURLFromDouyinShareText() {
    let clipboard = ManualVMClipboard(
      "1.53 复制打开抖音，看看【呜呼bomb的图文作品】非常推荐git上这个讲Harness的课程《lea... https://v.douyin.com/ez9W9I65x-U/ QxF:/ Q@k.Ch 04/17 :7pm"
    )
    let model = makeModel(clipboard: clipboard)

    model.readClipboardAndOpen()

    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(model.input, "https://v.douyin.com/ez9W9I65x-U/")
    XCTAssertTrue(model.isPresented)
    XCTAssertNil(model.errorMessage)
  }

  func testHistoricalRecapturePrefillsExistingCaptureSheetWithoutReadingClipboard() {
    let clipboard = ManualVMClipboard("https://private.example.test/clipboard")
    let model = makeModel(clipboard: clipboard)

    model.openForRecapture("https://www.douyin.com/note/7673819714897187302")

    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.input, "https://www.douyin.com/note/7673819714897187302")
    XCTAssertEqual(model.state, .idle)
    XCTAssertEqual(clipboard.reads, 0)
  }

  func testAutomaticClipboardSuggestionDoesNotPublishDouyinShareText() {
    let clipboard = ManualVMClipboard(
      "复制打开抖音 https://v.douyin.com/UX1kjPiekmQ/ 这段文字不应自动显示"
    )
    let model = makeModel(clipboard: clipboard)

    model.handleApplicationDidBecomeActive()

    XCTAssertNil(model.clipboardSuggestion)
    XCTAssertEqual(model.input, "")
  }

  func testManualSubmitQueuesOnlyTheURLExtractedFromShareText() async {
    let tracker = ManualVMTrackingFetcher()
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(
      captureService: .init(fetcher: tracker),
      clipboard: ManualVMClipboard(nil)
    )
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    model.open()
    model.input =
      "4.82 复制打开抖音，看看【青山言的作品】 https://v.douyin.com/UX1kjPiekmQ/ 01/12 h@o.QK :8pm YMj:/"
    model.submit()
    _ = await sink.waitForValues(count: 1)

    XCTAssertEqual(tracker.fetchedURLs.map(\.absoluteString), ["https://v.douyin.com/UX1kjPiekmQ/"])
    XCTAssertEqual(repository.acceptedDocuments.first?.url, "https://v.douyin.com/UX1kjPiekmQ/")
  }

  func testDouyinPublicShellFallsBackToRenderedCapture() async {
    let rendered = ManualVMDouyinCapture()
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(
      captureService: .init(
        fetcher: ManualVMFetcher(),
        sourceAdapters: [ManualVMDouyinShellAdapter()]
      ),
      douyinCapture: rendered,
      clipboard: ManualVMClipboard(nil)
    )
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { await sink.receive($0) }
    )

    model.open()
    model.input =
      "复制打开抖音【青山言的作品】 https://v.douyin.com/UX1kjPiekmQ/ 01/12"
    model.submit()
    _ = await sink.waitForValues(count: 1)

    XCTAssertEqual(rendered.capturedURLs.map(\.absoluteString), ["https://v.douyin.com/UX1kjPiekmQ/"])
    XCTAssertEqual(repository.acceptedDocuments.first?.url, "https://www.douyin.com/video/7661288207509769506")
    XCTAssertEqual(repository.acceptedDocuments.first?.method, "douyin_rendered_webkit")
  }

  func testShareTextWithMultipleWebLinksFailsClosed() {
    let model = makeModel(clipboard: ManualVMClipboard(nil))
    model.open()
    model.input = "比较 https://example.test/one 和 https://example.test/two"

    model.submit()

    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.errorMessage, "请输入一条完整网页链接，或只包含一条链接的分享文案。")
    XCTAssertTrue(model.pendingCaptures.isEmpty)
  }

  func testManualSubmitCommitsThenPublishesManualDocument() async {
    let clipboard = ManualVMClipboard(nil)
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = makeModel(clipboard: clipboard, repository: repository, sink: sink)
    let sheetClosed = expectation(description: "sheet closes after publication")
    let presentationObserver = model.$isPresented.dropFirst().sink {
      if !$0 { sheetClosed.fulfill() }
    }
    model.open(); model.input = "https://example.test/article"; model.submit()
    let published = await sink.waitForValues(count: 1)
    await fulfillment(of: [sheetClosed], timeout: 1)
    presentationObserver.cancel()
    XCTAssertEqual(repository.acceptedDocuments.count, 1)
    XCTAssertEqual(repository.acceptedDocuments.first?.origin, .manualLink)
    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(published.first?.document.origin, .manualLink)
    XCTAssertFalse(model.isPresented)
    XCTAssertEqual(model.state, .idle)
  }

  func testGitHubReadmeFixtureFlowsThroughManualIngestWithMarkdownBody() async {
    let api = URL(string: "https://api.github.com/repos/octo/learning/readme")!
    let resource = ManualVMGitHubResource([
      api.absoluteString: .init(url: api, statusCode: 200, contentType: "text/plain", body: Data("# Learning\n\nREADME body for summary.".utf8))
    ])
    let adapter = GitHubRepositorySourceAdapter(resources: resource)
    let repository = ManualVMRepository()
    let sink = ManualVMSink()
    let model = ManualLinkViewModel(
      captureService: .init(fetcher: ManualVMFetcher(), sourceAdapters: [adapter]),
      clipboard: ManualVMClipboard(nil)
    )
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { await sink.receive($0) })
    model.open(); model.input = "https://github.com/octo/learning"; model.submit()
    let published = await sink.waitForValues(count: 1)
    XCTAssertEqual(repository.acceptedDocuments.first?.text, "# Learning\n\nREADME body for summary.")
    XCTAssertEqual(published.first?.document.method, "github_readme_api")
    XCTAssertEqual(published.first?.document.platform, "github")
  }

  /// 队列化契约（2026-07-24）：提交即入队关窗；保存进行中体现在队列条目的
  /// saving 阶段，发布仍必须等 commit 返回；成功后条目移出队列。
  func testQueuedSubmitClosesSheetImmediatelyAndPublishesOnlyAfterCommit() async {
    let commitGate = ManualVMCommitGate()
    let repository = ManualVMRepository(blockingCommit: .init(gate: commitGate))
    let sink = ManualVMSink()
    let model = makeModel(clipboard: ManualVMClipboard(nil), repository: repository, sink: sink)

    model.open(); model.input = "https://example.test/article"; model.submit()

    // 入队即关窗：用户不再守着弹窗等待。
    XCTAssertFalse(model.isPresented)
    XCTAssertEqual(model.input, "")
    XCTAssertEqual(model.pendingCaptures.count, 1)

    await commitGate.waitForEntry()
    XCTAssertEqual(model.pendingCaptures.first?.phase, .saving)
    let valuesBeforeCommit = await sink.snapshot()
    XCTAssertTrue(valuesBeforeCommit.isEmpty, "CurrentCapture must not publish before commit returns")
    XCTAssertTrue(repository.acceptedDocuments.isEmpty, "the repository has not committed the document")

    await commitGate.release()
    let published = await sink.waitForValues(count: 1)

    XCTAssertEqual(repository.acceptedDocuments.count, 1)
    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(published.first?.document.origin, .manualLink)
    // 成功后条目移出队列。
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(2)
    while !model.pendingCaptures.isEmpty, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(model.pendingCaptures.isEmpty)
    XCTAssertEqual(model.state, .idle)
  }

  func testQueuedCaptureCancellationDoesNotRunWriteOperation() async throws {
    let storageWriteGate = StorageWriteGate(initialAvailability: .writable)
    let commitGate = ManualVMCommitGate()
    let blockingCommit = ManualVMBlockingCommit(gate: commitGate)
    let queuedWrites = ManualVMWriteCounter()
    let first = Task {
      try await storageWriteGate.performCaptureWrite(
        operation: { blockingCommit.block() },
        mapFailure: { _ in .writeFailed }
      )
    }
    await commitGate.waitForEntry()

    let queued = Task {
      try await storageWriteGate.performCaptureWrite(
        operation: { queuedWrites.increment() },
        mapFailure: { _ in .writeFailed }
      )
    }
    await storageWriteGate.waitForQueuedCaptureAttempt()
    queued.cancel()
    do {
      try await queued.value
      XCTFail("a queued capture must finish as cancelled")
    } catch is CancellationError {
      // Expected: cancellation removes the waiter before repository work begins.
    }
    XCTAssertEqual(queuedWrites.count, 0)

    await commitGate.release()
    try await first.value
    XCTAssertEqual(queuedWrites.count, 0)
  }

  func testEnqueueXBookmarksSkipsInvalidAndInBatchDuplicatesAndQueuesTheRest() {
    let repository = ManualVMRepository()
    let model = ManualLinkViewModel(captureService: .init(fetcher: ManualVMFetcher()), clipboard: ManualVMClipboard(nil))
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 }, captureSink: { _ in }
    )
    let outcome = model.enqueueXBookmarks([
      "2080312096865271866",
      "2080312096865271866", // 滚动重复采到，跳过
      "not-a-number",        // 非法 id，跳过
      "1234567890123",
    ])
    XCTAssertEqual(outcome.queued, 2)
    XCTAssertEqual(outcome.skipped, 2)
    XCTAssertEqual(model.pendingCaptures.count, 2)
    // 队列里是 x.com 状态链接，抓取时会走 X 解析分支。
    XCTAssertTrue(model.pendingCaptures.allSatisfy { $0.urlString.hasPrefix("https://x.com/i/status/") })
  }

  func testEnqueueXBookmarksSilentlySkipsWhatIsAlreadyInLibrary() throws {
    // 已在库的推文全部静默跳过——批量场景不能对每条弹重复确认框。
    let seeded = try CanonicalURL("https://x.com/i/status/1234567890123").value
    let repository = ManualVMRepository(existingCanonicalURLs: [seeded])
    let model = ManualLinkViewModel(captureService: .init(fetcher: ManualVMFetcher()), clipboard: ManualVMClipboard(nil))
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 }, captureSink: { _ in }
    )
    let outcome = model.enqueueXBookmarks(["1234567890123"])
    XCTAssertEqual(outcome, .init(queued: 0, skipped: 1))
    XCTAssertTrue(model.pendingCaptures.isEmpty)
  }

  func testInvalidNonemptyInputExplainsWhySubmitIsDisabled() {
    let model = makeModel(clipboard: ManualVMClipboard(nil))
    model.input = "这不是网页链接"
    XCTAssertFalse(model.canSubmit)
    XCTAssertEqual(
      model.inputValidationMessage,
      "请输入一条完整网页链接，或只包含一条链接的分享文案。"
    )

    model.input = "https://example.test/article"
    XCTAssertTrue(model.canSubmit)
    XCTAssertNil(model.inputValidationMessage)
  }

  func testAutomaticModelCallDisclosureCountsIndependentRemoteSteps() {
    XCTAssertEqual(
      AutomaticModelCallDisclosure(
        autoSummarize: true,
        autoMindMap: true,
        mayAutoTidyVideoTranscript: false
      ).message,
      "添加后将自动抓取并执行总结、脑图，预计产生 2 次模型调用。可在设置的「生成偏好」里关闭。"
    )
    XCTAssertNil(
      AutomaticModelCallDisclosure(
        autoSummarize: false,
        autoMindMap: false,
        mayAutoTidyVideoTranscript: false
      ).message
    )
    XCTAssertTrue(
      AutomaticModelCallDisclosure(
        autoSummarize: false,
        autoMindMap: false,
        mayAutoTidyVideoTranscript: true
      ).message?.contains("额外产生 1 次模型调用") == true
    )
  }

  private func makeModel(clipboard: ManualVMClipboard, repository: ManualVMRepository = ManualVMRepository(), sink: ManualVMSink = ManualVMSink()) -> ManualLinkViewModel {
    let model = ManualLinkViewModel(captureService: .init(fetcher: ManualVMFetcher()), clipboard: clipboard)
    model.configure(history: HistoryApplicationService(repository: repository), storageWriteGate: StorageWriteGate(initialAvailability: .writable), nowMilliseconds: { 1 }, captureSink: { await sink.receive($0) })
    return model
  }

  private func capturedDocument(platform: String, text: String, hasMedia: Bool) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-07-21T00:00:00Z",
      origin: .browserCapture,
      url: platform == "wechat" ? "https://mp.weixin.qq.com/s/demo" : "https://example.test/item",
      title: "Fixture",
      platform: platform,
      method: "rendered_dom",
      text: text,
      completeness: "full_article",
      capturedAt: "2026-07-21T00:00:00Z",
      sourceLabel: "fixture",
      media: hasMedia ? CaptureMedia(platform: platform, videoURL: "https://media.example.test/video.mp4") : nil
    )
  }
}

/// 从中文正文里复制链接时，末尾常带一个「。」或「，」。
///
/// `URL(string:)` 会把它百分号编码后照单全收——`…/claude-code。` 变成
/// `…/claude-code%E3%80%82`，scheme 和 host 都合法，于是「直接命中」这条路径
/// 把它当成有效链接放过去，抓取时才报「网页暂时无法打开」，而错在多了一个字符。
/// 工作台新建创作时,建的必须是稿件而不是笔记。
///
/// 这条接线只有一行调用,但它决定了三模块的边界成不成立——建成笔记的话,
/// 半成品会立刻混进「我的笔记」,而那正是这次重构要解决的问题。
final class WorkbenchDraftCreationTests: XCTestCase {
  @MainActor
  func testWorkbenchCreatesADraftNotANote() async {
    let repository = ManualVMRepository()
    let model = ManualLinkViewModel(
      captureService: .init(fetcher: ManualVMFetcher()),
      clipboard: ManualVMClipboard(nil)
    )
    model.configure(
      history: HistoryApplicationService(repository: repository),
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1 },
      captureSink: { _ in }
    )

    let created = expectation(description: "draft created")
    var taskID: TaskID?
    model.createPieceDraft(title: "某个灵感") { id in
      taskID = id
      created.fulfill()
    } onFailure: { message in
      XCTFail("建稿件失败: \(message)")
      created.fulfill()
    }
    await fulfillment(of: [created], timeout: 5)

    XCTAssertNotNil(taskID)
    // 这个替身只记录收到的文档(不实现 detail),而「收到了什么」正是
    // 这条接线要验证的东西:工作台交给落库通道的必须是一份稿件。
    guard let document = repository.acceptedDocuments.last else {
      return XCTFail("落库通道没有收到任何文档")
    }
    XCTAssertEqual(document.origin, .pieceDraft, "工作台建的必须是稿件,不能是笔记")
    XCTAssertTrue(
      (try? CanonicalURL(document.url))?.isDraft == true,
      "地址必须用稿件的 scheme"
    )
    XCTAssertEqual(document.title, "某个灵感", "标题应带上灵感原句")
  }
}

final class ExplicitWebLinkTrailingPunctuationTests: XCTestCase {
  private func url(_ raw: String) -> String? {
    ExplicitWebLinkInput.singleURL(from: raw)?.absoluteString
  }

  func testStripsTrailingCJKSentencePunctuation() {
    XCTAssertEqual(
      url("https://github.com/anthropics/claude-code。"),
      "https://github.com/anthropics/claude-code"
    )
    XCTAssertEqual(
      url("https://github.com/anthropics/claude-code，"),
      "https://github.com/anthropics/claude-code"
    )
    XCTAssertEqual(url("https://example.com/a？"), "https://example.com/a")
    // 连着几个标点也要剥干净。
    XCTAssertEqual(url("https://example.com/a。。"), "https://example.com/a")
  }

  /// 百分号编码的句号绝不该出现在结果里——那正是这个缺陷的指纹。
  func testResultNeverCarriesEncodedPunctuation() {
    let result = url("https://github.com/anthropics/claude-code。") ?? ""
    XCTAssertFalse(result.contains("%E3%80%82"))
    XCTAssertFalse(result.contains("%EF%BC%8C"))
  }

  /// 干净的链接不能被动到。
  func testCleanURLsAreUnchanged() {
    XCTAssertEqual(
      url("https://github.com/anthropics/claude-code"),
      "https://github.com/anthropics/claude-code"
    )
    // 路径里合法的点号与斜杠不算句尾标点。
    XCTAssertEqual(url("https://example.com/a.b/c/"), "https://example.com/a.b/c/")
  }

  /// 右括号不剥：Wikipedia 这类地址里它是路径的一部分。
  func testDoesNotStripClosingBracketsThatBelongToThePath() {
    XCTAssertEqual(
      url("https://zh.wikipedia.org/wiki/Swift_(编程语言)"),
      "https://zh.wikipedia.org/wiki/Swift_(%E7%BC%96%E7%A8%8B%E8%AF%AD%E8%A8%80)"
    )
  }

  /// 整句话里夹一个链接时仍走 detector，行为不变。
  func testSentenceContainingOneLinkStillResolves() {
    XCTAssertEqual(
      url("看这个 https://example.com/a 很好用"),
      "https://example.com/a"
    )
  }
}

/// 中文紧跟在链接后面且中间没有空格时，NSDataDetector 会把正文一起吃进链接。
///
/// 实测三种粘贴形式只有这一种坏：换行分隔 ✓、空格分隔 ✓、紧贴 ✗。
/// 坏掉时 scheme 与 host 仍然合法，一路放行到抓取才报「网页暂时无法打开」。
final class ExplicitWebLinkCJKAdjacencyTests: XCTestCase {
  private func url(_ raw: String) -> String? {
    ExplicitWebLinkInput.singleURL(from: raw)?.absoluteString
  }

  /// 用户实际粘贴的那段文本。
  func testChineseImmediatelyAfterURLIsNotSwallowed() {
    XCTAssertEqual(
      url("https://github.com/oil-oil/vibe-hub-skill帮我安装这个仓库里的 skills/vibehub Skill。"),
      "https://github.com/oil-oil/vibe-hub-skill"
    )
  }

  /// 有分隔时本来就是对的，不能因为这次改动反而变坏。
  func testSeparatedFormsKeepWorking() {
    let expected = "https://github.com/oil-oil/vibe-hub-skill"
    XCTAssertEqual(url("https://github.com/oil-oil/vibe-hub-skill\n帮我安装这个仓库"), expected)
    XCTAssertEqual(url("https://github.com/oil-oil/vibe-hub-skill 帮我安装这个仓库"), expected)
    XCTAssertEqual(url("看这个 https://github.com/oil-oil/vibe-hub-skill 很好用"), expected)
  }

  /// 百分号编码的中文是地址的一部分，必须原样保留——从浏览器复制中文维基就是这种形式。
  func testPercentEncodedCJKPathIsPreserved() {
    let encoded = "https://zh.wikipedia.org/wiki/%E7%BC%96%E7%A8%8B%E8%AF%AD%E8%A8%80"
    XCTAssertEqual(url(encoded), encoded)
  }

  /// 结果里不该再出现被吞掉的正文。
  func testResultNeverContainsEncodedProse() {
    let result = url("https://github.com/a/b帮我安装这个 仓库") ?? ""
    XCTAssertFalse(result.contains("%E5%B8%AE"), "「帮」被编码进了链接")
    XCTAssertEqual(result, "https://github.com/a/b")
  }

  /// 日文与全角字符走同一条规则。
  func testJapaneseAndFullwidthAlsoTerminateTheURL() {
    XCTAssertEqual(url("https://example.com/aこれはテスト です"), "https://example.com/a")
    XCTAssertEqual(url("https://example.com/a（说明） 见此"), "https://example.com/a")
  }
}
