import Foundation
import GRDB
import LinkDigestCore

public struct DatabaseCheckpoint: Codable, Sendable, Equatable {
  public let busy: Int
  public let logFrames: Int
  public let checkpointedFrames: Int
  public init(busy: Int, logFrames: Int, checkpointedFrames: Int) { self.busy = busy; self.logFrames = logFrames; self.checkpointedFrames = checkpointedFrames }
}

public struct HistoryTableCounts: Codable, Sendable, Equatable {
  public let tasks: Int
  public let snapshots: Int
  public let deliveries: Int
  public let runs: Int
  public let artifacts: Int
  public init(tasks: Int, snapshots: Int, deliveries: Int, runs: Int, artifacts: Int) {
    self.tasks = tasks; self.snapshots = snapshots; self.deliveries = deliveries; self.runs = runs; self.artifacts = artifacts
  }
}

public struct DatabaseMaintenance: Sendable {
  private let database: LocalDatabase
  public init(database: LocalDatabase) { self.database = database }

  public func integrityCheck() throws -> String {
    try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
  }

  public func counts() throws -> HistoryTableCounts {
    try database.read(readTableCounts)
  }

  public func passiveCheckpoint() throws -> DatabaseCheckpoint { try checkpoint("PASSIVE") }
  public func truncateCheckpoint() throws -> DatabaseCheckpoint { try checkpoint("TRUNCATE") }

  public func backup(to backupURL: URL) throws -> HistoryTableCounts {
    do {
      try database.dependencies.beforeBackup()
      guard !FileManager.default.fileExists(atPath: backupURL.path) else { throw RepositoryFailure.invalidInput }
      try database.dependencies.createDirectory(backupURL.deletingLastPathComponent())
      let destination = try DatabaseQueue(path: backupURL.path)
      do {
        try database.backupSource(to: destination)
        try destination.writeWithoutTransaction { db in
          let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
          guard mode?.lowercased() == "delete" else { throw RepositoryFailure.unavailable }
        }
        let value = try destination.read(readTableCounts)
        try destination.close()
        return value
      } catch {
        try? destination.close()
        try? FileManager.default.removeItem(at: backupURL)
        throw error
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  public static func restore(from backupURL: URL, to location: LocalDatabaseLocation, dependencies: PersistenceDependencies = .live) throws -> LocalDatabase {
    do {
      try dependencies.beforeRestore()
      guard !FileManager.default.fileExists(atPath: location.databaseURL.path) else { throw RepositoryFailure.invalidInput }
      try dependencies.createDirectory(location.directoryURL)
      let stagingURL = location.directoryURL.appendingPathComponent(".restore-\(UUID().uuidString.lowercased()).sqlite")
      defer { try? FileManager.default.removeItem(at: stagingURL) }

      var readOnly = Configuration(); readOnly.readonly = true; readOnly.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
      let source = try dependencies.openReadOnly(backupURL.path, readOnly)
      let expected = try source.read(readTableCounts)
      let destination = try DatabaseQueue(path: stagingURL.path)
      try source.backup(to: destination)
      try source.close()
      try destination.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") }
      try destination.close()

      let verification = try dependencies.openReadOnly(stagingURL.path, readOnly)
      let integrity = try verification.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "missing" }
      let actual = try verification.read(readTableCounts)
      let foreignKeyFailures = try verification.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
      try verification.close()
      guard integrity == "ok", expected == actual, foreignKeyFailures == 0 else { throw RepositoryFailure.integrityCheckFailed }

      try FileManager.default.moveItem(at: stagingURL, to: location.databaseURL)
      return try LocalDatabase.open(at: location, dependencies: dependencies)
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  private func checkpoint(_ mode: String) throws -> DatabaseCheckpoint {
    try database.writeWithoutTransaction { db in
      guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(\(mode))") else { throw RepositoryFailure.unavailable }
      return DatabaseCheckpoint(busy: row[0], logFrames: row[1], checkpointedFrames: row[2])
    }
  }
}

private func readTableCounts(_ db: Database) throws -> HistoryTableCounts {
  HistoryTableCounts(
    tasks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? 0,
    snapshots: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM content_snapshots") ?? 0,
    deliveries: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_deliveries") ?? 0,
    runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? 0,
    artifacts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts") ?? 0
  )
}
