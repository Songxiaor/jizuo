import Foundation
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestTransport

struct AppBootstrapResult: Sendable {
  let availability: StorageAvailability
  let history: HistoryApplicationService?
  let historyIsReadOnly: Bool
  let historyReadOnlyReason: RepositoryRecoveryReason?
  /// 只读降级时给用户看的补充说明（升级失败时带备份路径）。可写或完全打不开时为 nil。
  let historyReadOnlyRecoveryHint: String?
  /// Set only when opening history failed completely. A read-only repository is
  /// still safe to browse and therefore deliberately has no blocking error.
  let historyUnavailableCode: StorageErrorCode?
  let storageWriteGate: StorageWriteGate
  let serverStarted: Bool
}

actor AppComposition {
  typealias ApplicationSupportRoot = @Sendable () throws -> URL
  typealias RepositoryFactory = @Sendable (LocalDatabaseLocation) throws -> any HistoryRepository
  typealias ServerStarter = @Sendable (CaptureReceiver) throws -> Void
  typealias AvailabilitySink = @Sendable (StorageAvailability) async -> Void

  struct Dependencies: Sendable {
    let applicationSupportRoot: ApplicationSupportRoot
    let repositoryFactory: RepositoryFactory
    let nowMilliseconds: @Sendable () -> Int64
    let serverStarter: ServerStarter
    let availabilitySink: AvailabilitySink
    let captureSink: CaptureReceiver.CaptureSink
    /// 收藏夹同步的受理入口。缺省为 nil：单元测试与降级路径不需要它，
    /// 此时扩展会收到「请升级 App」而不是静默丢弃这批 id。
    let bookmarksSink: CaptureReceiver.BookmarksSink?
    let profileCandidatesSink: CaptureReceiver.ProfileCandidatesSink?

    init(
      applicationSupportRoot: @escaping ApplicationSupportRoot,
      repositoryFactory: @escaping RepositoryFactory,
      nowMilliseconds: @escaping @Sendable () -> Int64,
      serverStarter: @escaping ServerStarter,
      availabilitySink: @escaping AvailabilitySink,
      captureSink: @escaping CaptureReceiver.CaptureSink,
      bookmarksSink: CaptureReceiver.BookmarksSink? = nil,
      profileCandidatesSink: CaptureReceiver.ProfileCandidatesSink? = nil
    ) {
      self.applicationSupportRoot = applicationSupportRoot
      self.repositoryFactory = repositoryFactory
      self.nowMilliseconds = nowMilliseconds
      self.serverStarter = serverStarter
      self.availabilitySink = availabilitySink
      self.captureSink = captureSink
      self.bookmarksSink = bookmarksSink
      self.profileCandidatesSink = profileCandidatesSink
    }
  }

  private let dependencies: Dependencies
  private let storageWriteGate: StorageWriteGate
  private var bootstrapTask: Task<AppBootstrapResult, Never>?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
    storageWriteGate = StorageWriteGate(
      availabilitySink: dependencies.availabilitySink
    )
  }

  func bootstrap() async -> AppBootstrapResult {
    if let bootstrapTask {
      return await bootstrapTask.value
    }

    let dependencies = dependencies
    let storageWriteGate = storageWriteGate
    let task = Task {
      await Self.performBootstrap(
        dependencies: dependencies,
        storageWriteGate: storageWriteGate
      )
    }
    bootstrapTask = task
    return await task.value
  }

  private static func performBootstrap(
    dependencies: Dependencies,
    storageWriteGate: StorageWriteGate
  ) async -> AppBootstrapResult {
    await storageWriteGate.publishCurrentAvailability()

    let repository: any HistoryRepository
    do {
      let root = try dependencies.applicationSupportRoot()
      repository = try dependencies.repositoryFactory(
        LocalDatabaseLocation(applicationSupportRoot: root)
      )
    } catch let failure as RepositoryFailure {
      let availability = StorageAvailability.unavailable(
        StorageErrorMapper.map(failure, context: .open).code
      )
      return await finishUnavailable(
        availability,
        dependencies: dependencies,
        storageWriteGate: storageWriteGate
      )
    } catch {
      return await finishUnavailable(
        .unavailable(.unavailable),
        dependencies: dependencies,
        storageWriteGate: storageWriteGate
      )
    }

    switch repository.accessMode {
    case .writable:
      let history = HistoryApplicationService(repository: repository)
      do {
        _ = try history.recoverInterruptedRuns(at: dependencies.nowMilliseconds())
        await storageWriteGate.markWritableAfterBootstrap()
        let receiver = CaptureReceiver(
          history: history,
          storageWriteGate: storageWriteGate,
          nowMilliseconds: dependencies.nowMilliseconds,
          captureSink: dependencies.captureSink,
          bookmarksSink: dependencies.bookmarksSink,
          profileCandidatesSink: dependencies.profileCandidatesSink
        )
        let started = startServer(receiver, using: dependencies.serverStarter)
        return .init(
          availability: .writable,
          history: history,
          historyIsReadOnly: false,
          historyReadOnlyReason: nil,
          historyReadOnlyRecoveryHint: nil,
          historyUnavailableCode: nil,
          storageWriteGate: storageWriteGate,
          serverStarted: started
        )
      } catch let failure as RepositoryFailure {
        let availability = StorageAvailability.unavailable(
          StorageErrorMapper.map(failure, context: .write).code
        )
        return await finishUnavailable(
          availability,
          dependencies: dependencies,
          storageWriteGate: storageWriteGate
        )
      } catch {
        return await finishUnavailable(
          .unavailable(.writeFailed),
          dependencies: dependencies,
          storageWriteGate: storageWriteGate
        )
      }
    case let .readOnly(reason):
      let mapped = StorageErrorMapper.map(
        .readOnly(reason),
        context: .open
      )
      // Recovery-mode storage is a valid read port. Do not hand it to Capture
      // or Run (both write), but keep it available to the history browser.
      let availability = await storageWriteGate.degrade(mapped.code)
      let receiver = CaptureReceiver(
        history: nil,
        storageWriteGate: storageWriteGate,
        nowMilliseconds: dependencies.nowMilliseconds,
        captureSink: dependencies.captureSink,
        bookmarksSink: dependencies.bookmarksSink,
        profileCandidatesSink: dependencies.profileCandidatesSink
      )
      return .init(
        availability: availability,
        history: HistoryApplicationService(repository: repository),
        historyIsReadOnly: true,
        historyReadOnlyReason: reason,
        historyReadOnlyRecoveryHint: repository.readOnlyRecoveryHint,
        historyUnavailableCode: nil,
        storageWriteGate: storageWriteGate,
        serverStarted: startServer(receiver, using: dependencies.serverStarter)
      )
    }
  }

  private static func finishUnavailable(
    _ availability: StorageAvailability,
    dependencies: Dependencies,
    storageWriteGate: StorageWriteGate
  ) async -> AppBootstrapResult {
    let code = availability.code ?? .unavailable
    let degraded = await storageWriteGate.degrade(code)
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: storageWriteGate,
      nowMilliseconds: dependencies.nowMilliseconds,
      captureSink: dependencies.captureSink,
      bookmarksSink: dependencies.bookmarksSink,
      profileCandidatesSink: dependencies.profileCandidatesSink
    )
    return .init(
      availability: degraded,
      history: nil,
      historyIsReadOnly: false,
      historyReadOnlyReason: nil,
      historyReadOnlyRecoveryHint: nil,
      historyUnavailableCode: code,
      storageWriteGate: storageWriteGate,
      serverStarted: startServer(receiver, using: dependencies.serverStarter)
    )
  }

  private static func startServer(
    _ receiver: CaptureReceiver,
    using starter: ServerStarter
  ) -> Bool {
    do {
      try starter(receiver)
      return true
    } catch {
      return false
    }
  }
}

enum AppApplicationSupportRoot {
  static let smokeOverrideEnvironmentKey = "LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT"
  static let smokeOpenFailureEnvironmentKey = "LINKDIGEST_SMOKE_FORCE_STORAGE_OPEN_FAILURE"
  static let debugHistoryLoadingEnvironmentKey = "LINKDIGEST_DEBUG_HISTORY_LOADING"
  static let debugHistoryLoadingSentinelName = ".linkdigest-debug-history-loading"
  static let debugVisualFixtureEnvironmentKey = "LINKDIGEST_DEBUG_VISUAL_FIXTURE"
  static let debugVisualFixtureSentinelName = ".linkdigest-debug-visual-fixture"

  /// Resolves the one root that the composition root may pass to persistence.
  ///
  /// The override exists only in Debug builds so the production vertical smoke can
  /// exercise the real App composition without ever resolving the user's live
  /// Application Support directory. Release builds always use `liveRoot`.
  static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    liveRoot: () throws -> URL = liveApplicationSupportRoot
  ) throws -> URL {
    #if DEBUG
    if let rawOverride = environment[smokeOverrideEnvironmentKey] {
      let root = URL(fileURLWithPath: rawOverride, isDirectory: true)
        .standardizedFileURL
      guard root.path.hasPrefix("/"), root.path != "/" else {
        throw RepositoryFailure.unavailable
      }
      return root
    }
    #endif

    return try liveRoot()
  }

  /// Allows the production-composition smoke to take its structured open-failure
  /// branch without relying on host filesystem permissions. It is deliberately
  /// absent from Release builds, where neither smoke environment key has effect.
  static func shouldInjectOpenFailure(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    #if DEBUG
    environment[smokeOpenFailureEnvironmentKey] == "1"
    #else
    false
    #endif
  }

  /// A deliberately narrow visual-test hook. It cannot turn on for arbitrary
  /// Application Support roots, and is compiled out of Release builds.
  static func shouldHoldHistoryLoading(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Bool {
    #if DEBUG
    guard environment[debugHistoryLoadingEnvironmentKey] == "1",
          let rawRoot = environment[smokeOverrideEnvironmentKey]
    else { return false }

    let standardized = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
    // Some Foundation contexts retain Darwin's /private/tmp spelling after
    // standardization. Collapse only that exact alias before enforcing the
    // canonical /tmp layout below; all other roots remain fail-closed.
    let root: URL
    if standardized.path.hasPrefix("/private/tmp/") {
      root = URL(fileURLWithPath: "/tmp/" + standardized.path.dropFirst("/private/tmp/".count), isDirectory: true)
        .standardizedFileURL
    } else {
      root = standardized
    }
    let components = root.pathComponents
    // Only /tmp/linkdigest-history-state.<session>/Application Support is
    // accepted; no arbitrary Application Support root can opt in.
    guard components.count == 4,
          components[1] == "tmp",
          components[2].hasPrefix("linkdigest-history-state."),
          components[2].count > "linkdigest-history-state.".count,
          components[3] == "Application Support"
    else { return false }

    let sessionRoot = root.deletingLastPathComponent()
    return fileExists(sessionRoot.appendingPathComponent(debugHistoryLoadingSentinelName).path)
    #else
    false
    #endif
  }

  /// A screenshot-only fake configuration is available only when every Debug
  /// gate matches the same isolated temporary-root shape. Release does not
  /// compile this branch, so it cannot replace a user's real configuration.
  static func shouldUseVisualFixture(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Bool {
    #if DEBUG
    guard environment[debugVisualFixtureEnvironmentKey] == "1",
          let rawRoot = environment[smokeOverrideEnvironmentKey]
    else { return false }
    let standardized = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
    let root: URL
    if standardized.path.hasPrefix("/private/tmp/") {
      root = URL(
        fileURLWithPath: "/tmp/" + standardized.path.dropFirst("/private/tmp/".count),
        isDirectory: true
      ).standardizedFileURL
    } else {
      root = standardized
    }
    let components = root.pathComponents
    guard components.count == 4,
          components[1] == "tmp",
          components[2].hasPrefix("linkdigest-history-state."),
          components[2].count > "linkdigest-history-state.".count,
          components[3] == "Application Support"
    else { return false }
    let sessionRoot = root.deletingLastPathComponent()
    return fileExists(sessionRoot.appendingPathComponent(debugVisualFixtureSentinelName).path)
    #else
    false
    #endif
  }
}

func liveApplicationSupportRoot() throws -> URL {
  #if DEBUG
  // A successful smoke run with the override proves no future composition path
  // accidentally falls back to the real user directory.
  if ProcessInfo.processInfo.environment[
    AppApplicationSupportRoot.smokeOverrideEnvironmentKey
  ] != nil {
    throw RepositoryFailure.unavailable
  }
  #endif

  guard let root = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  ).first else {
    throw RepositoryFailure.unavailable
  }
  return root
}

final class UnixSocketServerLifecycle: @unchecked Sendable {
  private let path: String
  private let statusSink: @Sendable (String) async -> Void
  private let availabilitySink: @Sendable (Bool) async -> Void
  private let lock = NSLock()
  private var server: UnixSocketServer?
  private var healthTimer: DispatchSourceTimer?

  /// How often the published socket node gets re-checked.
  ///
  /// This used to ride on the accept timeout, which meant a filesystem stat
  /// every single second for the life of the process. Thirty seconds with a
  /// generous leeway lets the system coalesce the wakeup with whatever else
  /// it was already doing, and an unlinked socket is a rare, recoverable
  /// condition — not something worth a per-second poll.
  private static let defaultHealthCheckInterval: TimeInterval = 30
  private static let healthQueue = DispatchQueue(label: "linkdigest.capture.socket.health", qos: .utility)
  private let healthCheckInterval: TimeInterval

  init(
    path: String,
    statusSink: @escaping @Sendable (String) async -> Void,
    availabilitySink: @escaping @Sendable (Bool) async -> Void = { _ in },
    healthCheckInterval: TimeInterval = UnixSocketServerLifecycle.defaultHealthCheckInterval
  ) {
    self.path = path
    self.statusSink = statusSink
    self.availabilitySink = availabilitySink
    self.healthCheckInterval = healthCheckInterval
  }

  func start(_ receiver: CaptureReceiver) throws {
    let candidate = UnixSocketServer(path: path)
    let canStart = lock.withLock { () -> Bool in
      guard server == nil else { return false }
      server = candidate
      return true
    }
    guard canStart else { throw POSIXError(.EALREADY) }
    do {
      try candidate.start()
    } catch {
      lock.withLock {
        if server === candidate { server = nil }
      }
      throw error
    }

    do {
      try candidate.startAccepting(
        ioTimeout: 10,
        onClient: { client in
          Task.detached { await receiver.handleClient(client) }
        },
        onFailure: { [weak self] _ in
          guard let self, self.isRunning(candidate) else { return }
          Task {
            await self.statusSink("接收服务错误")
            await self.availabilitySink(false)
          }
        }
      )
    } catch {
      lock.withLock { if server === candidate { server = nil } }
      candidate.stop()
      throw error
    }

    Task {
      await statusSink("本机接收服务已启动")
      await availabilitySink(true)
    }
    startHealthCheck(for: candidate, receiver: receiver)
  }

  /// A pathname socket can disappear while its fd remains open: the App looks
  /// alive but every extension request gets ENOENT. Nothing tells us when that
  /// happens, so it has to be noticed by looking — just not every second.
  private func startHealthCheck(for candidate: UnixSocketServer, receiver: CaptureReceiver) {
    let timer = DispatchSource.makeTimerSource(queue: Self.healthQueue)
    timer.schedule(
      deadline: .now() + healthCheckInterval,
      repeating: healthCheckInterval,
      // 大 leeway 让系统把这次唤醒和别的事合并，闲置时几乎不单独醒。
      leeway: .milliseconds(max(10, Int(healthCheckInterval * 1000 / 3)))
    )
    timer.setEventHandler { [weak self] in
      guard let self, self.isRunning(candidate) else { return }
      guard !candidate.isPublishedAtPath() else { return }
      Task { await self.recoverMissingPublication(candidate, receiver: receiver) }
    }
    // 先 resume 再换班：DispatchSource 建出来是挂起的，挂起状态下被释放会崩，
    // 所以每一个建出来的定时器都必须先跑起来，用不上再 cancel。
    timer.resume()
    let stale = lock.withLock { () -> DispatchSourceTimer? in
      guard server === candidate else { return timer }
      let previous = healthTimer
      healthTimer = timer
      return previous
    }
    stale?.cancel()
  }

  func stop() {
    let owned = lock.withLock { () -> (UnixSocketServer?, DispatchSourceTimer?) in
      let value = (server, healthTimer)
      server = nil
      healthTimer = nil
      return value
    }
    owned.1?.cancel()
    owned.0?.stop()
  }

  private func isRunning(_ candidate: UnixSocketServer) -> Bool {
    lock.withLock { server === candidate }
  }

  private func recoverMissingPublication(
    _ candidate: UnixSocketServer,
    receiver: CaptureReceiver
  ) async {
    let owned = lock.withLock { () -> (Bool, DispatchSourceTimer?) in
      guard server === candidate else { return (false, nil) }
      let timer = healthTimer
      server = nil
      healthTimer = nil
      return (true, timer)
    }
    guard owned.0 else { return }
    owned.1?.cancel()

    await statusSink("接收服务连接中断，正在自动恢复")
    await availabilitySink(false)
    candidate.stop()
    do {
      try start(receiver)
    } catch {
      await statusSink("接收服务自动恢复失败")
      await availabilitySink(false)
    }
  }

  deinit { stop() }
}

func makeUnixSocketServerStarter(
  lifecycle: UnixSocketServerLifecycle
) -> AppComposition.ServerStarter {
  { receiver in try lifecycle.start(receiver) }
}
