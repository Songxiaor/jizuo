import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 文章级收藏：标记要能持久化，「收藏」筛选只回收藏项，侧栏计数要对。
///
/// 这三件事任何一个错都不报错、不崩溃，只是收藏形同虚设，所以用测试钉住。
/// 注意收藏是纯用户标记，不能顺手改 updated_at_ms——否则收藏一下就把条目顶到最前。
final class HistoryFavoriteTests: XCTestCase {
  private func capture(_ tag: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-07-28T00:00:00Z",
      idempotencyKey: "favorite-test-\(tag)",
      origin: .manualLink,
      url: "https://example.test/\(tag)",
      title: "条目\(tag)",
      platform: "generic",
      method: "rendered_dom",
      text: "正文 \(tag)",
      completeness: "complete",
      capturedAt: "2026-07-28T00:00:00Z",
      sourceLabel: "浏览器扩展")
  }

  private func withRepository(_ body: (GRDBHistoryRepository) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-favorite-tests-\(UUID().uuidString)",
      isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(
      at: LocalDatabaseLocation(directoryURL: directory), dependencies: .live)
    defer { try? repository.database.close() }
    try body(repository)
  }

  private func favoriteRows(_ repository: GRDBHistoryRepository) throws -> [String] {
    try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .favorite))
      .rows.map(\.taskID.rawValue)
  }

  func testFavoriteFilterReturnsOnlyFavorites() throws {
    try withRepository { repository in
      let a = try repository.acceptCapture(.init(document: capture("a"), receivedAtMilliseconds: 1))
      _ = try repository.acceptCapture(.init(document: capture("b"), receivedAtMilliseconds: 2))

      XCTAssertEqual(try favoriteRows(repository), [], "还没收藏任何条目")

      try repository.setFavorite(true, for: a.taskID)
      XCTAssertEqual(try favoriteRows(repository), [a.taskID.rawValue], "收藏后只该出现 a")
      XCTAssertEqual(
        try repository.navigationCounts().favorite, 1, "侧栏收藏计数要跟上")

      try repository.setFavorite(false, for: a.taskID)
      XCTAssertEqual(try favoriteRows(repository), [], "取消收藏后应清空")
      XCTAssertEqual(try repository.navigationCounts().favorite, 0)
    }
  }

  func testFavoriteFlagSurfacesOnRowAndDetail() throws {
    try withRepository { repository in
      let a = try repository.acceptCapture(.init(document: capture("a"), receivedAtMilliseconds: 1))
      try repository.setFavorite(true, for: a.taskID)

      let row = try repository.historyPage(limit: 50, after: nil, filter: .init())
        .rows.first { $0.taskID == a.taskID }
      XCTAssertEqual(row?.isFavorite, true, "列表行要带收藏标记")
      XCTAssertTrue(try repository.detail(taskID: a.taskID).isFavorite, "详情要带收藏标记")
    }
  }

  /// 收藏不能改动更新时间，否则会打乱按时间的阅读顺序。
  func testFavoriteDoesNotBumpUpdatedTimestamp() throws {
    try withRepository { repository in
      let a = try repository.acceptCapture(.init(document: capture("a"), receivedAtMilliseconds: 1))
      let before = try repository.detail(taskID: a.taskID).task.updatedAtMilliseconds
      try repository.setFavorite(true, for: a.taskID)
      let after = try repository.detail(taskID: a.taskID).task.updatedAtMilliseconds
      XCTAssertEqual(before, after, "收藏是纯标记，不该顶更新时间")
    }
  }

  func testSettingFavoriteOnMissingTaskThrows() throws {
    try withRepository { repository in
      XCTAssertThrowsError(try repository.setFavorite(true, for: TaskID()))
    }
  }
}
