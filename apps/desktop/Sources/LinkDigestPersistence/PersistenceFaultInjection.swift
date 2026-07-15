import Foundation
import GRDB
import LinkDigestCore

public struct PersistenceDependencies: @unchecked Sendable {
  public var createDirectory: @Sendable (URL) throws -> Void
  public var openWritable: @Sendable (String, Configuration) throws -> DatabasePool
  public var openReadOnly: @Sendable (String, Configuration) throws -> DatabaseQueue
  public var beforeWrite: @Sendable () throws -> Void
  public var beforeMigrationCommit: @Sendable () throws -> Void
  public var beforeTerminalCommit: @Sendable () throws -> Void
  public var beforeBackup: @Sendable () throws -> Void
  public var beforeRestore: @Sendable () throws -> Void

  public init(
    createDirectory: @escaping @Sendable (URL) throws -> Void,
    openWritable: @escaping @Sendable (String, Configuration) throws -> DatabasePool,
    openReadOnly: @escaping @Sendable (String, Configuration) throws -> DatabaseQueue,
    beforeWrite: @escaping @Sendable () throws -> Void = {},
    beforeMigrationCommit: @escaping @Sendable () throws -> Void = {},
    beforeTerminalCommit: @escaping @Sendable () throws -> Void = {},
    beforeBackup: @escaping @Sendable () throws -> Void = {},
    beforeRestore: @escaping @Sendable () throws -> Void = {}
  ) {
    self.createDirectory = createDirectory
    self.openWritable = openWritable
    self.openReadOnly = openReadOnly
    self.beforeWrite = beforeWrite
    self.beforeMigrationCommit = beforeMigrationCommit
    self.beforeTerminalCommit = beforeTerminalCommit
    self.beforeBackup = beforeBackup
    self.beforeRestore = beforeRestore
  }

  public static let live = PersistenceDependencies(
    createDirectory: { url in try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) },
    openWritable: { path, configuration in try DatabasePool(path: path, configuration: configuration) },
    openReadOnly: { path, configuration in try DatabaseQueue(path: path, configuration: configuration) }
  )

  public static func failing(
    open: Bool = false,
    write: Bool = false,
    createDirectory: Bool = false,
    migration: Bool = false,
    backup: Bool = false,
    restore: Bool = false
  ) -> PersistenceDependencies {
    var value = Self.live
    if open {
      value.openWritable = { _, _ in throw RepositoryFailure.injectedFailure }
      value.openReadOnly = { _, _ in throw RepositoryFailure.injectedFailure }
    }
    if write { value.beforeWrite = { throw RepositoryFailure.injectedFailure } }
    if createDirectory { value.createDirectory = { _ in throw RepositoryFailure.injectedFailure } }
    if migration { value.beforeMigrationCommit = { throw RepositoryFailure.injectedFailure } }
    if write { value.beforeTerminalCommit = { throw RepositoryFailure.injectedFailure } }
    if backup { value.beforeBackup = { throw RepositoryFailure.injectedFailure } }
    if restore { value.beforeRestore = { throw RepositoryFailure.injectedFailure } }
    return value
  }
}
