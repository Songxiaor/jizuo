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
  var repositoryAsAnnotationStore: (any AnnotationStoring)? { repository as? AnnotationStoring }

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
  public func setFavorite(_ isFavorite: Bool, for taskID: TaskID) throws { try repository.setFavorite(isFavorite, for: taskID) }
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
  // MARK: - 工作台

  public func createPiece(
    id: PieceID, spark: String, noteTaskID: TaskID, createdAtMilliseconds: Int64
  ) throws {
    try repository.createPiece(
      id: id, spark: spark, noteTaskID: noteTaskID, createdAtMilliseconds: createdAtMilliseconds
    )
  }
  public func pieces() throws -> [PieceSummary] { try repository.pieces() }
  public func piece(id: PieceID) throws -> PieceSummary? { try repository.piece(id: id) }
  public func finishPiece(id: PieceID, finishedAtMilliseconds: Int64) throws -> TaskID {
    try repository.finishPiece(id: id, finishedAtMilliseconds: finishedAtMilliseconds)
  }
  public func setPieceStage(_ stage: PieceStage?, for id: PieceID, updatedAtMilliseconds: Int64) throws {
    try repository.setPieceStage(stage, for: id, updatedAtMilliseconds: updatedAtMilliseconds)
  }
  public func addMaterial(taskID: TaskID, to pieceID: PieceID, addedAtMilliseconds: Int64) throws {
    try repository.addMaterial(taskID: taskID, to: pieceID, addedAtMilliseconds: addedAtMilliseconds)
  }
  public func removeMaterial(taskID: TaskID, from pieceID: PieceID) throws {
    try repository.removeMaterial(taskID: taskID, from: pieceID)
  }
  public func materials(of pieceID: PieceID) throws -> [PieceMaterial] {
    try repository.materials(of: pieceID)
  }
  public func deletePiece(id: PieceID) throws { try repository.deletePiece(id: id) }
  public func recordPieceEvent(_ event: PieceEvent) throws { try repository.recordPieceEvent(event) }
  public func pieceEvents(of id: PieceID) throws -> [PieceEvent] { try repository.pieceEvents(of: id) }
  public func draftRevisionPairs(limit: Int = 30) throws -> [DraftRevisionPair] {
    try repository.draftRevisionPairs(limit: limit)
  }

  // MARK: - 每日选题板

  public func recallMaterials(lane: TopicRecall.Lane, now: Int64) throws -> [PieceMaterial] {
    try repository.recallMaterials(lane: lane, now: now)
  }
  public func insertTopicCandidates(_ candidates: [TopicCandidate]) throws {
    try repository.insertTopicCandidates(candidates)
  }
  public func topicCandidates(dayStartMilliseconds: Int64) throws -> [TopicCandidate] {
    try repository.topicCandidates(dayStartMilliseconds: dayStartMilliseconds)
  }
  public func recentTopicCandidates(limit: Int = 60) throws -> [TopicCandidate] {
    try repository.recentTopicCandidates(limit: limit)
  }
  public func setTopicVerdict(_ verdict: TopicCandidate.Verdict, for id: UUID) throws {
    try repository.setTopicVerdict(verdict, for: id)
  }

  // MARK: - 方法库

  public func writingMethods() throws -> [WritingMethod] { try repository.writingMethods() }
  public func insertWritingMethod(_ method: WritingMethod) throws {
    try repository.insertWritingMethod(method)
  }
  public func setWritingMethodEnabled(_ isEnabled: Bool, for id: UUID) throws {
    try repository.setWritingMethodEnabled(isEnabled, for: id)
  }
  public func deleteWritingMethod(id: UUID) throws { try repository.deleteWritingMethod(id: id) }

  // MARK: - 爆款实验室

  public func hitPredictions() throws -> [HitPrediction] { try repository.hitPredictions() }
  public func hitPrediction(of pieceID: PieceID) throws -> HitPrediction? {
    try repository.hitPrediction(of: pieceID)
  }
  public func insertHitPrediction(_ prediction: HitPrediction) throws {
    try repository.insertHitPrediction(prediction)
  }
  public func settleHitPrediction(
    id: UUID, actual: HitPrediction.Tier, review: String, settledAtMilliseconds: Int64
  ) throws {
    try repository.settleHitPrediction(
      id: id, actual: actual, review: review, settledAtMilliseconds: settledAtMilliseconds
    )
  }

  public func noteID(matchingTitle title: String) throws -> TaskID? {
    try repository.noteID(matchingTitle: title)
  }
  public func notesLinking(toTitle title: String) throws -> [NoteBacklink] {
    try repository.notesLinking(toTitle: title)
  }
  public func noteTitles() throws -> [String] { try repository.noteTitles() }
  public func updateTaskTitle(
    taskID: TaskID,
    title: String,
    updatedAtMilliseconds: Int64
  ) throws {
    try repository.updateTaskTitle(
      taskID: taskID,
      title: title,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
  public func mediaAsset(taskID: TaskID) throws -> MediaAsset? { try repository.mediaAsset(taskID: taskID) }

  /// 该任务名下**全部**媒体文件的相对路径。
  ///
  /// 删除任务时必须用这个，不能用 `mediaAsset(taskID:)`——后者是
  /// `ORDER BY created_at_ms DESC LIMIT 1`，只返回最新一条。而 media_assets 的
  /// 唯一键是 (task_id, content_sha256)，同一任务可以有多行：重抓后字节不同、
  /// B 站合流成功与失败产出不同 sha。只删最新那条，其余文件的 DB 行被 CASCADE
  /// 删掉、磁盘文件却没人清，成为永久孤儿——而且没有任何清扫器会再发现它们。
  public func mediaRelativePaths(taskID: TaskID) throws -> [String] {
    try repository.mediaRelativePaths(taskID: taskID)
  }

  public func mediaAssets(taskID: TaskID) throws -> [MediaAsset] {
    try repository.mediaAssets(taskID: taskID)
  }
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
