import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 阅读位置落库（Migration023）。
///
/// 它以前住在 UserDefaults 里，三个后果：删掉记录那条键永远留着、备份带不走它、
/// 它和它描述的那条内容分属两个存储。这里钉的是搬完之后那三条都成立。
final class ReadingProgressStoreTests: XCTestCase {
  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-reading-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    try body(repository)
  }

  private func makeTask(_ repository: GRDBHistoryRepository, url: String) throws -> TaskID {
    try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-09-01T00:00:00Z",
        idempotencyKey: "reading-\(url)",
        origin: .manualLink,
        url: url,
        title: "标题",
        platform: "generic",
        method: "rendered_dom",
        text: "正文",
        completeness: "complete",
        capturedAt: "2026-09-01T00:00:00Z",
        sourceLabel: "浏览器扩展"
      ),
      receivedAtMilliseconds: 1_000
    )).taskID
  }

  func testPositionRoundTripsAndOverwrites() throws {
    try withRepository { repository in
      let taskID = try makeTask(repository, url: "https://example.test/read")
      // 没读过是 nil，不是 0：调用方要能区分「读到开头」和「从没打开过」。
      XCTAssertNil(try repository.readingPosition(taskID: taskID))

      try repository.saveReadingPosition(0.35, taskID: taskID, updatedAtMilliseconds: 10)
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.35, accuracy: 0.0001)

      // 覆盖而不是追加：一条内容只有一个「读到哪」。
      try repository.saveReadingPosition(0.80, taskID: taskID, updatedAtMilliseconds: 20)
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.80, accuracy: 0.0001)
      let rows = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_progress") ?? 0
      }
      XCTAssertEqual(rows, 1)
    }
  }

  func testPositionIsClampedToZeroAndOne() throws {
    try withRepository { repository in
      let taskID = try makeTask(repository, url: "https://example.test/clamp")
      try repository.saveReadingPosition(1.4, taskID: taskID, updatedAtMilliseconds: 10)
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 1)
      try repository.saveReadingPosition(-0.2, taskID: taskID, updatedAtMilliseconds: 20)
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0)
    }
  }

  /// 这一条是搬家的主要理由：删掉记录，进度跟着走。
  ///
  /// 在 UserDefaults 那一版里，`reading.position.v1.<id>` 会永远留着，
  /// 而且没有任何一处会清——键单调堆积，直到重装。
  func testDeletingTaskAlsoRemovesItsReadingPosition() throws {
    try withRepository { repository in
      let taskID = try makeTask(repository, url: "https://example.test/gone")
      try repository.saveReadingPosition(0.5, taskID: taskID, updatedAtMilliseconds: 10)
      _ = try repository.deleteTasks(taskIDs: [taskID])
      let rows = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_progress") ?? 0
      }
      XCTAssertEqual(rows, 0, "记录删了，阅读进度不该留下无主行")
    }
  }

  /// 进回收站**不**清进度：恢复之后应该还在原来读到的地方。
  func testMovingToTrashKeepsReadingPosition() throws {
    try withRepository { repository in
      let taskID = try makeTask(repository, url: "https://example.test/trash")
      try repository.saveReadingPosition(0.6, taskID: taskID, updatedAtMilliseconds: 10)
      try repository.moveToTrash(taskIDs: [taskID])
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.6, accuracy: 0.0001)
      try repository.restoreFromTrash(taskIDs: [taskID])
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.6, accuracy: 0.0001)
    }
  }

  /// 记录不在了就静默跳过：这条路径是滚动时触发的，报错只会变成一串没人处理的噪音。
  func testSavingForUnknownTaskIsIgnored() throws {
    try withRepository { repository in
      XCTAssertNoThrow(try repository.saveReadingPosition(0.3, taskID: TaskID(), updatedAtMilliseconds: 10))
      let rows = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_progress") ?? 0
      }
      XCTAssertEqual(rows, 0)
    }
  }

  /// 备份带得走它——这是搬家的第二个理由。
  func testReadingProgressSurvivesBackupAndRestore() throws {
    try withRepository { repository in
      let taskID = try makeTask(repository, url: "https://example.test/backup")
      try repository.saveReadingPosition(0.7, taskID: taskID, updatedAtMilliseconds: 10)

      let maintenance = DatabaseMaintenance(database: repository.database)
      let snapshot = try maintenance.backupToStore()
      try repository.saveReadingPosition(0.1, taskID: taskID, updatedAtMilliseconds: 20)
      _ = try maintenance.restoreInPlace(from: snapshot.url)

      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.7, accuracy: 0.0001)
    }
  }
}
