import XCTest
import LinkDigestCore
import LinkDigestPersistence
@testable import LinkDigestApp

/// 备份记录里的「这是什么备份」。
///
/// 恢复前存的那份以前落到兜底分支，显示成「手动备份」——用户看到一条自己没按过
/// 的「手动备份」，会以为是谁替他存了一份。
final class DataBackupKindTextTests: XCTestCase {
  private func file(
    _ name: String,
    isAutomatic: Bool = false,
    isDaily: Bool = false,
    isBeforeRestore: Bool = false
  ) -> DatabaseBackupFile {
    DatabaseBackupFile(
      url: URL(fileURLWithPath: "/tmp/linkdigest-kind-\(name)"),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      byteCount: 1_024,
      isAutomatic: isAutomatic,
      isDaily: isDaily,
      isBeforeRestore: isBeforeRestore
    )
  }

  func testBeforeRestoreBackupIsLabelledForWhatItIs() {
    XCTAssertEqual(
      DataBackupViewModel.kindText(file("history-before-restore-20260101-120000.sqlite", isBeforeRestore: true)),
      "恢复前备份"
    )
  }

  func testOtherKindsKeepTheirLabels() {
    XCTAssertEqual(
      DataBackupViewModel.kindText(file("history-daily-20260101-120000.sqlite", isDaily: true)),
      "每日自动备份"
    )
    XCTAssertEqual(
      DataBackupViewModel.kindText(file("history-v22-20260101-120000.sqlite", isAutomatic: true)),
      "升级前自动备份"
    )
    XCTAssertEqual(
      DataBackupViewModel.kindText(file("history-manual-20260101-120000.sqlite")),
      "手动备份"
    )
  }
}
