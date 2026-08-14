import Foundation
import LinkDigestCore
import LinkDigestPersistence

enum DataAssetOperationState: Sendable, Equatable {
  case idle
  case running
  case finished(String)
  case failed(String)
}

@MainActor
final class DataAssetsViewModel: ObservableObject {
  @Published private(set) var batchState: DataAssetOperationState = .idle
  @Published private(set) var batchProgress: HistoryBatchExportProgress?
  @Published private(set) var backupState: DataAssetOperationState = .idle
  @Published private(set) var diagnosticState: DataAssetOperationState = .idle
  @Published private(set) var restoreState: DataAssetOperationState = .idle
  @Published private(set) var scheduledRestore: ScheduledLibraryRestore?
  @Published private(set) var startupRestoreNotice: String?

  private var history: HistoryApplicationService?
  private let backupManager: LibraryBackupManager
  private let diagnostics: DiagnosticExportService

  init(
    backupManager: LibraryBackupManager,
    diagnostics: DiagnosticExportService = .init(),
    startupRestoreResult: Result<AppliedLibraryRestore?, Error>? = nil
  ) {
    self.backupManager = backupManager
    self.diagnostics = diagnostics
    if let startupRestoreResult {
      switch startupRestoreResult {
      case let .success(.some(result)):
        startupRestoreNotice = "已恢复 \(result.itemCount) 条资料。恢复前自动备份保存在：\(result.automaticBackupURL.path)"
      case .success(.none):
        break
      case .failure:
        startupRestoreNotice = "上次恢复未完成，当前资料已保留。请重新选择备份文件后再试。"
      }
    }
  }

  var canBatchExport: Bool {
    history != nil && batchState != .running
  }

  var isBusy: Bool {
    [batchState, backupState, diagnosticState, restoreState].contains(.running)
  }

  func configure(history: HistoryApplicationService?) {
    self.history = history
  }

  func dismissStartupRestoreNotice() {
    startupRestoreNotice = nil
  }

  func exportAllMarkdown(to parentDirectory: URL) async {
    guard let history, batchState != .running else { return }
    batchState = .running
    batchProgress = .init(completed: 0, total: 0, currentFilename: nil)
    let output = parentDirectory.appendingPathComponent(
      "汲作批量导出-\(Self.filenameTimestamp(Date()))",
      isDirectory: true
    )
    let exporter = HistoryBatchExporter(history: history)
    let (progressStream, progressContinuation) = AsyncStream<HistoryBatchExportProgress>.makeStream()
    let progressTask = Task { [weak self] in
      for await progress in progressStream {
        self?.publish(progress)
      }
    }
    do {
      let report = try await Task.detached(priority: .userInitiated) {
        try await exporter.exportMarkdown(to: output) { progress in
          progressContinuation.yield(progress)
        }
      }.value
      progressContinuation.finish()
      await progressTask.value
      batchState = .finished("已导出 \(report.exportedCount) 条 Markdown：\(report.directoryURL.path)")
    } catch is CancellationError {
      progressContinuation.finish()
      progressTask.cancel()
      batchState = .failed("批量导出已取消。")
    } catch {
      progressContinuation.finish()
      progressTask.cancel()
      batchState = .failed("批量导出未完成：\(Self.message(error))")
    }
  }

  func createBackup(in directory: URL) async {
    guard backupState != .running else { return }
    backupState = .running
    let destination = directory.appendingPathComponent(backupManager.suggestedBackupFilename())
    do {
      let inspection = try await Task.detached(priority: .userInitiated) { [backupManager] in
        try backupManager.createBackup(at: destination)
      }.value
      backupState = .finished(
        "已备份 \(inspection.database.counts.tasks) 条资料：\(destination.path)"
      )
    } catch {
      backupState = .failed("备份未完成：\(Self.message(error))")
    }
  }

  func scheduleRestore(from archiveURL: URL) async {
    guard restoreState != .running else { return }
    restoreState = .running
    do {
      let result = try await Task.detached(priority: .userInitiated) { [backupManager] in
        try backupManager.scheduleRestore(from: archiveURL)
      }.value
      scheduledRestore = result
      restoreState = .finished("备份已校验，当前库也已自动备份。退出并重新打开汲作后完成恢复。")
    } catch {
      restoreState = .failed("恢复未安排：\(Self.message(error))")
    }
  }

  func exportDiagnostics(in directory: URL) async {
    guard diagnosticState != .running else { return }
    diagnosticState = .running
    let destination = directory.appendingPathComponent(
      "汲作诊断-\(Self.filenameTimestamp(Date())).zip"
    )
    do {
      let report = try await Task.detached(priority: .userInitiated) { [diagnostics] in
        try diagnostics.export(to: destination)
      }.value
      diagnosticState = .finished(
        "诊断包已导出（含 \(report.crashReportCount) 份近期崩溃报告）：\(destination.path)"
      )
    } catch {
      diagnosticState = .failed("诊断信息未导出：\(Self.message(error))")
    }
  }

  private func publish(_ progress: HistoryBatchExportProgress) {
    batchProgress = progress
  }

  private static func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "请检查所选位置后重试。"
  }

  private static func filenameTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
