import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 三模块的边界。
///
/// 输入(抓取 + 笔记)、工作台(稿件)、输出各看各的。这组测试钉的就是
/// 「谁能在哪儿被看到」——那是三个模块之所以是三个模块的全部意义。
final class PieceDraftIsolationTests: XCTestCase {
  private func seed(_ repository: GRDBHistoryRepository) throws -> (captured: TaskID, note: TaskID, draft: TaskID) {
    // 用当前时间:`recent` 是「最近 7 天」,写死 1970 的时间戳会让它永远为空,
    // 那时失败的是测试数据而不是被测逻辑。
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let captured = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-02T00:00:00Z", origin: .manualLink,
        url: "https://example.test/a", title: "一篇抓来的网页",
        platform: "web", method: "fixture", text: "抓取正文里也有关键词 knowledge",
        completeness: "complete", capturedAt: "2026-08-02T00:00:00Z", sourceLabel: "网页"
      ),
      receivedAtMilliseconds: now
    )).taskID
    let note = try repository.acceptCapture(.init(
      document: try UserNoteDocument.make(title: "我的笔记", body: "笔记正文 knowledge"),
      receivedAtMilliseconds: now + 1
    )).taskID
    let draft = try repository.acceptCapture(.init(
      document: try PieceDraftDocument.make(title: "某件创作的稿子", body: "稿件正文 knowledge"),
      receivedAtMilliseconds: now + 2
    )).taskID
    return (captured, note, draft)
  }

  private func ids(_ page: HistoryPage) -> Set<TaskID> { Set(page.rows.map(\.taskID)) }

  private func page(
    _ repository: GRDBHistoryRepository, _ scope: HistoryListScope, search: String = ""
  ) throws -> HistoryPage {
    try repository.historyPage(
      limit: 50, after: nil as HistoryPageCursor?,
      filter: HistoryListFilter(scope: scope, searchText: search)
    )
  }

  /// 稿件能落库,而且用的是自己的 scheme。
  func testDraftIsAcceptedWithItsOwnScheme() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let seeded = try seed(repository)

      let detail = try repository.detail(taskID: seeded.draft)
      XCTAssertTrue(try XCTUnwrap(CanonicalURL(detail.task.canonicalURL)).isDraft)
      XCTAssertEqual(detail.snapshots.last?.sourceKind, CapturedDocument.Origin.pieceDraft.rawValue)
    }
  }

  /// 三个模块各看各的:浏览「全部」只有抓来的资料。
  func testBrowsingKeepsTheThreeModulesApart() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let s = try seed(repository)

      XCTAssertEqual(ids(try page(repository, .all)), [s.captured], "「全部」只该有抓来的资料")
      XCTAssertEqual(ids(try page(repository, .notes)), [s.note], "「我的笔记」不该混进稿件")
      XCTAssertEqual(ids(try page(repository, .drafts)), [s.draft])
      XCTAssertEqual(ids(try page(repository, .recent)), [s.captured])
    }
  }

  /// 搜索能找到笔记,但**找不到稿件**。
  ///
  /// 这是稿件和笔记待遇不同的地方:用户搜「我写过的那句话」,他要的是笔记
  /// 或成品,不是某件创作中途的一版草稿——半成品混进结果只会干扰判断。
  func testSearchReachesNotesButNotDrafts() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let s = try seed(repository)

      let hits = ids(try page(repository, .all, search: "knowledge"))
      XCTAssertTrue(hits.contains(s.captured))
      XCTAssertTrue(hits.contains(s.note), "搜索该能找到笔记")
      XCTAssertFalse(hits.contains(s.draft), "半成品不该被搜出来和成品混在一起")
    }
  }

  /// 侧边栏的数字必须和列表里看到的条数一致。
  func testNavigationCountsExcludeDrafts() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      _ = try seed(repository)

      let counts = try repository.navigationCounts()
      XCTAssertEqual(counts.all, 1, "「全部」的数字要对得上列表")
      XCTAssertEqual(counts.notes, 1)
      XCTAssertEqual(counts.recent, 1)
      // 侧边栏平台列表不该冒出一个「工作台稿件」项。
      XCTAssertFalse(counts.platforms.contains { $0.host == HistoryPlatformDisplay.draftHost })
    }
  }

  /// 收藏是给资料用的,稿件不该被算进去。
  func testFavoriteCountIgnoresDrafts() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let s = try seed(repository)

      try repository.setFavorite(true, for: s.draft)
      try repository.setFavorite(true, for: s.captured)
      XCTAssertEqual(try repository.navigationCounts().favorite, 1)
    }
  }

  /// 一条笔记不能伪装成稿件,反过来也不行。
  ///
  /// 校验放宽是绑定到具体 origin 的,不是放宽 scheme 白名单本身——
  /// 否则两个模块的隔离就成了摆设。
  func testOriginAndSchemeMustMatchEachOther() throws {
    let noteURLWithDraftOrigin = CapturedDocument(
      createdAt: "2026-08-02T00:00:00Z", origin: .pieceDraft,
      url: try CanonicalURL.note().value, title: "伪装",
      platform: "note", method: "x", text: "正文",
      completeness: "complete", capturedAt: "2026-08-02T00:00:00Z", sourceLabel: "x"
    )
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(noteURLWithDraftOrigin))

    let draftURLWithNoteOrigin = CapturedDocument(
      createdAt: "2026-08-02T00:00:00Z", origin: .userNote,
      url: try CanonicalURL.draft().value, title: "伪装",
      platform: "draft", method: "x", text: "正文",
      completeness: "complete", capturedAt: "2026-08-02T00:00:00Z", sourceLabel: "x"
    )
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(draftURLWithNoteOrigin))

    // 抓取来源仍然只能用 http(s):这道边界不能因为新增本机内容而松掉。
    let capturedWithLocalScheme = CapturedDocument(
      createdAt: "2026-08-02T00:00:00Z", origin: .browserCapture,
      url: try CanonicalURL.draft().value, title: "伪装",
      platform: "web", method: "x", text: "正文",
      completeness: "complete", capturedAt: "2026-08-02T00:00:00Z", sourceLabel: "x"
    )
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(capturedWithLocalScheme))
  }
}
