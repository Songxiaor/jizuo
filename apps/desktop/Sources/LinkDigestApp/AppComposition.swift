import Foundation
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestTransport

struct AppBootstrapResult: Sendable {
  let availability: StorageAvailability
  let history: HistoryApplicationService?
  let historyIsReadOnly: Bool
  let historyReadOnlyReason: RepositoryRecoveryReason?
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

    init(
      applicationSupportRoot: @escaping ApplicationSupportRoot,
      repositoryFactory: @escaping RepositoryFactory,
      nowMilliseconds: @escaping @Sendable () -> Int64,
      serverStarter: @escaping ServerStarter,
      availabilitySink: @escaping AvailabilitySink,
      captureSink: @escaping CaptureReceiver.CaptureSink
    ) {
      self.applicationSupportRoot = applicationSupportRoot
      self.repositoryFactory = repositoryFactory
      self.nowMilliseconds = nowMilliseconds
      self.serverStarter = serverStarter
      self.availabilitySink = availabilitySink
      self.captureSink = captureSink
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
          captureSink: dependencies.captureSink
        )
        let started = startServer(receiver, using: dependencies.serverStarter)
        return .init(
          availability: .writable,
          history: history,
          historyIsReadOnly: false,
          historyReadOnlyReason: nil,
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
        captureSink: dependencies.captureSink
      )
      return .init(
        availability: availability,
        history: HistoryApplicationService(repository: repository),
        historyIsReadOnly: true,
        historyReadOnlyReason: reason,
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
      captureSink: dependencies.captureSink
    )
    return .init(
      availability: degraded,
      history: nil,
      historyIsReadOnly: false,
      historyReadOnlyReason: nil,
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

func makeUnixSocketServerStarter(
  path: String,
  statusSink: @escaping @Sendable (String) async -> Void
) -> AppComposition.ServerStarter {
  { receiver in
    let server = UnixSocketServer(path: path)
    try server.start()
    Task { await statusSink("本机接收服务已启动") }
    Task.detached(priority: .userInitiated) {
      while !Task.isCancelled {
        let client: FileHandle
        do {
          client = try server.accept(timeout: 1, ioTimeout: 10)
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
          continue
        } catch {
          await statusSink("接收服务错误")
          return
        }
        Task.detached { await receiver.handleClient(client) }
      }
    }
  }
}
