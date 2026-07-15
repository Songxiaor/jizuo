import Foundation
import GRDB
import LinkDigestCore

public final class LocalDatabase: @unchecked Sendable {
  enum Backend { case writable(DatabasePool), readOnly(DatabaseQueue) }

  public let location: LocalDatabaseLocation
  public let accessMode: HistoryRepositoryAccessMode
  let dependencies: PersistenceDependencies
  private let backend: Backend

  private init(location: LocalDatabaseLocation, accessMode: HistoryRepositoryAccessMode, dependencies: PersistenceDependencies, backend: Backend) {
    self.location = location
    self.accessMode = accessMode
    self.dependencies = dependencies
    self.backend = backend
  }

  public static func open(at location: LocalDatabaseLocation, dependencies: PersistenceDependencies = .live) throws -> LocalDatabase {
    let exists = FileManager.default.fileExists(atPath: location.databaseURL.path)
    if !exists {
      do { try dependencies.createDirectory(location.directoryURL) }
      catch let failure as RepositoryFailure { throw failure }
      catch { throw RepositoryFailure.unavailable }
    }

    if exists {
      let version: Int
      do {
        let probe = try dependencies.openReadOnly(location.databaseURL.path, readOnlyConfiguration())
        version = try probe.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        try probe.close()
      } catch let failure as RepositoryFailure { throw failure }
      catch { throw RepositoryFailure.unavailable }
      if version > Migration001.schemaVersion {
        return try makeReadOnly(at: location, reason: .futureSchema, dependencies: dependencies)
      }
    }

    do {
      let pool = try dependencies.openWritable(location.databaseURL.path, writableConfiguration())
      do {
        let version = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if version < Migration001.schemaVersion {
          try pool.write { db in
            try Migration001.apply(to: db, beforeCommit: dependencies.beforeMigrationCommit)
          }
        }
        return LocalDatabase(location: location, accessMode: .writable, dependencies: dependencies, backend: .writable(pool))
      } catch {
        try? pool.close()
        return try makeReadOnly(at: location, reason: .migrationFailed, dependencies: dependencies)
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch {
      if exists { return try makeReadOnly(at: location, reason: .storageUnavailable, dependencies: dependencies) }
      throw RepositoryFailure.unavailable
    }
  }

  public func close() throws {
    switch backend {
    case let .writable(pool): try pool.close()
    case let .readOnly(queue): try queue.close()
    }
  }

  func read<T>(_ body: (Database) throws -> T) throws -> T {
    do {
      switch backend {
      case let .writable(pool): return try pool.read(body)
      case let .readOnly(queue): return try queue.read(body)
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  func write<T>(_ body: (Database) throws -> T) throws -> T {
    guard case let .writable(pool) = backend else {
      if case let .readOnly(reason) = accessMode { throw RepositoryFailure.readOnly(reason) }
      throw RepositoryFailure.unavailable
    }
    do {
      try dependencies.beforeWrite()
      return try pool.write(body)
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  func writeWithoutTransaction<T>(_ body: (Database) throws -> T) throws -> T {
    guard case let .writable(pool) = backend else {
      if case let .readOnly(reason) = accessMode { throw RepositoryFailure.readOnly(reason) }
      throw RepositoryFailure.unavailable
    }
    do {
      try dependencies.beforeWrite()
      return try pool.writeWithoutTransaction(body)
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  func backupSource(to destination: DatabaseQueue) throws {
    do {
      switch backend {
      case let .writable(pool): try pool.backup(to: destination)
      case let .readOnly(queue): try queue.backup(to: destination)
      }
    } catch { throw RepositoryFailure.unavailable }
  }

  private static func makeReadOnly(at location: LocalDatabaseLocation, reason: RepositoryRecoveryReason, dependencies: PersistenceDependencies) throws -> LocalDatabase {
    do {
      let queue = try dependencies.openReadOnly(location.databaseURL.path, readOnlyConfiguration())
      return LocalDatabase(location: location, accessMode: .readOnly(reason), dependencies: dependencies, backend: .readOnly(queue))
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  private static func writableConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.busyMode = .timeout(2)
    configuration.maximumReaderCount = 8
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    return configuration
  }

  private static func readOnlyConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(2)
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
    return configuration
  }
}
