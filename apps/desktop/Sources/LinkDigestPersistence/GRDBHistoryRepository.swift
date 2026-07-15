import Foundation
import GRDB
import LinkDigestCore

public final class GRDBHistoryRepository: HistoryRepository, @unchecked Sendable {
  public let database: LocalDatabase
  private let fingerprinter: any CaptureFingerprinting
  public var accessMode: HistoryRepositoryAccessMode { database.accessMode }

  public init(database: LocalDatabase, fingerprinter: any CaptureFingerprinting = SHA256CaptureFingerprinter()) {
    self.database = database
    self.fingerprinter = fingerprinter
  }

  public static func open(at location: LocalDatabaseLocation, dependencies: PersistenceDependencies = .live) throws -> GRDBHistoryRepository {
    try GRDBHistoryRepository(database: LocalDatabase.open(at: location, dependencies: dependencies))
  }

  public func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult {
    do { try CaptureValidator.validate(command.envelope) }
    catch { throw RepositoryFailure.invalidInput }
    let envelope = command.envelope
    let canonical: CanonicalURL
    do { canonical = try CanonicalURL(envelope.source.url) }
    catch { throw RepositoryFailure.invalidInput }
    guard let envelopeCreated = milliseconds(envelope.createdAt), let captured = milliseconds(envelope.capture.capturedAt) else {
      throw RepositoryFailure.invalidInput
    }
    let deliveryKey = CaptureDeliveryIdentity.key(for: envelope)
    let payloadDigest = fingerprinter.semanticPayloadSHA256(envelope)
    let bodyDigest = fingerprinter.bodySHA256(envelope.capture.text)

    do {
      return try database.write { db in
        if let row = try Row.fetchOne(db, sql: "SELECT payload_sha256, task_id, snapshot_id FROM capture_deliveries WHERE delivery_key = ?", arguments: [deliveryKey]) {
          let existing: String = row["payload_sha256"]
          guard existing == payloadDigest else { throw RepositoryFailure.captureIdempotencyConflict }
          return AcceptCaptureResult(taskID: requiredID(row["task_id"]), snapshotID: requiredID(row["snapshot_id"]), taskWasCreated: false, snapshotWasCreated: false, deliveryWasReplayed: true)
        }

        let taskID: TaskID
        let taskWasCreated: Bool
        if let raw: String = try String.fetchOne(db, sql: "SELECT id FROM tasks WHERE canonicalization_version = 1 AND canonical_url = ?", arguments: [canonical.value]) {
          taskID = requiredID(raw); taskWasCreated = false
        } else {
          taskID = TaskID(); taskWasCreated = true
          try db.execute(sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, ?, ?)", arguments: [taskID.rawValue, canonical.value, command.receivedAtMilliseconds, command.receivedAtMilliseconds])
        }

        let snapshotID: ContentSnapshotID
        let snapshotWasCreated: Bool
        if let raw: String = try String.fetchOne(db, sql: "SELECT id FROM content_snapshots WHERE task_id = ? AND body_sha256 = ?", arguments: [taskID.rawValue, bodyDigest]) {
          snapshotID = requiredID(raw); snapshotWasCreated = false
        } else {
          snapshotID = ContentSnapshotID(); snapshotWasCreated = true
          let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?", arguments: [taskID.rawValue]) ?? 0) + 1
          try db.execute(sql: """
            INSERT INTO content_snapshots (
              id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
              platform, capture_method, completeness, body_text, character_count, body_sha256, source_label, used_cookie
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS TEXT), ?, ?, ?, 0)
            """, arguments: [snapshotID.rawValue, taskID.rawValue, sequence, envelopeCreated, captured, envelope.source.kind, envelope.source.url, envelope.source.title, envelope.source.platform, envelope.capture.method, envelope.capture.completeness, Data(envelope.capture.text.utf8), envelope.capture.characterCount, bodyDigest, envelope.evidence.sourceLabel])
          try db.execute(sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?", arguments: [command.receivedAtMilliseconds, taskID.rawValue])
        }

        try db.execute(sql: "INSERT INTO capture_deliveries (delivery_key, capture_contract_version, request_id, payload_sha256, task_id, snapshot_id, received_at_ms) VALUES (?, 1, ?, ?, ?, ?, ?)", arguments: [deliveryKey, envelope.requestId, payloadDigest, taskID.rawValue, snapshotID.rawValue, command.receivedAtMilliseconds])
        return AcceptCaptureResult(taskID: taskID, snapshotID: snapshotID, taskWasCreated: taskWasCreated, snapshotWasCreated: snapshotWasCreated, deliveryWasReplayed: false)
      }
    } catch RepositoryFailure.unavailable {
      if let replay = try replayResult(deliveryKey: deliveryKey, payloadDigest: payloadDigest) { return replay }
      throw RepositoryFailure.unavailable
    }
  }

  public func createRun(_ command: CreateRunCommand) throws -> CreateRunResult {
    guard !command.idempotencyKey.isEmpty else { throw RepositoryFailure.invalidInput }
    do {
      return try database.write { db in
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE idempotency_key = ?", arguments: [command.idempotencyKey]) {
          guard runMatches(row, command) else { throw RepositoryFailure.runIdempotencyConflict }
          return CreateRunResult(runID: requiredID(row["id"]), wasCreated: false)
        }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM content_snapshots WHERE task_id = ? AND id = ?", arguments: [command.taskID.rawValue, command.snapshotID.rawValue]) == 1 else { throw RepositoryFailure.notFound }
        if let parent = command.rerunOfRunID {
          guard let parentTask: String = try String.fetchOne(db, sql: "SELECT task_id FROM runs WHERE id = ?", arguments: [parent.rawValue]), parentTask == command.taskID.rawValue else { throw RepositoryFailure.invalidInput }
        }
        try db.execute(sql: """
          INSERT INTO runs (id, task_id, snapshot_id, idempotency_key, rerun_of_run_id, kind, target_language, status, created_at_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?)
          """, arguments: [command.runID.rawValue, command.taskID.rawValue, command.snapshotID.rawValue, command.idempotencyKey, command.rerunOfRunID?.rawValue, command.kind.rawValue, command.targetLanguage, command.createdAtMilliseconds])
        try db.execute(sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?", arguments: [command.createdAtMilliseconds, command.taskID.rawValue])
        return CreateRunResult(runID: command.runID, wasCreated: true)
      }
    } catch RepositoryFailure.unavailable {
      if let existing = try existingRun(command) { return existing }
      throw RepositoryFailure.unavailable
    }
  }

  public func markRunRunning(_ command: MarkRunRunningCommand) throws {
    try database.write { db in
      try db.execute(sql: """
        UPDATE runs SET status = 'running', started_at_ms = ?, provider_profile_id = ?, provider_kind = ?,
          provider_base_url = ?, provider_api_mode = ?, model = ?
        WHERE id = ? AND status = 'queued'
        """, arguments: [command.startedAtMilliseconds, command.provider.profileID, command.provider.providerKind, command.provider.baseURL, command.provider.apiMode, command.provider.model, command.runID.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.invalidStateTransition }
    }
  }

  public func savePartialArtifact(_ command: SavePartialArtifactCommand) throws {
    guard !command.bodyText.isEmpty else { throw RepositoryFailure.invalidInput }
    try database.write { db in
      guard let statusRaw: String = try String.fetchOne(db, sql: "SELECT status FROM runs WHERE id = ?", arguments: [command.runID.rawValue]), RunStatus(rawValue: statusRaw) == .running else { throw RepositoryFailure.invalidStateTransition }
      try db.execute(sql: """
        INSERT INTO artifacts (id, run_id, content_format, completeness, body_text, created_at_ms, updated_at_ms)
        VALUES (?, ?, ?, 'partial', CAST(? AS TEXT), ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET content_format = excluded.content_format, completeness = 'partial', body_text = excluded.body_text, updated_at_ms = excluded.updated_at_ms
        """, arguments: [command.artifactID.rawValue, command.runID.rawValue, command.contentFormat.rawValue, Data(command.bodyText.utf8), command.updatedAtMilliseconds, command.updatedAtMilliseconds])
    }
  }

  public func finishRun(_ command: FinishRunCommand) throws {
    guard command.status.isTerminal else { throw RepositoryFailure.invalidStateTransition }
    if command.status == .completed {
      guard command.artifact?.completeness == .complete, command.artifact?.bodyText.isEmpty == false else { throw RepositoryFailure.invalidInput }
    } else if command.artifact?.completeness == .complete { throw RepositoryFailure.invalidInput }

    try database.write { db in
      guard let statusRaw: String = try String.fetchOne(db, sql: "SELECT status FROM runs WHERE id = ?", arguments: [command.runID.rawValue]), let current = RunStatus(rawValue: statusRaw), current.canTransition(to: command.status) else { throw RepositoryFailure.invalidStateTransition }
      if let artifact = command.artifact {
        guard !artifact.bodyText.isEmpty else { throw RepositoryFailure.invalidInput }
        try db.execute(sql: """
          INSERT INTO artifacts (id, run_id, content_format, completeness, body_text, created_at_ms, updated_at_ms)
          VALUES (?, ?, ?, ?, CAST(? AS TEXT), ?, ?)
          ON CONFLICT(run_id) DO UPDATE SET content_format = excluded.content_format, completeness = excluded.completeness, body_text = excluded.body_text, updated_at_ms = excluded.updated_at_ms
          """, arguments: [artifact.id.rawValue, command.runID.rawValue, artifact.contentFormat.rawValue, artifact.completeness.rawValue, Data(artifact.bodyText.utf8), command.finishedAtMilliseconds, command.finishedAtMilliseconds])
      }
      try database.dependencies.beforeTerminalCommit()
      try db.execute(sql: """
        UPDATE runs SET status = ?, finished_at_ms = ?, failure_code = ?, failure_retryable = ?,
          input_tokens = ?, output_tokens = ?, total_tokens = ?, cost_amount_micros = ?, cost_currency_code = ?
        WHERE id = ? AND status IN ('queued', 'running')
        """, arguments: [command.status.rawValue, command.finishedAtMilliseconds, command.failureCode, command.failureRetryable, command.usageCost.inputTokens, command.usageCost.outputTokens, command.usageCost.totalTokens, command.usageCost.costAmountMicros, command.usageCost.costCurrencyCode, command.runID.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.invalidStateTransition }
    }
  }

  public func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int {
    try database.write { db in
      try db.execute(sql: "UPDATE runs SET status = 'interrupted', finished_at_ms = ?, failure_code = 'APP_INTERRUPTED', failure_retryable = 1 WHERE status IN ('queued', 'running')", arguments: [milliseconds])
      return db.changesCount
    }
  }

  public func historyPage(limit: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage {
    let bounded = min(max(limit, 1), 200)
    return try database.read { db in
      var arguments: StatementArguments = []
      var predicate = ""
      if let cursor {
        predicate = "WHERE (t.updated_at_ms < ? OR (t.updated_at_ms = ? AND t.id < ?))"
        arguments += [cursor.updatedAtMilliseconds, cursor.updatedAtMilliseconds, cursor.taskID.rawValue]
      }
      arguments += [bounded]
      let rows = try Row.fetchAll(db, sql: """
        SELECT t.id, t.canonical_url, t.updated_at_ms,
          (SELECT s.title FROM content_snapshots s WHERE s.task_id = t.id ORDER BY s.sequence DESC LIMIT 1) AS title,
          (SELECT s.source_label FROM content_snapshots s WHERE s.task_id = t.id ORDER BY s.sequence DESC LIMIT 1) AS source_label,
          r.kind, r.status, r.model, COALESCE(r.finished_at_ms, r.started_at_ms, r.created_at_ms) AS latest_run_at_ms,
          r.input_tokens, r.output_tokens, r.total_tokens, r.cost_amount_micros, r.cost_currency_code,
          CASE WHEN a.body_text IS NULL THEN NULL ELSE substr(CAST(a.body_text AS BLOB), 1, 960) END AS artifact_preview_utf8
        FROM tasks t
        LEFT JOIN runs r ON r.id = (SELECT id FROM runs WHERE task_id = t.id ORDER BY created_at_ms DESC, id DESC LIMIT 1)
        LEFT JOIN artifacts a ON a.run_id = r.id
        \(predicate)
        ORDER BY t.updated_at_ms DESC, t.id DESC LIMIT ?
        """, arguments: arguments)
      let projections = try rows.map(historyRow)
      let next = projections.count == bounded ? projections.last.map { HistoryPageCursor(updatedAtMilliseconds: $0.updatedAtMilliseconds, taskID: $0.taskID) } : nil
      return HistoryPage(rows: projections, nextCursor: next)
    }
  }

  public func detail(taskID: TaskID) throws -> HistoryDetailProjection {
    try database.read { db in try detail(db: db, taskID: taskID) }
  }

  public func exportProjection(taskID: TaskID) throws -> HistoryExportProjection {
    let value = try detail(taskID: taskID)
    return HistoryExportProjection(task: value.task, snapshots: value.snapshots, runs: value.runs)
  }

  public func deleteTask(taskID: TaskID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [taskID.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  private func replayResult(deliveryKey: String, payloadDigest: String) throws -> AcceptCaptureResult? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT payload_sha256, task_id, snapshot_id FROM capture_deliveries WHERE delivery_key = ?", arguments: [deliveryKey]) else { return nil }
      let existing: String = row["payload_sha256"]
      guard existing == payloadDigest else { throw RepositoryFailure.captureIdempotencyConflict }
      return AcceptCaptureResult(taskID: requiredID(row["task_id"]), snapshotID: requiredID(row["snapshot_id"]), taskWasCreated: false, snapshotWasCreated: false, deliveryWasReplayed: true)
    }
  }

  private func existingRun(_ command: CreateRunCommand) throws -> CreateRunResult? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE idempotency_key = ?", arguments: [command.idempotencyKey]) else { return nil }
      guard runMatches(row, command) else { throw RepositoryFailure.runIdempotencyConflict }
      return CreateRunResult(runID: requiredID(row["id"]), wasCreated: false)
    }
  }

  private func runMatches(_ row: Row, _ command: CreateRunCommand) -> Bool {
    let task: String = row["task_id"], snapshot: String = row["snapshot_id"], kind: String = row["kind"]
    let rerun: String? = row["rerun_of_run_id"], language: String? = row["target_language"]
    return task == command.taskID.rawValue && snapshot == command.snapshotID.rawValue && kind == command.kind.rawValue && rerun == command.rerunOfRunID?.rawValue && language == command.targetLanguage
  }

  private func historyRow(_ row: Row) throws -> HistoryRowProjection {
    let canonical: String = row["canonical_url"]
    let kindRaw: String? = row["kind"], statusRaw: String? = row["status"]
    let previewData: Data? = row["artifact_preview_utf8"]
    let preview = previewData.map { boundedPreview(from: $0, scalarLimit: 240) }
    return HistoryRowProjection(taskID: requiredID(row["id"]), title: row["title"], canonicalURL: canonical, host: URLComponents(string: canonical)?.host ?? "", sourceLabel: row["source_label"] ?? "", latestRunKind: kindRaw.flatMap(RunKind.init), latestRunStatus: statusRaw.flatMap(RunStatus.init), latestModel: row["model"], updatedAtMilliseconds: row["updated_at_ms"], latestRunAtMilliseconds: row["latest_run_at_ms"], usageCost: try usage(row), artifactPreview: preview)
  }

  private func detail(db: Database, taskID: TaskID) throws -> HistoryDetailProjection {
    guard let taskRow = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) else { throw RepositoryFailure.notFound }
    let task = HistoryTask(id: requiredID(taskRow["id"]), canonicalURL: taskRow["canonical_url"], canonicalizationVersion: taskRow["canonicalization_version"], createdAtMilliseconds: taskRow["created_at_ms"], updatedAtMilliseconds: taskRow["updated_at_ms"])
    let snapshots = try Row.fetchAll(db, sql: "SELECT *, CAST(body_text AS BLOB) AS body_utf8 FROM content_snapshots WHERE task_id = ? ORDER BY sequence", arguments: [taskID.rawValue]).map(snapshot)
    let rows = try Row.fetchAll(db, sql: "SELECT r.*, a.id AS artifact_id, a.content_format, a.completeness AS artifact_completeness, CAST(a.body_text AS BLOB) AS artifact_body_utf8, a.created_at_ms AS artifact_created_at_ms, a.updated_at_ms AS artifact_updated_at_ms FROM runs r LEFT JOIN artifacts a ON a.run_id = r.id WHERE r.task_id = ? ORDER BY r.created_at_ms, r.id", arguments: [taskID.rawValue])
    return HistoryDetailProjection(task: task, snapshots: snapshots, runs: try rows.map(runDetail))
  }

  private func snapshot(_ row: Row) -> ContentSnapshot {
    let bodyData: Data = row["body_utf8"]
    let body = String(decoding: bodyData, as: UTF8.self)
    return ContentSnapshot(id: requiredID(row["id"]), taskID: requiredID(row["task_id"]), sequence: row["sequence"], envelopeCreatedAtMilliseconds: row["envelope_created_at_ms"], capturedAtMilliseconds: row["captured_at_ms"], sourceKind: row["source_kind"], sourceURL: row["source_url"], title: row["title"], platform: row["platform"], captureMethod: row["capture_method"], completeness: row["completeness"], bodyText: body, characterCount: row["character_count"], bodySHA256: row["body_sha256"], sourceLabel: row["source_label"], usedCookie: row["used_cookie"])
  }

  private func runDetail(_ row: Row) throws -> HistoryDetailProjection.RunDetail {
    let retryableInt: Int? = row["failure_retryable"]
    let run = HistoryRun(id: requiredID(row["id"]), taskID: requiredID(row["task_id"]), snapshotID: requiredID(row["snapshot_id"]), idempotencyKey: row["idempotency_key"], rerunOfRunID: optionalID(row["rerun_of_run_id"]), kind: RunKind(rawValue: row["kind"])!, targetLanguage: row["target_language"], status: RunStatus(rawValue: row["status"])!, providerProfileID: row["provider_profile_id"], providerKind: row["provider_kind"], providerBaseURL: row["provider_base_url"], providerAPIMode: row["provider_api_mode"], model: row["model"], createdAtMilliseconds: row["created_at_ms"], startedAtMilliseconds: row["started_at_ms"], finishedAtMilliseconds: row["finished_at_ms"], failureCode: row["failure_code"], failureRetryable: retryableInt.map { $0 != 0 }, usageCost: try usage(row))
    let artifact: HistoryArtifact?
    if let raw: String = row["artifact_id"] {
      let bodyData: Data = row["artifact_body_utf8"]
      guard let body = String(data: bodyData, encoding: .utf8) else { throw RepositoryFailure.integrityCheckFailed }
      artifact = HistoryArtifact(id: requiredID(raw), runID: run.id, contentFormat: ArtifactContentFormat(rawValue: row["content_format"])!, completeness: ArtifactCompleteness(rawValue: row["artifact_completeness"])!, bodyText: body, createdAtMilliseconds: row["artifact_created_at_ms"], updatedAtMilliseconds: row["artifact_updated_at_ms"])
    } else { artifact = nil }
    return .init(run: run, artifact: artifact)
  }

  private func usage(_ row: Row) throws -> RunUsageCost {
    try RunUsageCost(inputTokens: row["input_tokens"], outputTokens: row["output_tokens"], totalTokens: row["total_tokens"], costAmountMicros: row["cost_amount_micros"], costCurrencyCode: row["cost_currency_code"])
  }

  private func milliseconds(_ string: String) -> Int64? {
    let standard = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
    guard let date = standard.date(from: string) ?? fractional.date(from: string) else { return nil }
    return Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }
}

private func boundedPreview(from data: Data, scalarLimit: Int) -> String {
  var length = data.count
  while length > 0 {
    if let prefix = String(data: data.prefix(length), encoding: .utf8) {
      return String(prefix.unicodeScalars.prefix(scalarLimit))
    }
    length -= 1
  }
  return ""
}

private func requiredID<ID: HistoryIdentifier>(_ raw: String) -> ID { ID(raw)! }
private func optionalID<ID: HistoryIdentifier>(_ raw: String?) -> ID? { raw.flatMap(ID.init) }
