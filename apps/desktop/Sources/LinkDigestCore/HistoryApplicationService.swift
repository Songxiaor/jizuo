import Foundation

public struct HistoryApplicationService: Sendable {
  private let repository: any HistoryRepository
  public let storageIdentity: ObjectIdentifier
  public init(repository: any HistoryRepository) {
    self.repository = repository
    storageIdentity = ObjectIdentifier(repository as AnyObject)
  }

  var repositoryAsMindMapStore: (any MindMapStoring)? { repository as? MindMapStoring }
  var repositoryAsTokenUsageStore: (any TokenUsageRecording)? { repository as? TokenUsageRecording }

  public func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    try repository.acceptCapture(command)
  }

  public func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { try repository.createRun(command) }
  public func markRunRunning(_ command: MarkRunRunningCommand) throws { try repository.markRunRunning(command) }
  public func savePartialArtifact(_ command: SavePartialArtifactCommand) throws { try repository.savePartialArtifact(command) }
  public func finishRun(_ command: FinishRunCommand) throws { try repository.finishRun(command) }
  public func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int { try repository.recoverInterruptedRuns(at: milliseconds) }
  public func containsCanonicalURL(_ canonicalURL: CanonicalURL) throws -> Bool { try repository.containsCanonicalURL(canonicalURL) }
  public func historyPage(limit: Int = 50, after cursor: HistoryPageCursor? = nil) throws -> HistoryPage { try repository.historyPage(limit: limit, after: cursor) }
  public func historyPage(limit: Int = 50, after cursor: HistoryPageCursor? = nil, filter: HistoryListFilter) throws -> HistoryPage { try repository.historyPage(limit: limit, after: cursor, filter: filter) }
  public func navigationCounts() throws -> HistoryNavigationCounts { try repository.navigationCounts() }
  public func detail(taskID: TaskID) throws -> HistoryDetailProjection { try repository.detail(taskID: taskID) }
  public func exportProjection(taskID: TaskID) throws -> HistoryExportProjection { try repository.exportProjection(taskID: taskID) }
  public func allTags() throws -> [HistoryTag] { try repository.allTags() }
  public func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] { try repository.addTags(rawNames, to: taskID) }
  public func removeTag(normalizedName: String, from taskID: TaskID) throws { try repository.removeTag(normalizedName: normalizedName, from: taskID) }
  public func deleteTask(taskID: TaskID) throws { try repository.deleteTask(taskID: taskID) }
  public func deleteTasks(taskIDs: Set<TaskID>) throws -> BatchDeleteResult {
    try repository.deleteTasks(taskIDs: taskIDs)
  }
  public func attachMedia(_ command: AttachMediaCommand) throws { try repository.attachMedia(command) }
  public func updateSnapshotBodyText(
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    bodyText: String,
    updatedAtMilliseconds: Int64
  ) throws {
    try repository.updateSnapshotBodyText(
      taskID: taskID,
      snapshotID: snapshotID,
      bodyText: bodyText,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
  public func mediaAsset(taskID: TaskID) throws -> MediaAsset? { try repository.mediaAsset(taskID: taskID) }
  public func beginMediaTranscription(taskID: TaskID, mediaID: String) throws -> TranscriptionAttemptToken {
    try repository.beginMediaTranscription(taskID: taskID, mediaID: mediaID)
  }
  public func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult {
    try repository.updateMediaTranscriptionStatus(taskID: taskID, attempt: attempt, status: status)
  }
  public func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult {
    try repository.completeMediaTranscription(command)
  }
  public func beginTaskTranscription(taskID: TaskID, createdAtMilliseconds: Int64) throws -> TaskTranscriptionAttemptToken {
    try repository.beginTaskTranscription(taskID: taskID, createdAtMilliseconds: createdAtMilliseconds)
  }
  public func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult {
    try repository.updateTaskTranscriptionStatus(
      taskID: taskID,
      attempt: attempt,
      status: status,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
  public func completeTaskTranscription(_ command: CompleteTaskTranscriptionCommand) throws -> CompleteTaskTranscriptionResult {
    try repository.completeTaskTranscription(command)
  }
  public func isMediaContentReferenced(contentSHA256: String) throws -> Bool {
    try repository.isMediaContentReferenced(contentSHA256: contentSHA256)
  }
}
