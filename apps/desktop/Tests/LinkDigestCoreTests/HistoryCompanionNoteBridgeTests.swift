import XCTest
import LinkDigestShared
@testable import LinkDigestCore

final class HistoryCompanionNoteBridgeTests: XCTestCase {
  func testApplyLinkWithSummaryWritesCompletedSummarizeArtifact() throws {
    let repository = CompanionBridgeFakeRepository()
    let bridge = HistoryCompanionNoteBridge(
      history: HistoryApplicationService(repository: repository)
    )
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/bridge-summary",
      title: "桥接",
      body: "原文内容",
      summary: "手机上的摘要"
    )

    try bridge.apply(card)

    let taskID = try XCTUnwrap(repository.taskID(forCanonicalURL: try CanonicalURL(card.sourceURL!)))
    let detail = try repository.detail(taskID: taskID)
    let completed = detail.runs.filter { $0.run.kind == .summarize && $0.run.status == .completed }
    XCTAssertEqual(completed.count, 1)
    XCTAssertEqual(completed.first?.artifact?.bodyText, "手机上的摘要")
    XCTAssertEqual(completed.first?.run.model, "companion-sync")
  }

  func testApplySkipsDuplicateSummaryBody() throws {
    let repository = CompanionBridgeFakeRepository()
    let bridge = HistoryCompanionNoteBridge(
      history: HistoryApplicationService(repository: repository)
    )
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/bridge-skip",
      title: "跳过",
      body: "原文",
      summary: "不变摘要"
    )

    try bridge.apply(card)
    try bridge.apply(card)

    let taskID = try XCTUnwrap(repository.taskID(forCanonicalURL: try CanonicalURL(card.sourceURL!)))
    let detail = try repository.detail(taskID: taskID)
    let completed = detail.runs.filter { $0.run.kind == .summarize && $0.run.status == .completed }
    XCTAssertEqual(completed.count, 1)
    XCTAssertEqual(completed.first?.artifact?.bodyText, "不变摘要")
  }

  func testApplyUpdatedSummaryAppendsNewCompletedRun() throws {
    let repository = CompanionBridgeFakeRepository()
    let bridge = HistoryCompanionNoteBridge(
      history: HistoryApplicationService(repository: repository)
    )
    var card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/bridge-update",
      title: "更新",
      body: "原文",
      summary: "旧摘要"
    )
    try bridge.apply(card)

    card.summary = "新摘要"
    card.updatedAtMilliseconds += 10
    try bridge.apply(card)

    let taskID = try XCTUnwrap(repository.taskID(forCanonicalURL: try CanonicalURL(card.sourceURL!)))
    let detail = try repository.detail(taskID: taskID)
    let completed = detail.runs
      .filter { $0.run.kind == .summarize && $0.run.status == .completed }
      .sorted { $0.run.createdAtMilliseconds > $1.run.createdAtMilliseconds }
    XCTAssertEqual(completed.count, 2)
    XCTAssertEqual(completed.first?.artifact?.bodyText, "新摘要")
    XCTAssertEqual(HistorySyncNoteCardMapping.latestSummary(in: detail), "新摘要")
  }

  func testApplyTextNoteDoesNotCreateSummarizeRun() throws {
    let repository = CompanionBridgeFakeRepository()
    let bridge = HistoryCompanionNoteBridge(
      history: HistoryApplicationService(repository: repository)
    )
    let card = SyncNoteCardFactory.makeText(title: "笔记", body: "正文")
    try bridge.apply(card)

    let taskID = try XCTUnwrap(repository.taskID(forCanonicalURL: try HistorySyncNoteCardMapping.canonicalURL(for: card)))
    let detail = try repository.detail(taskID: taskID)
    XCTAssertTrue(detail.runs.isEmpty)
  }
}

/// 仅覆盖 Companion 桥接写回所需的最小 History 行为。
private final class CompanionBridgeFakeRepository: HistoryRepository, @unchecked Sendable {
  private struct TaskRecord {
    var task: HistoryTask
    var snapshots: [ContentSnapshot]
    var runs: [(run: HistoryRun, artifact: HistoryArtifact?)]
  }

  private var byTaskID: [String: TaskRecord] = [:]
  private var taskIDByCanonical: [String: TaskID] = [:]

  let accessMode: HistoryRepositoryAccessMode = .writable

  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    let url = try CanonicalURL(command.document.url)
    if let existing = taskIDByCanonical[url.value], var record = byTaskID[existing.rawValue] {
      let snapshotID = ContentSnapshotID()
      let snapshot = makeSnapshot(
        id: snapshotID,
        taskID: existing,
        sequence: (record.snapshots.last?.sequence ?? 0) + 1,
        document: command.document,
        at: command.receivedAtMilliseconds
      )
      record.snapshots.append(snapshot)
      record.task = HistoryTask(
        id: existing,
        canonicalURL: url.value,
        canonicalizationVersion: record.task.canonicalizationVersion,
        createdAtMilliseconds: record.task.createdAtMilliseconds,
        updatedAtMilliseconds: command.receivedAtMilliseconds
      )
      byTaskID[existing.rawValue] = record
      return .init(
        taskID: existing,
        snapshotID: snapshotID,
        taskWasCreated: false,
        snapshotWasCreated: true,
        deliveryWasReplayed: false
      )
    }

    let taskID = TaskID()
    let snapshotID = ContentSnapshotID()
    let snapshot = makeSnapshot(
      id: snapshotID,
      taskID: taskID,
      sequence: 1,
      document: command.document,
      at: command.receivedAtMilliseconds
    )
    let task = HistoryTask(
      id: taskID,
      canonicalURL: url.value,
      canonicalizationVersion: 1,
      createdAtMilliseconds: command.receivedAtMilliseconds,
      updatedAtMilliseconds: command.receivedAtMilliseconds
    )
    byTaskID[taskID.rawValue] = TaskRecord(task: task, snapshots: [snapshot], runs: [])
    taskIDByCanonical[url.value] = taskID
    return .init(
      taskID: taskID,
      snapshotID: snapshotID,
      taskWasCreated: true,
      snapshotWasCreated: true,
      deliveryWasReplayed: false
    )
  }

  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult {
    guard var record = byTaskID[command.taskID.rawValue] else { throw RepositoryFailure.notFound }
    guard record.snapshots.contains(where: { $0.id == command.snapshotID }) else {
      throw RepositoryFailure.notFound
    }
    if let existing = record.runs.first(where: { $0.run.idempotencyKey == command.idempotencyKey }) {
      return .init(runID: existing.run.id, wasCreated: false)
    }
    let run = HistoryRun(
      id: command.runID,
      taskID: command.taskID,
      snapshotID: command.snapshotID,
      idempotencyKey: command.idempotencyKey,
      rerunOfRunID: command.rerunOfRunID,
      kind: command.kind,
      targetLanguage: command.targetLanguage,
      status: .queued,
      providerProfileID: nil,
      providerKind: nil,
      providerBaseURL: nil,
      providerAPIMode: nil,
      model: nil,
      createdAtMilliseconds: command.createdAtMilliseconds,
      startedAtMilliseconds: nil,
      finishedAtMilliseconds: nil,
      failureCode: nil,
      failureRetryable: nil,
      usageCost: RunUsageCost()
    )
    record.runs.append((run, nil))
    byTaskID[command.taskID.rawValue] = record
    return .init(runID: command.runID, wasCreated: true)
  }

  func markRunRunning(_ command: MarkRunRunningCommand) throws {
    try mutateRun(id: command.runID) { run, _ in
      guard run.status == .queued else { throw RepositoryFailure.invalidStateTransition }
      run = HistoryRun(
        id: run.id,
        taskID: run.taskID,
        snapshotID: run.snapshotID,
        idempotencyKey: run.idempotencyKey,
        rerunOfRunID: run.rerunOfRunID,
        kind: run.kind,
        targetLanguage: run.targetLanguage,
        status: .running,
        providerProfileID: command.provider.profileID,
        providerKind: command.provider.providerKind,
        providerBaseURL: command.provider.baseURL,
        providerAPIMode: command.provider.apiMode,
        model: command.provider.model,
        createdAtMilliseconds: run.createdAtMilliseconds,
        startedAtMilliseconds: command.startedAtMilliseconds,
        finishedAtMilliseconds: nil,
        failureCode: nil,
        failureRetryable: nil,
        usageCost: run.usageCost
      )
    }
  }

  func savePartialArtifact(_: SavePartialArtifactCommand) throws {
    throw RepositoryFailure.unavailable
  }

  func finishRun(_ command: FinishRunCommand) throws {
    try mutateRun(id: command.runID) { run, artifact in
      guard run.status.canTransition(to: command.status) else {
        throw RepositoryFailure.invalidStateTransition
      }
      if command.status == .completed {
        guard let value = command.artifact, value.completeness == .complete, !value.bodyText.isEmpty else {
          throw RepositoryFailure.invalidInput
        }
        artifact = HistoryArtifact(
          id: value.id,
          runID: run.id,
          contentFormat: value.contentFormat,
          completeness: value.completeness,
          bodyText: value.bodyText,
          createdAtMilliseconds: command.finishedAtMilliseconds,
          updatedAtMilliseconds: command.finishedAtMilliseconds
        )
      }
      run = HistoryRun(
        id: run.id,
        taskID: run.taskID,
        snapshotID: run.snapshotID,
        idempotencyKey: run.idempotencyKey,
        rerunOfRunID: run.rerunOfRunID,
        kind: run.kind,
        targetLanguage: run.targetLanguage,
        status: command.status,
        providerProfileID: run.providerProfileID,
        providerKind: run.providerKind,
        providerBaseURL: run.providerBaseURL,
        providerAPIMode: run.providerAPIMode,
        model: run.model,
        createdAtMilliseconds: run.createdAtMilliseconds,
        startedAtMilliseconds: run.startedAtMilliseconds,
        finishedAtMilliseconds: command.finishedAtMilliseconds,
        failureCode: command.failureCode,
        failureRetryable: command.failureRetryable,
        usageCost: command.usageCost
      )
    }
  }

  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }

  func taskID(forCanonicalURL canonicalURL: CanonicalURL) throws -> TaskID? {
    taskIDByCanonical[canonicalURL.value]
  }

  func historyPage(limit _: Int, after _: HistoryPageCursor?) throws -> HistoryPage {
    .init(rows: [], nextCursor: nil)
  }

  func detail(taskID: TaskID) throws -> HistoryDetailProjection {
    guard let record = byTaskID[taskID.rawValue] else { throw RepositoryFailure.notFound }
    return HistoryDetailProjection(
      task: record.task,
      snapshots: record.snapshots,
      runs: record.runs.map { .init(run: $0.run, artifact: $0.artifact) }
    )
  }

  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection {
    throw RepositoryFailure.notFound
  }

  func deleteTask(taskID: TaskID) throws {
    guard let record = byTaskID.removeValue(forKey: taskID.rawValue) else {
      throw RepositoryFailure.notFound
    }
    taskIDByCanonical.removeValue(forKey: record.task.canonicalURL)
  }

  func updateSnapshotBodyText(
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    bodyText: String,
    updatedAtMilliseconds: Int64
  ) throws {
    guard var record = byTaskID[taskID.rawValue] else { throw RepositoryFailure.notFound }
    guard let index = record.snapshots.firstIndex(where: { $0.id == snapshotID }) else {
      throw RepositoryFailure.notFound
    }
    let old = record.snapshots[index]
    record.snapshots[index] = ContentSnapshot(
      id: old.id,
      taskID: old.taskID,
      sequence: old.sequence,
      envelopeCreatedAtMilliseconds: old.envelopeCreatedAtMilliseconds,
      capturedAtMilliseconds: old.capturedAtMilliseconds,
      sourceKind: old.sourceKind,
      sourceURL: old.sourceURL,
      title: old.title,
      platform: old.platform,
      captureMethod: old.captureMethod,
      completeness: old.completeness,
      bodyText: bodyText,
      characterCount: bodyText.count,
      bodySHA256: old.bodySHA256,
      sourceLabel: old.sourceLabel,
      usedCookie: old.usedCookie
    )
    record.task = HistoryTask(
      id: record.task.id,
      canonicalURL: record.task.canonicalURL,
      canonicalizationVersion: record.task.canonicalizationVersion,
      createdAtMilliseconds: record.task.createdAtMilliseconds,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
    byTaskID[taskID.rawValue] = record
  }

  func updateTaskTitle(
    taskID: TaskID,
    title: String,
    updatedAtMilliseconds: Int64
  ) throws {
    guard var record = byTaskID[taskID.rawValue] else { throw RepositoryFailure.notFound }
    guard var snapshot = record.snapshots.last else { throw RepositoryFailure.notFound }
    snapshot = ContentSnapshot(
      id: snapshot.id,
      taskID: snapshot.taskID,
      sequence: snapshot.sequence,
      envelopeCreatedAtMilliseconds: snapshot.envelopeCreatedAtMilliseconds,
      capturedAtMilliseconds: snapshot.capturedAtMilliseconds,
      sourceKind: snapshot.sourceKind,
      sourceURL: snapshot.sourceURL,
      title: title,
      platform: snapshot.platform,
      captureMethod: snapshot.captureMethod,
      completeness: snapshot.completeness,
      bodyText: snapshot.bodyText,
      characterCount: snapshot.characterCount,
      bodySHA256: snapshot.bodySHA256,
      sourceLabel: snapshot.sourceLabel,
      usedCookie: snapshot.usedCookie
    )
    record.snapshots[record.snapshots.count - 1] = snapshot
    record.task = HistoryTask(
      id: record.task.id,
      canonicalURL: record.task.canonicalURL,
      canonicalizationVersion: record.task.canonicalizationVersion,
      createdAtMilliseconds: record.task.createdAtMilliseconds,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
    byTaskID[taskID.rawValue] = record
  }

  private func mutateRun(
    id: RunID,
    _ body: (inout HistoryRun, inout HistoryArtifact?) throws -> Void
  ) throws {
    for (taskKey, var record) in byTaskID {
      guard let index = record.runs.firstIndex(where: { $0.run.id == id }) else { continue }
      var run = record.runs[index].run
      var artifact = record.runs[index].artifact
      try body(&run, &artifact)
      record.runs[index] = (run, artifact)
      byTaskID[taskKey] = record
      return
    }
    throw RepositoryFailure.notFound
  }

  private func makeSnapshot(
    id: ContentSnapshotID,
    taskID: TaskID,
    sequence: Int,
    document: CapturedDocument,
    at ms: Int64
  ) -> ContentSnapshot {
    ContentSnapshot(
      id: id,
      taskID: taskID,
      sequence: sequence,
      envelopeCreatedAtMilliseconds: ms,
      capturedAtMilliseconds: ms,
      sourceKind: document.origin.rawValue,
      sourceURL: document.url,
      title: document.title,
      platform: document.platform,
      captureMethod: document.method,
      completeness: document.completeness,
      bodyText: document.text,
      characterCount: document.text.count,
      bodySHA256: "fake",
      sourceLabel: document.sourceLabel,
      usedCookie: false
    )
  }
}
