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

  public func taskID(matchingCanonicalURL canonicalURL: CanonicalURL) throws -> TaskID? {
    try database.read { db in
      guard let raw = try String.fetchOne(
        db,
        sql: "SELECT id FROM tasks WHERE canonicalization_version = ? AND canonical_url = ?",
        arguments: [CanonicalURL.version, canonicalURL.value]
      ) else { return nil }
      return TaskID(raw)
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
    // 用户笔记与手动链接、本机转写同属「非浏览器来源」，deliveryKey 由
    // `CaptureDeliveryIdentity.key(for document:)` 统一生成为 `manual:v1:*`。
    //
    // 漏掉这一行的后果不是报错信息不好看——是 default 分支直接 return false，
    // 落库以 stateConflict 失败，而 UI 上只表现为「点新建没有任何反应」。
    case (.manualLink, 1), (.localTranscription, 1), (.userNote, 1), (.pieceDraft, 1), (.work, 1):
      expectedKey = "manual:v1:\(suffix)"
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
      // 笔记是独立区域：除了 `.notes` 自己，其余作用域一律把它排除。
      //
      // 抓来的资料和自己写的东西混在一张列表里，找素材时会被自己的草稿打断，
      // 写东西时又要在一堆网页里翻。底层仍共用同一张表，所以标签、搜索、导出
      // 照常可用——分开的只是「看到什么」。
      let notePredicate = "t.canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'"
      // 稿件是「过程」,比笔记藏得更深:除了 `.drafts` 自己,任何作用域都不显示它,
      // **搜索也不例外**。半成品被搜出来会和成品混在一起,而用户搜的是「我写过的
      // 那句话」,他要的是笔记或成品,不是某件创作中途的一版草稿。
      let draftPredicate = "t.canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'"
      let workPredicate = "t.canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'"
      if filter.scope.isDraftsOnly {
        predicates.append(draftPredicate)
      } else if filter.scope.isWorksOnly {
        predicates.append(workPredicate)
      } else {
        predicates.append("NOT (\(draftPredicate))")
        // 成品和笔记同样待遇:浏览时归自己那一区,搜索时可达——
        // 它是「我做出来的东西」,正是用户搜索时最想找到的。
        if filter.scope.isNotesOnly {
          predicates.append(notePredicate)
        } else if filter.searchText.isEmpty {
          predicates.append("NOT (\(notePredicate))")
          predicates.append("NOT (\(workPredicate))")
        }
      }
      // 搜索时不排除笔记：分区是为了「浏览时互不打扰」，而搜索恰恰是用户
      // 想不起来东西在哪才用的。要求他先答对「这句话我是写在笔记里还是存的
      // 网页」才肯给结果，等于把搜索最该解决的问题反过来当成前提。
      switch filter.scope {
      case .all, .notes, .drafts, .works:
        break
      case .favorite:
        predicates.append("t.is_favorite = 1")
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
        // 正文与标签也要能搜到。
        //
        // 原来只搜链接、标题、来源标签——「我记得有篇讲盲派格局的」找不回来，
        // 因为那篇标题里根本没有「盲派」。条目一多，搜不到正文等于搜索废掉。
        //
        // 作者不必单独加一列：抓取时写进正文 frontmatter 的 `author:` 行，
        // 搜正文自然覆盖。多加一个 LIKE 只会多一次全表扫描而不多命中任何东西。
        //
        // 用 LIKE 全扫而不是上 FTS：本机全部正文合计 185 KB，扫一遍是毫秒级。
        // 涨到几十 MB 之前都不必引入虚拟表和它的索引维护。
        predicates.append("""
          (
            t.canonical_url LIKE ? ESCAPE '\\'
            OR COALESCE(es.title, '') LIKE ? ESCAPE '\\'
            OR COALESCE(es.source_label, '') LIKE ? ESCAPE '\\'
            OR COALESCE(es.body_text, '') LIKE ? ESCAPE '\\'
            OR EXISTS (
              SELECT 1 FROM task_tags stt
              INNER JOIN tags stg ON stg.id = stt.tag_id
              WHERE stt.task_id = t.id
                AND (
                  stg.display_name LIKE ? ESCAPE '\\'
                  OR stg.normalized_name LIKE ? ESCAPE '\\'
                )
            )
            OR EXISTS (
              -- 总结、翻译、整理稿也要能搜到：记住的常常是总结里的一句话，
              -- 而不是原文的措辞。
              --
              -- 用 EXISTS 遍历这条目的全部产物，而不是复用外面那个 `a`——
              -- 那个只 JOIN 最近一次运行，先总结后翻译时搜总结就会漏。
              SELECT 1 FROM runs sr
              INNER JOIN artifacts sa ON sa.run_id = sr.id
              WHERE sr.task_id = t.id
                AND sa.body_text LIKE ? ESCAPE '\\'
            )
          )
          """)
        arguments += [pattern, pattern, pattern, pattern, pattern, pattern, pattern]
      }
      let predicate = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      arguments += [bounded]
      let rows = try Row.fetchAll(db, sql: """
        SELECT t.id, t.canonical_url, t.updated_at_ms, t.created_at_ms, t.is_favorite,
          es.title AS title,
          es.source_label AS source_label,
          CASE WHEN es.body_text IS NULL THEN NULL ELSE substr(CAST(es.body_text AS BLOB), 1, 8192) END AS source_body_utf8,
          r.kind, r.status, r.model, COALESCE(r.finished_at_ms, r.started_at_ms, r.created_at_ms) AS latest_run_at_ms,
          r.input_tokens, r.output_tokens, r.total_tokens, r.cost_amount_micros, r.cost_currency_code,
          CASE WHEN a.body_text IS NULL THEN NULL ELSE substr(CAST(a.body_text AS BLOB), 1, 960) END AS artifact_preview_utf8,
          EXISTS(SELECT 1 FROM content_snapshots ts WHERE ts.task_id = t.id AND ts.source_kind = 'local_transcription') AS has_transcript,
          -- 这条抓进来时带没带视频。`capture_contract_version = 2` 是持久信号；
          -- 签名播放地址本身从不入库，所以不能靠「有没有可播地址」判断。
          -- 已保存到本地的视频走 media_assets，两者取并集。
          (
            EXISTS(SELECT 1 FROM capture_deliveries cd WHERE cd.task_id = t.id AND cd.capture_contract_version = 2)
            OR EXISTS(SELECT 1 FROM media_assets ma WHERE ma.task_id = t.id)
          ) AS has_media,
          EXISTS(SELECT 1 FROM runs sr WHERE sr.task_id = t.id AND sr.kind = 'summarize' AND sr.status = 'completed') AS has_summary,
          EXISTS(SELECT 1 FROM task_mind_maps mm WHERE mm.task_id = t.id) AS has_mind_map
        FROM tasks t
        LEFT JOIN content_snapshots es ON es.task_id = t.id AND es.id = (
          COALESCE(
            (
              -- A completion may reuse an older source snapshot with identical
              -- text. In that case the evidence, not sequence, makes it the
              -- effective list/search snapshot. A newly created transcription
              -- still falls back to source metadata so author/platform do not
              -- disappear from the sidebar.
              SELECT CASE
                WHEN effective_snapshot.source_kind <> 'local_transcription'
                THEN latest_evidence.snapshot_id
                ELSE NULL
              END
              FROM (
                SELECT snapshot_id, attempt_generation, id
                FROM task_transcription_evidence
                WHERE task_id = t.id
                UNION ALL
                SELECT snapshot_id, attempt_generation, id
                FROM media_transcription_evidence
                WHERE task_id = t.id
                ORDER BY attempt_generation DESC, id DESC
                LIMIT 1
              ) latest_evidence
              INNER JOIN content_snapshots effective_snapshot
                ON effective_snapshot.id = latest_evidence.snapshot_id
            ),
            (
              SELECT s.id
              FROM content_snapshots s
              WHERE s.task_id = t.id AND s.source_kind <> 'local_transcription'
              ORDER BY s.sequence DESC
              LIMIT 1
            )
          )
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
      // 笔记是独立区域，所有"输入侧"的计数都要把它排除，否则「全部 10」里
      // 混着自己写的草稿，数字对不上用户在列表里看到的东西。
      let isNote = "canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'"
      let isDraft = "canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'"
      let isWork = "canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'"
      // 「抓来的资料」= 既不是笔记也不是稿件。把这个判据合成一处,
      // 而不是在每条计数后面各叠一次 AND NOT——那样加第三种内容时
      // 又要逐条改,漏一条就是一个对不上的数字。
      let isCaptured = "NOT (\(isNote)) AND NOT (\(isDraft)) AND NOT (\(isWork))"
      let notes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isNote)") ?? 0
      let works = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isWork)") ?? 0
      let all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured)") ?? 0
      let recent = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured) AND updated_at_ms >= (unixepoch('now') - 604800) * 1000"
      ) ?? 0
      let unsummarized = try Int.fetchOne(db, sql: """
        SELECT COUNT(*)
        FROM tasks t
        WHERE NOT (t.\(isNote)) AND NOT (t.\(isDraft)) AND NOT (t.\(isWork)) AND NOT EXISTS (
          SELECT 1
          FROM runs successful_run
          INNER JOIN artifacts successful_artifact ON successful_artifact.run_id = successful_run.id
          WHERE successful_run.task_id = t.id
            AND successful_run.status = 'completed'
            AND length(successful_artifact.body_text) > 0
        )
        """) ?? 0
      let favorite = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE \(isCaptured) AND is_favorite = 1") ?? 0

      let hostExpression = normalizedTaskHostSQL(tableAlias: "t")
      let platforms = try Row.fetchAll(db, sql: """
        SELECT \(hostExpression) AS host, COUNT(*) AS count
        FROM tasks t
        WHERE \(hostExpression) <> '' AND NOT (t.\(isNote)) AND NOT (t.\(isDraft)) AND NOT (t.\(isWork))
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
      return .init(all: all, recent: recent, unsummarized: unsummarized, favorite: favorite, notes: notes, works: works, platforms: platforms, tags: tags)
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

  public func setFavorite(_ isFavorite: Bool, for taskID: TaskID) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE tasks SET is_favorite = ? WHERE id = ?",
        arguments: [isFavorite ? 1 : 0, taskID.rawValue])
      // 收藏是纯用户标记，不动 updated_at_ms——否则收藏一下就把条目顶到「最近」最前，
      // 打乱按时间的阅读顺序。
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
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

  /// 该任务名下**全部**媒体资产。删除任务时必须用它而不是 `mediaAsset(taskID:)`：
  /// 后者只取最新一条，其余文件会变成没人能发现的孤儿。
  public func mediaAssets(taskID: TaskID) throws -> [MediaAsset] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM media_assets
          WHERE task_id = ?
          ORDER BY created_at_ms DESC, id DESC
          """,
        arguments: [taskID.rawValue]
      ).compactMap { try? mediaAsset($0) }
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

  /// 笔记的最新 snapshot：标题和正文都挂在它上面。
  ///
  /// 复用同一段子查询，避免「跳转按最新那条、反链按第一条」这种各查各的漂移。
  private static let latestNoteSnapshotJoin = """
    FROM tasks t
    INNER JOIN content_snapshots s ON s.task_id = t.id
      AND s.sequence = (SELECT MAX(sequence) FROM content_snapshots x WHERE x.task_id = t.id)
    WHERE t.canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'
    """

  // MARK: - 工作台

  /// 一件创作的汇总查询。
  ///
  /// 素材数和正文长度直接在 SQL 里算：首页要靠它们推断阶段，
  /// 逐条回查会让列表变成 N+1。
  private static let pieceSelect = """
    SELECT p.id AS id, p.spark AS spark, p.stage AS stage, p.note_task_id AS note_task_id,
      p.created_at_ms AS created_at_ms, p.updated_at_ms AS updated_at_ms,
      p.finished_at_ms AS finished_at_ms,
      COALESCE(s.title, '') AS title,
      (SELECT COUNT(*) FROM piece_materials m WHERE m.piece_id = p.id) AS material_count,
      -- 占位符不算字数。它是提示不是内容,算进去会让「7 字」这种数字
      -- 出现在一个字都没写的稿子上,阶段推断也会跟着偏。
      --
      -- 用字面量而不是绑定参数:这段 SQL 有两个调用点、参数顺序各不相同,
      -- 多一个占位符要在两处都对齐,漏一个就是一次运行期错位。
      CASE WHEN s.body_text = '\(PieceDraftDocument.placeholderBody)' THEN 0
           ELSE COALESCE(length(s.body_text), 0) END AS body_length
    FROM pieces p
    LEFT JOIN content_snapshots s ON s.task_id = p.note_task_id
      AND s.sequence = (SELECT MAX(sequence) FROM content_snapshots x WHERE x.task_id = p.note_task_id)
    """

  private func pieceSummary(_ row: Row) -> PieceSummary {
    let id: PieceID = requiredID(row["id"])
    let noteID: TaskID = requiredID(row["note_task_id"])
    let spark: String = row["spark"] ?? ""
    let title: String = row["title"] ?? ""
    let materialCount: Int = row["material_count"] ?? 0
    let bodyLength: Int = row["body_length"] ?? 0
    let finished: Int64? = row["finished_at_ms"]
    // stage 为 NULL 表示「跟着推断走」——手动覆盖过才会有值。
    let stored: String? = row["stage"]
    let stage = stored.flatMap(PieceStage.init(rawValue:)) ?? PieceStage.inferred(
      materialCount: materialCount, bodyLength: bodyLength, isFinished: finished != nil
    )
    return PieceSummary(
      id: id,
      spark: spark,
      // 标题还是灵感原句时不重复显示；标题空着也回退到灵感。
      title: title.isEmpty ? spark : title,
      stage: finished != nil ? .done : stage,
      noteTaskID: noteID,
      materialCount: materialCount,
      bodyLength: bodyLength,
      createdAtMilliseconds: row["created_at_ms"] ?? 0,
      updatedAtMilliseconds: row["updated_at_ms"] ?? 0,
      finishedAtMilliseconds: finished
    )
  }

  public func createPiece(
    id: PieceID, spark: String, noteTaskID: TaskID, createdAtMilliseconds: Int64
  ) throws {
    let trimmed = spark.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RepositoryFailure.invalidInput }
    try database.write { db in
      try db.execute(sql: """
        INSERT INTO pieces (id, spark, stage, note_task_id, created_at_ms, updated_at_ms, finished_at_ms)
        VALUES (?, ?, NULL, ?, ?, ?, NULL)
        """, arguments: [id.rawValue, trimmed, noteTaskID.rawValue, createdAtMilliseconds, createdAtMilliseconds])
    }
  }

  public func pieces() throws -> [PieceSummary] {
    try database.read { db in
      // 进行中的排前面，各自按最近动过排——搁置几天的那件不会掉到看不见的地方。
      try Row.fetchAll(db, sql: """
        \(Self.pieceSelect)
        ORDER BY (p.finished_at_ms IS NOT NULL), p.updated_at_ms DESC
        """).map(pieceSummary)
    }
  }

  public func piece(id: PieceID) throws -> PieceSummary? {
    try database.read { db in
      try Row.fetchOne(db, sql: "\(Self.pieceSelect) WHERE p.id = ?", arguments: [id.rawValue])
        .map(pieceSummary)
    }
  }

  /// 这条 task 是不是某件创作的稿子。
  ///
  /// 存稿这条路上每保存一次就要问一遍,所以不能用「取全部创作再在内存里找」——
  /// 那是把一次索引查找换成一次全表扫描加一轮 `PieceSummary` 构造,
  /// 而自动保存每隔几秒就会踩一次。
  public func piece(noteTaskID: TaskID) throws -> PieceSummary? {
    try database.read { db in
      try Row.fetchOne(
        db,
        sql: "\(Self.pieceSelect) WHERE p.note_task_id = ? LIMIT 1",
        arguments: [noteTaskID.rawValue]
      ).map(pieceSummary)
    }
  }

  public func recordPieceEvent(_ event: PieceEvent) throws {
    try database.write { db in
      try db.execute(sql: """
        INSERT INTO piece_events (id, piece_id, kind, detail, created_at_ms)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [
          event.id.uuidString.lowercased(), event.pieceID.rawValue,
          event.kind.rawValue,
          // 截断而不是拒绝:这条记录是顺带产生的,写作路径不该因为稿子太长而失败。
          // 上限的理由见 `PieceEvent.detailCharacterLimit`——这张表按
          // 「稿子长度 × 保存次数」增长,是本机库里唯一需要封顶的。
          String(event.detail.prefix(PieceEvent.detailCharacterLimit)),
          event.createdAtMilliseconds,
        ])
    }
  }

  public func pieceEvents(of id: PieceID) throws -> [PieceEvent] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT id, piece_id, kind, detail, created_at_ms
        FROM piece_events WHERE piece_id = ? ORDER BY created_at_ms
        """, arguments: [id.rawValue]).compactMap { row in
        guard let uuid = UUID(uuidString: row["id"]),
              let kind = PieceEvent.Kind(rawValue: row["kind"]) else { return nil }
        let pieceID: PieceID = requiredID(row["piece_id"])
        return PieceEvent(
          id: uuid, pieceID: pieceID, kind: kind,
          detail: row["detail"] ?? "", createdAtMilliseconds: row["created_at_ms"] ?? 0
        )
      }
    }
  }

  /// 某件创作最近一条某类事件。
  ///
  /// 存在的理由是 `pieceEvents(of:)` 会把这件创作的**每一版全文**都读进内存
  /// （起草和修订的 `detail` 都是整篇稿子），而调用方多数时候只要最后一条。
  /// 挂在自动保存路径上的那次判断尤其不能用全量读。
  public func lastPieceEvent(of id: PieceID, kind: PieceEvent.Kind) throws -> PieceEvent? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT id, piece_id, kind, detail, created_at_ms
        FROM piece_events
        WHERE piece_id = ? AND kind = ?
        ORDER BY created_at_ms DESC, id DESC
        LIMIT 1
        """, arguments: [id.rawValue, kind.rawValue])
      else { return nil }
      guard let uuid = UUID(uuidString: row["id"]) else { return nil }
      return PieceEvent(
        id: uuid, pieceID: requiredID(row["piece_id"]), kind: kind,
        detail: row["detail"] ?? "", createdAtMilliseconds: row["created_at_ms"] ?? 0
      )
    }
  }

  public func draftRevisionPairs(limit: Int) throws -> [DraftRevisionPair] {
    try database.read { db in
      // 每件创作取**最后一次** AI 产出,以及它之后你改成的那一版。
      //
      // 取最后一次而不是全部:同一件创作可能重跑好几次起草,中间那些
      // 你根本没看过就重跑了,拿它们做配对只会引入噪声。
      //
      // 「有没有修订」必须在 SQL 里判掉,不能取回来再在 Swift 里丢。
      // LIMIT 数的是行,一旦让没配对的行占了名额,「最近 30 次起草里有 20 次
      // 没改过」就会让这个方法只返回 10 对——调用方据此显示「还需要 N 篇改过
      // 的稿子」,而库里其实早就够了,提炼按钮永远点不亮。
      //
      // 两处 JOIN 都按 id 精确定位而不是按时间相等:同一毫秒内落两条 drafted
      // 会让「时间相等」匹配到多行,一次起草凭空变成两对。
      let rows = try Row.fetchAll(db, sql: """
        WITH last_draft AS (
          SELECT dg.piece_id AS piece_id,
                 dg.detail AS generated,
                 dg.created_at_ms AS generated_at
          FROM piece_events dg
          WHERE dg.kind = ?
            AND dg.id = (
              SELECT id FROM piece_events
              WHERE piece_id = dg.piece_id AND kind = ?
              ORDER BY created_at_ms DESC, id DESC
              LIMIT 1
            )
        )
        SELECT d.generated AS generated, d.generated_at AS generated_at,
               r.detail AS revised, r.created_at_ms AS revised_at
        FROM last_draft d
        JOIN piece_events r ON r.id = (
          SELECT id FROM piece_events
          WHERE piece_id = d.piece_id AND kind = ? AND created_at_ms > d.generated_at
            AND length(detail) > 0
          ORDER BY created_at_ms DESC, id DESC
          LIMIT 1
        )
        ORDER BY d.generated_at DESC
        LIMIT ?
        """, arguments: [
          PieceEvent.Kind.drafted.rawValue, PieceEvent.Kind.drafted.rawValue,
          PieceEvent.Kind.revised.rawValue, max(0, limit),
        ])
      return rows.map { row in
        DraftRevisionPair(
          generated: row["generated"] ?? "", revised: row["revised"] ?? "",
          generatedAtMilliseconds: row["generated_at"] ?? 0,
          revisedAtMilliseconds: row["revised_at"] ?? 0
        )
      }
    }
  }

  public func finishPiece(id: PieceID, finishedAtMilliseconds: Int64) throws -> TaskID {
    try database.write { db in
      let row = try Row.fetchOne(db, sql: """
        SELECT p.note_task_id AS task_id, COALESCE(s.title, '') AS title
        FROM pieces p
        LEFT JOIN content_snapshots s ON s.task_id = p.note_task_id
          AND s.sequence = (SELECT MAX(sequence) FROM content_snapshots x WHERE x.task_id = p.note_task_id)
        WHERE p.id = ?
        """, arguments: [id.rawValue])
      guard let row else { throw RepositoryFailure.notFound }
      let taskID: TaskID = requiredID(row["task_id"])

      // 原地换身份,不新建一条。
      //
      // 复制成品的话,输出里改了字、创作里还是旧的,两份很快就对不上;
      // 而「这篇成了」说的本来就是同一个东西的状态变化。
      let workURL = try CanonicalURL.work().value
      try db.execute(
        sql: "UPDATE tasks SET canonical_url = ?, updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        arguments: [workURL, finishedAtMilliseconds, taskID.rawValue]
      )
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
      // snapshot 的来源标记也要跟着变,否则详情页仍按稿件渲染。
      try db.execute(sql: """
        UPDATE content_snapshots
        SET source_kind = ?, source_url = ?, source_label = ?, platform = ?
        WHERE task_id = ?
        """, arguments: [
          CapturedDocument.Origin.work.rawValue, workURL, "我的作品",
          HistoryPlatformDisplay.workHost, taskID.rawValue,
        ])
      try db.execute(sql: """
        UPDATE pieces SET stage = ?, finished_at_ms = ?, updated_at_ms = MAX(updated_at_ms, ?)
        WHERE id = ?
        """, arguments: [
          PieceStage.done.rawValue, finishedAtMilliseconds, finishedAtMilliseconds, id.rawValue,
        ])
      return taskID
    }
  }

  public func setPieceStage(_ stage: PieceStage?, for id: PieceID, updatedAtMilliseconds: Int64) throws {
    try database.write { db in
      // NULL 代表「回到自动推断」；`done` 同时落一个完成时间，首页据此把它沉下去。
      let raw = stage?.rawValue
      let finished = stage == .done ? updatedAtMilliseconds : nil
      try db.execute(sql: """
        UPDATE pieces SET stage = ?, finished_at_ms = ?, updated_at_ms = MAX(updated_at_ms, ?)
        WHERE id = ?
        """, arguments: [raw, finished, updatedAtMilliseconds, id.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  public func addMaterial(taskID: TaskID, to pieceID: PieceID, addedAtMilliseconds: Int64) throws {
    try database.write { db in
      // 重复加入不报错：用户从两个地方各点了一次是常事，静默保持一份就好。
      try db.execute(sql: """
        INSERT OR IGNORE INTO piece_materials (piece_id, task_id, added_at_ms) VALUES (?, ?, ?)
        """, arguments: [pieceID.rawValue, taskID.rawValue, addedAtMilliseconds])
      try db.execute(
        sql: "UPDATE pieces SET updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        arguments: [addedAtMilliseconds, pieceID.rawValue]
      )
    }
  }

  public func removeMaterial(taskID: TaskID, from pieceID: PieceID) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM piece_materials WHERE piece_id = ? AND task_id = ?",
        arguments: [pieceID.rawValue, taskID.rawValue]
      )
    }
  }

  public func materials(of pieceID: PieceID) throws -> [PieceMaterial] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT m.task_id AS task_id, m.added_at_ms AS added_at_ms,
          t.canonical_url AS canonical_url, COALESCE(s.title, '') AS title
        FROM piece_materials m
        LEFT JOIN tasks t ON t.id = m.task_id
        LEFT JOIN content_snapshots s ON s.task_id = t.id
          AND s.sequence = (SELECT MAX(sequence) FROM content_snapshots x WHERE x.task_id = t.id)
        WHERE m.piece_id = ?
        ORDER BY m.added_at_ms
        """, arguments: [pieceID.rawValue]).map { row in
        let id: TaskID = requiredID(row["task_id"])
        let canonical: String? = row["canonical_url"]
        let title: String = row["title"] ?? ""
        // canonical_url 为 null 说明原记录已经不在了——外键是 CASCADE，
        // 正常删除会连这行一起删；留这个分支是为了万一出现悬挂引用时
        // 显示「已不在」，而不是画一行空白。
        let host = canonical.map {
          $0.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
            ? HistoryPlatformDisplay.noteHost
            : (URLComponents(string: $0)?.host ?? "")
        } ?? ""
        return PieceMaterial(
          id: id,
          title: title.isEmpty ? (canonical ?? "已不在") : title,
          host: host,
          addedAtMilliseconds: row["added_at_ms"] ?? 0,
          isAvailable: canonical != nil
        )
      }
    }
  }

  public func deletePiece(id: PieceID) throws {
    try database.write { db in
      // 只删这件创作本身。正文那条笔记留着——它是用户写的东西，
      // 「不做这篇了」不等于「把稿子扔了」。
      try db.execute(sql: "DELETE FROM pieces WHERE id = ?", arguments: [id.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  // MARK: - 每日选题板

  public func recallMaterials(lane: TopicRecall.Lane, now: Int64) throws -> [PieceMaterial] {
    let range = TopicRecall.range(for: lane.window, now: now)
    return try database.read { db in
      var conditions = ["t.updated_at_ms BETWEEN ? AND ?"]
      var arguments: [DatabaseValueConvertible] = [range.from, range.through]

      // 稿件和成品都不能当素材：它们是这套系统自己的产物，喂回去只会让模型
      // 越来越像它自己写的东西。
      //
      // 成品必须和稿件一起排除，否则规则会自相矛盾：`finishPiece` 是把稿子那条
      // task **原地**转成成品，同一条内容在「做完」前后换个前缀就从排除变成召回。
      //
      // 笔记留着——那是用户自己想的东西，正是最该参与碰撞的素材。
      //
      // 前缀取自 `HistoryPlatformDisplay`，和历史列表判定笔记/稿件/成品用的是
      // 同一组常量；这里原来用 `CanonicalURL.draftScheme` 手工拼冒号，值虽相同
      // 却是第二个来源，改一处漏一处的经典形状。
      conditions.append("t.canonical_url NOT LIKE ?")
      arguments.append("\(HistoryPlatformDisplay.draftURLPrefix)%")
      conditions.append("t.canonical_url NOT LIKE ?")
      arguments.append("\(HistoryPlatformDisplay.workURLPrefix)%")

      if !lane.tags.isEmpty {
        let placeholders = lane.tags.map { _ in "?" }.joined(separator: ", ")
        // 标签的大小写不敏感靠参数侧统一小写达成（`normalized_name` 本就是小写）。
        // 这里曾经写成 `IN (...) COLLATE NOCASE`——那个 COLLATE 作用在 IN 的布尔
        // 结果上，一个字都没管到，只是看着像做了。
        conditions.append("""
          EXISTS (
            SELECT 1 FROM task_tags tt
            JOIN tags g ON g.id = tt.tag_id
            WHERE tt.task_id = t.id AND g.normalized_name IN (\(placeholders))
          )
          """)
        arguments.append(contentsOf: lane.tags.map { $0.lowercased() })
      }
      arguments.append(max(0, lane.limit))

      return try Row.fetchAll(db, sql: """
        SELECT t.id AS task_id, t.updated_at_ms AS added_at_ms,
          t.canonical_url AS canonical_url, COALESCE(s.title, '') AS title
        FROM tasks t
        LEFT JOIN content_snapshots s ON s.task_id = t.id
          AND s.sequence = (SELECT MAX(sequence) FROM content_snapshots x WHERE x.task_id = t.id)
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY t.updated_at_ms DESC
        LIMIT ?
        """, arguments: StatementArguments(arguments)).map { row in
        let id: TaskID = requiredID(row["task_id"])
        let canonical: String? = row["canonical_url"]
        let title: String = row["title"] ?? ""
        let host = canonical.map {
          $0.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
            ? HistoryPlatformDisplay.noteHost
            : (URLComponents(string: $0)?.host ?? "")
        } ?? ""
        return PieceMaterial(
          id: id,
          title: title.isEmpty ? (canonical ?? "已不在") : title,
          host: host,
          addedAtMilliseconds: row["added_at_ms"] ?? 0,
          isAvailable: canonical != nil
        )
      }
    }
  }

  public func insertTopicCandidates(_ candidates: [TopicCandidate]) throws {
    guard !candidates.isEmpty else { return }
    try database.write { db in
      for candidate in candidates {
        try db.execute(sql: """
          INSERT INTO topic_candidates
            (id, day_start_ms, title, summary, is_out_of_bounds, verdict, created_at_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """, arguments: [
            candidate.id.uuidString.lowercased(),
            candidate.dayStartMilliseconds,
            String(candidate.title.prefix(500)),
            // 截断而不是拒绝：模型偶尔无视字数要求，那时该被处理的是数据，
            // 不该让用户看到「今天没出选题」。
            String(candidate.summary.prefix(400)),
            candidate.isOutOfBounds ? 1 : 0,
            candidate.verdict.rawValue,
            candidate.createdAtMilliseconds,
          ])
        for taskID in candidate.materialTaskIDs {
          // 素材可能在生成过程中被删了。这条关联进不去不该让整批候选失败——
          // 候选本身还是有用的，只是少了一份出处。
          //
          // 只放行外键失败这一种。`OR IGNORE` 管的是主键重复，管不到外键；
          // 而早先整句套 `try?` 会把「磁盘满」「表不存在」一并吞掉——那两种
          // 是这一批候选真的没存进去，却和「少了一份出处」长得一模一样。
          do {
            try db.execute(sql: """
              INSERT OR IGNORE INTO topic_candidate_materials (candidate_id, task_id)
              VALUES (?, ?)
              """, arguments: [candidate.id.uuidString.lowercased(), taskID.rawValue])
          } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            // 比的是 extendedResultCode:`resultCode` 给的是 primary code
            // （外键失败时是笼统的 SQLITE_CONSTRAINT），拿它比对永远不成立，
            // 素材被删就会把整批候选一起带走。
            continue
          }
        }
      }
    }
  }

  public func topicCandidates(dayStartMilliseconds: Int64) throws -> [TopicCandidate] {
    try database.read { db in
      try fetchCandidates(db, sql: """
        SELECT * FROM topic_candidates WHERE day_start_ms = ? ORDER BY created_at_ms
        """, arguments: [dayStartMilliseconds])
    }
  }

  public func recentTopicCandidates(limit: Int) throws -> [TopicCandidate] {
    try database.read { db in
      try fetchCandidates(db, sql: """
        SELECT * FROM topic_candidates
        ORDER BY day_start_ms DESC, created_at_ms
        LIMIT ?
        """, arguments: [max(0, limit)])
    }
  }

  // MARK: - 爆款实验室

  public func hitPredictions() throws -> [HitPrediction] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT * FROM hit_predictions ORDER BY predicted_at_ms DESC
        """).compactMap(Self.hitPrediction(from:))
    }
  }

  public func hitPrediction(of pieceID: PieceID) throws -> HitPrediction? {
    try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM hit_predictions WHERE piece_id = ?",
                       arguments: [pieceID.rawValue]).flatMap(Self.hitPrediction(from:))
    }
  }

  public func insertHitPrediction(_ prediction: HitPrediction) throws {
    try database.write { db in
      try db.execute(sql: """
        INSERT INTO hit_predictions
          (id, piece_id, predicted, reasoning, predicted_at_ms, actual, actual_at_ms, review)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
          prediction.id.uuidString.lowercased(),
          prediction.pieceID.rawValue,
          prediction.predicted.rawValue,
          String(prediction.reasoning.prefix(2000)),
          prediction.predictedAtMilliseconds,
          prediction.actual?.rawValue,
          prediction.actualAtMilliseconds,
          String(prediction.review.prefix(2000)),
        ])
    }
  }

  public func settleHitPrediction(
    id: UUID, actual: HitPrediction.Tier, review: String, settledAtMilliseconds: Int64
  ) throws {
    try database.write { db in
      // 只写实际结果和复盘。predicted 和 reasoning 碰都不碰——
      // 一旦能改，人会不自觉地往结果的方向修，然后得出「我判断挺准的」
      // 这个毫无价值的结论。整个校准循环靠的就是这个「不可改」。
      try db.execute(sql: """
        UPDATE hit_predictions SET actual = ?, actual_at_ms = ?, review = ? WHERE id = ?
        """, arguments: [
          actual.rawValue, settledAtMilliseconds,
          String(review.prefix(2000)), id.uuidString.lowercased(),
        ])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  private static func hitPrediction(from row: Row) -> HitPrediction? {
    guard let uuid = UUID(uuidString: row["id"]),
          let pieceID = PieceID(row["piece_id"] as String? ?? ""),
          let predicted = HitPrediction.Tier(rawValue: row["predicted"] ?? "")
    else { return nil }
    return HitPrediction(
      id: uuid,
      pieceID: pieceID,
      predicted: predicted,
      reasoning: row["reasoning"] ?? "",
      predictedAtMilliseconds: row["predicted_at_ms"] ?? 0,
      actual: (row["actual"] as String?).flatMap(HitPrediction.Tier.init(rawValue:)),
      actualAtMilliseconds: row["actual_at_ms"],
      review: row["review"] ?? ""
    )
  }

  // MARK: - 方法库

  public func writingMethods() throws -> [WritingMethod] {
    try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT id, body, origin, is_enabled, created_at_ms
        FROM writing_methods ORDER BY created_at_ms
        """).compactMap { row -> WritingMethod? in
        guard let uuid = UUID(uuidString: row["id"]),
              let origin = WritingMethod.Origin(rawValue: row["origin"] ?? "")
        else { return nil }
        return WritingMethod(
          id: uuid,
          body: row["body"] ?? "",
          origin: origin,
          isEnabled: (row["is_enabled"] as Int? ?? 1) == 1,
          createdAtMilliseconds: row["created_at_ms"] ?? 0
        )
      }
    }
  }

  public func insertWritingMethod(_ method: WritingMethod) throws {
    try database.write { db in
      try db.execute(sql: """
        INSERT INTO writing_methods (id, body, origin, is_enabled, created_at_ms)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [
          method.id.uuidString.lowercased(),
          String(method.body.prefix(1000)),
          method.origin.rawValue,
          method.isEnabled ? 1 : 0,
          method.createdAtMilliseconds,
        ])
    }
  }

  public func setWritingMethodEnabled(_ isEnabled: Bool, for id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "UPDATE writing_methods SET is_enabled = ? WHERE id = ?",
                     arguments: [isEnabled ? 1 : 0, id.uuidString.lowercased()])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  public func deleteWritingMethod(id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM writing_methods WHERE id = ?",
                     arguments: [id.uuidString.lowercased()])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  public func setTopicVerdict(_ verdict: TopicCandidate.Verdict, for id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "UPDATE topic_candidates SET verdict = ? WHERE id = ?",
                     arguments: [verdict.rawValue, id.uuidString.lowercased()])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  private func fetchCandidates(
    _ db: Database, sql: String, arguments: StatementArguments
  ) throws -> [TopicCandidate] {
    let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
    return try rows.compactMap { row -> TopicCandidate? in
      guard let uuid = UUID(uuidString: row["id"]),
            let verdict = TopicCandidate.Verdict(rawValue: row["verdict"] ?? "")
      else { return nil }
      let materials = try String.fetchAll(db, sql: """
        SELECT task_id FROM topic_candidate_materials WHERE candidate_id = ?
        """, arguments: [row["id"] as String? ?? ""]).compactMap { TaskID($0) }
      return TopicCandidate(
        id: uuid,
        dayStartMilliseconds: row["day_start_ms"] ?? 0,
        title: row["title"] ?? "",
        summary: row["summary"] ?? "",
        materialTaskIDs: materials,
        isOutOfBounds: (row["is_out_of_bounds"] as Int? ?? 0) == 1,
        verdict: verdict,
        createdAtMilliseconds: row["created_at_ms"] ?? 0
      )
    }
  }

  public func noteID(matchingTitle title: String) throws -> TaskID? {
    let normalized = WikiLink.normalizedTitle(title)
    guard !normalized.isEmpty else { return nil }
    return try database.read { db in
      // 大小写与首尾空白不参与匹配：要求人记住当初标题的大小写会让链接经常断掉。
      // 同名多条时取最近更新的那条——那是用户刚写过、最可能指的那一条。
      let row = try Row.fetchOne(db, sql: """
        SELECT t.id AS id
        \(Self.latestNoteSnapshotJoin)
          AND lower(trim(COALESCE(s.title, ''))) = ?
        ORDER BY t.updated_at_ms DESC
        LIMIT 1
        """, arguments: [normalized])
      guard let row else { return nil }
      let id: TaskID = requiredID(row["id"])
      return id
    }
  }

  public func noteTitles() throws -> [String] {
    try database.read { db in
      try String.fetchAll(db, sql: """
        SELECT COALESCE(s.title, '') AS title
        \(Self.latestNoteSnapshotJoin)
          AND COALESCE(s.title, '') <> ''
        ORDER BY t.updated_at_ms DESC
        """)
    }
  }

  public func notesLinking(toTitle title: String) throws -> [NoteBacklink] {
    let normalized = WikiLink.normalizedTitle(title)
    guard !normalized.isEmpty else { return [] }
    // SQL 只做粗筛：把正文里出现过 `[[…标题…]]` 的行捞出来，是否真的是一条
    // 指向本篇的链接，交给 WikiLink 用同一套解析判定。让 SQL 去理解链接语法
    // 会立刻和编辑器、跳转两处的口径分家。
    let rows = try database.read { db in
      try Row.fetchAll(db, sql: """
        SELECT t.id AS id, COALESCE(s.title, '') AS title, s.body_text AS body_text
        \(Self.latestNoteSnapshotJoin)
          AND lower(COALESCE(s.body_text, '')) LIKE ? ESCAPE '\\'
        ORDER BY t.updated_at_ms DESC
        """, arguments: ["%[[%\(escapedLikePattern(normalized))%]]%"])
    }
    return rows.compactMap { row -> NoteBacklink? in
      let body: String = row["body_text"] ?? ""
      let links = WikiLink.targets(in: body).map(WikiLink.normalizedTitle)
      guard links.contains(normalized) else { return nil }
      let id: TaskID = requiredID(row["id"])
      let title: String = row["title"] ?? ""
      return NoteBacklink(id: id, title: title.isEmpty ? UserNoteDocument.untitledTitle : title)
    }
  }

  public func updateTaskTitle(
    taskID: TaskID,
    title: String,
    updatedAtMilliseconds: Int64
  ) throws {
    try database.write { db in
      // 标题挂在 snapshot 上而不是 tasks 上——列表读的也是最新那一条的 title，
      // 所以改名要落到 MAX(sequence) 这条，否则列表看不到变化。
      try db.execute(sql: """
        UPDATE content_snapshots SET title = ?
        WHERE task_id = ?
          AND sequence = (SELECT MAX(sequence) FROM content_snapshots WHERE task_id = ?)
        """, arguments: [title, taskID.rawValue, taskID.rawValue])
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

  /// 笔记在列表里的预览。
  ///
  /// 跳过与标题重复的那个一级标题行：标题就在预览正上方，再念一遍是白占一行。
  /// 其余 Markdown 记号保留——`- ` 这样的符号本身就说明了「这条是个清单」。
  static func notePreview(from body: String, title: String?) -> String? {
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let first = lines.first {
      let trimmed = first.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { lines.removeFirst(); continue }
      guard trimmed.hasPrefix("# ") else { break }
      let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      guard heading == title?.trimmingCharacters(in: .whitespaces) else { break }
      lines.removeFirst()
    }
    let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : String(joined.prefix(240))
  }

  private func historyRow(_ row: Row) throws -> HistoryRowProjection {
    let canonical: String = row["canonical_url"]
    let kindRaw: String? = row["kind"], statusRaw: String? = row["status"]
    let previewData: Data? = row["artifact_preview_utf8"]
    var preview = previewData.map { boundedPreview(from: $0, scalarLimit: 240) }
    let sourceBody: Data? = row["source_body_utf8"]
    let frontmatter = sourceBody.map { MarkdownNoteFrontmatter.parse(boundedPreview(from: $0, scalarLimit: 8_192)) }
    // 笔记没有总结产物，列表行于是只剩一个标题和一个日期，看不出里面写了什么。
    // 拿正文开头补上——那正是想在列表里看到的东西。
    if preview == nil, canonical.hasPrefix(HistoryPlatformDisplay.noteURLPrefix), let sourceBody {
      preview = Self.notePreview(
        from: boundedPreview(from: sourceBody, scalarLimit: 1_024),
        title: row["title"]
      )
    }
    let hasTranscript = (row["has_transcript"] as Int64? ?? 0) == 1
    let hasMedia = (row["has_media"] as Int64? ?? 0) == 1
    let hasSummary = (row["has_summary"] as Int64? ?? 0) == 1
    let hasMindMap = (row["has_mind_map"] as Int64? ?? 0) == 1
    let isFavorite = (row["is_favorite"] as Int64? ?? 0) == 1
    // 笔记的 URL 是 `linkdigest-note:<uuid>`，没有 host 段，URLComponents 给回
    // 空串——列表行于是拿空串去查图标，落进「用首字母画个徽标」的兜底，画出来
    // 是个看不懂的方块。这里和导航计数用的是同一个 host 口径。
    let host: String = if canonical.hasPrefix(HistoryPlatformDisplay.noteURLPrefix) {
      HistoryPlatformDisplay.noteHost
    } else if canonical.hasPrefix(HistoryPlatformDisplay.draftURLPrefix) {
      HistoryPlatformDisplay.draftHost
    } else if canonical.hasPrefix(HistoryPlatformDisplay.workURLPrefix) {
      HistoryPlatformDisplay.workHost
    } else {
      URLComponents(string: canonical)?.host ?? ""
    }
    return HistoryRowProjection(taskID: requiredID(row["id"]), title: row["title"], canonicalURL: canonical, host: host, sourceLabel: row["source_label"] ?? "", latestRunKind: kindRaw.flatMap(RunKind.init), latestRunStatus: statusRaw.flatMap(RunStatus.init), latestModel: row["model"], updatedAtMilliseconds: row["updated_at_ms"], createdAtMilliseconds: row["created_at_ms"], latestRunAtMilliseconds: row["latest_run_at_ms"], usageCost: try usage(row), artifactPreview: preview, author: frontmatter?.author, published: frontmatter?.published, hasTranscript: hasTranscript, hasMedia: hasMedia, hasSummary: hasSummary, hasMindMap: hasMindMap, isFavorite: isFavorite)
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
    // V2 capture_deliveries always ingested a MediaDescriptor. Ephemeral URLs
    // are never stored; this flag is the durable "this task had session media"
    // fact used by history UI after the in-memory descriptor is replaced.
    let hadMediaDescriptor = try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM capture_deliveries
          WHERE task_id = ? AND capture_contract_version = 2
        )
        """,
      arguments: [taskID.rawValue]
    ) ?? false
    let isFavorite = (taskRow["is_favorite"] as Int64? ?? 0) == 1
    return HistoryDetailProjection(
      task: task,
      snapshots: snapshots,
      runs: try rows.map(runDetail),
      tags: try tags(db: db, taskID: taskID),
      media: try mediaRow.map { try mediaAsset($0) },
      hadMediaDescriptor: hadMediaDescriptor,
      isFavorite: isFavorite
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
  let normalized = """
    CASE
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.noteURLPrefix)%'
        THEN '\(HistoryPlatformDisplay.noteHost)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.draftURLPrefix)%'
        THEN '\(HistoryPlatformDisplay.draftHost)'
      WHEN \(tableAlias).canonical_url LIKE '\(HistoryPlatformDisplay.workURLPrefix)%'
        THEN '\(HistoryPlatformDisplay.workHost)'
      WHEN \(raw) LIKE 'www.%' THEN substr(\(raw), 5)
      WHEN \(raw) LIKE 'www2.%' THEN substr(\(raw), 6)
      WHEN \(raw) LIKE 'm.%' THEN substr(\(raw), 3)
      WHEN \(raw) LIKE 'mobile.%' THEN substr(\(raw), 8)
      WHEN \(raw) LIKE 'amp.%' THEN substr(\(raw), 5)
      ELSE \(raw)
    END
    """
  let cases = HistoryPlatformRegistry.platforms.flatMap { platform -> [String] in
    var result: [String] = []
    if !platform.exactHosts.isEmpty {
      let hosts = platform.exactHosts
        .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
        .joined(separator: ", ")
      result.append("WHEN \(normalized) IN (\(hosts)) THEN '\(platform.canonicalHost)'")
    }
    for suffix in platform.suffixHosts {
      let safe = suffix.replacingOccurrences(of: "'", with: "''")
      result.append("WHEN \(normalized) = '\(safe)' OR \(normalized) LIKE '%.\(safe)' THEN '\(platform.canonicalHost)'")
    }
    return result
  }.joined(separator: "\n")
  return "CASE\n\(cases)\nELSE \(normalized)\nEND"
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

// MARK: - Mind maps

extension GRDBHistoryRepository: MindMapStoring {
  public func saveMindMap(_ record: TaskMindMapRecord) throws {
    let outlineJSON: String
    do {
      outlineJSON = String(decoding: try JSONEncoder().encode(record.outline), as: UTF8.self)
    } catch { throw RepositoryFailure.invalidInput }
    guard !record.themeID.isEmpty, record.themeID.count <= 64 else {
      throw RepositoryFailure.invalidInput
    }
    try database.write { db in
      guard let storedTask: String = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE id = ?", arguments: [record.taskID.rawValue]
      ), storedTask == record.taskID.rawValue else { throw RepositoryFailure.invalidInput }
      try db.execute(
        sql: """
          INSERT INTO task_mind_maps
            (task_id, outline_json, theme_id, user_edited, provider, model,
             prompt_tokens, completion_tokens, total_tokens, created_at_ms, updated_at_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(task_id) DO UPDATE SET
            outline_json = excluded.outline_json,
            theme_id = excluded.theme_id,
            user_edited = excluded.user_edited,
            provider = excluded.provider,
            model = excluded.model,
            prompt_tokens = excluded.prompt_tokens,
            completion_tokens = excluded.completion_tokens,
            total_tokens = excluded.total_tokens,
            updated_at_ms = excluded.updated_at_ms
          """,
        arguments: [
          record.taskID.rawValue, outlineJSON, record.themeID, record.userEdited ? 1 : 0,
          record.provider, record.model, record.promptTokens, record.completionTokens,
          record.totalTokens, record.createdAtMilliseconds, record.updatedAtMilliseconds,
        ]
      )
    }
  }

  public func loadMindMap(taskID: TaskID) throws -> TaskMindMapRecord? {
    try database.read { db in
      guard let row = try Row.fetchOne(
        db, sql: "SELECT * FROM task_mind_maps WHERE task_id = ?", arguments: [taskID.rawValue]
      ) else { return nil }
      let outlineJSON: String = row["outline_json"]
      guard let outline = try? JSONDecoder().decode(
        MindMapOutline.self, from: Data(outlineJSON.utf8)
      ) else { return nil }
      return TaskMindMapRecord(
        taskID: taskID,
        outline: outline,
        themeID: row["theme_id"],
        userEdited: (row["user_edited"] as Int64? ?? 0) == 1,
        provider: row["provider"],
        model: row["model"],
        promptTokens: (row["prompt_tokens"] as Int64?).map(Int.init),
        completionTokens: (row["completion_tokens"] as Int64?).map(Int.init),
        totalTokens: (row["total_tokens"] as Int64?).map(Int.init),
        createdAtMilliseconds: row["created_at_ms"],
        updatedAtMilliseconds: row["updated_at_ms"]
      )
    }
  }

  public func deleteMindMap(taskID: TaskID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM task_mind_maps WHERE task_id = ?", arguments: [taskID.rawValue])
    }
  }
}

// MARK: - Token ledger

extension GRDBHistoryRepository: TokenUsageRecording {
  public func appendTokenUsage(_ usage: TaskTokenUsage) throws {
    guard !usage.operation.isEmpty, usage.operation.count <= 64 else {
      throw RepositoryFailure.invalidInput
    }
    try database.write { db in
      guard let storedTask: String = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE id = ?", arguments: [usage.taskID.rawValue]
      ), storedTask == usage.taskID.rawValue else { throw RepositoryFailure.invalidInput }
      try db.execute(
        sql: """
          INSERT INTO task_token_usages
            (id, task_id, operation, prompt_tokens, completion_tokens, total_tokens, created_at_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          UUID().uuidString.lowercased(), usage.taskID.rawValue, usage.operation,
          usage.promptTokens, usage.completionTokens, usage.totalTokens,
          usage.createdAtMilliseconds,
        ]
      )
    }
  }

  public func ledgerTokenTotals(taskID: TaskID) throws -> TaskTokenTotals {
    try database.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(prompt_tokens), 0) AS p,
                 COALESCE(SUM(completion_tokens), 0) AS c,
                 COALESCE(SUM(total_tokens), 0) AS t
          FROM task_token_usages WHERE task_id = ?
          """,
        arguments: [taskID.rawValue]
      )
      return TaskTokenTotals(
        promptTokens: Int(row?["p"] as Int64? ?? 0),
        completionTokens: Int(row?["c"] as Int64? ?? 0),
        totalTokens: Int(row?["t"] as Int64? ?? 0)
      )
    }
  }
}

// MARK: - Annotations (excerpts + note)

extension GRDBHistoryRepository: AnnotationStoring {
  public func saveNote(taskID: TaskID, body: String, updatedAtMilliseconds: Int64) throws {
    try database.write { db in
      guard let stored: String = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE id = ?", arguments: [taskID.rawValue]
      ), stored == taskID.rawValue else { throw RepositoryFailure.invalidInput }
      if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try db.execute(sql: "DELETE FROM task_notes WHERE task_id = ?", arguments: [taskID.rawValue])
      } else {
        try db.execute(
          sql: """
            INSERT INTO task_notes (task_id, body, updated_at_ms) VALUES (?, ?, ?)
            ON CONFLICT(task_id) DO UPDATE SET body = excluded.body, updated_at_ms = excluded.updated_at_ms
            """,
          arguments: [taskID.rawValue, body, updatedAtMilliseconds]
        )
      }
    }
  }

  public func loadNote(taskID: TaskID) throws -> String? {
    try database.read { db in
      try String.fetchOne(db, sql: "SELECT body FROM task_notes WHERE task_id = ?", arguments: [taskID.rawValue])
    }
  }

  public func addExcerpt(_ excerpt: TaskExcerpt) throws {
    let text = excerpt.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 4_000 else { throw RepositoryFailure.invalidInput }
    try database.write { db in
      guard let stored: String = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE id = ?", arguments: [excerpt.taskID.rawValue]
      ), stored == excerpt.taskID.rawValue else { throw RepositoryFailure.invalidInput }
      try db.execute(
        sql: "INSERT INTO task_excerpts (id, task_id, excerpt, created_at_ms) VALUES (?, ?, ?, ?)",
        arguments: [excerpt.id, excerpt.taskID.rawValue, text, excerpt.createdAtMilliseconds]
      )
    }
  }

  public func listExcerpts(taskID: TaskID) throws -> [TaskExcerpt] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM task_excerpts WHERE task_id = ? ORDER BY created_at_ms, id",
        arguments: [taskID.rawValue]
      ).map { row in
        TaskExcerpt(
          id: row["id"], taskID: taskID, excerpt: row["excerpt"],
          createdAtMilliseconds: row["created_at_ms"]
        )
      }
    }
  }

  public func deleteExcerpt(id: String, taskID: TaskID) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM task_excerpts WHERE id = ? AND task_id = ?",
        arguments: [id, taskID.rawValue]
      )
    }
  }
}
