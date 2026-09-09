import XCTest
import LinkDigestCore
@testable import LinkDigestApp

@MainActor
final class GalleryPaginationAcceptanceTests: XCTestCase {
  func testFailureRetryAppendsOnlyMissingPageAndKeepsMultipleSelections() async throws {
    let fixture = GalleryPaginationAcceptanceState()
    let model = fixture.model, repository = fixture.repository
    defer { repository.releaseFailure() }
    fixture.start()
    try await waitUntil { model.listState == .loaded && model.rows.count == 4 }
    XCTAssertTrue(model.selectedTaskIDs.isEmpty, "图库初始不应自动勾选")
    let firstIDs = model.rows.map(\.taskID)
    let selected: Set<TaskID> = [firstIDs[0], firstIDs[2]]
    selected.forEach { model.toggleGallerySelection($0) }
    model.loadNextPageIfNeeded(after: model.rows.last!)
    try await waitUntil { model.isLoadingNextPage && repository.requestTrail.contains(firstIDs[3].rawValue) }
    let initialReads = repository.requestTrail.filter { $0 == "initial" }.count
    model.searchText = "" // Same-value control updates must also be harmless.
    // Keep the next page pending past the 200ms search debounce. A redundant
    // search reset used to reload page one here and silently cancel pagination.
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(model.isLoadingNextPage, "空搜索的延迟刷新不得打断分页")
    XCTAssertEqual(repository.requestTrail.filter { $0 == "initial" }.count, initialReads)
    XCTAssertEqual(model.selectedTaskIDs, selected)
    repository.releaseFailure()
    try await waitUntil { model.listErrorCode != nil && !model.isLoadingNextPage }
    XCTAssertEqual(model.listState, .loaded)
    XCTAssertEqual(model.rows.map(\.taskID), firstIDs)
    XCTAssertEqual(model.selectedTaskIDs, selected)
    XCTAssertTrue(model.canRetryList)
    let firstPageReads = repository.requestTrail.filter { $0 == "initial" }.count

    model.retryList()
    try await waitUntil { model.rows.count == 6 && model.listErrorCode == nil && !model.isLoadingNextPage }
    XCTAssertEqual(Array(model.rows.prefix(4)).map(\.taskID), firstIDs)
    XCTAssertEqual(Set(model.rows.map(\.taskID)).count, 6, "重试不能重复追加已有卡片")
    XCTAssertEqual(model.selectedTaskIDs, selected)
    XCTAssertEqual(repository.requestTrail.filter { $0 == "initial" }.count, firstPageReads)
    XCTAssertEqual(repository.requestTrail.filter { $0 != "initial" }, [firstIDs[3].rawValue, firstIDs[3].rawValue])
    let requests = repository.requestTrail
    model.loadNextPageIfNeeded(after: model.rows.last!)
    XCTAssertEqual(repository.requestTrail, requests, "末页成功后不得自动继续请求")
  }

  func testPlatformChangeCancelsPendingSearchBeforePagination() async throws {
    let fixture = GalleryPaginationAcceptanceState()
    let model = fixture.model, repository = fixture.repository
    defer { repository.releaseFailure() }
    fixture.start()
    try await waitUntil { model.listState == .loaded && model.rows.count == 4 }
    model.searchText = "previous platform query"
    model.selectHost("example.test")
    try await waitUntil { model.listState == .loaded && model.rows.count == 4 }
    XCTAssertEqual(model.searchText, "")
    model.loadNextPageIfNeeded(after: model.rows.last!)
    try await waitUntil { model.isLoadingNextPage && repository.requestTrail.contains(repository.rows[3].taskID.rawValue) }
    let requests = repository.requestTrail
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(repository.requestTrail, requests, "立即切换来源后不得再补一次旧搜索刷新")
    XCTAssertTrue(model.isLoadingNextPage)
    repository.releaseFailure()
    try await waitUntil { model.listErrorCode != nil && !model.isLoadingNextPage }
  }

  func testStateRecordSerializesFailureCodeInsteadOfLeavingStaleLoadingSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pagination-record-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = GalleryPaginationAcceptanceState(root: root)
    defer { fixture.repository.releaseFailure() }
    fixture.start()
    try await waitUntil { fixture.model.rows.count == 4 }
    fixture.model.loadNextPageIfNeeded(after: fixture.model.rows.last!)
    try await waitUntil { fixture.model.isLoadingNextPage }
    fixture.record()
    fixture.repository.releaseFailure()
    try await waitUntil { fixture.model.listErrorCode != nil && !fixture.model.isLoadingNextPage }
    fixture.record()
    let data = try Data(contentsOf: root.appendingPathComponent("pagination-state.json"))
    let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(snapshot["error"] as? String, StorageErrorCode.unavailable.rawValue)
    XCTAssertEqual(snapshot["isLoadingNextPage"] as? Bool, false)
    XCTAssertEqual((snapshot["rowIDs"] as? [String])?.count, 4)
  }

  func testFixtureRejectsWritesAndUnexpectedCursor() {
    let repository = GalleryPaginationAcceptanceRepository()
    XCTAssertEqual(repository.accessMode, .readOnly(.storageUnavailable))
    XCTAssertThrowsError(try repository.deleteTask(taskID: repository.rows[0].taskID))
    XCTAssertThrowsError(try repository.historyPage(limit: 30, after: .init(
      updatedAtMilliseconds: repository.rows[0].updatedAtMilliseconds, taskID: repository.rows[0].taskID)))
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<150 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("隔离分页未在预期时间内进入下一状态")
    throw CancellationError()
  }
}
