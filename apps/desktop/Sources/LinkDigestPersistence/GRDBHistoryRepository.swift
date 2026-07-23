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
    do {
      guard provenanceIsConsistent(command.provenance, with: command.document) else {
        throw RepositoryFailure.invalidInput
      }
      try CapturedDocumentValidator.validate(command.document)
    }
    catch { throw RepositoryFailure.invalidInput }
    let document = command.document
    let canonical: CanonicalURL
    do { canonical = try CanonicalURL(document.url) }
    catch { throw RepositoryFailure.invalidInput }
    guard let envelopeCreated = milliseconds(document.createdAt), let captured = milliseconds(document.capturedAt) else {
      throw RepositoryFailure.invalidInput
    }
    let deliveryKey = command.provenance.deliveryKey
    let payloadDigest = command.provenance.semanticPayloadSHA256
    let contractVersion = command.provenance.captureContractVersion
    let bodyDigest = fingerprinter.bodySHA256(document.text)

    do {
      return try database.write { db in
        if let row = try Row.fetchOne(db, sql: "SELECT capture_contract_version, payload_sha256, task_id, snapshot_id FROM capture_deliveries WHERE delivery_key = ?", arguments: [deliveryKey]) {
          let existing: String = row["payload_sha256"]
          let existingVersion: Int = row["capture_contract_version"]
          guard existing == payloadDigest, existingVersion == contractVersion else { throw RepositoryFailure.captureIdempotencyConflict }
          return AcceptCaptureResult(taskID: requiredID(row["task_id"]), snapshotID: requiredID(row["snapshot_id"]), taskWasCreated: false, snapshotWasCreated: false, deliveryWasReplayed: true)
        }

        let taskID: TaskID
        let taskWasCreated: Bool
        if let raw: String = try String.fetchOne(db, sql: "SELECT id FROM tasks WHERE canonicalization_version = 1 AND canonical_url = ?", arguments: [canonical.value]) {
          taskID = requiredID(raw); taskWasCreated = false
        } else {
          taskID = TaskID(); taskWasCreated = true
          // Platform is first-class in the sidebar's 平台 section, so captures
          // no longer duplicate it as an automatic tag.
          try db.execute(sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, ?, ?)", arguments: [taskID.rawValue, canonical.value, command.receivedAtMilliseconds, command.receivedAtMilliseconds])
        }

        let snapshotID: ContentSnapshotID
        let snapshotWasCreated: Bool
        if let raw: String = try String.fetchOne(db, sql: "SELECT id FROM content_snapshots WHERE task_id = ? AND body_sha256 = ?", arguments: [taskID.rawValue, bodyDigest]) {
          snapshotID = requiredID(raw); snapshotWasCreated = false
          if document.usedCookie {
            try db.execute(
              sql: "UPDATE content_snapshots SET source_label = ?, used_cookie_v2 = 1 WHERE id = ? AND task_id = ?",
              arguments: [document.sourceLabel, snapshotID.rawValue, taskID.rawValue]
            )
            guard db.changesCount == 1 else { throw RepositoryFailure.integrityCheckFailed }
          }
        } else {
          snapshotID = ContentSnapshotID(); snapshotWasCreated = true
          let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?", arguments: [taskID.rawValue]) ?? 0) + 1
          try db.execute(sql: """
            INSERT INTO content_snapshots (
              id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
              platform, capture_method, completeness, body_text, character_count, body_sha256, source_label,
              used_cookie, used_cookie_v2
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS TEXT), ?, ?, ?, 0, ?)
            """, arguments: [snapshotID.rawValue, taskID.rawValue, sequence, envelopeCreated, captured, document.origin.rawValue, document.url, document.title, document.platform, document.method, document.completeness, Data(document.text.utf8), document.characterCount, bodyDigest, document.sourceLabel, document.usedCookie ? 1 : 0])
          try db.execute(sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?", arguments: [command.receivedAtMilliseconds, taskID.rawValue])
        }

        try db.execute(sql: "INSERT INTO capture_deliveries (delivery_key, capture_contract_version, request_id, payload_sha256, task_id, snapshot_id, received_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [deliveryKey, contractVersion, document.requestID, payloadDigest, taskID.rawValue, snapshotID.rawValue, command.receivedAtMilliseconds])
        return AcceptCaptureResult(taskID: taskID, snapshotID: snapshotID, taskWasCreated: taskWasCreated, snapshotWasCreated: snapshotWasCreated, deliveryWasReplayed: false)
      }
    } catch RepositoryFailure.unavailable {
      if let replay = try replayResult(deliveryKey: deliveryKey, contractVersion: contractVersion, payloadDigest: payloadDigest) { return replay }
      throw RepositoryFailure.unavailable
    }
  }

  /// 一次性清理历史上自动附加的平台同义标签（GitHub/X/公众号/抖音）。
  /// 平台已是导航的第一维度，这些旧标签只会与之重复。幂等，可安全重复调用。
  public func removeLegacyPlatformTags() throws {
    let names = Array(HistoryTagNormalizer.platformSynonymNormalizedNames)
    guard !names.isEmpty else { return }
    let placeholders = names.map { _ in "?" }.joined(separator: ",")
    do {
      try database.write { db in
        try db.execute(
          sql: "DELETE FROM task_tags WHERE tag_id IN (SELECT id FROM tags WHERE normalized_name IN (\(placeholders)))",
          arguments: StatementArguments(names)
        )
        try db.execute(
          sql: "DELETE FROM tags WHERE normalized_name IN (\(placeholders))",
          arguments: StatementArguments(names)
        )
      }
    } catch let failure as RepositoryFailure {
      throw failure
    } catch {
      throw RepositoryFailure.unavailable
    }
  }

  public func containsCanonicalURL(_ canonicalURL: CanonicalURL) throws -> Bool {
    try database.read { db in
      // Do not page through history rows for clipboard dedupe: this is the
      // authoritative versioned canonical key and remains exact at any size.
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM tasks WHERE canonicalization_version = ? AND canonical_url = ?)",
        arguments: [CanonicalURL.version, canonicalURL.value]
      ) ?? false
    }
  }

  private func provenanceIsConsistent(
    _ provenance: CaptureDeliveryProvenance,
    with document: CapturedDocument
  ) -> Bool {
    guard provenance.semanticPayloadSHA256.count == 64,
          provenance.semanticPayloadSHA256.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (97...102).contains($0.value)
          })
    else { return false }

    let suffix: String
    if let key = document.idempotencyKey {
      guard !key.isEmpty else { return false }
      suffix = "id:\(key)"
    } else {
      guard !document.requestID.isEmpty else { return false }
      suffix = "req:\(document.requestID)"
    }

    let expectedKey: String
    switch (document.origin, provenance.captureContractVersion) {
    case (.browserCapture, 1): expectedKey = "capture:v1:\(suffix)"
    case (.browserCapture, 2): expectedKey = "capture:v2:\(suffix)"
    case (.manualLink, 1), (.localTranscription, 1): expectedKey = "manual:v1:\(suffix)"
    default: return false
    }
    return provenance.deliveryKey == expectedKey
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
    return try database.write { db in
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
    try historyPage(limit: limit, after: cursor, filter: .none)
  }

  public func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    let bounded = min(max(limit, 1), 200)
    return try database.read { db in
      var arguments: StatementArguments = []
      var predicates: [String] = []
      let normalizedHost = normalizedTaskHostSQL(tableAlias: "t")
      if let cursor {
        predicates.append("(t.updated_at_ms < ? OR (t.updated_at_ms = ? AND t.id < ?))")
        arguments += [cursor.updatedAtMilliseconds, cursor.updatedAtMilliseconds, cursor.taskID.rawValue]
      }
      if !filter.tagNormalizedNames.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.tagNormalizedNames.count).joined(separator: ", ")
        predicates.append("""
          t.id IN (
            SELECT tt.task_id
            FROM task_tags tt
            INNER JOIN tags tag ON tag.id = tt.tag_id
            WHERE tag.normalized_name IN (\(placeholders))
            GROUP BY tt.task_id
            HAVING COUNT(DISTINCT tag.normalized_name) = ?
          )
          """)
        for tagName in filter.tagNormalizedNames {
          arguments += [tagName]
        }
        arguments += [filter.tagNormalizedNames.count]
      }
      if !filter.hosts.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.hosts.count).joined(separator: ", ")
        predicates.append("\(normalizedHost) IN (\(placeholders))")
        for host in filter.hosts { arguments += [host] }
      }
      switch filter.scope {
      case .all:
        break
      case .recent:
        predicates.append("t.updated_at_ms >= (unixepoch('now') - 604800) * 1000")
      case .unsummarized:
        predicates.append("""
          NOT EXISTS (
            SELECT 1
            FROM runs successful_run
            INNER JOIN artifacts successful_artifact ON successful_artifact.run_id = successful_run.id
            WHERE successful_run.task_id = t.id
              AND successful_run.status = 'completed'
              AND length(successful_artifact.body_text) > 0
          )
          """)
      }
      if !filter.searchText.isEmpty {
        let pattern = "%\(escapedLikePattern(filter.searchText))%"
        predicates.append("""
          (
            t.canonical_url LIKE ? ESCAPE '\\'
            OR COALESCE(es.title, '') LIKE ? ESCAPE '\\'
            OR COALESCE(es.source_label, '') LIKE ? ESCAPE '\\'
          )
          """)
        arguments += [pattern, pattern, pattern]
      }
      let predicate = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      arguments += [bounded]
      let rows = try Row.fetchAll(db, sql: """
        SELECT t.id, t.canonical_url, t.updated_at_ms, t.created_at_ms,
          es.title AS title,
          es.source_label AS source_label,
          CASE WHEN es.body_text IS NULL THEN NULL ELSE substr(CAST(es.body_text AS BLOB), 1, 8192) END AS source_body_utf8,
          r.kind, r.status, r.model, COALESCE(r.finished_at_ms, r.started_at_ms, r.created_at_ms) AS latest_run_at_ms,
          r.input_tokens, r.output_tokens, r.total_tokens, r.cost_amount_micros, r.cost_currency_code,
          CASE WHEN a.body_text IS NULL THEN NULL ELSE substr(CAST(a.body_text AS BLOB), 1, 960) END AS artifact_preview_utf8
        FROM tasks t
        LEFT JOIN content_snapshots es ON es.task_id = t.id AND es.id = (
          SELECT s.id
          FROM content_snapshots s
          WHERE s.task_id = t.id AND s.source_kind <> 'local_transcription'
          ORDER BY s.sequence DESC
          LIMIT 1
        )
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

  public func navigationCounts() throws -> HistoryNavigationCounts {
    try database.read { db in
      let all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? 0
      let recent = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM tasks WHERE updated_at_ms >= (unixepoch('now') - 604800) * 1000"
      ) ?? 0
      let unsummarized = try Int.fetchOne(db, sql: """
        SELECT COUNT(*)
        FROM tasks t
        WHERE NOT EXISTS (
          SELECT 1
          FROM runs successful_run
          INNER JOIN artifacts successful_artifact ON successful_artifact.run_id = successful_run.id
          WHERE successful_run.task_id = t.id
            AND successful_run.status = 'completed'
            AND length(successful_artifact.body_text) > 0
        )
        """) ?? 0

      let hostExpression = normalizedTaskHostSQL(tableAlias: "t")
      let platforms = try Row.fetchAll(db, sql: """
        SELECT \(hostExpression) AS host, COUNT(*) AS count
        FROM tasks t
        WHERE \(hostExpression) <> ''
        GROUP BY \(hostExpression)
        ORDER BY count DESC, host COLLATE NOCASE ASC
        """).compactMap { row -> HistoryNavigationPlatform? in
          let host: String = row["host"]
          let count: Int = row["count"]
          return host.isEmpty ? nil : .init(host: host, count: count)
        }
      let tags = try Row.fetchAll(db, sql: """
        SELECT tag.display_name, tag.normalized_name, COUNT(DISTINCT tt.task_id) AS count
        FROM tags tag
        INNER JOIN task_tags tt ON tt.tag_id = tag.id
        GROUP BY tag.id, tag.display_name, tag.normalized_name
        ORDER BY count DESC, tag.normalized_name COLLATE NOCASE ASC
        """).compactMap { row -> HistoryNavigationTag? in
          guard let tag = self.tag(row) else { return nil }
          let count: Int = row["count"]
          return .init(tag: tag, count: count)
        }
      return .init(all: all, recent: recent, unsummarized: unsummarized, platforms: platforms, tags: tags)
    }
  }

  public func detail(taskID: TaskID) throws -> HistoryDetailProjection {
    try database.read { db in try detail(db: db, taskID: taskID) }
  }

  public func exportProjection(taskID: TaskID) throws -> HistoryExportProjection {
    let value = try detail(taskID: taskID)
    return HistoryExportProjection(task: value.task, snapshots: value.snapshots, runs: value.runs, tags: value.tags)
  }

  public func allTags() throws -> [HistoryTag] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT tag.display_name, tag.normalized_name
        FROM tags tag
        WHERE EXISTS (SELECT 1 FROM task_tags tt WHERE tt.tag_id = tag.id)
        ORDER BY tag.normalized_name COLLATE NOCASE, tag.id
        """).compactMap(tag)
    }
  }

  public func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] {
    let candidates = HistoryTagNormalizer.normalizedTags(rawNames)
    return try database.write { db in
      try assignTags(candidates, to: taskID, db: db, createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
      return try tags(db: db, taskID: taskID)
    }
  }

  public func removeTag(normalizedName: String, from taskID: TaskID) throws {
    guard let requested = HistoryTagNormalizer.normalized(normalizedName) else { throw RepositoryFailure.invalidInput }
    try database.write { db in
      guard try Int.fetchOne(db, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) == 1 else {
        throw RepositoryFailure.notFound
      }
      try db.execute(sql: """
        DELETE FROM task_tags
        WHERE task_id = ?
          AND tag_id = (SELECT id FROM tags WHERE normalized_name = ? COLLATE NOCASE)
        """, arguments: [taskID.rawValue, requested.normalizedName])
      try db.execute(sql: "DELETE FROM tags WHERE NOT EXISTS (SELECT 1 FROM task_tags WHERE task_tags.tag_id = tags.id)")
    }
  }

  public func deleteTask(taskID: TaskID) throws {
    let result = try deleteTasks(taskIDs: [taskID])
    guard result.deletedTaskIDs == [taskID] else { throw RepositoryFailure.notFound }
  }

  public func deleteTasks(taskIDs: Set<TaskID>) throws -> BatchDeleteResult {
    guard !taskIDs.isEmpty else { throw RepositoryFailure.invalidInput }
    let requested = taskIDs.sorted { $0.rawValue < $1.rawValue }
    return try database.write { db in
      var deleted: [TaskID] = []
      var failed: [TaskID] = []
      for taskID in requested {
        try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [taskID.rawValue])
        if db.changesCount == 1 { deleted.append(taskID) }
        else { failed.append(taskID) }
      }
      try db.execute(sql: "DELETE FROM tags WHERE NOT EXISTS (SELECT 1 FROM task_tags WHERE task_tags.tag_id = tags.id)")
      try database.dependencies.beforeTerminalCommit()
      return BatchDeleteResult(
        requestedTaskIDs: requested,
        deletedTaskIDs: deleted,
        failedTaskIDs: failed
      )
    }
  }

  public func attachMedia(_ command: AttachMediaCommand) throws {
    let asset = command.asset
    guard asset.transcriptionStatus == .none else {
      throw RepositoryFailure.invalidStateTransition
    }
    guard asset.byteSize > 0,
          asset.contentSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          !asset.relativePath.isEmpty,
          asset.relativePath.range(of: #"^[a-f0-9]{64}\.(mp4|mov)$"#, options: .regularExpression) != nil
    else { throw RepositoryFailure.invalidInput }
    try database.write { db in
      guard try Int.fetchOne(db, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [asset.taskID.rawValue]) == 1 else {
        throw RepositoryFailure.notFound
      }
      if let snapshotID = asset.snapshotID {
        guard try Int.fetchOne(
          db,
          sql: "SELECT 1 FROM content_snapshots WHERE task_id = ? AND id = ?",
          arguments: [asset.taskID.rawValue, snapshotID.rawValue]
        ) == 1 else { throw RepositoryFailure.notFound }
      }
      // Idempotent on (task_id, content_sha256): keep the durable identity and
      // transcription state, while repairing the current local-file location.
      if try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM media_assets WHERE task_id = ? AND content_sha256 = ?",
        arguments: [asset.taskID.rawValue, asset.contentSHA256]
      ) == 1 {
        try db.execute(
          sql: """
            UPDATE media_assets
            SET snapshot_id = ?,
                relative_path = ?,
                file_bookmark = ?,
                byte_size = ?,
                duration_seconds = ?,
                platform = ?,
                author = ?
            WHERE task_id = ? AND content_sha256 = ?
            """,
          arguments: [
            asset.snapshotID?.rawValue,
            asset.relativePath,
            asset.fileBookmark,
            asset.byteSize,
            asset.durationSeconds,
            asset.platform,
            asset.author,
            asset.taskID.rawValue,
            asset.contentSHA256,
          ]
        )
        guard db.changesCount == 1 else { throw RepositoryFailure.unavailable }
        return
      }
      try db.execute(
        sql: """
          INSERT INTO media_assets (
            id, task_id, snapshot_id, relative_path, file_bookmark, content_sha256, byte_size,
            duration_seconds, platform, author, transcription_status, created_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          asset.id,
          asset.taskID.rawValue,
          asset.snapshotID?.rawValue,
          asset.relativePath,
          asset.fileBookmark,
          asset.contentSHA256,
          asset.byteSize,
          asset.durationSeconds,
          asset.platform,
          asset.author,
          asset.transcriptionStatus.rawValue,
          asset.createdAtMilliseconds,
        ]
      )
    }
  }

  public func mediaAsset(taskID: TaskID) throws -> MediaAsset? {
    try database.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM media_assets
          WHERE task_id = ?
          ORDER BY created_at_ms DESC, id DESC
          LIMIT 1
          """,
        arguments: [taskID.rawValue]
      ) else { return nil }
      return try mediaAsset(row)
    }
  }

  public func beginMediaTranscription(
    taskID: TaskID,
    mediaID: String
  ) throws -> TranscriptionAttemptToken {
    guard validUUID(mediaID) else { throw RepositoryFailure.invalidInput }
    return try database.write { db in
      guard try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM media_assets WHERE id = ? AND task_id = ?",
        arguments: [mediaID, taskID.rawValue]
      ) == 1 else { throw RepositoryFailure.notFound }
      let currentMaximum = try latestTranscriptionGeneration(db: db, taskID: taskID)
      guard currentMaximum < Int64.max else { throw RepositoryFailure.invalidStateTransition }
      let attempt = TranscriptionAttemptToken(mediaID: mediaID, generation: currentMaximum + 1)
      try db.execute(
        sql: """
          UPDATE media_assets
          SET transcription_status = 'pending',
              transcription_attempt_id = ?,
              transcription_attempt_generation = ?
          WHERE id = ? AND task_id = ?
          """,
        arguments: [attempt.id, attempt.generation, mediaID, taskID.rawValue]
      )
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
      return attempt
    }
  }

  public func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult {
    guard validUUID(attempt.id), validUUID(attempt.mediaID), attempt.generation > 0 else {
      throw RepositoryFailure.invalidInput
    }
    return try database.write { db in
      guard try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM media_assets WHERE id = ? AND task_id = ?",
        arguments: [attempt.mediaID, taskID.rawValue]
      ) == 1 else { throw RepositoryFailure.notFound }
      guard try latestTranscriptionGeneration(db: db, taskID: taskID) == attempt.generation else {
        return .stale
      }
      try db.execute(
        sql: """
          UPDATE media_assets
          SET transcription_status = ?
          WHERE id = ? AND task_id = ?
            AND transcription_attempt_id = ?
            AND transcription_attempt_generation = ?
            AND transcription_status IN ('pending', 'running')
          """,
        arguments: [status.rawValue, attempt.mediaID, taskID.rawValue, attempt.id, attempt.generation]
      )
      return db.changesCount == 1 ? .applied : .stale
    }
  }

  public func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult {
    let document = command.document
    guard document.origin == .localTranscription,
          ["speech_analyzer_local", "openai_compatible_audio_transcriptions"].contains(document.method) else {
      throw RepositoryFailure.invalidInput
    }
    do { try CapturedDocumentValidator.validate(document) }
    catch { throw RepositoryFailure.invalidInput }
    let canonical: CanonicalURL
    do { canonical = try CanonicalURL(document.url) }
    catch { throw RepositoryFailure.invalidInput }
    guard let envelopeCreated = milliseconds(document.createdAt), let captured = milliseconds(document.capturedAt) else {
      throw RepositoryFailure.invalidInput
    }
    let evidence = command.evidence, attempt = command.attempt
    guard validUUID(attempt.id),
          validUUID(attempt.mediaID),
          attempt.generation > 0,
          validUUID(evidence.id),
          validFact(evidence.source, maximum: 64),
          validFact(evidence.engine, maximum: 128),
          validOptionalFact(evidence.provider, maximum: 128),
          validOptionalFact(evidence.model, maximum: 256),
          validOptionalFact(evidence.localeIdentifier, minimum: 2, maximum: 64),
          validOptionalFact(evidence.language, minimum: 2, maximum: 32),
          evidence.completedAtMilliseconds == command.receivedAtMilliseconds
    else { throw RepositoryFailure.invalidInput }
    let bodyDigest = fingerprinter.bodySHA256(document.text)

    return try database.write { db in
      guard let storedCanonical: String = try String.fetchOne(
        db,
        sql: "SELECT canonical_url FROM tasks WHERE id = ?",
        arguments: [command.taskID.rawValue]
      ), storedCanonical == canonical.value else { throw RepositoryFailure.notFound }
      guard let media = try Row.fetchOne(
        db,
        sql: "SELECT id, transcription_status, transcription_attempt_id, transcription_attempt_generation FROM media_assets WHERE id = ? AND task_id = ?",
        arguments: [attempt.mediaID, command.taskID.rawValue]
      ) else { throw RepositoryFailure.notFound }
      let mediaID: String = media["id"]
      let currentAttemptID: String? = media["transcription_attempt_id"]
      let currentAttemptGeneration: Int64? = media["transcription_attempt_generation"]
      let currentStatus: String = media["transcription_status"]

      if currentAttemptID == attempt.id,
         currentAttemptGeneration == attempt.generation,
         let replaySnapshotRaw: String = try String.fetchOne(
           db,
           sql: "SELECT snapshot_id FROM media_transcription_evidence WHERE media_id = ? AND attempt_id = ? AND attempt_generation = ?",
           arguments: [mediaID, attempt.id, attempt.generation]
         ) {
        return .replay(AcceptCaptureResult(
          taskID: command.taskID,
          snapshotID: requiredID(replaySnapshotRaw),
          taskWasCreated: false,
          snapshotWasCreated: false,
          deliveryWasReplayed: true
        ))
      }

      guard currentAttemptID == attempt.id,
            currentAttemptGeneration == attempt.generation,
            try latestTranscriptionGeneration(db: db, taskID: command.taskID) == attempt.generation,
            [TranscriptionStatus.pending.rawValue, TranscriptionStatus.running.rawValue].contains(currentStatus)
      else {
        return .stale
      }

      let snapshotID: ContentSnapshotID
      let snapshotWasCreated: Bool
      if let existing = try Row.fetchOne(
        db,
        sql: "SELECT id FROM content_snapshots WHERE task_id = ? AND body_sha256 = ?",
        arguments: [command.taskID.rawValue, bodyDigest]
      ) {
        snapshotID = requiredID(existing["id"])
        snapshotWasCreated = false
      } else {
        snapshotID = ContentSnapshotID()
        snapshotWasCreated = true
        let sequence = (try Int.fetchOne(
          db,
          sql: "SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?",
          arguments: [command.taskID.rawValue]
        ) ?? 0) + 1
        try db.execute(sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
            platform, capture_method, completeness, body_text, character_count, body_sha256, source_label,
            used_cookie, used_cookie_v2
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS TEXT), ?, ?, ?, 0, ?)
          """, arguments: [snapshotID.rawValue, command.taskID.rawValue, sequence, envelopeCreated, captured,
            document.origin.rawValue, document.url, document.title, document.platform, document.method,
            document.completeness, Data(document.text.utf8), document.characterCount, bodyDigest, document.sourceLabel,
            document.usedCookie ? 1 : 0])
      }

      try db.execute(
        sql: """
          INSERT INTO media_transcription_evidence (
            id, media_id, task_id, snapshot_id, attempt_id, attempt_generation, source, engine,
            provider, model, locale_identifier, language, completed_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          evidence.id,
          mediaID,
          command.taskID.rawValue,
          snapshotID.rawValue,
          attempt.id,
          attempt.generation,
          evidence.source,
          evidence.engine,
          evidence.provider,
          evidence.model,
          evidence.localeIdentifier,
          evidence.language,
          evidence.completedAtMilliseconds,
        ]
      )

      // Fault-injection seam proves snapshot + evidence + status share this transaction.
      try database.dependencies.beforeTerminalCommit()
      try db.execute(
        sql: "UPDATE media_assets SET transcription_status = 'completed' WHERE id = ? AND task_id = ? AND transcription_attempt_id = ? AND transcription_attempt_generation = ? AND transcription_status IN ('pending', 'running')",
        arguments: [mediaID, command.taskID.rawValue, attempt.id, attempt.generation]
      )
      guard db.changesCount == 1 else { throw RepositoryFailure.invalidStateTransition }
      try db.execute(
        sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        arguments: [command.receivedAtMilliseconds, command.taskID.rawValue]
      )
      return .accepted(AcceptCaptureResult(
        taskID: command.taskID,
        snapshotID: snapshotID,
        taskWasCreated: false,
        snapshotWasCreated: snapshotWasCreated,
        deliveryWasReplayed: false
      ))
    }
  }

  public func beginTaskTranscription(
    taskID: TaskID,
    createdAtMilliseconds: Int64
  ) throws -> TaskTranscriptionAttemptToken {
    try database.write { db in
      guard try Int.fetchOne(db, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) == 1 else {
        throw RepositoryFailure.notFound
      }
      let maximum = try latestTranscriptionGeneration(db: db, taskID: taskID)
      guard maximum < Int64.max else { throw RepositoryFailure.invalidStateTransition }
      let attempt = TaskTranscriptionAttemptToken(taskID: taskID, generation: maximum + 1)
      try db.execute(sql: """
        INSERT INTO task_transcription_attempts (
          id, task_id, generation, status, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, 'pending', ?, ?)
        """, arguments: [attempt.id, taskID.rawValue, attempt.generation, createdAtMilliseconds, createdAtMilliseconds])
      return attempt
    }
  }

  public func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult {
    guard attempt.taskID == taskID, validUUID(attempt.id), attempt.generation > 0 else {
      throw RepositoryFailure.invalidInput
    }
    return try database.write { db in
      guard try Int.fetchOne(db, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) == 1 else {
        throw RepositoryFailure.notFound
      }
      guard try latestTranscriptionGeneration(db: db, taskID: taskID) == attempt.generation else {
        return .stale
      }
      try db.execute(sql: """
        UPDATE task_transcription_attempts
        SET status = ?, updated_at_ms = ?
        WHERE id = ? AND task_id = ? AND generation = ?
          AND status IN ('pending', 'running')
        """, arguments: [
          status.rawValue, updatedAtMilliseconds, attempt.id, taskID.rawValue,
          attempt.generation,
        ])
      return db.changesCount == 1 ? .applied : .stale
    }
  }

  public func completeTaskTranscription(
    _ command: CompleteTaskTranscriptionCommand
  ) throws -> CompleteTaskTranscriptionResult {
    let document = command.document
    // `openai_compatible_chat_tidy` is a text-in/text-out pass over an existing
    // transcript; it persists through the same task-transcription seam but is
    // not a valid media (audio) transcription method.
    guard document.origin == .localTranscription,
          ["speech_analyzer_local", "openai_compatible_audio_transcriptions",
           "openai_compatible_chat_tidy"].contains(document.method) else {
      throw RepositoryFailure.invalidInput
    }
    do { try CapturedDocumentValidator.validate(document) }
    catch { throw RepositoryFailure.invalidInput }
    let canonical: CanonicalURL
    do { canonical = try CanonicalURL(document.url) }
    catch { throw RepositoryFailure.invalidInput }
    guard let envelopeCreated = milliseconds(document.createdAt), let captured = milliseconds(document.capturedAt) else {
      throw RepositoryFailure.invalidInput
    }
    let evidence = command.evidence, attempt = command.attempt
    guard attempt.taskID == command.taskID,
          validUUID(attempt.id), attempt.generation > 0,
          validUUID(evidence.id),
          validFact(evidence.source, maximum: 64),
          validFact(evidence.engine, maximum: 128),
          validOptionalFact(evidence.provider, maximum: 128),
          validOptionalFact(evidence.model, maximum: 256),
          validOptionalFact(evidence.localeIdentifier, minimum: 2, maximum: 64),
          validOptionalFact(evidence.language, minimum: 2, maximum: 32),
          evidence.completedAtMilliseconds == command.receivedAtMilliseconds
    else { throw RepositoryFailure.invalidInput }
    let bodyDigest = fingerprinter.bodySHA256(document.text)

    return try database.write { db in
      guard let storedCanonical: String = try String.fetchOne(
        db,
        sql: "SELECT canonical_url FROM tasks WHERE id = ?",
        arguments: [command.taskID.rawValue]
      ), storedCanonical == canonical.value else { throw RepositoryFailure.notFound }

      if let replaySnapshot: String = try String.fetchOne(
        db,
        sql: "SELECT snapshot_id FROM task_transcription_evidence WHERE attempt_id = ? AND task_id = ? AND attempt_generation = ?",
        arguments: [attempt.id, command.taskID.rawValue, attempt.generation]
      ) {
        return .replay(.init(
          taskID: command.taskID,
          snapshotID: requiredID(replaySnapshot),
          taskWasCreated: false,
          snapshotWasCreated: false,
          deliveryWasReplayed: true
        ))
      }

      guard let owner = try Row.fetchOne(
        db,
        sql: "SELECT status, generation FROM task_transcription_attempts WHERE id = ? AND task_id = ?",
        arguments: [attempt.id, command.taskID.rawValue]
      ) else { return .stale }
      let ownerStatus: String = owner["status"]
      let ownerGeneration: Int64 = owner["generation"]
      let latestGeneration = try latestTranscriptionGeneration(db: db, taskID: command.taskID)
      guard ownerGeneration == attempt.generation,
            latestGeneration == attempt.generation,
            ["pending", "running"].contains(ownerStatus)
      else { return .stale }

      let snapshotID: ContentSnapshotID
      let snapshotWasCreated: Bool
      if let existing: String = try String.fetchOne(
        db,
        sql: "SELECT id FROM content_snapshots WHERE task_id = ? AND body_sha256 = ?",
        arguments: [command.taskID.rawValue, bodyDigest]
      ) {
        snapshotID = requiredID(existing)
        snapshotWasCreated = false
      } else {
        snapshotID = ContentSnapshotID()
        snapshotWasCreated = true
        let sequence = (try Int.fetchOne(
          db,
          sql: "SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?",
          arguments: [command.taskID.rawValue]
        ) ?? 0) + 1
        try db.execute(sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
            platform, capture_method, completeness, body_text, character_count, body_sha256, source_label,
            used_cookie, used_cookie_v2
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS TEXT), ?, ?, ?, 0, ?)
          """, arguments: [
            snapshotID.rawValue, command.taskID.rawValue, sequence, envelopeCreated, captured,
            document.origin.rawValue, document.url, document.title, document.platform, document.method,
            document.completeness, Data(document.text.utf8), document.characterCount, bodyDigest, document.sourceLabel,
            document.usedCookie ? 1 : 0,
          ])
      }

      try db.execute(sql: """
        INSERT INTO task_transcription_evidence (
          id, attempt_id, task_id, attempt_generation, snapshot_id, source, engine,
          provider, model, locale_identifier, language, completed_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
          evidence.id, attempt.id, command.taskID.rawValue, attempt.generation, snapshotID.rawValue,
          evidence.source, evidence.engine, evidence.provider, evidence.model,
          evidence.localeIdentifier, evidence.language, evidence.completedAtMilliseconds,
        ])
      try database.dependencies.beforeTerminalCommit()
      try db.execute(sql: """
        UPDATE task_transcription_attempts
        SET status = 'completed', updated_at_ms = ?, completed_at_ms = ?
        WHERE id = ? AND task_id = ? AND generation = ? AND status IN ('pending', 'running')
        """, arguments: [
          command.receivedAtMilliseconds, command.receivedAtMilliseconds,
          attempt.id, command.taskID.rawValue, attempt.generation,
        ])
      guard db.changesCount == 1 else { throw RepositoryFailure.invalidStateTransition }
      try db.execute(
        sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        arguments: [command.receivedAtMilliseconds, command.taskID.rawValue]
      )
      return .accepted(.init(
        taskID: command.taskID,
        snapshotID: snapshotID,
        taskWasCreated: false,
        snapshotWasCreated: snapshotWasCreated,
        deliveryWasReplayed: false
      ))
    }
  }

  /// Paths for files that become unreferenced after a task delete. Caller
  /// unlinks files only when no remaining row uses the same content hash.
  public func mediaRelativePaths(taskID: TaskID) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT relative_path FROM media_assets WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    }
  }

  public func updateSnapshotBodyText(
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    bodyText: String,
    updatedAtMilliseconds: Int64
  ) throws {
    let bodyDigest = fingerprinter.bodySHA256(bodyText)
    try database.write { db in
      // 只改正文与其派生列（字数、指纹），不动身份、序号或来源标记。
      try db.execute(sql: """
        UPDATE content_snapshots SET body_text = CAST(? AS TEXT), character_count = ?, body_sha256 = ?
        WHERE id = ? AND task_id = ?
        """, arguments: [
          Data(bodyText.utf8), bodyText.unicodeScalars.count, bodyDigest,
          snapshotID.rawValue, taskID.rawValue,
        ])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
      try db.execute(
        sql: "UPDATE tasks SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        arguments: [updatedAtMilliseconds, taskID.rawValue]
      )
    }
  }

  public func isMediaContentReferenced(contentSHA256: String) throws -> Bool {
    try database.read { db in
      (try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM media_assets WHERE content_sha256 = ? LIMIT 1",
        arguments: [contentSHA256]
      ) ?? 0) == 1
    }
  }

  private func replayResult(deliveryKey: String, contractVersion: Int, payloadDigest: String) throws -> AcceptCaptureResult? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT capture_contract_version, payload_sha256, task_id, snapshot_id FROM capture_deliveries WHERE delivery_key = ?", arguments: [deliveryKey]) else { return nil }
      let existing: String = row["payload_sha256"]
      let existingVersion: Int = row["capture_contract_version"]
      guard existing == payloadDigest, existingVersion == contractVersion else { throw RepositoryFailure.captureIdempotencyConflict }
      return AcceptCaptureResult(taskID: requiredID(row["task_id"]), snapshotID: requiredID(row["snapshot_id"]), taskWasCreated: false, snapshotWasCreated: false, deliveryWasReplayed: true)
    }
  }

  private func assignTags(
    _ candidates: [HistoryTag],
    to taskID: TaskID,
    db: Database,
    createdAtMilliseconds: Int64
  ) throws {
    guard try Int.fetchOne(db, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) == 1 else {
      throw RepositoryFailure.notFound
    }
    var assigned = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_tags WHERE task_id = ?", arguments: [taskID.rawValue]) ?? 0
    for candidate in candidates {
      let tagID: Int64
      if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE normalized_name = ? COLLATE NOCASE", arguments: [candidate.normalizedName]) {
        tagID = existing
      } else {
        try db.execute(
          sql: "INSERT INTO tags (normalized_name, display_name, created_at_ms) VALUES (?, ?, ?)",
          arguments: [candidate.normalizedName, candidate.name, createdAtMilliseconds]
        )
        tagID = db.lastInsertedRowID
      }
      let alreadyAssigned = try Int.fetchOne(
        db,
        sql: "SELECT 1 FROM task_tags WHERE task_id = ? AND tag_id = ?",
        arguments: [taskID.rawValue, tagID]
      ) == 1
      guard !alreadyAssigned else { continue }
      guard assigned < HistoryTagNormalizer.maximumTagsPerTask else { break }
      try db.execute(
        sql: "INSERT INTO task_tags (task_id, tag_id, created_at_ms) VALUES (?, ?, ?)",
        arguments: [taskID.rawValue, tagID, createdAtMilliseconds]
      )
      assigned += 1
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
    let sourceBody: Data? = row["source_body_utf8"]
    let frontmatter = sourceBody.map { MarkdownNoteFrontmatter.parse(boundedPreview(from: $0, scalarLimit: 8_192)) }
    return HistoryRowProjection(taskID: requiredID(row["id"]), title: row["title"], canonicalURL: canonical, host: URLComponents(string: canonical)?.host ?? "", sourceLabel: row["source_label"] ?? "", latestRunKind: kindRaw.flatMap(RunKind.init), latestRunStatus: statusRaw.flatMap(RunStatus.init), latestModel: row["model"], updatedAtMilliseconds: row["updated_at_ms"], createdAtMilliseconds: row["created_at_ms"], latestRunAtMilliseconds: row["latest_run_at_ms"], usageCost: try usage(row), artifactPreview: preview, author: frontmatter?.author, published: frontmatter?.published)
  }

  private func detail(db: Database, taskID: TaskID) throws -> HistoryDetailProjection {
    guard let taskRow = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [taskID.rawValue]) else { throw RepositoryFailure.notFound }
    let task = HistoryTask(id: requiredID(taskRow["id"]), canonicalURL: taskRow["canonical_url"], canonicalizationVersion: taskRow["canonicalization_version"], createdAtMilliseconds: taskRow["created_at_ms"], updatedAtMilliseconds: taskRow["updated_at_ms"])
    var snapshots = try Row.fetchAll(db, sql: "SELECT *, CAST(body_text AS BLOB) AS body_utf8 FROM content_snapshots WHERE task_id = ? ORDER BY sequence", arguments: [taskID.rawValue]).map(snapshot)
    if let effectiveID = try effectiveSnapshotID(db: db, taskID: taskID),
       let index = snapshots.firstIndex(where: { $0.id == effectiveID }),
       index != snapshots.indices.last {
      snapshots.append(snapshots.remove(at: index))
    }
    let rows = try Row.fetchAll(db, sql: "SELECT r.*, a.id AS artifact_id, a.content_format, a.completeness AS artifact_completeness, CAST(a.body_text AS BLOB) AS artifact_body_utf8, a.created_at_ms AS artifact_created_at_ms, a.updated_at_ms AS artifact_updated_at_ms FROM runs r LEFT JOIN artifacts a ON a.run_id = r.id WHERE r.task_id = ? ORDER BY r.created_at_ms, r.id", arguments: [taskID.rawValue])
    let mediaRow = try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM media_assets
        WHERE task_id = ?
        ORDER BY created_at_ms DESC, id DESC
        LIMIT 1
        """,
      arguments: [taskID.rawValue]
    )
    return HistoryDetailProjection(
      task: task,
      snapshots: snapshots,
      runs: try rows.map(runDetail),
      tags: try tags(db: db, taskID: taskID),
      media: try mediaRow.map { try mediaAsset($0) }
    )
  }

  private func mediaAsset(_ row: Row) throws -> MediaAsset {
    let statusRaw: String = row["transcription_status"]
    guard let status = TranscriptionStatus(rawValue: statusRaw) else {
      throw RepositoryFailure.integrityCheckFailed
    }
    let snapshotRaw: String? = row["snapshot_id"]
    return MediaAsset(
      id: row["id"],
      taskID: requiredID(row["task_id"]),
      snapshotID: snapshotRaw.flatMap { ContentSnapshotID($0) },
      relativePath: row["relative_path"],
      fileBookmark: row["file_bookmark"],
      contentSHA256: row["content_sha256"],
      byteSize: row["byte_size"],
      durationSeconds: row["duration_seconds"],
      platform: row["platform"],
      author: row["author"],
      transcriptionStatus: status,
      createdAtMilliseconds: row["created_at_ms"]
    )
  }

  private func tags(db: Database, taskID: TaskID) throws -> [HistoryTag] {
    try Row.fetchAll(db, sql: """
      SELECT tag.display_name, tag.normalized_name
      FROM task_tags tt
      INNER JOIN tags tag ON tag.id = tt.tag_id
      WHERE tt.task_id = ?
      ORDER BY tag.normalized_name COLLATE NOCASE, tag.id
      """, arguments: [taskID.rawValue]).compactMap(tag)
  }

  private func tag(_ row: Row) -> HistoryTag? {
    guard
      let display: String = row["display_name"],
      let normalized: String = row["normalized_name"],
      let normalizedValue = HistoryTagNormalizer.normalized(display),
      normalizedValue.normalizedName == normalized
    else {
      return nil
    }
    return normalizedValue
  }

  private func snapshot(_ row: Row) -> ContentSnapshot {
    let bodyData: Data = row["body_utf8"]
    let body = String(decoding: bodyData, as: UTF8.self)
    let usedCookieV1: Int = row["used_cookie"]
    let usedCookieV2: Int = row["used_cookie_v2"]
    return ContentSnapshot(id: requiredID(row["id"]), taskID: requiredID(row["task_id"]), sequence: row["sequence"], envelopeCreatedAtMilliseconds: row["envelope_created_at_ms"], capturedAtMilliseconds: row["captured_at_ms"], sourceKind: row["source_kind"], sourceURL: row["source_url"], title: row["title"], platform: row["platform"], captureMethod: row["capture_method"], completeness: row["completeness"], bodyText: body, characterCount: row["character_count"], bodySHA256: row["body_sha256"], sourceLabel: row["source_label"], usedCookie: usedCookieV1 != 0 || usedCookieV2 != 0)
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
    try RunUsageCost.validated(inputTokens: row["input_tokens"], outputTokens: row["output_tokens"], totalTokens: row["total_tokens"], costAmountMicros: row["cost_amount_micros"], costCurrencyCode: row["cost_currency_code"])
  }

  private func effectiveSnapshotID(db: Database, taskID: TaskID) throws -> ContentSnapshotID? {
    let raw: String? = try String.fetchOne(
      db,
      sql: """
        SELECT COALESCE(
          (
            SELECT combined.snapshot_id
            FROM (
              SELECT snapshot_id, attempt_generation, id
              FROM task_transcription_evidence
              WHERE task_id = ?
              UNION ALL
              SELECT snapshot_id, attempt_generation, id
              FROM media_transcription_evidence
              WHERE task_id = ?
            ) combined
            ORDER BY combined.attempt_generation DESC, combined.id DESC
            LIMIT 1
          ),
          (
            SELECT id
            FROM content_snapshots
            WHERE task_id = ?
            ORDER BY sequence DESC
            LIMIT 1
          )
        )
        """,
      arguments: [taskID.rawValue, taskID.rawValue, taskID.rawValue]
    )
    return raw.flatMap(ContentSnapshotID.init)
  }

  /// One task-wide owner sequence shared by durable-media and transient V2
  /// transcription, so neither path can complete late over the other.
  private func latestTranscriptionGeneration(db: Database, taskID: TaskID) throws -> Int64 {
    try Int64.fetchOne(db, sql: """
      SELECT MAX(generation) FROM (
        SELECT transcription_attempt_generation AS generation FROM media_assets WHERE task_id = ?
        UNION ALL
        SELECT attempt_generation AS generation FROM media_transcription_evidence WHERE task_id = ?
        UNION ALL
        SELECT generation FROM task_transcription_attempts WHERE task_id = ?
        UNION ALL
        SELECT attempt_generation AS generation FROM task_transcription_evidence WHERE task_id = ?
      )
      """, arguments: [taskID.rawValue, taskID.rawValue, taskID.rawValue, taskID.rawValue]) ?? 0
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

private func escapedLikePattern(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}

/// SQLite has no URL-host function. URLs stored in `tasks` have already passed
/// the public-web admission policy, so this expression only extracts and
/// normalizes that durable canonical host for grouping/filtering; it never
/// admits a URL or changes network policy.
private func normalizedTaskHostSQL(tableAlias: String) -> String {
  let raw = "lower(substr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3), 1, instr(substr(\(tableAlias).canonical_url, instr(\(tableAlias).canonical_url, '://') + 3) || '/', '/') - 1))"
  return """
    CASE
      WHEN \(raw) LIKE 'www.%' THEN substr(\(raw), 5)
      WHEN \(raw) LIKE 'www2.%' THEN substr(\(raw), 6)
      WHEN \(raw) LIKE 'm.%' THEN substr(\(raw), 3)
      WHEN \(raw) LIKE 'mobile.%' THEN substr(\(raw), 8)
      WHEN \(raw) LIKE 'amp.%' THEN substr(\(raw), 5)
      ELSE \(raw)
    END
    """
}

private func requiredID<ID: HistoryIdentifier>(_ raw: String) -> ID { ID(raw)! }
private func optionalID<ID: HistoryIdentifier>(_ raw: String?) -> ID? { raw.flatMap(ID.init) }
private func validUUID(_ raw: String) -> Bool {
  UUID(uuidString: raw)?.uuidString.lowercased() == raw
}
private func validFact(_ value: String, minimum: Int = 1, maximum: Int) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed == value && (minimum ... maximum).contains(value.count)
}
private func validOptionalFact(_ value: String?, minimum: Int = 1, maximum: Int) -> Bool {
  value.map { validFact($0, minimum: minimum, maximum: maximum) } ?? true
}
