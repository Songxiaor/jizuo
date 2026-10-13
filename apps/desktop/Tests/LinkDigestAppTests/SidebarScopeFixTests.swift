import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore
import LinkDigestPersistence

/// 2026-10-13 审查第二轮补的单元测试：切范围撤选中、切形式保选中、
/// 标签不换范围、博主「按最近保存」的排序与取数、侧栏换基准换算。
@MainActor
final class SidebarScopeFixTests: XCTestCase {
  private var root: URL!
  private var repository: GRDBHistoryRepository!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-sidebar-fix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
  }

  override func tearDown() async throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func capture(_ slug: String, at milliseconds: Int64) throws -> TaskID {
    try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-09-01T00:00:00Z",
        idempotencyKey: "sidebar-fix-\(slug)",
        origin: .manualLink,
        url: "https://example.test/\(slug)",
        title: "条目 \(slug)",
        platform: "generic",
        method: "rendered_dom",
        text: "正文 \(slug)",
        completeness: "complete",
        capturedAt: "2026-09-01T00:00:00Z",
        sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: milliseconds
    )).taskID
  }

  private func makeModel() async -> HistoryViewModel {
    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded || model.listState == .empty }
    return model
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  /// 走查 #9：切范围（收藏 → 全部）时撤下旧选中；新列表到手自动接住第一条。
  func testSwitchingScopeDropsSelectionThenPicksFirstRow() async throws {
    let older = try capture("older", at: 1_000), newer = try capture("newer", at: 2_000)
    try repository.setFavorite(true, for: older)
    let model = await makeModel()

    model.selectScope(.favorite)
    await waitUntil { model.rows.map(\.taskID) == [older] }
    model.selectedTaskID = older
    await waitUntil { model.detail?.task.id == older }

    model.selectScope(.all)
    XCTAssertTrue(model.selectedTaskIDs.isEmpty, "换范围先撤下旧选中")
    XCTAssertNil(model.detail)
    await waitUntil { model.selectedTaskID == newer && model.detail?.task.id == newer }
  }

  /// 审查 #2：重复点当前已经亮着的那一行，不撤选中、不换详情。
  func testReselectingCurrentScopeKeepsSelection() async throws {
    let first = try capture("a", at: 1_000)
    let model = await makeModel()
    await waitUntil { model.selectedTaskID == first }

    model.selectScope(.all)
    XCTAssertEqual(model.selectedTaskID, first, "已在「全部」且没挂筛选时再点一次，不该动选中")
  }

  /// 审查 #2：换显示形式（和清搜索）不换范围，正在读的那条留在屏上。
  func testSwitchingFormKeepsSelection() async throws {
    let older = try capture("older", at: 1_000), newer = try capture("newer", at: 2_000)
    let model = await makeModel()
    await waitUntil { model.rows.count == 2 }
    model.selectedTaskID = older
    await waitUntil { model.detail?.task.id == older }

    model.selectForm(.article)
    XCTAssertEqual(model.selectedTaskID, older, "形式只是收窄，正在读的不该被换成列表第一条")
    XCTAssertEqual(model.selectedForm, .article)

    model.selectForm(nil)
    XCTAssertEqual(model.selectedTaskID, older)
  }

  /// 走查 #5 的口径：标签叠在当前范围上时，作用域行仍然亮着。
  func testHasNonTagCategoryFilterIgnoresTags() async throws {
    _ = try capture("a", at: 1_000)
    let model = await makeModel()
    await waitUntil { model.listState == .loaded || model.listState == .empty }

    XCTAssertFalse(model.hasNonTagCategoryFilter)
    XCTAssertFalse(model.hasCategoryFilter)

    let tag = HistoryTagNormalizer.normalized("AI Agent")
    model.toggleTag(HistoryTag(name: tag!.name, normalizedName: tag!.normalizedName), additive: true)
    XCTAssertTrue(model.hasCategoryFilter)
    XCTAssertFalse(model.hasNonTagCategoryFilter, "只选标签时不该算「换地方」的筛选")

    model.selectHost("example.test")
    XCTAssertTrue(model.hasNonTagCategoryFilter)
  }

  /// 「按最近保存」：按最近一条作品的存入时间倒序，没作品的按名字跟后。
  func testCreatorsByRecentSaveSortsByLatestWorkThenName() {
    func summary(_ name: String, lastSaved: Int64?) -> CreatorSummary {
      .init(
        id: CreatorID(UUID()),
        identity: CreatorIdentity(platform: "douyin.com", authorID: name)!,
        profileURL: "https://www.douyin.com/user/\(name)",
        displayName: name,
        pinnedRank: nil,
        savedWorkCount: lastSaved == nil ? 0 : 1,
        createdAtMilliseconds: 0,
        updatedAtMilliseconds: 0,
        lastSavedAtMilliseconds: lastSaved
      )
    }
    let a = summary("阿呆", lastSaved: 100)
    let b = summary("白露", lastSaved: 300)
    let c = summary("迟到", lastSaved: 200)
    let none1 = summary("没作品", lastSaved: nil)
    let none2 = summary("啊没作品", lastSaved: nil)

    let sorted = HistoryContentView.creatorsByRecentSave([none1, c, none2, a, b])
    XCTAssertEqual(sorted.map(\.listingTitle), ["白露", "迟到", "阿呆", "啊没作品", "没作品"])
  }

  /// 「按最近保存」一次取完再排：所有博主都参与排序（新列表没有下一页），
  /// 不是只排第一页；最近存过作品的排前面。
  func testRecentSaveArrangementLoadsAllPagesWithoutCursor() async throws {
    let older = try repository.upsertCreator(upsertCommand(
      platform: "douyin.com", authorID: "MS4wLjABAAAA-old", name: "早就存过", now: 1
    ))
    let newer = try repository.upsertCreator(upsertCommand(
      platform: "douyin.com", authorID: "MS4wLjABAAAA-new", name: "刚存过", now: 2
    ))
    let oldWork = try capture("old-work", at: 1_000)
    let newWork = try capture("new-work", at: 9_000)
    try repository.attachCreatorWork(creatorID: older.id, taskID: oldWork)
    try repository.attachCreatorWork(creatorID: newer.id, taskID: newWork)

    let model = await makeModel()
    model.enterCreatorDirectory()
    await waitUntil { !model.creatorDirectoryRows.isEmpty && !model.isLoadingCreatorPage }
    model.creatorArrangement = .byRecentSave
    await waitUntil { !model.isLoadingCreatorPage }
    // 按各自最近一条作品的存入时间倒序；没作品的跟在后面。
    let order = model.creatorDirectoryRows.map(\.id)
    XCTAssertEqual(order.first, newer.id, "最近存过作品的博主排第一")
    XCTAssertTrue(order.contains(older.id), "一次取完：后面页的博主也在排序里")
    XCTAssertEqual(order.count, model.navigationCounts.creatorCount, "排序覆盖全部博主，不只是第一页")
  }
}

private func upsertCommand(
  platform: String,
  authorID: String,
  name: String?,
  now: Int64
) -> UpsertCreatorCommand {
  UpsertCreatorCommand(
    identity: CreatorIdentity(platform: platform, authorID: authorID)!,
    profileURL: "https://www.douyin.com/user/\(authorID)",
    displayName: name,
    avatarURL: nil,
    nowMilliseconds: now
  )!
}
