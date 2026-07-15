import Foundation

public struct HistoryApplicationService: Sendable {
  private let repository: any HistoryRepository
  public init(repository: any HistoryRepository) { self.repository = repository }

  public func acceptCapture(_ envelope: CaptureEnvelopeV1, receivedAtMilliseconds: Int64) throws -> AcceptCaptureResult {
    try repository.acceptCapture(.init(envelope: envelope, receivedAtMilliseconds: receivedAtMilliseconds))
  }

  public func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { try repository.createRun(command) }
  public func markRunRunning(_ command: MarkRunRunningCommand) throws { try repository.markRunRunning(command) }
  public func savePartialArtifact(_ command: SavePartialArtifactCommand) throws { try repository.savePartialArtifact(command) }
  public func finishRun(_ command: FinishRunCommand) throws { try repository.finishRun(command) }
  public func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int { try repository.recoverInterruptedRuns(at: milliseconds) }
  public func historyPage(limit: Int = 50, after cursor: HistoryPageCursor? = nil) throws -> HistoryPage { try repository.historyPage(limit: limit, after: cursor) }
  public func detail(taskID: TaskID) throws -> HistoryDetailProjection { try repository.detail(taskID: taskID) }
  public func exportProjection(taskID: TaskID) throws -> HistoryExportProjection { try repository.exportProjection(taskID: taskID) }
  public func deleteTask(taskID: TaskID) throws { try repository.deleteTask(taskID: taskID) }
}
