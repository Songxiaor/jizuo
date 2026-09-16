import Foundation
import GRDB
@testable import LinkDigestPersistence

/// 造一个「停在某个历史版本」的库。
///
/// 迁移链在生产代码里是 `LocalDatabase.open` 里一串 `if version < N`，那串代码
/// 只能从头跑到最新版；要测「从 v20 升上来」就必须能停在 v20。这里把手动逐条
/// apply 的那段收成一处——每个迁移测试各抄一份的话，加一次迁移就要改好几处，
/// 而漏改的表现是「那个测试悄悄停在更早的版本上」，看着照样绿。
enum MigrationFixture {
  /// 可以造出来的历史版本。加迁移时在这里补一条。
  static let supportedVersions = Array(1...LocalDatabase.latestSchemaVersion)

  static func apply(upTo version: Int, in db: Database) throws {
    precondition(version >= 1, "至少要建到 v1")
    if version >= 1 { try Migration001.apply(to: db, beforeCommit: {}) }
    if version >= 2 { try Migration002.apply(to: db) }
    if version >= 3 { try Migration003.apply(to: db) }
    if version >= 4 { try Migration004.apply(to: db) }
    if version >= 5 { try Migration005.apply(to: db) }
    if version >= 6 { try Migration006.apply(to: db) }
    if version >= 7 { try Migration007.apply(to: db) }
    if version >= 8 { try Migration008.apply(to: db) }
    if version >= 9 { try Migration009.apply(to: db) }
    if version >= 10 { try Migration010.apply(to: db) }
    if version >= 11 { try Migration011.apply(to: db) }
    if version >= 12 { try Migration012.apply(to: db) }
    if version >= 13 { try Migration013.apply(to: db) }
    if version >= 14 { try Migration014.apply(to: db) }
    if version >= 15 { try Migration015.apply(to: db) }
    if version >= 16 { try Migration016.apply(to: db) }
    if version >= 17 { try Migration017.apply(to: db) }
    if version >= 18 { try Migration018.apply(to: db) }
    if version >= 19 { try Migration019.apply(to: db) }
    if version >= 20 { try Migration020.apply(to: db) }
    if version >= 21 { try Migration021.apply(to: db) }
    if version >= 22 { try Migration022.apply(to: db) }
    if version >= 23 { try Migration023.apply(to: db) }
  }
}
