import Foundation

public struct HistoryPageCursor: Codable, Sendable, Equatable {
  public let updatedAtMilliseconds: Int64
  public let taskID: TaskID
  public init(updatedAtMilliseconds: Int64, taskID: TaskID) { self.updatedAtMilliseconds = updatedAtMilliseconds; self.taskID = taskID }
}

public struct HistoryRowProjection: Codable, Sendable, Equatable {
  public let taskID: TaskID
  public let title: String?
  public let canonicalURL: String
  public let host: String
  public let sourceLabel: String
  public let latestRunKind: RunKind?
  public let latestRunStatus: RunStatus?
  public let latestModel: String?
  public let updatedAtMilliseconds: Int64
  public let latestRunAtMilliseconds: Int64?
  public let usageCost: RunUsageCost
  public let artifactPreview: String?
  public init(taskID: TaskID, title: String?, canonicalURL: String, host: String, sourceLabel: String, latestRunKind: RunKind?, latestRunStatus: RunStatus?, latestModel: String?, updatedAtMilliseconds: Int64, latestRunAtMilliseconds: Int64?, usageCost: RunUsageCost, artifactPreview: String?) {
    self.taskID = taskID; self.title = title; self.canonicalURL = canonicalURL; self.host = host; self.sourceLabel = sourceLabel; self.latestRunKind = latestRunKind; self.latestRunStatus = latestRunStatus; self.latestModel = latestModel; self.updatedAtMilliseconds = updatedAtMilliseconds; self.latestRunAtMilliseconds = latestRunAtMilliseconds; self.usageCost = usageCost; self.artifactPreview = artifactPreview
  }
}

public struct HistoryPage: Codable, Sendable, Equatable {
  public let rows: [HistoryRowProjection]
  public let nextCursor: HistoryPageCursor?
  public init(rows: [HistoryRowProjection], nextCursor: HistoryPageCursor?) { self.rows = rows; self.nextCursor = nextCursor }
}

public struct HistoryDetailProjection: Codable, Sendable, Equatable {
  public struct RunDetail: Codable, Sendable, Equatable {
    public let run: HistoryRun
    public let artifact: HistoryArtifact?
    public init(run: HistoryRun, artifact: HistoryArtifact?) { self.run = run; self.artifact = artifact }
  }
  public let task: HistoryTask
  public let snapshots: [ContentSnapshot]
  public let runs: [RunDetail]
  public init(task: HistoryTask, snapshots: [ContentSnapshot], runs: [RunDetail]) { self.task = task; self.snapshots = snapshots; self.runs = runs }
}

public struct HistoryExportProjection: Codable, Sendable, Equatable {
  public static let formatVersion = 1
  public let formatVersion: Int
  public let task: HistoryTask
  public let snapshots: [ContentSnapshot]
  public let runs: [HistoryDetailProjection.RunDetail]

  public init(task: HistoryTask, snapshots: [ContentSnapshot], runs: [HistoryDetailProjection.RunDetail]) {
    formatVersion = Self.formatVersion
    self.task = task
    self.snapshots = snapshots
    self.runs = runs
  }
}
