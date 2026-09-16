import Foundation
import GRDB
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 连接级 PRAGMA 是「设了没设」这种沉默事实：设错了不报错，只是慢或者不省。
///
/// 曾经加上 `synchronous = NORMAL` 后持久化测试整批变红，当时误判成 PRAGMA 的锅
/// 而回退；真正的原因在资源包布局（已修）。这次把它钉住：写连接是 NORMAL(1) 且
/// 缓存 16MB，只读连接**不套这套 PRAGMA**——它本来就不写盘，跟着改只是徒增一个
/// 和写入语义无关的差异。
final class DatabasePragmaTests: XCTestCase {
  private func withTemporaryDirectory(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-pragma-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  func testWritableConnectionsUseSynchronousNormal() throws {
    try withTemporaryDirectory { location in
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let onWriter = try database.write { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") }
      XCTAssertEqual(onWriter, 1, "写连接应当是 NORMAL(1)")
      let onReader = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") }
      XCTAssertEqual(onReader, 1, "池里的读连接同样走 prepareDatabase，也应当是 NORMAL(1)")
    }
  }

  func testWritableConnectionsUseSixteenMegabyteCache() throws {
    try withTemporaryDirectory { location in
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      // 负数按 KB 计：-16000 = 16MB。
      let cacheSize = try database.write { db in try Int.fetchOne(db, sql: "PRAGMA cache_size") }
      XCTAssertEqual(cacheSize, -16_000)
    }
  }

  func testForeignKeysStayOnAlongsideTheNewPragmas() throws {
    try withTemporaryDirectory { location in
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let foreignKeys = try database.write { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
      XCTAssertEqual(foreignKeys, 1)
    }
  }

  func testReadOnlyConnectionsKeepSQLiteDefaults() throws {
    try withTemporaryDirectory { location in
      do {
        let database = try LocalDatabase.open(at: location)
        try database.close()
      }
      // 把 user_version 顶到未来版本，`open` 会退化成只读连接。
      let raw = try DatabaseQueue(path: location.databaseURL.path)
      try raw.write { db in
        try db.execute(sql: "PRAGMA user_version = \(LocalDatabase.latestSchemaVersion + 50)")
      }
      try raw.close()

      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      guard case .readOnly = database.accessMode else {
        return XCTFail("未来 schema 应当退化成只读")
      }
      // `synchronous` 在 WAL 库上本来就默认 NORMAL，读回来分不出「我们设的」和
      // 「SQLite 自己的默认」。`cache_size` 分得出：我们给写连接设的是 -16000
      // （负数按 KB 计），SQLite 自己的默认是正数页数。
      let cacheSize = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA cache_size") }
      XCTAssertNotEqual(cacheSize, -16_000, "只读连接不套写连接那套 PRAGMA")
      XCTAssertEqual((cacheSize ?? 0) > 0, true, "只读连接停在 SQLite 默认的按页计数：\(cacheSize as Any)")
    }
  }

  /// 迁移本身要能在打开这些 PRAGMA 的连接上跑完。
  ///
  /// 「PRAGMA 导致持久化测试失败」的旧结论就是在这一步被证伪的：真正的失败在
  /// 资源包，不在同步级别。这条测试让新库能建起来这件事有一个直接证据。
  func testFreshDatabaseMigratesToLatestSchemaWithPragmasOn() throws {
    try withTemporaryDirectory { location in
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      let version = try database.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") }
      XCTAssertEqual(version, LocalDatabase.latestSchemaVersion)
      XCTAssertEqual(database.accessMode, .writable)
    }
  }
}
