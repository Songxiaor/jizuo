import Foundation
import XCTest
import LinkDigestCore
import LinkDigestPersistence
@testable import LinkDigestApp

@MainActor
final class ReadingContinuityTests: XCTestCase {
  func testCitationIncludesSelectionTitleAndSource() {
    let value = ReadingCitationFormatter.format(
      selection: "  一段值得保留的话。  ",
      title: "文章标题",
      sourceURL: "https://example.test/article"
    )
    XCTAssertTrue(value.hasPrefix("一段值得保留的话。"))
    XCTAssertTrue(value.contains("《文章标题》"))
    XCTAssertTrue(value.hasSuffix("https://example.test/article"))
  }

  func testSummaryCitationMatcherKeepsOnlyExactSourceQuotes() {
    let source = "开头。\n\n这是一段来自原文的完整引用。\n\n结尾。"
    let summary = "> 这是一段来自原文的完整引用。\n\n> 这段并不在原文里。"
    XCTAssertEqual(
      SummaryCitationMatcher.exactQuotes(summary: summary, source: source),
      ["这是一段来自原文的完整引用。"]
    )
  }

  /// 阅读位置现在落在数据库里（Migration023）。
  ///
  /// 这一条钉的是「库接上之前也不能弄丢进度」：详情页在冷启动的头几百毫秒就可能
  /// 打开，那时历史还没就绪。如果那时读到 0 并且把 0 写回去，用户真正读到的位置
  /// 就被这次「过早的 0」覆盖掉了——所以接上之前的读写只留在内存里，接上时补写。
  func testReadingPositionIsBufferedBeforeStorageIsReadyThenFlushed() throws {
    try withTemporaryHistory { history, repository in
      let taskID = try seedTask(repository)
      // 库还没接上：写入只留在内存里，读回来仍然是刚写的那个值。
      ReadingPositionStore.configure(history: nil)
      ReadingPositionStore.save(0.44, for: taskID.rawValue)
      XCTAssertEqual(ReadingPositionStore.progress(for: taskID.rawValue), 0.44, accuracy: 0.0001)
      XCTAssertNil(try repository.readingPosition(taskID: taskID))

      // 接上之后补写进库。
      ReadingPositionStore.configure(history: history)
      defer { ReadingPositionStore.configure(history: nil) }
      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.44, accuracy: 0.0001)
      XCTAssertEqual(ReadingPositionStore.progress(for: taskID.rawValue), 0.44, accuracy: 0.0001)
    }
  }

  func testReadingPositionClampsAndRoundTripsThroughStorage() throws {
    try withTemporaryHistory { history, repository in
      let taskID = try seedTask(repository)
      ReadingPositionStore.configure(history: history)
      defer { ReadingPositionStore.configure(history: nil) }

      ReadingPositionStore.save(1.4, for: taskID.rawValue)
      XCTAssertEqual(ReadingPositionStore.progress(for: taskID.rawValue), 1)
      ReadingPositionStore.save(-0.2, for: taskID.rawValue)
      XCTAssertEqual(ReadingPositionStore.progress(for: taskID.rawValue), 0)
      // 不是一条 task 的标识（历史上的合成 id）一律忽略，不炸。
      ReadingPositionStore.save(0.5, for: "not-a-uuid")
      XCTAssertEqual(ReadingPositionStore.progress(for: "not-a-uuid"), 0)
    }
  }

  /// 旧的 UserDefaults 进度搬一次就删键，不留双写。
  ///
  /// 留着双写的话「哪一边是真的」就成了永远要回答的问题，而两边一旦不一致，
  /// 用户看到的是进度自己跳回去。
  func testLegacyDefaultsAreMigratedOnceAndTheKeysAreRemoved() throws {
    let (_, defaults) = try ephemeralDefaults("linkdigest-reading-legacy-")
    try withTemporaryHistory { history, repository in
      let taskID = try seedTask(repository)
      let orphanKey = ReadingPositionStore.legacyPrefix + "not-a-task-id"
      defaults.set(0.62, forKey: ReadingPositionStore.legacyPrefix + taskID.rawValue)
      defaults.set(0.31, forKey: orphanKey)

      ReadingPositionStore.migrateLegacyDefaultsIfNeeded(history: history, defaults: defaults)

      XCTAssertEqual(try XCTUnwrap(repository.readingPosition(taskID: taskID)), 0.62, accuracy: 0.0001)
      XCTAssertNil(defaults.object(forKey: ReadingPositionStore.legacyPrefix + taskID.rawValue))
      XCTAssertNil(
        defaults.object(forKey: orphanKey),
        "无主的旧键正是这次要清掉的东西"
      )
    }
  }

  // MARK: - 夹具

  private func withTemporaryHistory(
    _ body: (HistoryApplicationService, GRDBHistoryRepository) throws -> Void
  ) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-reading-continuity-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    try body(HistoryApplicationService(repository: repository), repository)
  }

  @discardableResult
  private func seedTask(_ repository: GRDBHistoryRepository) throws -> TaskID {
    let seed = UUID().uuidString.lowercased()
    return try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-09-01T00:00:00Z",
        idempotencyKey: "reading-continuity-\(seed)",
        origin: .manualLink,
        url: "https://example.test/\(seed)",
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
}
