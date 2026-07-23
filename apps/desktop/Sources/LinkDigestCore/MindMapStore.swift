import Foundation

/// One persisted mind map per task: the contract JSON plus the chosen theme
/// and display-only token usage. SVG is never stored — the local renderer
/// regenerates it from the outline, so theme changes and user edits are free.
public struct TaskMindMapRecord: Codable, Sendable, Equatable {
  public let taskID: TaskID
  public let outline: MindMapOutline
  public let themeID: String
  public let userEdited: Bool
  public let provider: String?
  public let model: String?
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64

  public init(
    taskID: TaskID,
    outline: MindMapOutline,
    themeID: String,
    userEdited: Bool = false,
    provider: String? = nil,
    model: String? = nil,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.outline = outline
    self.themeID = themeID
    self.userEdited = userEdited
    self.provider = provider
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

/// Kept separate from `HistoryRepository` so existing conformers (including
/// test doubles) stay source-compatible; the GRDB repository adopts it.
public protocol MindMapStoring: Sendable {
  func saveMindMap(_ record: TaskMindMapRecord) throws
  func loadMindMap(taskID: TaskID) throws -> TaskMindMapRecord?
  func deleteMindMap(taskID: TaskID) throws
}

extension HistoryApplicationService {
  /// nil when the underlying repository predates mind-map storage.
  public var mindMapStore: (any MindMapStoring)? { repositoryAsMindMapStore }
  /// nil when the underlying repository predates the token ledger.
  public var tokenUsageStore: (any TokenUsageRecording)? { repositoryAsTokenUsageStore }
}

/// One ledger row per non-Run LLM operation (tidy, mind map, …). Runs keep
/// their own usage columns; the whole-task total sums both sources.
public struct TaskTokenUsage: Sendable, Equatable {
  public let taskID: TaskID
  public let operation: String
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  public let createdAtMilliseconds: Int64

  public init(
    taskID: TaskID,
    operation: String,
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?,
    createdAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.operation = operation
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

public struct TaskTokenTotals: Sendable, Equatable {
  public let promptTokens: Int
  public let completionTokens: Int
  public let totalTokens: Int

  public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}

public protocol TokenUsageRecording: Sendable {
  func appendTokenUsage(_ usage: TaskTokenUsage) throws
  /// Ledger-only totals; the caller adds Run usage from the detail projection.
  func ledgerTokenTotals(taskID: TaskID) throws -> TaskTokenTotals
}
