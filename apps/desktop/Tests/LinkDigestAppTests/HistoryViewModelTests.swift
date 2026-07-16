import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

@MainActor
final class HistoryViewModelTests: XCTestCase {
  func testEmptyAndPagedHistorySelectsFirstItemAndLoadsDetail() async {
    let first = makeRow(title: "第一条", updatedAt: 30), second = makeRow(title: "第二条", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first], nextCursor: cursor(for: first)), remainingPages: [first.taskID.rawValue: .init(rows: [second], nextCursor: nil)], details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded && model.detailState == .loaded }
    XCTAssertEqual(model.selectedTaskID, first.taskID)
    model.loadNextPageIfNeeded(after: first)
    await waitUntil { model.rows.count == 2 }
    XCTAssertEqual(model.rows.map(\.taskID), [first.taskID, second.taskID])
  }

  func testRapidSelectionCannotOverwriteNewerDetail() async {
    let first = makeRow(title: "慢详情", updatedAt: 30), second = makeRow(title: "新详情", updatedAt: 20)
    let blocker = DetailBlocker(taskID: first.taskID)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], blocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded }
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    blocker.release.signal()
    try? await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.detail?.task.id, second.taskID)
  }

  func testReloadCancelsAPageRequestAndReleasesThePaginationState() async {
    let first = makeRow(title: "第一页", updatedAt: 30), second = makeRow(title: "下一页", updatedAt: 20)
    let blocker = PageBlocker()
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first], nextCursor: cursor(for: first)), remainingPages: [first.taskID.rawValue: .init(rows: [second], nextCursor: nil)], details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], pageBlocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded }
    model.loadNextPageIfNeeded(after: first)
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(model.isLoadingNextPage)
    model.reload()
    XCTAssertFalse(model.isLoadingNextPage)
    blocker.release.signal()
    await waitUntil { model.listState == .loaded && model.rows == [first] }
  }

  func testDeletionNeedsConfirmationAndOnlyDeletesSelectedTask() async {
    let first = makeRow(title: "第一条", updatedAt: 30), second = makeRow(title: "第二条", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion(); XCTAssertTrue(model.isDeleteConfirmationPresented); XCTAssertEqual(repository.deletedTaskIDs, [])
    model.cancelDeletion(); XCTAssertEqual(repository.deletedTaskIDs, [])
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID] && model.rows.count == 1 }
    XCTAssertEqual(model.selectedTaskID, second.taskID)
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID, second.taskID] && model.listState == .empty }
    XCTAssertNil(model.selectedTaskID)
  }

  func testDeletionFailureKeepsSelectionAndReadOnlyNeverDeletes() async {
    let row = makeRow(title: "不可删除", updatedAt: 30)
    let failing = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)], deleteFailure: .unavailable)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: failing), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { model.isDeleteFailurePresented }
    XCTAssertEqual(model.selectedTaskID, row.taskID); XCTAssertEqual(model.deleteErrorCode, .writeFailed)
    let readOnly = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)])
    model.configure(
      history: HistoryApplicationService(repository: readOnly),
      isReadOnly: true,
      unavailableCode: nil,
      readOnlyReason: .futureSchema
    )
    await waitUntil { model.detailState == .loaded }
    XCTAssertEqual(model.historyReadOnlyReason, .futureSchema)
    XCTAssertFalse(model.canDelete); model.requestDeletion(); model.confirmDeletion(); XCTAssertEqual(readOnly.deletedTaskIDs, [])
  }

  func testDeletionUsesTaskCapturedWhenConfirmationWasPresented() async {
    let first = makeRow(title: "先选中", updatedAt: 30), second = makeRow(title: "后选中", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion()
    XCTAssertTrue(model.isDeleteConfirmationPresented)
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID] }
    XCTAssertEqual(model.rows.map(\.taskID), [second.taskID])
    XCTAssertEqual(model.selectedTaskID, second.taskID)
  }

  func testWritableAndReadOnlyHistoryCanPrepareAndFinishOrCancelExport() async {
    let row = makeRow(title: "可导出", updatedAt: 30)
    let detail = makeDetail(for: row)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: detail])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.markdown)
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.exportFile?.format, .markdown)
    XCTAssertTrue(model.exportFile?.suggestedFilename.contains("可导出") == true)
    model.completeExportSave()
    XCTAssertFalse(model.isExportPanelPresented)
    XCTAssertNil(model.exportFile)

    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: true, unavailableCode: nil, readOnlyReason: .futureSchema)
    await waitUntil { model.detailState == .loaded }
    XCTAssertTrue(model.canExport)
    model.requestExport(.json)
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.exportFile?.format, .json)
    model.cancelExport()
    XCTAssertFalse(model.isExportPanelPresented)
    XCTAssertNil(model.exportFile)
    XCTAssertFalse(model.isExportSaveFailurePresented)
  }

  func testExportPreparationFailureIsSafeAndSaveFailureHasRecoveryState() async {
    let row = makeRow(title: "失败导出", updatedAt: 30)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)], exportFailure: .unavailable)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.plainText)
    await waitUntil { model.isExportPreparationFailurePresented }
    XCTAssertNil(model.exportFile)
    XCTAssertFalse(model.isExportPanelPresented)
    model.dismissExportPreparationFailure()
    XCTAssertFalse(model.isExportPreparationFailurePresented)

    model.failExportSave()
    XCTAssertTrue(model.isExportSaveFailurePresented)
    model.dismissExportSaveFailure()
    XCTAssertFalse(model.isExportSaveFailurePresented)
  }

  func testRapidSelectionCannotPresentOldExport() async {
    let first = makeRow(title: "慢导出", updatedAt: 30), second = makeRow(title: "新导出", updatedAt: 20)
    let blocker = ExportBlocker(taskID: first.taskID)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], exportBlocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.markdown)
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 1), .success)
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    model.requestExport(.json)
    blocker.release.signal()
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.exportFile?.format, .json)
    XCTAssertTrue(model.exportFile?.suggestedFilename.contains("新导出") == true)
  }

  func testProtectedDeletionIsBlockedAtRequestAndConfirmationTime() async {
    let row = makeRow(title: "正在运行", updatedAt: 30)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    XCTAssertTrue(model.canDelete)
    XCTAssertFalse(model.canDelete(protectedTaskID: row.taskID))
    model.requestDeletion(protectedTaskID: row.taskID)
    XCTAssertFalse(model.isDeleteConfirmationPresented)
    XCTAssertEqual(repository.deletedTaskIDs, [])
    XCTAssertTrue(model.canDelete)

    model.requestDeletion()
    XCTAssertTrue(model.isDeleteConfirmationPresented)
    model.confirmDeletion(protectedTaskID: row.taskID)
    XCTAssertFalse(model.isDeleteConfirmationPresented)
    XCTAssertTrue(model.isProtectedDeletionAlertPresented)
    XCTAssertEqual(repository.deletedTaskIDs, [])
    XCTAssertTrue(model.canDelete)
  }

  private func waitUntil(timeout: Duration = .seconds(1), file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

private final class HistoryScreenRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let firstPage: HistoryPage, remainingPages: [String: HistoryPage], details: [TaskID: HistoryDetailProjection]
  private let blocker: DetailBlocker?, pageBlocker: PageBlocker?, exportBlocker: ExportBlocker?, deleteFailure: RepositoryFailure?, exportFailure: RepositoryFailure?
  private let lock = NSLock(); private var deletes: [TaskID] = []
  init(firstPage: HistoryPage, remainingPages: [String: HistoryPage] = [:], details: [TaskID: HistoryDetailProjection], blocker: DetailBlocker? = nil, pageBlocker: PageBlocker? = nil, exportBlocker: ExportBlocker? = nil, deleteFailure: RepositoryFailure? = nil, exportFailure: RepositoryFailure? = nil) { self.firstPage = firstPage; self.remainingPages = remainingPages; self.details = details; self.blocker = blocker; self.pageBlocker = pageBlocker; self.exportBlocker = exportBlocker; self.deleteFailure = deleteFailure; self.exportFailure = exportFailure }
  var deletedTaskIDs: [TaskID] { lock.withLock { deletes } }
  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws { throw RepositoryFailure.invalidInput }
  func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw RepositoryFailure.invalidInput }
  func finishRun(_: FinishRunCommand) throws { throw RepositoryFailure.invalidInput }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage { guard let cursor else { return firstPage }; if let pageBlocker { pageBlocker.entered.signal(); _ = pageBlocker.release.wait(timeout: .now() + 1) }; return remainingPages[cursor.taskID.rawValue] ?? .init(rows: [], nextCursor: nil) }
  func detail(taskID: TaskID) throws -> HistoryDetailProjection { if blocker?.taskID == taskID { blocker?.entered.signal(); _ = blocker?.release.wait(timeout: .now() + 1) }; guard let detail = details[taskID] else { throw RepositoryFailure.notFound }; return detail }
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection {
    if exportBlocker?.taskID == taskID { exportBlocker?.entered.signal(); _ = exportBlocker?.release.wait(timeout: .now() + 1) }
    if let exportFailure { throw exportFailure }
    guard let detail = details[taskID] else { throw RepositoryFailure.notFound }
    return .init(task: detail.task, snapshots: detail.snapshots, runs: detail.runs)
  }
  func deleteTask(taskID: TaskID) throws { if let deleteFailure { throw deleteFailure }; lock.withLock { deletes.append(taskID) } }
}

private final class DetailBlocker: @unchecked Sendable { let taskID: TaskID; let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0); init(taskID: TaskID) { self.taskID = taskID } }
private final class PageBlocker: @unchecked Sendable { let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0) }
private final class ExportBlocker: @unchecked Sendable { let taskID: TaskID; let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0); init(taskID: TaskID) { self.taskID = taskID } }
private func makeRow(title: String, updatedAt: Int64) -> HistoryRowProjection { .init(taskID: TaskID(), title: title, canonicalURL: "https://example.test/\(updatedAt)", host: "example.test", sourceLabel: "网页", latestRunKind: .summarize, latestRunStatus: .completed, latestModel: "fixture-model", updatedAtMilliseconds: updatedAt, latestRunAtMilliseconds: updatedAt, usageCost: .unknown, artifactPreview: "fixture") }
private func cursor(for row: HistoryRowProjection) -> HistoryPageCursor { .init(updatedAtMilliseconds: row.updatedAtMilliseconds, taskID: row.taskID) }
private func makeDetail(for row: HistoryRowProjection) -> HistoryDetailProjection { let snapshot = ContentSnapshot(id: ContentSnapshotID(), taskID: row.taskID, sequence: 1, envelopeCreatedAtMilliseconds: 1, capturedAtMilliseconds: 1, sourceKind: "web", sourceURL: row.canonicalURL, title: row.title, platform: "fixture", captureMethod: "page", completeness: "complete", bodyText: "fixture body", characterCount: 12, bodySHA256: String(repeating: "a", count: 64), sourceLabel: "网页", usedCookie: false); return .init(task: .init(id: row.taskID, canonicalURL: row.canonicalURL, canonicalizationVersion: 1, createdAtMilliseconds: 1, updatedAtMilliseconds: row.updatedAtMilliseconds), snapshots: [snapshot], runs: []) }
