import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore

/// 打开代抓标签的浏览器。App 只做两件事：挑一台本机真的能用的浏览器，后台打开一个标签。
///
/// 「能用」有两个条件，缺一不可：app 包在，Native Messaging 清单也在。只看 app 在不在，
/// 会在装过扩展又被删掉的人身上开一个空白标签，然后等 90 秒才报错；先看清单就能立刻
/// 给出「扩展没装好」。
struct BrowserCaptureLauncher: Sendable {
  /// 静默打开一个 URL。返回 false = 没能打开（浏览器不在、open 失败）。
  /// 必须是 async：`open` 进程会同步等退出，跑在主 actor 上会卡住整个界面。
  typealias Opener = @Sendable (String, String) async -> Bool

  let homeRoot: URL
  let applicationRoots: [URL]
  let open: Opener
  /// 测试用：跳过「本机装没装」的探测，直接指定一台浏览器。
  let forcedBrowser: BrowserSupportBrowser?

  static let nativeHostManifestName = "com.syc.linkdigest.v01.json"

  /// ego 是用户日常用的浏览器，优先选它；没有就退回 Chrome。顺序固定，不看谁跑过，
  /// 免得同一个人在不同机器上得到不同的「临时标签落在哪个浏览器」。
  static let preferenceOrder: [BrowserSupportBrowser] = [.ego, .chrome]

  func availableBrowser() -> BrowserSupportBrowser? {
    if let forcedBrowser { return forcedBrowser }
    return Self.preferenceOrder.first { browser in
      browser.isApplicationPresent(in: applicationRoots)
        && nativeMessagingManifestPresent(for: browser)
    }
  }

  /// 只判断「清单文件在不在」。清单指向的可执行文件失联由设置页负责修复，
  /// 这里多读一次也没法验证扩展本身有没有加载。
  private func nativeMessagingManifestPresent(for browser: BrowserSupportBrowser) -> Bool {
    let directory = homeRoot.appendingPathComponent(browser.nativeMessagingRelativePath, isDirectory: true)
    return FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(Self.nativeHostManifestName).path
    )
  }

  /// 后台打开标签：`open -g` 不会把浏览器带到前台，用户不在电脑前也不会被抢焦点。
  /// 地址带上代抓标记：扩展只对带标记的标签发 native message，失败时也只关这些标签。
  func openTab(url: String, in browser: BrowserSupportBrowser) async -> Bool {
    await open(browser.appBundleName, BrowserCaptureMarker.markedURL(url))
  }

  static let live = BrowserCaptureLauncher(
    homeRoot: FileManager.default.homeDirectoryForCurrentUser,
    applicationRoots: BrowserSupportBrowser.systemApplicationRoots(
      homeRoot: FileManager.default.homeDirectoryForCurrentUser
    ),
    open: { bundleName, url in
      await Task.detached(priority: .userInitiated) { () -> Bool in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundleName, url]
        do {
          try process.run()
          process.waitUntilExit()
          return process.terminationStatus == 0
        } catch {
          return false
        }
      }.value
    },
    forcedBrowser: nil
  )

  static func stub(
    available: Bool,
    opens: Bool = true,
    opened: (@Sendable (String, String) -> Void)? = nil
  ) -> BrowserCaptureLauncher {
    BrowserCaptureLauncher(
      homeRoot: URL(fileURLWithPath: "/nonexistent"),
      applicationRoots: [URL(fileURLWithPath: "/nonexistent")],
      open: { bundleName, url in
        opened?(bundleName, url)
        return opens
      },
      forcedBrowser: available ? .ego : nil
    )
  }
}

/// 代抓回来的内容。带 envelope 是必须的：入库的「来源」按浏览器抓取记，
/// 只用 CapturedDocument 会被当成 App 本机生成的文档而拒绝。
struct RelayedCapture: Sendable {
  let document: CapturedDocument
  let envelope: CaptureWireEnvelope
}

/// 抓取队列看到的代抓能力。测试用它注入一个「立刻返回文档」的假实现，
/// 不必真的打开浏览器。
@MainActor
protocol BrowserCaptureRelaying: AnyObject {
  func capture(urlString: String, pendingID: UUID) async throws -> RelayedCapture
}

/// 浏览器代抓的会话簿。
///
/// 抓取队列发现「自己打不开」之后，不直接判失败，而是交给这里：
/// 1. 登记一个一次性 job（排队项 id + 链接 + 过期时间）；
/// 2. 在用户的浏览器里后台打开这个链接；
/// 3. 等扩展问「这个地址有待抓任务吗」（`claimJob`）→ 等扩展把内容送回来（`deliver`）；
/// 4. 内容回来就当作这次抓取读到的页面，交回给队列继续入库、下载、转写。
///
/// 队列本身串行，所以同一时刻最多只有一个标签；job 一次性，送回来即作废，
/// 过期也作废——不会出现第二天清晨还认领昨天标签的情况。
@MainActor
final class BrowserCaptureRelay: BrowserCaptureRelaying {
  /// 扩展一般几秒内就会认领；90 秒足够慢页面加载完，又不会让自动化一个链接干等五分钟。
  static let defaultTimeout: TimeInterval = 90
  /// job 的最长寿命：比超时长一点，盖住「超时后标签才慢吞吞加载完」的迟到认领。
  static let jobLifetime: TimeInterval = 180

  private final class Job {
    let id: String
    let urlString: String
    let pendingID: UUID
    let createdAt: Date
    var claimedTabID: Int?
    var delivered = false
    /// 这个 job 期间有没有扩展来问过（不管地址对不对）。用来区分
    /// 「扩展真没连上」和「连上了但落地页对不上任务」。
    var sawQuery = false
    var lastQueryLanding: String?

    init(id: String, urlString: String, pendingID: UUID, createdAt: Date) {
      self.id = id
      self.urlString = urlString
      self.pendingID = pendingID
      self.createdAt = createdAt
    }
  }

  /// `withCheckedThrowingContinuation` 的闭包是 sending：主 actor 状态不能直接写进闭包，
  /// 所以先建一个线程安全的盒子交给两边共用。
  private final class WaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<RelayedCapture, Error>?

    var continuation: CheckedContinuation<RelayedCapture, Error>? {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    func resume(returning value: RelayedCapture) -> Bool {
      let continuation = lock.withLock { () -> CheckedContinuation<RelayedCapture, Error>? in
        let value = stored
        stored = nil
        return value
      }
      continuation?.resume(returning: value)
      return continuation != nil
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
      let continuation = lock.withLock { () -> CheckedContinuation<RelayedCapture, Error>? in
        let value = stored
        stored = nil
        return value
      }
      continuation?.resume(throwing: error)
      return continuation != nil
    }
  }

  private let launcher: BrowserCaptureLauncher
  private let now: @Sendable () -> Date
  private let timeout: TimeInterval
  private var jobs: [String: Job] = [:]
  private var waiters: [String: WaitBox] = [:]
  private var timeoutTasks: [String: Task<Void, Never>] = [:]

  init(
    launcher: BrowserCaptureLauncher = .live,
    timeout: TimeInterval = BrowserCaptureRelay.defaultTimeout,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.launcher = launcher
    self.timeout = timeout
    self.now = now
  }

  /// 当前活着的 job 数（测试与诊断用）。
  var activeJobCount: Int { jobs.count }

  var activeJobIDs: [String] { Array(jobs.keys) }

  /// 已经挂上等待、等扩展送内容的抓取数（测试用）。
  var waitingJobCount: Int { waiters.count }

  /// 抓取队列调用：打开标签并等扩展把这一页送回来。
  func capture(urlString: String, pendingID: UUID) async throws -> RelayedCapture {
    cleanupExpired()
    // 名单外的站点，扩展没有访问权限：连标签地址都看不到，等 90 秒也只会超时。
    // 立刻用能看懂的原因结束，让调用方换办法（App 自己的直读/登录会话）。
    let parsedURL = URL(string: urlString)
    guard let parsedURL, BrowserCaptureHostPolicy.allows(parsedURL) else {
      throw BrowserCaptureRelayFailure.permissionMissing(host: parsedURL?.host ?? "")
    }
    guard let browser = launcher.availableBrowser() else {
      throw BrowserCaptureRelayFailure.browserUnavailable
    }
    let job = Job(
      id: UUID().uuidString.lowercased(),
      urlString: urlString,
      pendingID: pendingID,
      createdAt: now()
    )
    // 先登记再开标签：扩展可能在标签加载完成的第一时间就来问。
    jobs[job.id] = job
    AppLog.notice(.capture, "browser_relay_job_registered", [
      "job": String(job.id.prefix(8)),
      "landing": BrowserCaptureLanding.describe(urlString),
    ])
    guard await launcher.openTab(url: urlString, in: browser) else {
      jobs.removeValue(forKey: job.id)
      AppLog.error(.capture, "browser_relay_open_failed", code: "browser_capture_unavailable",
                   ["landing": BrowserCaptureLanding.describe(urlString)])
      throw BrowserCaptureRelayFailure.browserUnavailable
    }
    scheduleTimeout(for: job)
    let box = WaitBox()
    waiters[job.id] = box
    let jobID = job.id
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          box.continuation = continuation
        }
      } onCancel: {
        Task { @MainActor in
          self.fail(jobID: jobID, reason: .cancelled)
        }
      }
    } catch {
      jobs.removeValue(forKey: job.id)
      waiters.removeValue(forKey: job.id)
      throw error
    }
  }

  /// 扩展问「这些地址里有待代抓的吗」。命中就把 job 交给发问的那个标签：
  /// 之后别的标签再问同样的地址不再返回它，避免两条重复入库。
  /// 同一个标签可以重复问（抓取失败后重试），仍拿回同一个 job。
  func claimJob(
    candidateURLs: [String],
    tabID: Int,
    allowsRelayTabFallback: Bool = false
  ) -> String? {
    cleanupExpired()
    let ordered = jobs.values
      .filter { !$0.delivered }
      .sorted { $0.createdAt < $1.createdAt }
    guard let oldest = ordered.first else { return nil }
    // 「扩展来过」按 job 记：超时要据此区分真没连上和落地页对不上。
    oldest.sawQuery = true
    if let landing = candidateURLs.first { oldest.lastQueryLanding = BrowserCaptureLanding.describe(landing) }
    AppLog.notice(.capture, "browser_relay_query", [
      "job": String(oldest.id.prefix(8)),
      "tab": String(tabID),
      "landing": oldest.lastQueryLanding ?? "unknown",
      "candidates": String(candidateURLs.count),
    ])
    for job in ordered {
      if let matched = candidateURLs.first(where: {
        BrowserCaptureJobMatching.matches(candidate: $0, jobURL: job.urlString)
      }) {
        if let claimedTabID = job.claimedTabID, claimedTabID != tabID { continue }
        job.claimedTabID = tabID
        AppLog.notice(.capture, "browser_relay_claimed", [
          "job": String(job.id.prefix(8)), "tab": String(tabID), "match": "url",
          "landing": BrowserCaptureLanding.describe(matched),
        ])
        return job.id
      }
    }
    // 地址对不上：短链重定向后整串都换了、或 MV3 后台重启丢了导航历史。
    // 带标记的标签本身就是 App 开的证据；只有一单在等时交给它，绝不乱抓。
    if allowsRelayTabFallback, ordered.count == 1, oldest.claimedTabID == nil {
      oldest.claimedTabID = tabID
      AppLog.notice(.capture, "browser_relay_claimed", [
        "job": String(oldest.id.prefix(8)), "tab": String(tabID), "match": "relayTab",
        "landing": oldest.lastQueryLanding ?? "unknown",
      ])
      return oldest.id
    }
    AppLog.notice(.capture, "browser_relay_query_unmatched", [
      "tab": String(tabID),
      "landing": oldest.lastQueryLanding ?? "unknown",
      "jobs": String(ordered.count),
    ])
    return nil
  }

  /// 扩展发现页面落地成了平台错误页/登录页：按真实原因立即失败。
  /// 返回 false 表示这一单已经结束（重复回报或已超时）。
  @discardableResult
  func reportBlocked(jobID: String, reason: BrowserCaptureJobOutcomeRequest.Reason, finalURL: String) -> Bool {
    guard let job = jobs[jobID], !job.delivered else { return false }
    let landing = BrowserCaptureLanding.describe(finalURL)
    let error = Self.captureError(for: reason, jobURL: job.urlString)
    AppLog.notice(.capture, "browser_relay_blocked", [
      "job": String(job.id.prefix(8)), "reason": reason.rawValue, "landing": landing,
      "code": String(describing: error),
    ])
    fail(jobID: jobID, reason: .blocked(error, landing: landing))
    return true
  }

  /// 平台落地页 → 用户能处理的抓取错误。小红书缺访问码和笔记已删除要分开：
  /// 前者换一条完整分享链接就行，后者怎么重试都没用。
  static func captureError(
    for reason: BrowserCaptureJobOutcomeRequest.Reason,
    jobURL: String
  ) -> ManualLinkError {
    let url = URL(string: jobURL)
    let isXiaohongshu = url.map { XiaohongshuURL.matches($0) } ?? false
    let bareLink = url.map { XiaohongshuURL.isBareNoteLink($0) } ?? false
    switch reason {
    case .noteUnavailable, .notFound:
      guard isXiaohongshu else { return .invalidPageResult }
      return bareLink ? .shareLinkMissingToken : .shareLinkExpired
    case .loginRequired: return .loginRequired
    case .verificationRequired: return .verificationRequired
    case .unknown: return .invalidPageResult
    }
  }

  /// 扩展把内容送回：认回 job，唤醒等待中的抓取。返回 false 表示这个 job 已经作废，
  /// 调用方按普通浏览器抓取处理即可。
  func deliver(jobID: String, envelope: CaptureWireEnvelope) -> Bool {
    guard let job = jobs[jobID], !job.delivered, let waiter = waiters.removeValue(forKey: jobID) else {
      return false
    }
    job.delivered = true
    timeoutTasks.removeValue(forKey: jobID)?.cancel()
    jobs.removeValue(forKey: jobID)
    AppLog.notice(.capture, "browser_relay_delivered", [
      "job": String(job.id.prefix(8)),
      "bytes": String(envelope.characterCount),
    ])
    let document: CapturedDocument
    switch envelope {
    case let .v1(value): document = CapturedDocument(wire: value)
    case let .v2(value): document = CapturedDocument(wire: value)
    }
    return waiter.resume(returning: RelayedCapture(document: document, envelope: envelope))
  }

  /// 队列项被取消/队列清空时调用，别让标签和等待一直挂着。
  func cancel(pendingID: UUID) {
    for job in jobs.values where job.pendingID == pendingID {
      fail(jobID: job.id, reason: .cancelled)
    }
  }

  func cancelAll() {
    for id in Array(jobs.keys) {
      fail(jobID: id, reason: .cancelled)
    }
  }

  private func scheduleTimeout(for job: Job) {
    let seconds = timeout
    timeoutTasks[job.id] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      guard let self, let current = self.jobs[job.id] else { return }
      let reason: BrowserCaptureRelayFailure
      if current.claimedTabID != nil {
        reason = .timedOut
      } else if current.sawQuery {
        // 扩展连上了、也看到了这个标签，但落地地址对不上任何排队项。
        reason = .targetNotMatched(landing: current.lastQueryLanding ?? "unknown")
      } else {
        reason = .extensionNotConnected
      }
      self.fail(jobID: job.id, reason: reason)
    }
  }

  private func fail(jobID: String, reason: BrowserCaptureRelayFailure) {
    timeoutTasks.removeValue(forKey: jobID)?.cancel()
    jobs.removeValue(forKey: jobID)
    AppLog.notice(.capture, "browser_relay_finished", [
      "job": String(jobID.prefix(8)), "code": reason.code,
    ])
    waiters.removeValue(forKey: jobID)?.resume(throwing: reason)
  }

  /// job 过期作废：让仍在等待的抓取立刻拿到明确原因，而不是等到 90 秒超时又一份。
  private func cleanupExpired() {
    let deadline = now()
    for job in jobs.values where job.createdAt.addingTimeInterval(Self.jobLifetime) < deadline {
      fail(jobID: job.id, reason: .timedOut)
    }
  }
}
