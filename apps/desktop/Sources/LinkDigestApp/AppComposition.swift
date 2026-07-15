import Foundation
import LinkDigestCore
import LinkDigestPersistence
import LinkDigestTransport

struct AppBootstrapResult: Sendable {
  let availability: StorageAvailability
  let history: HistoryApplicationService?
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
      return await finishUnavailable(
        .unavailable(mapped.code),
        dependencies: dependencies,
        storageWriteGate: storageWriteGate
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
