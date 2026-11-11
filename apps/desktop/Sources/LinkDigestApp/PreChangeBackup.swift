import Foundation
import LinkDigestPersistence

/// 批量改动前的整库备份，走和「设置 → 数据备份 → 立即备份」同一条路
/// （`DatabaseMaintenance.backupToStore()`），并和每日自动备份互斥。
/// 失败一律往外抛：调用方据此**不执行**后面的改动。
enum PreChangeBackup {
  static func perform(location: LocalDatabaseLocation) async throws {
    try await Task.detached(priority: .userInitiated) {
      guard DatabaseBackupActivity.tryBegin() else { throw DatabaseBackupBusyError() }
      defer { DatabaseBackupActivity.end() }
      let database = try LocalDatabase.open(at: location)
      defer { try? database.close() }
      _ = try DatabaseMaintenance(database: database).backupToStore()
    }.value
  }
}
