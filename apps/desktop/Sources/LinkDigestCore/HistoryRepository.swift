import Foundation

public enum RepositoryFailure: Error, Sendable, Equatable, CustomStringConvertible {
  case unavailable
  case readOnly(RepositoryRecoveryReason)
  case notFound
  case captureIdempotencyConflict
  case runIdempotencyConflict
  case invalidStateTransition
  case invalidInput
  case integrityCheckFailed
  case injectedFailure

  public var description: String {
    switch self {
    case .unavailable: "History storage is unavailable."
    case let .readOnly(reason): "History storage is read-only (\(reason.rawValue))."
    case .notFound: "The requested history record was not found."
    case .captureIdempotencyConflict: "CAPTURE_IDEMPOTENCY_CONFLICT"
    case .runIdempotencyConflict: "RUN_IDEMPOTENCY_CONFLICT"
    case .invalidStateTransition: "The run state transition is not allowed."
    case .invalidInput: "The history request is invalid."
    case .integrityCheckFailed: "History storage failed integrity verification."
    case .injectedFailure: "The requested test failure was injected."
    }
  }
}

public enum RepositoryRecoveryReason: String, Codable, Sendable, Equatable {
  case futureSchema = "future_schema"
  case migrationFailed = "migration_failed"
  case storageUnavailable = "storage_unavailable"
}

public enum HistoryRepositoryAccessMode: Sendable, Equatable {
  case writable
  case readOnly(RepositoryRecoveryReason)
}

public struct AcceptCaptureCommand: Sendable, Equatable {
  public let document: CapturedDocument
  public let provenance: CaptureDeliveryProvenance
  public let receivedAtMilliseconds: Int64
  public init(envelope: CaptureEnvelopeV1, receivedAtMilliseconds: Int64) throws {
    do {
      document = .init(wire: envelope)
      provenance = try .browserV1(envelope)
      self.receivedAtMilliseconds = receivedAtMilliseconds
    } catch {
      throw RepositoryFailure.invalidInput
    }
  }
  public init(envelope: CaptureEnvelopeV2, receivedAtMilliseconds: Int64) throws {
    do {
      document = .init(wire: envelope)
      provenance = try .browserV2(envelope)
      self.receivedAtMilliseconds = receivedAtMilliseconds
    } catch {
      throw RepositoryFailure.invalidInput
    }
  }
  public init(document: CapturedDocument, receivedAtMilliseconds: Int64) throws {
    do {
      self.document = document
      provenance = try .localDocument(document)
      self.receivedAtMilliseconds = receivedAtMilliseconds
    } catch {
      throw RepositoryFailure.invalidInput
    }
  }

  init(
    validatedDocument document: CapturedDocument,
    provenance: CaptureDeliveryProvenance,
    receivedAtMilliseconds: Int64
  ) {
    self.document = document
    self.provenance = provenance
    self.receivedAtMilliseconds = receivedAtMilliseconds
  }
}

public struct AcceptCaptureResult: Sendable, Equatable {
  public let taskID: TaskID
  public let snapshotID: ContentSnapshotID
  public let taskWasCreated: Bool
  public let snapshotWasCreated: Bool
  public let deliveryWasReplayed: Bool
  public init(taskID: TaskID, snapshotID: ContentSnapshotID, taskWasCreated: Bool, snapshotWasCreated: Bool, deliveryWasReplayed: Bool) {
    self.taskID = taskID; self.snapshotID = snapshotID; self.taskWasCreated = taskWasCreated; self.snapshotWasCreated = snapshotWasCreated; self.deliveryWasReplayed = deliveryWasReplayed
  }
}

public struct BatchDeleteResult: Sendable, Equatable {
  public let requestedTaskIDs: [TaskID]
  public let deletedTaskIDs: [TaskID]
  public let failedTaskIDs: [TaskID]

  public init(
    requestedTaskIDs: [TaskID],
    deletedTaskIDs: [TaskID],
    failedTaskIDs: [TaskID]
  ) {
    self.requestedTaskIDs = requestedTaskIDs
    self.deletedTaskIDs = deletedTaskIDs
    self.failedTaskIDs = failedTaskIDs
  }
}

public struct CompleteMediaTranscriptionCommand: Sendable, Equatable {
  public let taskID: TaskID
  public let attempt: TranscriptionAttemptToken
  public let document: CapturedDocument
  public let evidence: TranscriptionCompletionEvidence
  public let receivedAtMilliseconds: Int64
  public init(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    document: CapturedDocument,
    evidence: TranscriptionCompletionEvidence,
    receivedAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.attempt = attempt
    self.document = document
    self.evidence = evidence
    self.receivedAtMilliseconds = receivedAtMilliseconds
  }
}

public struct CompleteTaskTranscriptionCommand: Sendable, Equatable {
  public let taskID: TaskID
  public let attempt: TaskTranscriptionAttemptToken
  public let document: CapturedDocument
  public let evidence: TranscriptionCompletionEvidence
  public let receivedAtMilliseconds: Int64

  public init(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    document: CapturedDocument,
    evidence: TranscriptionCompletionEvidence,
    receivedAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.attempt = attempt
    self.document = document
    self.evidence = evidence
    self.receivedAtMilliseconds = receivedAtMilliseconds
  }
}

public struct CreateRunCommand: Sendable, Equatable {
  public let runID: RunID
  public let taskID: TaskID
  public let snapshotID: ContentSnapshotID
  public let idempotencyKey: String
  public let rerunOfRunID: RunID?
  public let kind: RunKind
  public let targetLanguage: String?
  public let createdAtMilliseconds: Int64
  public init(runID: RunID = RunID(), taskID: TaskID, snapshotID: ContentSnapshotID, idempotencyKey: String, rerunOfRunID: RunID? = nil, kind: RunKind, targetLanguage: String? = nil, createdAtMilliseconds: Int64) {
    self.runID = runID; self.taskID = taskID; self.snapshotID = snapshotID; self.idempotencyKey = idempotencyKey; self.rerunOfRunID = rerunOfRunID; self.kind = kind; self.targetLanguage = targetLanguage; self.createdAtMilliseconds = createdAtMilliseconds
  }
}

public struct CreateRunResult: Sendable, Equatable {
  public let runID: RunID
  public let wasCreated: Bool
  public init(runID: RunID, wasCreated: Bool) { self.runID = runID; self.wasCreated = wasCreated }
}

public struct MarkRunRunningCommand: Sendable, Equatable {
  public let runID: RunID
  public let startedAtMilliseconds: Int64
  public let provider: ProviderRunMetadata
  public init(runID: RunID, startedAtMilliseconds: Int64, provider: ProviderRunMetadata) { self.runID = runID; self.startedAtMilliseconds = startedAtMilliseconds; self.provider = provider }
}

public struct SavePartialArtifactCommand: Sendable, Equatable {
  public let runID: RunID
  public let artifactID: ArtifactID
  public let contentFormat: ArtifactContentFormat
  public let bodyText: String
  public let updatedAtMilliseconds: Int64
  public init(runID: RunID, artifactID: ArtifactID = ArtifactID(), contentFormat: ArtifactContentFormat, bodyText: String, updatedAtMilliseconds: Int64) {
    self.runID = runID; self.artifactID = artifactID; self.contentFormat = contentFormat; self.bodyText = bodyText; self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

public struct FinishRunCommand: Sendable, Equatable {
  public struct ArtifactValue: Sendable, Equatable {
    public let id: ArtifactID
    public let contentFormat: ArtifactContentFormat
    public let completeness: ArtifactCompleteness
    public let bodyText: String
    public init(id: ArtifactID = ArtifactID(), contentFormat: ArtifactContentFormat, completeness: ArtifactCompleteness, bodyText: String) {
      self.id = id; self.contentFormat = contentFormat; self.completeness = completeness; self.bodyText = bodyText
    }
  }
  public let runID: RunID
  public let status: RunStatus
  public let finishedAtMilliseconds: Int64
  public let artifact: ArtifactValue?
  public let usageCost: RunUsageCost
  public let failureCode: String?
  public let failureRetryable: Bool?
  public init(runID: RunID, status: RunStatus, finishedAtMilliseconds: Int64, artifact: ArtifactValue? = nil, usageCost: RunUsageCost = .unknown, failureCode: String? = nil, failureRetryable: Bool? = nil) {
    self.runID = runID; self.status = status; self.finishedAtMilliseconds = finishedAtMilliseconds; self.artifact = artifact; self.usageCost = usageCost; self.failureCode = failureCode; self.failureRetryable = failureRetryable
  }
}

public protocol HistoryRepository: Sendable {
  var accessMode: HistoryRepositoryAccessMode { get }
  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult
  func markRunRunning(_ command: MarkRunRunningCommand) throws
  func savePartialArtifact(_ command: SavePartialArtifactCommand) throws
  func finishRun(_ command: FinishRunCommand) throws
  func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int
  func containsCanonicalURL(_ canonicalURL: CanonicalURL) throws -> Bool
  func historyPage(limit: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage
  func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage
  func navigationCounts() throws -> HistoryNavigationCounts
  func detail(taskID: TaskID) throws -> HistoryDetailProjection
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection
  func allTags() throws -> [HistoryTag]
  func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag]
  func removeTag(normalizedName: String, from taskID: TaskID) throws
  func setFavorite(_ isFavorite: Bool, for taskID: TaskID) throws
  func deleteTask(taskID: TaskID) throws
  func deleteTasks(taskIDs: Set<TaskID>) throws -> BatchDeleteResult
  func attachMedia(_ command: AttachMediaCommand) throws
  func mediaAsset(taskID: TaskID) throws -> MediaAsset?
  /// 该任务名下**全部**媒体文件的相对路径（mediaAsset 只返回最新一条）。
  func mediaRelativePaths(taskID: TaskID) throws -> [String]
  /// 该任务名下**全部**媒体资产（mediaAsset 只返回最新一条）。
  func mediaAssets(taskID: TaskID) throws -> [MediaAsset]
  func beginMediaTranscription(taskID: TaskID, mediaID: String) throws -> TranscriptionAttemptToken
  func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult
  func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult
  func beginTaskTranscription(taskID: TaskID, createdAtMilliseconds: Int64) throws -> TaskTranscriptionAttemptToken
  func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult
  func completeTaskTranscription(_ command: CompleteTaskTranscriptionCommand) throws -> CompleteTaskTranscriptionResult
  func isMediaContentReferenced(contentSHA256: String) throws -> Bool
  /// 用户手动校对后的转写文本原地写回该 snapshot；只允许修改正文，
  /// 不改 snapshot 身份、序号或来源标记。找不到匹配行时抛 `notFound`。
  func updateSnapshotBodyText(
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    bodyText: String,
    updatedAtMilliseconds: Int64
  ) throws
  /// 新建一件创作。正文笔记由调用方先建好并传进来。
  func createPiece(
    id: PieceID,
    spark: String,
    noteTaskID: TaskID,
    createdAtMilliseconds: Int64
  ) throws
  /// 首页列表：进行中的在前，已发出的沉到后面。
  func pieces() throws -> [PieceSummary]
  func piece(id: PieceID) throws -> PieceSummary?
  /// 这条 task 是不是某件创作的稿子。存稿路径上每次保存都要问一遍,
  /// 所以给一次索引查找,而不是 `pieces()` 回来自己找。
  func piece(noteTaskID: TaskID) throws -> PieceSummary?
  /// 记一件事。
  func recordPieceEvent(_ event: PieceEvent) throws
  /// 一件创作身上发生过的事,按时间正序。
  ///
  /// 注意每条 `detail` 都可能是一整篇稿子。只要最后一条时用
  /// `lastPieceEvent(of:kind:)`,别把全部版本读进内存再丢掉。
  func pieceEvents(of id: PieceID) throws -> [PieceEvent]
  /// 某件创作最近一条某类事件,没有则 nil。
  func lastPieceEvent(of id: PieceID, kind: PieceEvent.Kind) throws -> PieceEvent?
  /// 「AI 写成这样、我改成了那样」的配对,最近的在前。
  ///
  /// 这是判断沉淀真正要用的东西——单看任何一边都得不出偏好。
  func draftRevisionPairs(limit: Int) throws -> [DraftRevisionPair]
  /// 把一件创作标记为完成:稿件转成作品,离开工作台进入输出。
  ///
  /// 返回作品所在的 task。原稿件的 task **原地转换**,不新建一条——
  /// 复制的话你在输出里改了字,回头看创作里还是旧的。
  func finishPiece(id: PieceID, finishedAtMilliseconds: Int64) throws -> TaskID
  /// 手动覆盖阶段。传 nil 表示回到自动推断。
  func setPieceStage(_ stage: PieceStage?, for id: PieceID, updatedAtMilliseconds: Int64) throws
  func addMaterial(taskID: TaskID, to pieceID: PieceID, addedAtMilliseconds: Int64) throws
  func removeMaterial(taskID: TaskID, from pieceID: PieceID) throws
  func materials(of pieceID: PieceID) throws -> [PieceMaterial]
  func deletePiece(id: PieceID) throws

  // MARK: - 每日选题板

  /// 按一路召回规格取素材。
  ///
  /// 取数是确定性的：时间窗口、条数、标签匹配全在 SQL 里。
  /// 语义判断（哪些能碰撞）留给模型——把「哪些素材有意思」也交给模型，
  /// 它就得先读完整个素材库。
  func recallMaterials(lane: TopicRecall.Lane, now: Int64) throws -> [PieceMaterial]
  /// 写入一批候选。同一天可以多批，追加不覆盖。
  func insertTopicCandidates(_ candidates: [TopicCandidate]) throws
  /// 某一天的候选。
  func topicCandidates(dayStartMilliseconds: Int64) throws -> [TopicCandidate]
  /// 最近 N 天里出现过的候选，新的在前。用来翻选题板。
  func recentTopicCandidates(limit: Int) throws -> [TopicCandidate]
  func setTopicVerdict(_ verdict: TopicCandidate.Verdict, for id: UUID) throws

  // MARK: - 方法库

  /// 全部方法，启用与否都给——界面要能看到停用的那些。
  func writingMethods() throws -> [WritingMethod]
  /// 入库。调用前必须过 `MethodAdmission`。
  func insertWritingMethod(_ method: WritingMethod) throws
  func setWritingMethodEnabled(_ isEnabled: Bool, for id: UUID) throws
  func deleteWritingMethod(id: UUID) throws

  // MARK: - 爆款实验室

  func hitPredictions() throws -> [HitPrediction]
  func hitPrediction(of pieceID: PieceID) throws -> HitPrediction?
  /// 记一次预测。同一件创作只能记一次——允许重来，「盲」就没了。
  func insertHitPrediction(_ prediction: HitPrediction) throws
  /// 录入实际结果与复盘。预测本身不可改。
  func settleHitPrediction(
    id: UUID, actual: HitPrediction.Tier, review: String, settledAtMilliseconds: Int64
  ) throws

  /// 按标题找一条笔记，供 `[[标题]]` 跳转用。找不到返回 nil。
  ///
  /// 只在笔记里找：双链是笔记之间的东西，链到一篇抓来的网页上没有意义——
  /// 那篇网页的标题是抓取时定的，用户并没有给它起过名字。
  func noteID(matchingTitle title: String) throws -> TaskID?
  /// 哪些笔记的正文里出现了 `[[title]]`。
  func notesLinking(toTitle title: String) throws -> [NoteBacklink]
  /// 全部笔记的标题，供输入 `[[` 时补全。
  func noteTitles() throws -> [String]
  /// 改标题。
  ///
  /// 只对用户自己写的笔记开放：抓取记录的标题是抓来的事实，改了会让它和来源
  /// 对不上；笔记的标题从来就是用户给的，不能改反而说不通。
  func updateTaskTitle(
    taskID: TaskID,
    title: String,
    updatedAtMilliseconds: Int64
  ) throws
}

public extension HistoryRepository {
  /// Clipboard suggestions must fail closed when history cannot be queried.
  /// The production repository overrides this with an indexed exact lookup.
  func containsCanonicalURL(_: CanonicalURL) throws -> Bool { throw RepositoryFailure.unavailable }

  func deleteTasks(taskIDs: Set<TaskID>) throws -> BatchDeleteResult {
    _ = taskIDs
    throw RepositoryFailure.unavailable
  }

  /// Read-only / unavailable repositories deliberately return an empty rail:
  /// navigation must never make an otherwise readable list fail to load.
  func navigationCounts() throws -> HistoryNavigationCounts { .init() }

  /// Default no-op so older test doubles stay source-compatible until they opt in.
  func attachMedia(_ command: AttachMediaCommand) throws {
    _ = command
    throw RepositoryFailure.unavailable
  }

  func mediaAsset(taskID: TaskID) throws -> MediaAsset? {
    _ = taskID
    return nil
  }

  func mediaRelativePaths(taskID: TaskID) throws -> [String] {
    _ = taskID
    return []
  }

  func mediaAssets(taskID: TaskID) throws -> [MediaAsset] {
    // 默认实现退回单条，保证未实现该方法的仓库不会静默漏删。
    try mediaAsset(taskID: taskID).map { [$0] } ?? []
  }

  func beginMediaTranscription(taskID: TaskID, mediaID: String) throws -> TranscriptionAttemptToken {
    _ = taskID
    _ = mediaID
    throw RepositoryFailure.unavailable
  }

  /// Default failure keeps older test doubles source-compatible while ensuring
  /// production callers never mistake an ignored status update for persistence.
  func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult {
    _ = taskID
    _ = attempt
    _ = status
    throw RepositoryFailure.unavailable
  }

  func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult {
    _ = command
    throw RepositoryFailure.unavailable
  }

  func beginTaskTranscription(taskID: TaskID, createdAtMilliseconds: Int64) throws -> TaskTranscriptionAttemptToken {
    _ = taskID
    _ = createdAtMilliseconds
    throw RepositoryFailure.unavailable
  }

  func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult {
    _ = taskID
    _ = attempt
    _ = status
    _ = updatedAtMilliseconds
    throw RepositoryFailure.unavailable
  }

  func completeTaskTranscription(_ command: CompleteTaskTranscriptionCommand) throws -> CompleteTaskTranscriptionResult {
    _ = command
    throw RepositoryFailure.unavailable
  }

  func isMediaContentReferenced(contentSHA256: String) throws -> Bool {
    _ = contentSHA256
    return false
  }
}

public extension HistoryRepository {
  /// Existing test doubles and alternate repositories can retain their old
  /// paging implementation until they opt into local SQL filtering.
  func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    guard filter == .none else { throw RepositoryFailure.unavailable }
    return try historyPage(limit: limit, after: cursor)
  }

  func allTags() throws -> [HistoryTag] { [] }
  func addTags(_: [String], to _: TaskID) throws -> [HistoryTag] { throw RepositoryFailure.unavailable }
  func removeTag(normalizedName _: String, from _: TaskID) throws { throw RepositoryFailure.unavailable }
  func setFavorite(_: Bool, for _: TaskID) throws { throw RepositoryFailure.unavailable }

  /// 转写校对编辑需要真实持久化支持；旧测试替身默认视为不可用。
  func updateSnapshotBodyText(
    taskID _: TaskID,
    snapshotID _: ContentSnapshotID,
    bodyText _: String,
    updatedAtMilliseconds _: Int64
  ) throws { throw RepositoryFailure.unavailable }

  func updateTaskTitle(
    taskID _: TaskID,
    title _: String,
    updatedAtMilliseconds _: Int64
  ) throws { throw RepositoryFailure.unavailable }

  /// 双链在旧测试替身上一律「找不到」而不是抛错：链接指不到东西是正常状态，
  /// 不该让整个视图进入错误分支。
  /// 工作台在旧测试替身上一律为空/不可用：它是新增能力，
  /// 已有的替身没有理由被迫实现它。
  func createPiece(
    id _: PieceID, spark _: String, noteTaskID _: TaskID, createdAtMilliseconds _: Int64
  ) throws { throw RepositoryFailure.unavailable }
  func pieces() throws -> [PieceSummary] { [] }
  func piece(id _: PieceID) throws -> PieceSummary? { nil }
  func setPieceStage(_: PieceStage?, for _: PieceID, updatedAtMilliseconds _: Int64) throws {
    throw RepositoryFailure.unavailable
  }
  func finishPiece(id _: PieceID, finishedAtMilliseconds _: Int64) throws -> TaskID {
    throw RepositoryFailure.unavailable
  }
  func recordPieceEvent(_: PieceEvent) throws { throw RepositoryFailure.unavailable }
  // 工作台这一批的读方法统一 throw,不返回空集合。
  //
  // 「没实现」和「真的没数据」返回同一个 `[]`,表现是选题板说「素材还不够」、
  // 提炼说「还需要 N 篇改过的稿子」——两句都指向用户去攒数据,而实际原因是
  // 这个替身根本没接上取数层。让它抛出去,调用方要么处理要么当场炸,
  // 至少不会把一个接线错误伪装成一句用户指令。
  func piece(noteTaskID _: TaskID) throws -> PieceSummary? {
    throw RepositoryFailure.unavailable
  }
  func recallMaterials(lane _: TopicRecall.Lane, now _: Int64) throws -> [PieceMaterial] {
    throw RepositoryFailure.unavailable
  }
  func insertTopicCandidates(_: [TopicCandidate]) throws { throw RepositoryFailure.unavailable }
  func topicCandidates(dayStartMilliseconds _: Int64) throws -> [TopicCandidate] {
    throw RepositoryFailure.unavailable
  }
  func recentTopicCandidates(limit _: Int) throws -> [TopicCandidate] {
    throw RepositoryFailure.unavailable
  }
  func setTopicVerdict(_: TopicCandidate.Verdict, for _: UUID) throws {
    throw RepositoryFailure.unavailable
  }
  func writingMethods() throws -> [WritingMethod] { throw RepositoryFailure.unavailable }
  func insertWritingMethod(_: WritingMethod) throws { throw RepositoryFailure.unavailable }
  func setWritingMethodEnabled(_: Bool, for _: UUID) throws { throw RepositoryFailure.unavailable }
  func deleteWritingMethod(id _: UUID) throws { throw RepositoryFailure.unavailable }
  func hitPredictions() throws -> [HitPrediction] { throw RepositoryFailure.unavailable }
  func hitPrediction(of _: PieceID) throws -> HitPrediction? {
    throw RepositoryFailure.unavailable
  }
  func insertHitPrediction(_: HitPrediction) throws { throw RepositoryFailure.unavailable }
  func settleHitPrediction(
    id _: UUID, actual _: HitPrediction.Tier, review _: String, settledAtMilliseconds _: Int64
  ) throws { throw RepositoryFailure.unavailable }
  func pieceEvents(of _: PieceID) throws -> [PieceEvent] { throw RepositoryFailure.unavailable }
  func lastPieceEvent(of _: PieceID, kind _: PieceEvent.Kind) throws -> PieceEvent? {
    throw RepositoryFailure.unavailable
  }
  func draftRevisionPairs(limit _: Int) throws -> [DraftRevisionPair] {
    throw RepositoryFailure.unavailable
  }
  func addMaterial(taskID _: TaskID, to _: PieceID, addedAtMilliseconds _: Int64) throws {
    throw RepositoryFailure.unavailable
  }
  func removeMaterial(taskID _: TaskID, from _: PieceID) throws { throw RepositoryFailure.unavailable }
  func materials(of _: PieceID) throws -> [PieceMaterial] { [] }
  func deletePiece(id _: PieceID) throws { throw RepositoryFailure.unavailable }

  func noteID(matchingTitle _: String) throws -> TaskID? { nil }
  func notesLinking(toTitle _: String) throws -> [NoteBacklink] { [] }
  func noteTitles() throws -> [String] { [] }
}
