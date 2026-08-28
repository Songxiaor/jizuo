import Foundation
import GRDB
import LinkDigestCore

public final class LocalDatabase: @unchecked Sendable {
  /// 当前 schema 版本的**唯一来源**。
  ///
  /// 加一次迁移就只改这一行。之前生产代码和测试各自引用「最后那个 Migration0NN」，
  /// 于是每加一次迁移，迁移测试就整批变红——因为它们钉的是一个具体版本号，
  /// 而它们真正想表达的是「跟着最新走」。
  public static let latestSchemaVersion = Migration019.schemaVersion

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
      if version > Self.latestSchemaVersion {
        return try makeReadOnly(at: location, reason: .futureSchema, dependencies: dependencies)
      }
    }

    do {
      let pool = try dependencies.openWritable(location.databaseURL.path, writableConfiguration())
      do {
        let version = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if version < Self.latestSchemaVersion {
          try pool.write { db in
            if version < Migration001.schemaVersion {
              try Migration001.apply(to: db, beforeCommit: dependencies.beforeMigrationCommit)
            }
            if version < Migration002.schemaVersion {
              try Migration002.apply(to: db)
            }
            if version < Migration003.schemaVersion {
              try Migration003.apply(to: db)
            }
            if version < Migration004.schemaVersion {
              try Migration004.apply(to: db)
            }
            if version < Migration005.schemaVersion {
              try Migration005.apply(to: db)
            }
            if version < Migration006.schemaVersion {
              try Migration006.apply(to: db)
            }
            if version < Migration007.schemaVersion {
              try Migration007.apply(to: db)
            }
            if version < Migration008.schemaVersion {
              try Migration008.apply(to: db)
            }
            if version < Migration009.schemaVersion {
              try Migration009.apply(to: db)
            }
            if version < Migration010.schemaVersion {
              try Migration010.apply(to: db)
            }
            if version < Migration011.schemaVersion {
              try Migration011.apply(to: db)
            }
            if version < Migration012.schemaVersion {
              try Migration012.apply(to: db)
            }
            if version < Migration013.schemaVersion {
              try Migration013.apply(to: db)
            }
            if version < Migration014.schemaVersion {
              try Migration014.apply(to: db)
            }
            if version < Migration015.schemaVersion {
              try Migration015.apply(to: db)
            }
            if version < Migration016.schemaVersion {
              try Migration016.apply(to: db)
            }
            if version < Migration017.schemaVersion {
              try Migration017.apply(to: db)
            }
            if version < Migration018.schemaVersion {
              try Migration018.apply(to: db)
            }
            if version < Migration019.schemaVersion {
              try Migration019.apply(to: db)
            }
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
      // autocheckpoint 保持 SQLite 默认（1000 页，约 4MB 触发一次 PASSIVE
      // checkpoint）——这里**故意不写 pragma**，写了才是偏离。
      //
      // 2026-07-27 之前这里是 `PRAGMA wal_autocheckpoint = 0`，配上「生产代码零
      // checkpoint 调用方」，WAL 只增不减。旧注释推断增长「有界于一次会话」，理由
      // 是干净退出时 SQLite 会 checkpoint 并删掉 WAL——实测推翻了这个前提：
      // 退出钩子（LinkDigestApp 的 willTerminate / SIGTERM）只 stop socket 和清
      // 临时文件，`LocalDatabase.close()` 在 App 里零调用方，进程直接终止，
      // 于是「干净退出」从未发生。实测后果：主库停在 364KB / 7-19，而 WAL 长到
      // 12.9MB，是主库的 35 倍，跨会话单调累积。
      //
      // 关闭 autocheckpoint 的常见理由是怕写入被 checkpoint 卡住，但默认的
      // autocheckpoint 走 PASSIVE：遇到活跃读者就放弃、不阻塞写入，那份担心本身
      // 不成立。原始意图无从考证（随 aeb5e2e「freeze P0-RC-02B baseline」96 文件
      // 一起进来，提交无正文，全仓文档零处提及 autocheckpoint），因此按标准行为
      // 收敛而不是继续猜。
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
