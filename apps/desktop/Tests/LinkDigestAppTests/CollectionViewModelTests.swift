import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore
import LinkDigestPersistence

/// 合集在界面这一层：点侧栏进合集、按合集顺序列出、拖动调整顺序、加入 / 移出、
/// 弹窗新建、导入文件夹挂钩。全部跑在临时库上。
@MainActor
final class CollectionViewModelTests: XCTestCase {
  private var root: URL!
  private var repository: GRDBHistoryRepository!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-collection-vm-\(UUID().uuidString)", isDirectory: true)
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
        idempotencyKey: "collection-vm-\(slug)",
        origin: .manualLink,
        url: "https://example.test/\(slug)",
        title: "第 \(slug) 讲",
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

  func testSelectingCollectionListsItsItemsInCollectionOrderAndOtherNavigationLeavesIt() async throws {
    let first = try capture("1", at: 1_000), second = try capture("2", at: 2_000), third = try capture("3", at: 3_000)
    let collection = try repository.createCollection(name: "教程")
    try repository.addTasks([first, third, second], toCollection: collection.id)
    let model = await makeModel()
    await waitUntil { model.collections.map(\.id) == [collection.id] }
    XCTAssertEqual(model.collections.first?.itemCount, 3)

    model.selectCollection(collection.id)
    XCTAssertTrue(model.hasCategoryFilter, "进了合集，「全部」不该再亮")
    await waitUntil { model.rows.map(\.taskID) == [first, third, second] }
    XCTAssertEqual(model.selectedCollection?.name, "教程")

    // 点侧栏其它入口都离开合集。
    model.selectScope(.all)
    XCTAssertNil(model.selectedCollectionID)
    await waitUntil { model.rows.map(\.taskID) == [third, second, first] }
    model.selectCollection(collection.id)
    model.selectForm(.article)
    XCTAssertNil(model.selectedCollectionID)
    model.selectCollection(collection.id)
    model.selectHost("example.test")
    XCTAssertNil(model.selectedCollectionID)
  }

  func testDragReorderPersistsAndRemoveKeepsContent() async throws {
    let first = try capture("1", at: 1_000), second = try capture("2", at: 2_000), third = try capture("3", at: 3_000)
    let collection = try repository.createCollection(name: "排序")
    try repository.addTasks([first, second, third], toCollection: collection.id)
    let model = await makeModel()
    await waitUntil { !model.collections.isEmpty }
    model.selectCollection(collection.id)
    await waitUntil { model.rows.map(\.taskID) == [first, second, third] && model.listState == .loaded }
    XCTAssertTrue(model.canReorderSelectedCollection)

    // 把第三条拖到最前：界面立刻变，库里跟着变。
    model.moveCollectionRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    XCTAssertEqual(model.rows.map(\.taskID), [third, first, second])
    await waitUntil { (try? self.repository.collectionItems(id: collection.id).map(\.taskID)) == [third, first, second] }
    // 把第一条拖到末尾。
    model.moveCollectionRows(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    await waitUntil { (try? self.repository.collectionItems(id: collection.id).map(\.taskID)) == [first, second, third] }

    // 搜索时不能拖：搜索结果只是合集的一部分。
    model.searchText = "正文"
    XCTAssertFalse(model.canReorderSelectedCollection)
    model.searchText = ""

    model.removeFromSelectedCollection(taskIDs: [second])
    XCTAssertFalse(model.rows.contains { $0.taskID == second })
    await waitUntil { (try? self.repository.collectionItems(id: collection.id).map(\.taskID)) == [first, third] }
    await waitUntil { model.collections.first?.itemCount == 2 }
    XCTAssertNoThrow(try repository.detail(taskID: second), "移出合集不删内容")
  }

  func testAddFromMenuAndCreateWithItemsThroughPrompt() async throws {
    let first = try capture("1", at: 1_000), second = try capture("2", at: 2_000), third = try capture("3", at: 3_000)
    let model = await makeModel()

    // 多选：不在合集里时按存入先后加（列表是新的在上）。
    model.selectedTaskIDs = [first, second, third]
    XCTAssertEqual(model.collectionTargets(for: second), [first, second, third])
    let outsider = TaskID()
    XCTAssertEqual(model.collectionTargets(for: outsider), [outsider], "右键的不在多选里时只作用于它自己")
    model.requestNewCollection(adding: model.collectionTargets(for: second))
    XCTAssertEqual(model.collectionPrompt, .create(adding: [first, second, third]))
    model.collectionNameDraft = "  一套教程 "
    model.confirmCollectionPrompt()
    XCTAssertNil(model.collectionPrompt)
    await waitUntil { model.collections.first?.itemCount == 3 }
    let collection = try XCTUnwrap(model.collections.first)
    XCTAssertEqual(collection.name, "一套教程")
    XCTAssertEqual(try repository.collectionItems(id: collection.id).map(\.taskID), [first, second, third])
    XCTAssertNil(model.selectedCollectionID, "带着内容新建时不跳走，用户还在读")

    // 再加一次已经在里面的：不重复。
    model.addToCollection(collection.id, taskIDs: [second])
    await waitUntil { model.collectionFeedback?.contains("已经在") == true }
    XCTAssertEqual(try repository.collectionItems(id: collection.id).count, 3)

    // 单选时知道它在哪些合集里（菜单打勾）。
    model.selectedTaskID = first
    await waitUntil { model.selectedTaskCollectionIDs == [collection.id] }

    // 右键的不是正在读的那条时也知道它在哪些合集里；多选时只算整批都在的。
    await waitUntil { model.collectionMembership[third] == [collection.id] }
    XCTAssertEqual(model.collectionIDs(containingAll: [third]), [collection.id])
    XCTAssertEqual(model.collectionIDs(containingAll: [second, third]), [collection.id])
    XCTAssertEqual(model.collectionIDs(containingAll: [third, outsider]), [], "有一条不在里面就不打勾")

    // 空名字不建。
    model.requestNewCollection()
    model.collectionNameDraft = "   "
    model.confirmCollectionPrompt()
    XCTAssertEqual(model.collectionFeedback, "合集要有个名字。")
  }

  func testRenameAndDeletePromptsKeepContent() async throws {
    let first = try capture("1", at: 1_000)
    let collection = try repository.createCollection(name: "旧名字")
    try repository.addTasks([first], toCollection: collection.id)
    let model = await makeModel()
    await waitUntil { model.collections.count == 1 }
    model.selectCollection(collection.id)

    model.requestRenameCollection(try XCTUnwrap(model.collections.first))
    XCTAssertEqual(model.collectionNameDraft, "旧名字")
    model.collectionNameDraft = "新名字"
    model.confirmCollectionPrompt()
    await waitUntil { model.collections.first?.name == "新名字" }

    model.requestDeleteCollection(try XCTUnwrap(model.collections.first))
    model.confirmCollectionPrompt()
    await waitUntil { model.collections.isEmpty }
    XCTAssertNil(model.selectedCollectionID, "删掉正在看的合集后回到全部")
    XCTAssertNoThrow(try repository.detail(taskID: first))
  }

  func testImportedFolderHookCreatesThenAppends() async throws {
    let first = try capture("1", at: 1_000), second = try capture("2", at: 2_000), third = try capture("3", at: 3_000)
    let model = await makeModel()
    let folder = root.appendingPathComponent("Claude Code 教程", isDirectory: true)

    let created = await model.applyImportedFolder(folderName: "Claude Code 教程", folderURL: folder, orderedTaskIDs: [second, first])
    XCTAssertEqual(created?.origin, .importedFolder)
    XCTAssertEqual(created?.name, "Claude Code 教程")
    XCTAssertNil(model.selectedCollectionID, "导入不抢当前阅读焦点")

    // 同一个文件夹换种写法再导入一次：同一个合集，只往后追加。
    let again = await model.applyImportedFolder(
      folderName: "Claude Code 教程",
      folderURL: folder.appendingPathComponent("sub/..", isDirectory: true),
      orderedTaskIDs: [first, third]
    )
    XCTAssertEqual(again?.id, created?.id)
    XCTAssertEqual(try repository.collectionItems(id: XCTUnwrap(created?.id)).map(\.taskID), [second, first, third])

    // 总控集成用的那个入口签名：不等结果、不抛错。
    let other = root.appendingPathComponent("另一个文件夹", isDirectory: true)
    model.handleImportedFolder(folderName: "另一个文件夹", folderURL: other, orderedTaskIDs: [third])
    await waitUntil { model.collections.count == 2 }
  }
}
