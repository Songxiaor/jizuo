import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

/// 搜索必须能搜到正文和标签。
///
/// 改这里之前只搜链接、标题、来源标签——「我记得有篇讲盲派格局的」找不回来，
/// 因为那篇标题里根本没有「盲派」。条目一多，搜不到正文等于搜索废掉。
/// 这类缺陷不报错、不崩溃，只是东西找不回来，所以用测试钉住。
final class HistorySearchScopeTests: XCTestCase {
  private func capture(
    url: String,
    title: String,
    body: String,
    sourceLabel: String = "浏览器扩展"
  ) -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-07-28T00:00:00Z",
      idempotencyKey: "search-test-\(url)",
      origin: .manualLink,
      url: url,
      title: title,
      platform: "generic",
      method: "rendered_dom",
      text: body,
      completeness: "complete",
      capturedAt: "2026-07-28T00:00:00Z",
      sourceLabel: sourceLabel
    )
  }

  /// 与 HistoryPersistenceTests 里那个同形；那边是 private，跨文件用不了。
  private func withRepository(
    _ body: (GRDBHistoryRepository, LocalDatabaseLocation) throws -> Void
  ) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-search-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let location = LocalDatabaseLocation(directoryURL: directory)
    let repository = try GRDBHistoryRepository.open(at: location, dependencies: .live)
    defer { try? repository.database.close() }
    try body(repository, location)
  }

  private func search(_ repository: GRDBHistoryRepository, _ text: String) throws -> [String] {
    try repository.historyPage(limit: 50, after: nil, filter: .init(searchText: text))
      .rows.map(\.taskID.rawValue)
  }

  func testSearchMatchesBodyTextNotJustTitle() throws {
    try withRepository { repository, _ in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/a",
        title: "完全无关的标题",
        body: "咱们来讲讲命局中的格局配置情况，先说说盲派命理对格局的概念。"
      ), receivedAtMilliseconds: 1))
      _ = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/b",
        title: "另一条",
        body: "毫不相干的内容。"
      ), receivedAtMilliseconds: 1))

      // 这一条是整件事的起点：关键词只在正文里，标题里没有。
      XCTAssertEqual(try search(repository, "盲派"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "格局配置"), [target.taskID.rawValue])
      // 原有维度不能因此失效。
      XCTAssertEqual(try search(repository, "完全无关"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "example.test/a"), [target.taskID.rawValue])
    }
  }

  /// 作者写在正文 frontmatter 里，搜正文自然覆盖——不必单独加一列。
  func testAuthorInFrontmatterIsReachableThroughBodySearch() throws {
    try withRepository { repository, _ in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/c",
        title: "提升 Agent 的信息搜索能力",
        body: "---\nauthor: \"Orange AI (@oran_ge)\"\n---\n\n众所周知，搜索是最基础的能力。"
      ), receivedAtMilliseconds: 1))
      XCTAssertEqual(try search(repository, "oran_ge"), [target.taskID.rawValue])
      XCTAssertEqual(try search(repository, "Orange AI"), [target.taskID.rawValue])
    }
  }

  func testSearchMatchesTagNames() throws {
    try withRepository { repository, _ in
      let target = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/d",
        title: "无关标题",
        body: "无关正文。"
      ), receivedAtMilliseconds: 1))
      _ = try repository.addTags(["潜意识"], to: target.taskID)
      XCTAssertEqual(try search(repository, "潜意识"), [target.taskID.rawValue])
    }
  }

  /// 搜不中的必须真的搜不中，否则「能搜到」只是因为把所有条目都返回了。
  func testUnrelatedQueryReturnsNothing() throws {
    try withRepository { repository, _ in
      _ = try repository.acceptCapture(.init(document: capture(
        url: "https://example.test/e",
        title: "标题",
        body: "正文。"
      ), receivedAtMilliseconds: 1))
      XCTAssertTrue(try search(repository, "这个词哪里都没有").isEmpty)
    }
  }
}
