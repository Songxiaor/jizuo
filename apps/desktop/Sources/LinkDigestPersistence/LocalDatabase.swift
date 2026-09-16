import Foundation
import GRDB
import LinkDigestCore

public final class LocalDatabase: @unchecked Sendable {
  /// 当前 schema 版本的**唯一来源**。
  ///
  /// 加一次迁移就只改这一行。之前生产代码和测试各自引用「最后那个 Migration0NN」，
  /// 于是每加一次迁移，迁移测试就整批变红——因为它们钉的是一个具体版本号，
  /// 而它们真正想表达的是「跟着最新走」。
  public static let latestSchemaVersion = Migration023.schemaVersion

  enum Backend { case writable(DatabasePool), readOnly(DatabaseQueue) }

  public let location: LocalDatabaseLocation
  public let accessMode: HistoryRepositoryAccessMode
  /// 这次打开时为「升级前」自动存下的那份备份。
  ///
  /// 升级成功时它仍然留在 `backups/` 里（受数量上限管），这里只在**升级失败**
  /// 并因此降级成只读时才有值：那种情况下用户最需要知道的一件事就是
  /// 「你的原始数据在这个文件里，一个字没动」。
  public let migrationBackupURL: URL?
  let dependencies: PersistenceDependencies
  private let backend: Backend

  /// 只读降级时给用户看的一句补充说明。可写时为 nil。
  public var readOnlyRecoveryHint: String? {
    guard case let .readOnly(reason) = accessMode else { return nil }
    switch reason {
    case .futureSchema:
      return "这个资料库是更新版本的汲作写的，当前版本只能查看，不能改动。升级到最新版即可恢复。"
    case .migrationFailed:
      if let migrationBackupURL {
        return "升级资料库时出错，已按只读方式打开。升级前的完整备份保存在：\(migrationBackupURL.path)"
      }
      return "升级资料库时出错，已按只读方式打开。"
    case .storageUnavailable:
      return "资料库暂时打不开，已按只读方式打开可读的部分。"
    }
  }

  private init(
    location: LocalDatabaseLocation,
    accessMode: HistoryRepositoryAccessMode,
    dependencies: PersistenceDependencies,
    backend: Backend,
    migrationBackupURL: URL? = nil
  ) {
    self.location = location
    self.accessMode = accessMode
    self.dependencies = dependencies
    self.backend = backend
    self.migrationBackupURL = migrationBackupURL
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
      // 升级前存下的那份备份。放在两层 do 之外，失败分支才拿得到它的路径。
      var migrationBackupURL: URL?
      do {
        let version = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if version < Self.latestSchemaVersion {
          // 迁移是全库范围、不可逆的改写，而它一旦中途出错，用户看到的是
          // 「App 打不开了」而不是「升级失败」。这里在动任何 schema 之前先整库
          // 存一份，用 SQLite 的在线备份 API 而不是拷文件——WAL 模式下主库文件
          // 本身不是完整状态，拷出来的经常是一份少了最近写入的库。
          //
          // 备份失败就**不升级**，直接按只读打开：升级前拿不到保险绳时，宁可让
          // 用户继续看得到东西，也不要赌一次没有退路的改写。磁盘满是最常见的
          // 触发条件，而磁盘满时做迁移本来也很危险。
          //
          // 全新库（version == 0 且文件不存在）没有东西可备，跳过。
          if exists, version > 0 {
            let store = DatabaseBackupStore(location: location)
            let url = store.url(forFileName: DatabaseBackupStore.automaticFileName(schemaVersion: version, at: Date()))
            try writeBackup(from: pool, to: url, dependencies: dependencies)
            migrationBackupURL = url
          }
          // 失败注入必须在「即将改 schema」之前，且对**任何**待执行的迁移生效。
          // 以前只挂在 Migration001 的 beforeCommit 上：从 v22 升到 v23 时 001
          // 根本不会跑，测试里的 `.failing(migration: true)` 就变成「升级成功」。
          try dependencies.beforeMigrationCommit()
          try pool.write { db in
            if version < Migration001.schemaVersion {
              try Migration001.apply(to: db, beforeCommit: {})
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
            if version < Migration020.schemaVersion {
              try Migration020.apply(to: db)
            }
            if version < Migration021.schemaVersion {
              try Migration021.apply(to: db)
            }
            if version < Migration022.schemaVersion {
              try Migration022.apply(to: db)
            }
            if version < Migration023.schemaVersion {
              try Migration023.apply(to: db)
            }
          }
          // 升级成功了，旧备份就只剩「万一」的价值：留最近 3 份，更早的删掉。
          // 清理失败不影响本次打开——那只是占地方。
          if migrationBackupURL != nil {
            _ = try? DatabaseBackupStore(location: location).pruneAutomaticBackups()
          }
        }
        // `tasks.normalized_host` 是按平台注册表算出来的物化列，而注册表是编译期
        // 常量：新版本加一个平台，旧记录的归属就该跟着变，但 schema 版本不会动，
        // 于是迁移链管不到它。这里比对一次表达式指纹，变了才重算全表——正常启动
        // 只多一次单行读。
        let hostClassificationIsCurrent = try pool.read(TaskClassificationSQL.hostClassificationIsCurrent)
        if !hostClassificationIsCurrent {
          try pool.write(TaskClassificationSQL.reconcileHostClassification)
        }
        return LocalDatabase(location: location, accessMode: .writable, dependencies: dependencies, backend: .writable(pool))
      } catch {
        try? pool.close()
        // 备份留着，不清理：这是失败之后唯一能拿回原始数据的东西。
        return try makeReadOnly(
          at: location,
          reason: .migrationFailed,
          dependencies: dependencies,
          migrationBackupURL: migrationBackupURL
        )
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

  private static func makeReadOnly(
    at location: LocalDatabaseLocation,
    reason: RepositoryRecoveryReason,
    dependencies: PersistenceDependencies,
    migrationBackupURL: URL? = nil
  ) throws -> LocalDatabase {
    do {
      let queue = try dependencies.openReadOnly(location.databaseURL.path, readOnlyConfiguration())
      return LocalDatabase(
        location: location,
        accessMode: .readOnly(reason),
        dependencies: dependencies,
        backend: .readOnly(queue),
        migrationBackupURL: migrationBackupURL
      )
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  /// 整库写一份到 `url`，走 SQLite 在线备份 API。
  ///
  /// 不用 `FileManager.copyItem`：WAL 模式下主库文件不是完整状态，最近的写入
  /// 还在 `-wal` 里，拷出来的是一份少了尾巴的库。备份产物统一转成 DELETE 日志
  /// 模式，这样它就是**单个自包含文件**，用户直接拷走也不会丢东西。
  static func writeBackup(from pool: DatabasePool, to url: URL, dependencies: PersistenceDependencies) throws {
    do {
      guard !FileManager.default.fileExists(atPath: url.path) else { throw RepositoryFailure.invalidInput }
      try dependencies.createDirectory(url.deletingLastPathComponent())
      let destination = try DatabaseQueue(path: url.path)
      do {
        try pool.backup(to: destination)
        try destination.writeWithoutTransaction { db in
          let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
          guard mode?.lowercased() == "delete" else { throw RepositoryFailure.unavailable }
        }
        try destination.close()
      } catch {
        try? destination.close()
        try? FileManager.default.removeItem(at: url)
        throw error
      }
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  /// 把 `source` 的内容整库写回**当前这个**库。恢复备份用。
  func restoreDestination(from source: DatabaseQueue) throws {
    guard case let .writable(pool) = backend else {
      if case let .readOnly(reason) = accessMode { throw RepositoryFailure.readOnly(reason) }
      throw RepositoryFailure.unavailable
    }
    do {
      try dependencies.beforeWrite()
      try source.backup(to: pool)
    } catch let failure as RepositoryFailure { throw failure }
    catch { throw RepositoryFailure.unavailable }
  }

  private static func writableConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.busyMode = .timeout(2)
    configuration.maximumReaderCount = 8
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA cache_size = -16000")
      // WAL 模式下 NORMAL 是标准配置：只在 checkpoint 时 fsync，断电最坏丢最后
      // 几个已提交事务，不会损坏库。默认的 FULL 让每次自动保存、每条 token 台账
      // 都等一次磁盘同步。cache_size 负数按 KB 计：整库 8MB 左右，16MB 足够常驻。
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
