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
  /// 任务首次入库时间；旧序列化数据可能缺失，因此保持可选以兼容解码。
  public let createdAtMilliseconds: Int64?
  public let latestRunAtMilliseconds: Int64?
  public let usageCost: RunUsageCost
  public let artifactPreview: String?
  public let author: String?
  public let published: String?
  /// 处理状态徽标：可选以兼容旧序列化数据（缺失=未知，不显示）。
  public let hasTranscript: Bool?
  public let hasSummary: Bool?
  public let hasMindMap: Bool?
  public init(taskID: TaskID, title: String?, canonicalURL: String, host: String, sourceLabel: String, latestRunKind: RunKind?, latestRunStatus: RunStatus?, latestModel: String?, updatedAtMilliseconds: Int64, createdAtMilliseconds: Int64? = nil, latestRunAtMilliseconds: Int64?, usageCost: RunUsageCost, artifactPreview: String?, author: String? = nil, published: String? = nil, hasTranscript: Bool? = nil, hasSummary: Bool? = nil, hasMindMap: Bool? = nil) {
    self.taskID = taskID; self.title = title; self.canonicalURL = canonicalURL; self.host = host; self.sourceLabel = sourceLabel; self.latestRunKind = latestRunKind; self.latestRunStatus = latestRunStatus; self.latestModel = latestModel; self.updatedAtMilliseconds = updatedAtMilliseconds; self.createdAtMilliseconds = createdAtMilliseconds; self.latestRunAtMilliseconds = latestRunAtMilliseconds; self.usageCost = usageCost; self.artifactPreview = artifactPreview; self.author = author; self.published = published; self.hasTranscript = hasTranscript; self.hasSummary = hasSummary; self.hasMindMap = hasMindMap
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
  public let tags: [HistoryTag]
  /// Optional local video asset for Loop V captures. Absent for pure-text history.
  public let media: MediaAsset?
  /// True when any capture delivery for this task used contract V2.
  /// V2 envelopes always carry a `MediaDescriptor` (ephemeral URLs are not
  /// persisted); the flag is derived from existing `capture_deliveries` rows,
  /// not a schema migration.
  public let hadMediaDescriptor: Bool
  public init(
    task: HistoryTask,
    snapshots: [ContentSnapshot],
    runs: [RunDetail],
    tags: [HistoryTag] = [],
    media: MediaAsset? = nil,
    hadMediaDescriptor: Bool = false
  ) {
    self.task = task
    self.snapshots = snapshots
    self.runs = runs
    self.tags = tags
    self.media = media
    self.hadMediaDescriptor = hadMediaDescriptor
  }
}

public struct HistoryExportProjection: Codable, Sendable, Equatable {
  public static let formatVersion = 1
  public let formatVersion: Int
  public let task: HistoryTask
  public let snapshots: [ContentSnapshot]
  public let runs: [HistoryDetailProjection.RunDetail]
  public let tags: [HistoryTag]

  public init(task: HistoryTask, snapshots: [ContentSnapshot], runs: [HistoryDetailProjection.RunDetail], tags: [HistoryTag] = []) {
    formatVersion = Self.formatVersion
    self.task = task
    // An export projection is an explicit data-escape boundary. Keep user-facing
    // history, but strip fields that only exist for repository/provider control.
    self.snapshots = snapshots.map { snapshot in
      ContentSnapshot(
        id: snapshot.id,
        taskID: snapshot.taskID,
        sequence: snapshot.sequence,
        envelopeCreatedAtMilliseconds: snapshot.envelopeCreatedAtMilliseconds,
        capturedAtMilliseconds: snapshot.capturedAtMilliseconds,
        sourceKind: snapshot.sourceKind,
        sourceURL: snapshot.sourceURL,
        title: snapshot.title,
        platform: snapshot.platform,
        captureMethod: snapshot.captureMethod,
        completeness: snapshot.completeness,
        bodyText: snapshot.bodyText,
        characterCount: snapshot.characterCount,
        bodySHA256: snapshot.bodySHA256,
        sourceLabel: snapshot.sourceLabel,
        usedCookie: false
      )
    }
    self.runs = runs.map { detail in
      let run = detail.run
      let safeRun = HistoryRun(
        id: run.id,
        taskID: run.taskID,
        snapshotID: run.snapshotID,
        idempotencyKey: "",
        rerunOfRunID: run.rerunOfRunID,
        kind: run.kind,
        targetLanguage: run.targetLanguage,
        status: run.status,
        providerProfileID: nil,
        providerKind: nil,
        providerBaseURL: nil,
        providerAPIMode: nil,
        model: run.model,
        createdAtMilliseconds: run.createdAtMilliseconds,
        startedAtMilliseconds: run.startedAtMilliseconds,
        finishedAtMilliseconds: run.finishedAtMilliseconds,
        failureCode: nil,
        failureRetryable: nil,
        usageCost: run.usageCost
      )
      return .init(run: safeRun, artifact: detail.artifact)
    }
    self.tags = HistoryTagNormalizer.normalizedTags(tags.map(\.name))
  }

  private enum CodingKeys: String, CodingKey { case formatVersion, task, snapshots, runs, tags }

  /// The on-disk JSON schema intentionally excludes provider configuration,
  /// idempotency keys, cookie-use markers and raw failure material. Decoding
  /// restores the same public projection with safe defaults for those fields.
  private struct SnapshotValue: Codable {
    let id: ContentSnapshotID
    let taskID: TaskID
    let sequence: Int
    let envelopeCreatedAtMilliseconds: Int64
    let capturedAtMilliseconds: Int64
    let sourceKind: String
    let sourceURL: String
    let title: String?
    let platform: String
    let captureMethod: String
    let completeness: String
    let bodyText: String
    let characterCount: Int
    let bodySHA256: String
    let sourceLabel: String

    init(_ value: ContentSnapshot) {
      id = value.id; taskID = value.taskID; sequence = value.sequence
      envelopeCreatedAtMilliseconds = value.envelopeCreatedAtMilliseconds
      capturedAtMilliseconds = value.capturedAtMilliseconds
      sourceKind = value.sourceKind; sourceURL = value.sourceURL; title = value.title
      platform = value.platform; captureMethod = value.captureMethod
      completeness = value.completeness; bodyText = value.bodyText
      characterCount = value.characterCount; bodySHA256 = value.bodySHA256
      sourceLabel = value.sourceLabel
    }

    var projection: ContentSnapshot {
      .init(id: id, taskID: taskID, sequence: sequence, envelopeCreatedAtMilliseconds: envelopeCreatedAtMilliseconds, capturedAtMilliseconds: capturedAtMilliseconds, sourceKind: sourceKind, sourceURL: sourceURL, title: title, platform: platform, captureMethod: captureMethod, completeness: completeness, bodyText: bodyText, characterCount: characterCount, bodySHA256: bodySHA256, sourceLabel: sourceLabel, usedCookie: false)
    }
  }

  private struct RunValue: Codable {
    let id: RunID
    let taskID: TaskID
    let snapshotID: ContentSnapshotID
    let rerunOfRunID: RunID?
    let kind: RunKind
    let targetLanguage: String?
    let status: RunStatus
    let model: String?
    let createdAtMilliseconds: Int64
    let startedAtMilliseconds: Int64?
    let finishedAtMilliseconds: Int64?
    let usageCost: RunUsageCost
    let artifact: HistoryArtifact?

    init(_ value: HistoryDetailProjection.RunDetail) {
      let run = value.run
      id = run.id; taskID = run.taskID; snapshotID = run.snapshotID
      rerunOfRunID = run.rerunOfRunID; kind = run.kind; targetLanguage = run.targetLanguage
      status = run.status; model = run.model; createdAtMilliseconds = run.createdAtMilliseconds
      startedAtMilliseconds = run.startedAtMilliseconds; finishedAtMilliseconds = run.finishedAtMilliseconds
      usageCost = run.usageCost; artifact = value.artifact
    }

    var projection: HistoryDetailProjection.RunDetail {
      let run = HistoryRun(id: id, taskID: taskID, snapshotID: snapshotID, idempotencyKey: "", rerunOfRunID: rerunOfRunID, kind: kind, targetLanguage: targetLanguage, status: status, providerProfileID: nil, providerKind: nil, providerBaseURL: nil, providerAPIMode: nil, model: model, createdAtMilliseconds: createdAtMilliseconds, startedAtMilliseconds: startedAtMilliseconds, finishedAtMilliseconds: finishedAtMilliseconds, failureCode: nil, failureRetryable: nil, usageCost: usageCost)
      return .init(run: run, artifact: artifact)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .formatVersion)
    guard version == Self.formatVersion else {
      throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: container, debugDescription: "Unsupported history export format version.")
    }
    let decodedTask = try container.decode(HistoryTask.self, forKey: .task)
    let decodedSnapshots = try container.decode([SnapshotValue].self, forKey: .snapshots).map(\.projection)
    let decodedRuns = try container.decode([RunValue].self, forKey: .runs).map(\.projection)
    let decodedTags = try container.decodeIfPresent([HistoryTag].self, forKey: .tags) ?? []
    try Self.validateV1(
      task: decodedTask,
      snapshots: decodedSnapshots,
      runs: decodedRuns,
      codingPath: decoder.codingPath
    )
    formatVersion = version
    task = decodedTask
    snapshots = decodedSnapshots
    runs = decodedRuns
    tags = HistoryTagNormalizer.normalizedTags(decodedTags.map(\.name))
  }

  private static func validateV1(
    task: HistoryTask,
    snapshots: [ContentSnapshot],
    runs: [HistoryDetailProjection.RunDetail],
    codingPath: [any CodingKey]
  ) throws {
    func corrupted(_ description: String) -> DecodingError {
      .dataCorrupted(.init(codingPath: codingPath, debugDescription: description))
    }
    guard isCanonical(task.id) else { throw corrupted("Task id is not a canonical UUID.") }

    var snapshotIDs = Set<ContentSnapshotID>()
    for snapshot in snapshots {
      guard isCanonical(snapshot.id), isCanonical(snapshot.taskID) else {
        throw corrupted("Snapshot contains a non-canonical UUID.")
      }
      guard snapshot.taskID == task.id else { throw corrupted("Snapshot does not belong to the exported task.") }
      guard snapshotIDs.insert(snapshot.id).inserted else { throw corrupted("Snapshot ids must be unique.") }
    }

    var runIDs = Set<RunID>()
    for detail in runs {
      let run = detail.run
      guard isCanonical(run.id), isCanonical(run.taskID), isCanonical(run.snapshotID) else {
        throw corrupted("Run contains a non-canonical UUID.")
      }
      if let rerunOfRunID = run.rerunOfRunID, !isCanonical(rerunOfRunID) {
        throw corrupted("Rerun id is not a canonical UUID.")
      }
      guard runIDs.insert(run.id).inserted else { throw corrupted("Run ids must be unique.") }
    }

    var artifactIDs = Set<ArtifactID>()
    for detail in runs {
      let run = detail.run
      guard run.taskID == task.id else { throw corrupted("Run does not belong to the exported task.") }
      guard snapshotIDs.contains(run.snapshotID) else { throw corrupted("Run references a snapshot outside the export.") }
      if let rerunOfRunID = run.rerunOfRunID {
        guard rerunOfRunID != run.id, runIDs.contains(rerunOfRunID) else {
          throw corrupted("Rerun references a run outside the export or itself.")
        }
      }
      do {
        _ = try RunUsageCost.validated(
          inputTokens: run.usageCost.inputTokens,
          outputTokens: run.usageCost.outputTokens,
          totalTokens: run.usageCost.totalTokens,
          costAmountMicros: run.usageCost.costAmountMicros,
          costCurrencyCode: run.usageCost.costCurrencyCode
        )
      } catch {
        throw corrupted("Run usage or cost is invalid.")
      }
      if let artifact = detail.artifact {
        guard isCanonical(artifact.id), isCanonical(artifact.runID) else {
          throw corrupted("Artifact contains a non-canonical UUID.")
        }
        guard artifact.runID == run.id else { throw corrupted("Artifact does not belong to its run.") }
        guard artifactIDs.insert(artifact.id).inserted else { throw corrupted("Artifact ids must be unique.") }
      }
    }
  }

  private static func isCanonical<Identifier: HistoryIdentifier>(_ identifier: Identifier) -> Bool {
    Identifier(identifier.rawValue) != nil
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(formatVersion, forKey: .formatVersion)
    try container.encode(task, forKey: .task)
    try container.encode(snapshots.map(SnapshotValue.init), forKey: .snapshots)
    try container.encode(runs.map(RunValue.init), forKey: .runs)
    try container.encode(tags, forKey: .tags)
  }
}
