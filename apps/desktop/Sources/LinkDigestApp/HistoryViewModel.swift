import Combine
import Foundation
import LinkDigestCore

enum HistoryListState: Equatable { case idle, loading, empty, loaded, failed }
enum HistoryDetailState: Equatable { case idle, loading, loaded, failed }
private enum PageResult: Sendable { case success(HistoryPage), failure(StorageErrorCode) }
private enum DetailResult: Sendable { case success(HistoryDetailProjection), failure(StorageErrorCode) }
private enum DeleteResult: Sendable { case success, failure(StorageErrorCode) }
private enum ExportResult: Sendable { case success(HistoryExportFile), failure }

/// The one serial, non-MainActor boundary for all synchronous repository work.
/// SwiftUI state remains on MainActor while SQLite never executes there.
private actor HistoryRepositoryWorker {
  func delete(_ history: HistoryApplicationService, taskID: TaskID) -> DeleteResult {
    do { try history.deleteTask(taskID: taskID); return .success }
    catch { return .failure(HistoryViewModel.storageCode(for: error, context: .write)) }
  }

  func export(_ history: HistoryApplicationService, taskID: TaskID, format: HistoryExportFormat) -> ExportResult {
    do { return .success(try HistoryExportRenderer.render(history.exportProjection(taskID: taskID), as: format)) }
    catch { return .failure }
  }
}

@MainActor
final class HistoryViewModel: ObservableObject {
  @Published private(set) var rows: [HistoryRowProjection] = []
  @Published var selectedTaskID: TaskID? { didSet { if selectedTaskID != oldValue { loadDetailForSelection() } } }
  @Published private(set) var detail: HistoryDetailProjection?
  @Published private(set) var listState: HistoryListState = .idle
  @Published private(set) var detailState: HistoryDetailState = .idle
  @Published private(set) var isLoadingNextPage = false
  @Published private(set) var isReadOnly = false
  @Published private(set) var historyReadOnlyReason: RepositoryRecoveryReason?
  @Published private(set) var blockingErrorCode: StorageErrorCode?
  @Published private(set) var listErrorCode: StorageErrorCode?
  @Published private(set) var detailErrorCode: StorageErrorCode?
  @Published private(set) var deleteErrorCode: StorageErrorCode?
  @Published var isDeleteConfirmationPresented = false
  @Published var isDeleteFailurePresented = false
  @Published var isProtectedDeletionAlertPresented = false
  @Published private(set) var isDeleting = false
  @Published private(set) var isPreparingExport = false
  @Published private(set) var exportFile: HistoryExportFile?
  @Published var isExportPanelPresented = false
  @Published var isExportPreparationFailurePresented = false
  @Published var isExportSaveFailurePresented = false

  private let worker = HistoryRepositoryWorker()
  private var history: HistoryApplicationService?
  private var nextCursor: HistoryPageCursor?
  private var configurationGeneration = UUID()
  private var listRequestID = UUID()
  private var detailRequestID = UUID()
  private var deleteRequestID = UUID()
  private var exportRequestID = UUID()
  private(set) var pendingDeletionTaskID: TaskID?
  private var pageTask: Task<Void, Never>?
  private var detailTask: Task<Void, Never>?
  private var deleteTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?

  deinit { pageTask?.cancel(); detailTask?.cancel(); deleteTask?.cancel(); exportTask?.cancel() }

  var canDelete: Bool { history != nil && !isReadOnly && selectedTaskID != nil && !isDeleting }
  var canExport: Bool { history != nil && selectedTaskID != nil && !isPreparingExport }
  func canDelete(protectedTaskID: TaskID?) -> Bool {
    canDelete && selectedTaskID != protectedTaskID
  }
  var canRetryList: Bool { history != nil && blockingErrorCode == nil }

  func beginBootstrapLoading() {
    guard history == nil, blockingErrorCode == nil else { return }
    listState = .loading
    detailState = .loading
  }

  func configure(
    history: HistoryApplicationService?,
    isReadOnly: Bool,
    unavailableCode: StorageErrorCode?,
    readOnlyReason: RepositoryRecoveryReason? = nil
  ) {
    configurationGeneration = UUID()
    pageTask?.cancel(); detailTask?.cancel(); deleteTask?.cancel(); invalidateExportPreparation()
    self.history = history; self.isReadOnly = isReadOnly
    historyReadOnlyReason = isReadOnly ? readOnlyReason : nil
    blockingErrorCode = unavailableCode
    rows = []; selectedTaskID = nil; detail = nil; nextCursor = nil
    listErrorCode = nil; detailErrorCode = nil; deleteErrorCode = nil
    pendingDeletionTaskID = nil
    isDeleteConfirmationPresented = false; isDeleteFailurePresented = false; isProtectedDeletionAlertPresented = false
    isLoadingNextPage = false; isDeleting = false
    guard history != nil else { listState = .failed; detailState = .idle; return }
    reload()
  }

  func reload() {
    guard let history else { return }
    let generation = configurationGeneration, requestID = UUID()
    listRequestID = requestID; pageTask?.cancel(); isLoadingNextPage = false
    listState = .loading; listErrorCode = nil; nextCursor = nil
    pageTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.pageResult(history, cursor: nil)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveInitialPage(result, generation: generation, requestID: requestID)
    }
  }

  func loadNextPageIfNeeded(after row: HistoryRowProjection) {
    guard rows.last?.taskID == row.taskID, let cursor = nextCursor, !isLoadingNextPage, let history else { return }
    let generation = configurationGeneration, requestID = listRequestID
    isLoadingNextPage = true; listErrorCode = nil
    pageTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.pageResult(history, cursor: cursor)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveNextPage(result, generation: generation, requestID: requestID)
    }
  }

  func retryList() { guard canRetryList else { return }; reload() }
  func retryDetail() { loadDetailForSelection() }
  func reveal(taskID: TaskID) { selectedTaskID = taskID; reload() }
  func requestExport(_ format: HistoryExportFormat) {
    guard let history, let taskID = selectedTaskID, !isPreparingExport else { return }
    let generation = configurationGeneration, requestID = UUID()
    exportRequestID = requestID
    isPreparingExport = true; exportFile = nil
    isExportPanelPresented = false; isExportPreparationFailurePresented = false; isExportSaveFailurePresented = false
    exportTask = Task { [weak self, worker] in
      let result = await worker.export(history, taskID: taskID, format: format)
      guard !Task.isCancelled else { return }
      self?.receiveExport(result, taskID: taskID, generation: generation, requestID: requestID)
    }
  }

  func cancelExport() { invalidateExportPreparation() }
  func completeExportSave() {
    exportFile = nil
    isExportPanelPresented = false
    isExportSaveFailurePresented = false
  }
  func failExportSave() {
    exportFile = nil
    isExportPanelPresented = false
    isExportSaveFailurePresented = true
  }
  func dismissExportPreparationFailure() { isExportPreparationFailurePresented = false }
  func dismissExportSaveFailure() { isExportSaveFailurePresented = false }
  func requestDeletion(protectedTaskID: TaskID? = nil) {
    guard canDelete, let taskID = selectedTaskID, taskID != protectedTaskID else { return }
    pendingDeletionTaskID = taskID
    isDeleteConfirmationPresented = true
  }

  func cancelDeletion() {
    pendingDeletionTaskID = nil
    isDeleteConfirmationPresented = false
  }
  func dismissDeleteFailure() { isDeleteFailurePresented = false }
  func dismissProtectedDeletionAlert() { isProtectedDeletionAlertPresented = false }

  func confirmDeletion(protectedTaskID: TaskID? = nil) {
    guard let taskID = pendingDeletionTaskID, let history, !isReadOnly, !isDeleting else {
      pendingDeletionTaskID = nil
      isDeleteConfirmationPresented = false
      return
    }
    guard taskID != protectedTaskID else {
      pendingDeletionTaskID = nil
      isDeleteConfirmationPresented = false
      isProtectedDeletionAlertPresented = true
      return
    }
    let generation = configurationGeneration, requestID = UUID(), deletedIndex = rows.firstIndex { $0.taskID == taskID }
    deleteRequestID = requestID; isDeleteConfirmationPresented = false; isDeleting = true; deleteErrorCode = nil
    deleteTask = Task { [weak self, worker] in
      let result = await worker.delete(history, taskID: taskID)
      guard !Task.isCancelled else { return }
      self?.receiveDeletion(result, taskID: taskID, deletedIndex: deletedIndex, generation: generation, requestID: requestID)
    }
  }

  private func receiveInitialPage(_ result: PageResult, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == listRequestID else { return }
    switch result {
    case let .success(page):
      rows = page.rows; nextCursor = page.nextCursor; listState = page.rows.isEmpty ? .empty : .loaded
      if page.rows.isEmpty {
        detail = nil; detailState = .idle
      } else if let selectedTaskID, rows.contains(where: { $0.taskID == selectedTaskID }) {
        loadDetailForSelection()
      } else { selectedTaskID = rows.first?.taskID }
    case let .failure(code):
      listState = .failed; listErrorCode = code; rows = []; selectedTaskID = nil; detail = nil; detailState = .idle
    }
  }

  private func receiveNextPage(_ result: PageResult, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == listRequestID else { return }
    isLoadingNextPage = false
    switch result {
    case let .success(page):
      let existing = Set(rows.map(\.taskID)); rows.append(contentsOf: page.rows.filter { !existing.contains($0.taskID) }); nextCursor = page.nextCursor
    case let .failure(code): listErrorCode = code
    }
  }

  private func loadDetailForSelection() {
    invalidateExportPreparation()
    guard let history, let taskID = selectedTaskID else { detail = nil; detailState = .idle; return }
    let generation = configurationGeneration, requestID = UUID()
    detailRequestID = requestID; detailTask?.cancel(); detail = nil; detailErrorCode = nil; detailState = .loading
    detailTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.detailResult(history, taskID: taskID)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveDetail(result, taskID: taskID, generation: generation, requestID: requestID)
    }
  }

  private func receiveDetail(_ result: DetailResult, taskID: TaskID, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == detailRequestID, selectedTaskID == taskID else { return }
    switch result {
    case let .success(value): detail = value; detailState = .loaded
    case let .failure(code): detail = nil; detailErrorCode = code; detailState = .failed
    }
  }

  private func receiveDeletion(_ result: DeleteResult, taskID: TaskID, deletedIndex: Int?, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == deleteRequestID else { return }
    isDeleting = false; pendingDeletionTaskID = nil
    switch result {
    case .success:
      guard let index = rows.firstIndex(where: { $0.taskID == taskID }) else { reload(); return }
      rows.remove(at: index)
      if selectedTaskID == taskID {
        let preferred = min(deletedIndex ?? index, max(rows.count - 1, 0))
        selectedTaskID = rows.indices.contains(preferred) ? rows[preferred].taskID : nil
      }
      if rows.isEmpty { listState = .empty; detail = nil; detailState = .idle }
    case let .failure(code): deleteErrorCode = code; isDeleteFailurePresented = true
    }
  }

  private func receiveExport(_ result: ExportResult, taskID: TaskID, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == exportRequestID, selectedTaskID == taskID else { return }
    isPreparingExport = false
    switch result {
    case let .success(file):
      exportFile = file
      isExportPanelPresented = true
    case .failure:
      exportFile = nil
      isExportPreparationFailurePresented = true
    }
  }

  private func invalidateExportPreparation() {
    exportTask?.cancel()
    exportRequestID = UUID()
    isPreparingExport = false
    exportFile = nil
    isExportPanelPresented = false
  }

  nonisolated static func storageCode(for error: Error, context: StorageFailureContext) -> StorageErrorCode {
    if let failure = error as? RepositoryFailure { return StorageErrorMapper.map(failure, context: context).code }
    return StorageErrorMapper.mapUnknown(context: context).code
  }

  nonisolated private static func pageResult(_ history: HistoryApplicationService, cursor: HistoryPageCursor?) -> PageResult {
    do { return .success(try history.historyPage(limit: 50, after: cursor)) }
    catch { return .failure(storageCode(for: error, context: .open)) }
  }

  nonisolated private static func detailResult(_ history: HistoryApplicationService, taskID: TaskID) -> DetailResult {
    do { return .success(try history.detail(taskID: taskID)) }
    catch { return .failure(storageCode(for: error, context: .open)) }
  }
}
