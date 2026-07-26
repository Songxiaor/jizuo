import Foundation
import LinkDigestAdapters
import LinkDigestCore

/// Process-only recovery of streaming playback for history entries.
/// LRU cache (default 10) + single in-flight refresh; never persists signed URLs.
@MainActor
final class SessionMediaPlaybackController: ObservableObject {
  enum RefreshPhase: Equatable {
    case idle
    case refreshing
    case failed(String)
  }

  @Published private(set) var restoreMode: SessionMediaRestoreMode
  @Published private(set) var phase: RefreshPhase = .idle
  @Published private(set) var activeTaskID: TaskID?
  /// Bumps when cache or phase changes so detail views re-read descriptors.
  @Published private(set) var generation = 0

  private let preferenceStore: UserDefaultsMediaStoragePreferenceStore
  private let cache: SessionMediaDescriptorCache
  private let refreshService: SessionMediaRefreshService
  private var refreshTask: Task<Void, Never>?
  /// 每条视频用户手动选过的清晰度；仅进程内。
  private var chosenQuality: [TaskID: BilibiliStreamQualityPreference] = [:]
  /// 最近一次选流的可见记录：API 给了哪些档、我们选了哪条、为什么。
  /// 不含 Cookie 与签名 URL。
  @Published private(set) var selectionDiagnostic: String?
  /// 当前这条已经发起过多少次刷新。
  ///
  /// 「一直转圈」有两种截然不同的成因：请求真的慢，或者刷新被反复取消重启。
  /// 两者界面上长得一模一样，但修法完全不同。次数一涨就是后者——
  /// 连超时都活不下来，因为计时器每次跟着任务一起被取消。
  @Published private(set) var refreshAttempts = 0

  init(
    preferenceStore: UserDefaultsMediaStoragePreferenceStore,
    refreshService: SessionMediaRefreshService,
    cache: SessionMediaDescriptorCache = SessionMediaDescriptorCache()
  ) {
    self.preferenceStore = preferenceStore
    self.refreshService = refreshService
    self.cache = cache
    self.restoreMode = preferenceStore.sessionMediaRestoreMode
  }

  func reloadPreferences() {
    restoreMode = preferenceStore.sessionMediaRestoreMode
  }

  func setRestoreMode(_ mode: SessionMediaRestoreMode) {
    preferenceStore.sessionMediaRestoreMode = mode
    restoreMode = mode
  }

  func cachedDescriptor(for taskID: TaskID) -> MediaDescriptor? {
    cache.descriptor(for: taskID)
  }

  /// Seed cache when a browser capture still has a live descriptor (session warm).
  func rememberCurrentCapture(_ capture: CurrentCapture) {
    guard let descriptor = capture.mediaDescriptor else { return }
    guard case .playable = CurrentCaptureMediaPreview.resolve(descriptor) else { return }
    cache.insert(descriptor, for: capture.taskID)
    generation &+= 1
  }

  /// Called when history detail becomes active for a task that once had session media.
  func detailBecameActive(
    taskID: TaskID,
    platform: String?,
    sourceURL: String,
    author: String?,
    hadMediaDescriptor: Bool,
    hasLocalMedia: Bool,
    isCurrentCaptureWithDescriptor: Bool,
    isYouTube: Bool
  ) {
    // 必须在覆盖 activeTaskID 之前记下旧值，否则无法判断「在飞的那次刷新是不是同一条」。
    let previouslyActive = activeTaskID
    restoreMode = preferenceStore.sessionMediaRestoreMode
    activeTaskID = taskID
    // Local file / live current capture / YouTube embed own their own UI paths.
    if hasLocalMedia || isCurrentCaptureWithDescriptor || isYouTube || !hadMediaDescriptor {
      cancelRefresh(clearPhase: true)
      return
    }
    if cache.descriptor(for: taskID) != nil {
      phase = .idle
      generation &+= 1
      return
    }
    if restoreMode == .automatic {
      // 同一条已经在刷新中就别重来。
      //
      // `requestRefresh` 开头会 `cancelRefresh` 掉在飞的那次并把 `generation` 加一，
      // 而卡片带着 `.id(generation)`，一变就重建视图、重新走到这里——于是
      // 「取消→重启→再取消」形成死循环，界面永远停在「正在重新获取播放…」。
      // 拉低清档时请求快，能赶在下一轮重建前完成，所以一直没暴露；
      // 换成 4K 双轨后请求变慢，循环就锁死了。
      if previouslyActive == taskID, phase == .refreshing { return }
      requestRefresh(
        taskID: taskID,
        platform: platform,
        sourceURL: sourceURL,
        author: author
      )
    } else {
      cancelRefresh(clearPhase: true)
    }
  }

  /// 刷新播放地址的硬上限。两次 playurl 请求正常都在数秒内完成；
  /// 超过这个数就当作挂住，给出可见失败而不是无限转圈。
  static var refreshTimeoutSeconds: TimeInterval = 25

  struct RefreshTimedOut: Error {}

  /// 给一段异步工作套超时。超时后取消它并抛 `RefreshTimedOut`。
  private static func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw RefreshTimedOut()
      }
      guard let first = try await group.next() else { throw RefreshTimedOut() }
      group.cancelAll()
      return first
    }
  }

  func requestRefresh(
    taskID: TaskID,
    platform: String?,
    sourceURL: String,
    author: String?,
    qualityOverride: BilibiliStreamQualityPreference? = nil
  ) {
    cancelRefresh(clearPhase: false)
    if activeTaskID != taskID { refreshAttempts = 0 }
    refreshAttempts += 1
    activeTaskID = taskID
    phase = .refreshing
    generation &+= 1
    if let qualityOverride { chosenQuality[taskID] = qualityOverride }
    // 用户在这条视频上选过的清晰度必须粘住。
    //
    // 手选清晰度会先清缓存再带 override 刷新，但清缓存那一刻，自动恢复路径
    // 会看到「没有缓存 + 模式是 automatic」，于是补发一次**不带 override** 的刷新，
    // 把刚拿到的高清结果盖成自动策略的结果——长片自动策略强制走 progressive，
    // 于是 4K 双轨被换回 720P 整段，表现就是「选了尽量高清没反应」。
    let effectiveQuality = qualityOverride ?? chosenQuality[taskID]
    let startedAt = Date()
    refreshTask = Task { @MainActor in
      do {
        // 刷新必须有出口。没有超时的话，请求一旦挂住（既不返回也不抛错），
        // 界面就永远停在「正在重新获取播放…」——无法和「正在慢慢加载」区分，
        // 排查时等于没有信息。超时后把已耗时写进错误里，至少能看出是挂了还是慢。
        let service = self.refreshService
        let descriptor = try await Self.withTimeout(seconds: Self.refreshTimeoutSeconds) {
          try await service.refresh(
            platform: platform,
            sourceURL: sourceURL,
            author: author,
            qualityOverride: effectiveQuality
          )
        }
        guard !Task.isCancelled, activeTaskID == taskID else { return }
        cache.insert(descriptor, for: taskID)
        selectionDiagnostic = refreshService.bilibiliDiagnostics.latest()
        phase = .idle
        generation &+= 1
      } catch is RefreshTimedOut {
        guard !Task.isCancelled, activeTaskID == taskID else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        phase = .failed("获取播放地址超时（已等 \(elapsed) 秒）。可以再试一次，或改选较低清晰度。")
        selectionDiagnostic = refreshService.bilibiliDiagnostics.latest()
        generation &+= 1
      } catch is CancellationError {
        guard activeTaskID == taskID else { return }
        phase = .idle
      } catch let error as SessionMediaRefreshError {
        guard !Task.isCancelled, activeTaskID == taskID else { return }
        phase = .failed(error.userMessage)
        generation &+= 1
      } catch {
        guard !Task.isCancelled, activeTaskID == taskID else { return }
        phase = .failed(SessionMediaRefreshError.networkOrParse.userMessage)
        generation &+= 1
      }
    }
  }

  /// Drop a cached stream (e.g. unplayable Dolby Vision dual-track) and re-fetch
  /// with the latest quality / codec selection rules.
  func invalidateAndRefresh(
    taskID: TaskID,
    platform: String?,
    sourceURL: String,
    author: String?,
    qualityOverride: BilibiliStreamQualityPreference? = nil
  ) {
    cache.remove(taskID)
    generation &+= 1
    requestRefresh(
      taskID: taskID,
      platform: platform,
      sourceURL: sourceURL,
      author: author,
      qualityOverride: qualityOverride
    )
  }

  /// 用户在某条视频上手动选过的清晰度。只活在进程内，跟签名地址一样不写历史。
  /// 用来让清晰度菜单显示当前选中项，切走再回来不至于忘掉用户刚选的档。
  func chosenQuality(for taskID: TaskID) -> BilibiliStreamQualityPreference? {
    chosenQuality[taskID]
  }

  func cancelRefresh(clearPhase: Bool) {
    refreshTask?.cancel()
    refreshTask = nil
    if clearPhase { phase = .idle }
  }
}
