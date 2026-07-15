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
  public let envelope: CaptureEnvelopeV1
  public let receivedAtMilliseconds: Int64
  public init(envelope: CaptureEnvelopeV1, receivedAtMilliseconds: Int64) { self.envelope = envelope; self.receivedAtMilliseconds = receivedAtMilliseconds }
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
  func historyPage(limit: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage
  func detail(taskID: TaskID) throws -> HistoryDetailProjection
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection
  func deleteTask(taskID: TaskID) throws
}
