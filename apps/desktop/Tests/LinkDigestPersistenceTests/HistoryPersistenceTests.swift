import Foundation
import XCTest
import GRDB
import LinkDigestCore
@testable import LinkDigestPersistence

final class HistoryMigrationAndFaultTests: XCTestCase {
  func testEmptyDatabaseMigratesToCandidate001AndRejectsExtraHyphenUUIDs() throws {
    try withRepository { repository, _ in
      XCTAssertEqual(repository.accessMode, .writable)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 1)
      let sql = try repository.database.read { db in
        try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_schema WHERE type = 'table' AND name IN ('tasks','content_snapshots','runs','artifacts','capture_deliveries')")
      }
      XCTAssertEqual(sql.count, 5)
      for row in sql where ["tasks", "content_snapshots", "runs", "artifacts"].contains(row["name"] as String) {
        let tableSQL: String = row["sql"]
        XCTAssertTrue(tableSQL.contains("WITHOUT ROWID"))
        XCTAssertTrue(tableSQL.contains("length(replace(id, '-', '')) = 32"))
        XCTAssertTrue(tableSQL.contains("replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'"))
      }
      let snapshotSQL: String = sql.first { ($0["name"] as String) == "content_snapshots" }!["sql"]
      XCTAssertFalse(snapshotSQL.contains("length(body_text)"))
      for (index, invalidID) in [
        "NOT-A-UUID",
        "-2345678-1234-1234-1234-123456789abc",
        "12345678-1234-1234-1234-123456789ab-",
      ].enumerated() {
        XCTAssertThrowsError(try repository.database.write { db in
          try db.execute(sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, 0, 0)", arguments: [invalidID, "https://invalid.test/\(index)"])
        })
      }
    }
  }

  func test001ReopenIsIdempotentAndFutureSchemaIsReadOnly() throws {
    try withTemporaryLocation { location in
      let first = try LocalDatabase.open(at: location)
      try first.write { try $0.execute(sql: "PRAGMA user_version = 2") }
      try first.close()
      let future = try LocalDatabase.open(at: location)
      XCTAssertEqual(future.accessMode, .readOnly(.futureSchema))
      XCTAssertThrowsError(try future.write { _ in 1 }) { XCTAssertEqual($0 as? RepositoryFailure, .readOnly(.futureSchema)) }
      try future.close()
    }
  }

  func testFutureSchemaRetainsExistingHistoryForReadOnlyBrowsing() throws {
    try withTemporaryLocation { location in
      let writable = try GRDBHistoryRepository.open(at: location)
      let first = try writable.acceptCapture(.init(
        envelope: capture(requestID: "future-first", key: "future-first", url: "https://example.test/future-first", body: "first body"),
        receivedAtMilliseconds: 10
      ))
      let second = try writable.acceptCapture(.init(
        envelope: capture(requestID: "future-second", key: "future-second", url: "https://example.test/future-second", body: "second body"),
        receivedAtMilliseconds: 20
      ))
      try writable.database.close()
      let upgrader = try DatabaseQueue(path: location.databaseURL.path)
      try upgrader.write { try $0.execute(sql: "PRAGMA user_version = 2") }
      try upgrader.close()

      let future = try GRDBHistoryRepository.open(at: location)
      XCTAssertEqual(future.accessMode, .readOnly(.futureSchema))
      let history = HistoryApplicationService(repository: future)
      XCTAssertEqual(try history.historyPage(limit: 50).rows.map(\.taskID), [second.taskID, first.taskID])
      XCTAssertEqual(try history.detail(taskID: first.taskID).snapshots.first?.bodyText, "first body")
      XCTAssertThrowsError(try history.deleteTask(taskID: first.taskID)) {
        XCTAssertEqual($0 as? RepositoryFailure, .readOnly(.futureSchema))
      }
      try future.database.close()
    }
  }

  func testMigrationFailureLeavesNoHalfTablesAndCanRecoverForward() throws {
    try withTemporaryLocation { location in
      let failed = try LocalDatabase.open(at: location, dependencies: .failing(migration: true))
      XCTAssertEqual(failed.accessMode, .readOnly(.migrationFailed))
      let tables = try failed.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'") }
      XCTAssertTrue(tables.isEmpty)
      XCTAssertEqual(try failed.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 0)
      try failed.close()
      let recovered = try LocalDatabase.open(at: location)
      XCTAssertEqual(recovered.accessMode, .writable)
      XCTAssertEqual(try recovered.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 1)
      try recovered.close()
    }
  }

  func testOpenCreateDirectoryWriteBackupAndRestoreFailuresAreInjected() throws {
    try withTemporaryLocation(createDirectory: false) { location in
      XCTAssertThrowsError(try LocalDatabase.open(at: location, dependencies: .failing(createDirectory: true))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: location.databaseURL.path))
    }
    try withTemporaryLocation { location in
      XCTAssertThrowsError(try LocalDatabase.open(at: location, dependencies: .failing(open: true))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
    }
    try withRepository(dependencies: .failing(write: true)) { repository, _ in
      XCTAssertThrowsError(try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
    }
    try withRepository { repository, location in
      let backup = location.directoryURL.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
      var backupFailure = PersistenceDependencies.live; backupFailure.beforeBackup = { throw RepositoryFailure.injectedFailure }
      let failingDatabase = try LocalDatabase.open(at: location, dependencies: backupFailure)
      XCTAssertThrowsError(try DatabaseMaintenance(database: failingDatabase).backup(to: backup)) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
      try failingDatabase.close()
      var restoreFailure = PersistenceDependencies.live; restoreFailure.beforeRestore = { throw RepositoryFailure.injectedFailure }
      XCTAssertThrowsError(try DatabaseMaintenance.restore(from: backup, to: LocalDatabaseLocation(directoryURL: location.directoryURL.appendingPathComponent("restore")), dependencies: restoreFailure)) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
      _ = repository
    }
  }
}

final class HistoryRepositoryCaptureTests: XCTestCase {
  func testCaptureLedgerReplayConflictCanonicalAndBodyReuse() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(envelope: capture(requestID: "r1", key: "same", url: "https://EXAMPLE.test:443/article?b=2&a=1#one", body: "body-one"), receivedAtMilliseconds: 10))
      XCTAssertTrue(first.taskWasCreated); XCTAssertTrue(first.snapshotWasCreated)
      let replay = try repository.acceptCapture(.init(envelope: capture(requestID: "transport-retry", key: "same", url: "https://EXAMPLE.test:443/article?b=2&a=1#one", body: "body-one"), receivedAtMilliseconds: 11))
      XCTAssertEqual(replay.taskID, first.taskID); XCTAssertTrue(replay.deliveryWasReplayed)
      XCTAssertThrowsError(try repository.acceptCapture(.init(envelope: capture(requestID: "r-conflict", key: "same", url: "https://example.test/article", body: "changed"), receivedAtMilliseconds: 12))) { XCTAssertEqual($0 as? RepositoryFailure, .captureIdempotencyConflict) }

      let sameBody = try repository.acceptCapture(.init(envelope: capture(requestID: "r2", key: "different", url: "https://example.test/article?b=2&a=1#two", body: "body-one"), receivedAtMilliseconds: 13))
      XCTAssertEqual(sameBody.taskID, first.taskID); XCTAssertEqual(sameBody.snapshotID, first.snapshotID); XCTAssertFalse(sameBody.snapshotWasCreated)
      let newBody = try repository.acceptCapture(.init(envelope: capture(requestID: "r3", key: "third", url: "https://example.test/article?b=2&a=1", body: "body-two"), receivedAtMilliseconds: 14))
      XCTAssertEqual(newBody.taskID, first.taskID); XCTAssertTrue(newBody.snapshotWasCreated)
      let detail = try repository.detail(taskID: first.taskID)
      XCTAssertEqual(detail.snapshots.map(\.sequence), [1, 2])
      XCTAssertTrue(detail.runs.isEmpty)
      XCTAssertEqual(try DatabaseMaintenance(database: repository.database).counts(), .init(tasks: 1, snapshots: 2, deliveries: 3, runs: 0, artifacts: 0))
    }
  }

  func testTwoPoolsPreserveCaptureIdempotencyAndConflictSemanticsUnderRace() throws {
    try withTemporaryLocation { location in
      let first = try GRDBHistoryRepository.open(at: location)
      let second = try GRDBHistoryRepository.open(at: location)
      defer { try? first.database.close(); try? second.database.close() }

      let same = try raceTwo(
        { try first.acceptCapture(.init(envelope: capture(requestID: "race-same-a", key: "race-same", url: "https://race.example/same", body: "same"), receivedAtMilliseconds: 1)) },
        { try second.acceptCapture(.init(envelope: capture(requestID: "race-same-b", key: "race-same", url: "https://race.example/same", body: "same"), receivedAtMilliseconds: 2)) }
      )
      let sameSuccesses = same.compactMap { observation -> AcceptCaptureResult? in if case let .success(value) = observation { return value }; return nil }
      XCTAssertEqual(sameSuccesses.count, 2)
      XCTAssertEqual(Set(sameSuccesses.map(\.taskID)).count, 1)
      XCTAssertEqual(Set(sameSuccesses.map(\.snapshotID)).count, 1)
      XCTAssertEqual(same.filter { if case .failure = $0 { true } else { false } }.count, 0)

      let different = try raceTwo(
        { try first.acceptCapture(.init(envelope: capture(requestID: "race-diff-a", key: "race-diff", url: "https://race.example/diff", body: "left"), receivedAtMilliseconds: 3)) },
        { try second.acceptCapture(.init(envelope: capture(requestID: "race-diff-b", key: "race-diff", url: "https://race.example/diff", body: "right"), receivedAtMilliseconds: 4)) }
      )
      XCTAssertEqual(different.filter { if case .success = $0 { true } else { false } }.count, 1)
      let failures = different.compactMap { observation -> RepositoryFailure? in if case let .failure(value) = observation { return value }; return nil }
      XCTAssertEqual(failures, [.captureIdempotencyConflict])
    }
  }

  func testCaptureValidatesBeforeStorageAndRoundTripsEmbeddedNUL() throws {
    try withRepository { repository, _ in
      let invalid = capture(body: "a\0b", characterCount: 2)
      XCTAssertThrowsError(try repository.acceptCapture(.init(envelope: invalid, receivedAtMilliseconds: 1))) { XCTAssertEqual($0 as? RepositoryFailure, .invalidInput) }
      let accepted = try repository.acceptCapture(.init(envelope: capture(body: "a\0b", characterCount: 3), receivedAtMilliseconds: 2))
      let snapshot = try repository.detail(taskID: accepted.taskID).snapshots.single!
      XCTAssertEqual(snapshot.bodyText, "a\0b")
      XCTAssertEqual(snapshot.characterCount, 3)
      XCTAssertEqual(snapshot.bodySHA256, "59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138")
    }
  }
}

final class HistoryRepositoryRunTests: XCTestCase {
  func testRunIdempotencyStateMachinePartialTerminalAndRerun() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let create = CreateRunCommand(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "run:one", kind: .summarize, createdAtMilliseconds: 2)
      let first = try repository.createRun(create)
      XCTAssertTrue(first.wasCreated)
      XCTAssertFalse(try repository.createRun(create).wasCreated)
      let conflict = CreateRunCommand(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "run:one", kind: .translate, targetLanguage: "zh", createdAtMilliseconds: 2)
      XCTAssertThrowsError(try repository.createRun(conflict)) { XCTAssertEqual($0 as? RepositoryFailure, .runIdempotencyConflict) }

      try repository.markRunRunning(.init(runID: first.runID, startedAtMilliseconds: 3, provider: .init(profileID: "profile-local", providerKind: "openai-compatible", baseURL: "https://provider.example/v1", apiMode: "chat_completions", model: "fixture-model")))
      try repository.savePartialArtifact(.init(runID: first.runID, contentFormat: .markdown, bodyText: "partial", updatedAtMilliseconds: 4))
      let usage = try RunUsageCost(inputTokens: nil, outputTokens: 7, totalTokens: nil, costAmountMicros: 1200, costCurrencyCode: "USD")
      try repository.finishRun(.init(runID: first.runID, status: .completed, finishedAtMilliseconds: 5, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "complete"), usageCost: usage))
      XCTAssertThrowsError(try repository.finishRun(.init(runID: first.runID, status: .failed, finishedAtMilliseconds: 6))) { XCTAssertEqual($0 as? RepositoryFailure, .invalidStateTransition) }

      let rerun = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "run:rerun", rerunOfRunID: first.runID, kind: .summarize, createdAtMilliseconds: 7))
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.runs.count, 2)
      XCTAssertEqual(detail.runs.first?.artifact?.bodyText, "complete")
      XCTAssertEqual(detail.runs.first?.run.usageCost, usage)
      XCTAssertThrowsError(try repository.database.write { db in
        try db.execute(sql: "UPDATE runs SET cost_amount_micros = 1, cost_currency_code = '12$' WHERE id = ?", arguments: [first.runID.rawValue])
      })
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.first?.run.usageCost, usage)
      XCTAssertEqual(detail.runs.last?.run.rerunOfRunID, first.runID)
      XCTAssertEqual(rerun.wasCreated, true)
    }
  }

  func testArtifactNULRoundTripsPartialTerminalReopenRecoveryDetailAndExport() throws {
    try withTemporaryLocation { location in
      var repository = try GRDBHistoryRepository.open(at: location)
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let partialRun = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "nul-partial", kind: .summarize, createdAtMilliseconds: 2))
      try repository.markRunRunning(.init(runID: partialRun.runID, startedAtMilliseconds: 3, provider: .init()))
      try repository.savePartialArtifact(.init(runID: partialRun.runID, contentFormat: .plainText, bodyText: "a\0b", updatedAtMilliseconds: 4))
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "a\0b")
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "a\0b")
      try repository.database.close()

      repository = try GRDBHistoryRepository.open(at: location)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "a\0b")
      XCTAssertEqual(try repository.recoverInterruptedRuns(at: 5), 1)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "a\0b")
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).runs.single?.artifact?.bodyText, "a\0b")

      let terminalRun = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "nul-terminal", kind: .summarize, createdAtMilliseconds: 6))
      try repository.markRunRunning(.init(runID: terminalRun.runID, startedAtMilliseconds: 7, provider: .init()))
      try repository.finishRun(.init(runID: terminalRun.runID, status: .completed, finishedAtMilliseconds: 8, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "\0a")))
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.runs.last?.artifact?.bodyText, "\0a")
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).runs.last?.artifact?.bodyText, "\0a")
      XCTAssertEqual(try repository.historyPage(limit: 1, after: nil).rows.single?.artifactPreview, "\0a")
      try repository.database.close()
    }
  }

  func testArtifactStrictUTF8ReadMapsInvalidBytesToIntegrityFailure() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let run = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "invalid-utf8", kind: .summarize, createdAtMilliseconds: 2))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init()))
      try repository.savePartialArtifact(.init(runID: run.runID, contentFormat: .plainText, bodyText: "valid", updatedAtMilliseconds: 4))
      try repository.database.write { db in
        try db.execute(sql: "UPDATE artifacts SET body_text = CAST(X'FF' AS TEXT) WHERE run_id = ?", arguments: [run.runID.rawValue])
      }
      XCTAssertThrowsError(try repository.detail(taskID: accepted.taskID)) { XCTAssertEqual($0 as? RepositoryFailure, .integrityCheckFailed) }
      XCTAssertThrowsError(try repository.exportProjection(taskID: accepted.taskID)) { XCTAssertEqual($0 as? RepositoryFailure, .integrityCheckFailed) }
    }
  }

  func testHistoryPreviewUsesBoundedUTF8PrefixAndPreservesLeadingNUL() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let run = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "bounded-preview", kind: .summarize, createdAtMilliseconds: 2))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init()))
      let body = "\0" + String(repeating: "😀", count: 300)
      try repository.finishRun(.init(runID: run.runID, status: .completed, finishedAtMilliseconds: 4, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: body)))
      let preview = try XCTUnwrap(repository.historyPage(limit: 1, after: nil).rows.single?.artifactPreview)
      XCTAssertTrue(preview.hasPrefix("\0"))
      XCTAssertEqual(preview.unicodeScalars.count, 240)
      XCTAssertNotEqual(preview, body)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).runs.single?.artifact?.bodyText, body)
    }
  }

  func testTwoPoolsPreserveRunConflictSemanticsUnderRace() throws {
    try withTemporaryLocation { location in
      let first = try GRDBHistoryRepository.open(at: location)
      let accepted = try first.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let second = try GRDBHistoryRepository.open(at: location)
      defer { try? first.database.close(); try? second.database.close() }
      let observations = try raceTwo(
        { try first.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "run-race", kind: .summarize, createdAtMilliseconds: 2)) },
        { try second.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "run-race", kind: .translate, targetLanguage: "zh", createdAtMilliseconds: 3)) }
      )
      XCTAssertEqual(observations.filter { if case .success = $0 { true } else { false } }.count, 1)
      let failures = observations.compactMap { observation -> RepositoryFailure? in if case let .failure(value) = observation { return value }; return nil }
      XCTAssertEqual(failures, [.runIdempotencyConflict])
    }
  }

  func testTerminalArtifactAndUsageRollbackTogether() throws {
    try withTemporaryLocation { location in
      let setup = try GRDBHistoryRepository.open(at: location)
      let accepted = try setup.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let run = try setup.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "atomic", kind: .summarize, createdAtMilliseconds: 2))
      try setup.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init()))
      try setup.database.close()

      var dependencies = PersistenceDependencies.live
      dependencies.beforeTerminalCommit = { throw RepositoryFailure.injectedFailure }
      let injected = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      XCTAssertThrowsError(try injected.finishRun(.init(runID: run.runID, status: .completed, finishedAtMilliseconds: 4, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "must rollback"), usageCost: try RunUsageCost(totalTokens: 9)))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
      let detail = try injected.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.runs.single?.run.status, .running)
      XCTAssertNil(detail.runs.single?.artifact)
      XCTAssertEqual(detail.runs.single?.run.usageCost, .unknown)
      try injected.database.close()
    }
  }

  func testRecoveryPreservesPartialAndInterruptsQueuedAndRunning() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let queued = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "queued", kind: .summarize, createdAtMilliseconds: 2))
      let running = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "running", kind: .translate, targetLanguage: "zh", createdAtMilliseconds: 3))
      try repository.markRunRunning(.init(runID: running.runID, startedAtMilliseconds: 4, provider: .init()))
      try repository.savePartialArtifact(.init(runID: running.runID, contentFormat: .plainText, bodyText: "survives", updatedAtMilliseconds: 5))
      XCTAssertEqual(try repository.recoverInterruptedRuns(at: 6), 2)
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.runs.map(\.run.status), [.interrupted, .interrupted])
      XCTAssertNil(detail.runs.first?.artifact)
      XCTAssertEqual(detail.runs.last?.artifact?.bodyText, "survives")
      _ = queued
    }
  }
}

final class HistoryProjectionMaintenanceAndConcurrencyTests: XCTestCase {
  func testTaskSortDateChangesOnlyForSnapshotAndNewRunWhileLatestRunDateTracksLifecycle() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(envelope: capture(requestID: "date-a1", key: "date-a1", url: "https://date.example/a", body: "v1"), receivedAtMilliseconds: 10))
      _ = try repository.acceptCapture(.init(envelope: capture(requestID: "date-a2", key: "date-a2", url: "https://date.example/a", body: "v2"), receivedAtMilliseconds: 15))
      XCTAssertEqual(try repository.detail(taskID: first.taskID).task.updatedAtMilliseconds, 15)

      let command = CreateRunCommand(taskID: first.taskID, snapshotID: first.snapshotID, idempotencyKey: "date-run", kind: .summarize, createdAtMilliseconds: 20)
      let run = try repository.createRun(command)
      XCTAssertEqual(try repository.detail(taskID: first.taskID).task.updatedAtMilliseconds, 20)
      let replayWithLaterTimestamp = CreateRunCommand(taskID: first.taskID, snapshotID: first.snapshotID, idempotencyKey: "date-run", kind: .summarize, createdAtMilliseconds: 999)
      XCTAssertFalse(try repository.createRun(replayWithLaterTimestamp).wasCreated)
      XCTAssertEqual(try repository.detail(taskID: first.taskID).task.updatedAtMilliseconds, 20)

      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 30, provider: .init()))
      try repository.savePartialArtifact(.init(runID: run.runID, contentFormat: .plainText, bodyText: "partial", updatedAtMilliseconds: 40))
      try repository.finishRun(.init(runID: run.runID, status: .completed, finishedAtMilliseconds: 50, artifact: .init(contentFormat: .plainText, completeness: .complete, bodyText: "complete")))
      var row = try XCTUnwrap(repository.historyPage(limit: 10, after: nil).rows.first { $0.taskID == first.taskID })
      XCTAssertEqual(row.updatedAtMilliseconds, 20)
      XCTAssertEqual(row.latestRunAtMilliseconds, 50)

      let second = try repository.acceptCapture(.init(envelope: capture(requestID: "date-b", key: "date-b", url: "https://date.example/b", body: "b"), receivedAtMilliseconds: 25))
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.first?.taskID, second.taskID)

      let rerun = try repository.createRun(.init(taskID: first.taskID, snapshotID: first.snapshotID, idempotencyKey: "date-rerun", rerunOfRunID: run.runID, kind: .summarize, createdAtMilliseconds: 60))
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.first?.taskID, first.taskID)
      try repository.markRunRunning(.init(runID: rerun.runID, startedAtMilliseconds: 70, provider: .init()))
      try repository.savePartialArtifact(.init(runID: rerun.runID, contentFormat: .plainText, bodyText: "rerun partial", updatedAtMilliseconds: 75))
      XCTAssertEqual(try repository.recoverInterruptedRuns(at: 80), 1)
      row = try XCTUnwrap(repository.historyPage(limit: 10, after: nil).rows.first { $0.taskID == first.taskID })
      XCTAssertEqual(row.updatedAtMilliseconds, 60)
      XCTAssertEqual(row.latestRunAtMilliseconds, 80)

      let third = try repository.acceptCapture(.init(envelope: capture(requestID: "date-c", key: "date-c", url: "https://date.example/c", body: "c"), receivedAtMilliseconds: 65))
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.first?.taskID, third.taskID)
    }
  }

  func testKeysetDetailExportAndHardDeleteCascade() throws {
    try withRepository { repository, _ in
      var taskIDs: [TaskID] = []
      for index in 0..<3 {
        let result = try repository.acceptCapture(.init(envelope: capture(requestID: "page-\(index)", key: "page-\(index)", url: "https://example.test/\(index)", body: "body-\(index)", title: "Title \(index)"), receivedAtMilliseconds: Int64(index + 1)))
        taskIDs.append(result.taskID)
      }
      let persistedRun = try repository.createRun(.init(taskID: taskIDs[0], snapshotID: try repository.detail(taskID: taskIDs[0]).snapshots.single!.id, idempotencyKey: "delete-cascade", kind: .summarize, createdAtMilliseconds: 10))
      try repository.markRunRunning(.init(runID: persistedRun.runID, startedAtMilliseconds: 11, provider: .init(model: "projection-model")))
      try repository.finishRun(.init(runID: persistedRun.runID, status: .completed, finishedAtMilliseconds: 12, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "projection preview")))
      let first = try repository.historyPage(limit: 2, after: nil)
      XCTAssertEqual(first.rows.count, 2); XCTAssertNotNil(first.nextCursor)
      let second = try repository.historyPage(limit: 2, after: first.nextCursor)
      XCTAssertEqual(second.rows.count, 1)
      XCTAssertTrue(Set(first.rows.map(\.taskID)).isDisjoint(with: Set(second.rows.map(\.taskID))))
      let export = try repository.exportProjection(taskID: taskIDs[0])
      XCTAssertEqual(export.formatVersion, 1); XCTAssertEqual(export.snapshots.single?.bodyText, "body-0")
      XCTAssertEqual(try repository.historyPage(limit: 3, after: nil).rows.first { $0.taskID == taskIDs[0] }?.artifactPreview, "projection preview")
      try repository.deleteTask(taskID: taskIDs[0])
      XCTAssertThrowsError(try repository.detail(taskID: taskIDs[0])) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
      let remaining = try DatabaseMaintenance(database: repository.database).counts()
      XCTAssertEqual(remaining.tasks, 2)
      XCTAssertEqual(remaining.runs, 0)
      XCTAssertEqual(remaining.artifacts, 0)
      XCTAssertNoThrow(try repository.detail(taskID: taskIDs[1]))
    }
  }

  func testWALCheckpointOnlineBackupAndRestorePreserveFiveTableCounts() throws {
    try withRepository { repository, location in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let run = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "backup-run", kind: .summarize, createdAtMilliseconds: 2))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init()))
      try repository.finishRun(.init(runID: run.runID, status: .completed, finishedAtMilliseconds: 4, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "result")))
      for index in 0..<32 {
        _ = try repository.acceptCapture(.init(envelope: capture(requestID: "wal-\(index)", key: "wal-\(index)", url: "https://wal.example/\(index)", body: String(repeating: "x", count: 1024)), receivedAtMilliseconds: Int64(index + 10)))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: location.walURL.path))
      let maintenance = DatabaseMaintenance(database: repository.database)
      let passive = try maintenance.passiveCheckpoint()
      XCTAssertEqual(passive.busy, 0)
      XCTAssertGreaterThan(passive.logFrames, 0)
      XCTAssertEqual(passive.checkpointedFrames, passive.logFrames)
      let expected = try maintenance.counts()
      let backupURL = location.directoryURL.deletingLastPathComponent().appendingPathComponent("history-backup.sqlite")
      XCTAssertEqual(try maintenance.backup(to: backupURL), expected)
      let restoreLocation = LocalDatabaseLocation(directoryURL: location.directoryURL.deletingLastPathComponent().appendingPathComponent("restored"))
      let restored = try DatabaseMaintenance.restore(from: backupURL, to: restoreLocation)
      XCTAssertEqual(try DatabaseMaintenance(database: restored).integrityCheck(), "ok")
      XCTAssertEqual(try DatabaseMaintenance(database: restored).counts(), expected)
      let truncated = try maintenance.truncateCheckpoint()
      XCTAssertEqual(truncated.busy, 0)
      XCTAssertEqual(truncated.logFrames, 0)
      XCTAssertEqual(truncated.checkpointedFrames, 0)
      XCTAssertEqual(try maintenance.counts(), expected)
      try restored.close()
    }
  }

  func testProjectionAndStableFailuresExcludeSecretAndRawStorageMaterial() throws {
    try withRepository { repository, location in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let run = try repository.createRun(.init(taskID: accepted.taskID, snapshotID: accepted.snapshotID, idempotencyKey: "secret-hygiene", kind: .summarize, createdAtMilliseconds: 2))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 3, provider: .init(profileID: "profile-safe", providerKind: "openai-compatible", baseURL: "https://provider.invalid/v1", apiMode: "chat_completions", model: "fixture")))
      try repository.finishRun(.init(runID: run.runID, status: .failed, finishedAtMilliseconds: 4, failureCode: "PROVIDER_UNAVAILABLE", failureRetryable: true))
      let json = String(decoding: try JSONEncoder().encode(repository.exportProjection(taskID: accepted.taskID)), as: UTF8.self)
      for forbidden in ["apiKey", "secretReference", "authorizationHeader", "cookieValue", "rawError", "rawProviderBody", location.directoryURL.path] {
        XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
      }
      XCTAssertFalse(RepositoryFailure.unavailable.description.contains(location.directoryURL.path))
      XCTAssertFalse(RepositoryFailure.unavailable.description.localizedCaseInsensitiveContains("sql"))
    }
  }

  func testOneWriterEightReadersUseStartGateOverlapAndNoLostWrites() throws {
    try withRepository { repository, _ in
      let queue = DispatchQueue(label: "history-concurrency", attributes: .concurrent)
      let ready = DispatchGroup(), workers = DispatchGroup(), gate = DispatchSemaphore(value: 0)
      let writerStarted = DispatchSemaphore(value: 0)
      let state = ConcurrencyWitness()
      let writes = 120

      ready.enter(); workers.enter()
      queue.async {
        ready.leave(); gate.wait(); defer { workers.leave(); state.writerFinished() }
        state.writerStarted()
        for _ in 0..<8 { writerStarted.signal() }
        do {
          for index in 0..<writes where !state.isCancelled {
            _ = try repository.acceptCapture(.init(envelope: capture(requestID: "concurrent-\(index)", key: "concurrent-\(index)", url: "https://concurrent.example/\(index)", body: "body-\(index)"), receivedAtMilliseconds: Int64(index)))
          }
        } catch { state.record(error) }
      }
      for reader in 0..<8 {
        ready.enter(); workers.enter()
        queue.async {
          ready.leave(); gate.wait(); writerStarted.wait(); defer { workers.leave() }
          do {
            for _ in 0..<200 where !state.isCancelled {
              _ = try repository.historyPage(limit: 20, after: nil)
              state.readerObserved(writerActive: state.writerIsActive)
            }
          } catch { state.record(error) }
          _ = reader
        }
      }
      XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
      for _ in 0..<9 { gate.signal() }
      let completed = workers.wait(timeout: .now() + 10)
      if completed != .success {
        state.cancel()
        for _ in 0..<9 { gate.signal() }
        for _ in 0..<8 { writerStarted.signal() }
        let drained = workers.wait(timeout: .now() + 3)
        XCTAssertEqual(drained, .success, "workers must drain beyond the configured 2-second SQLite busy timeout")
      }
      XCTAssertEqual(completed, .success)
      XCTAssertTrue(state.errors.isEmpty)
      XCTAssertTrue(state.overlapObserved)
      XCTAssertEqual(try DatabaseMaintenance(database: repository.database).counts().tasks, writes)
    }
  }

  func testTimedOutConcurrentWorkersDrainAfterTwoSecondBusyTimeout() throws {
    try withTemporaryLocation { location in
      let locker = try GRDBHistoryRepository.open(at: location)
      let accepted = try locker.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let contender = try GRDBHistoryRepository.open(at: location)
      defer { try? locker.database.close(); try? contender.database.close() }
      let queue = DispatchQueue(label: "history-timeout-cleanup", attributes: .concurrent)
      let workers = DispatchGroup(), lockHeld = DispatchSemaphore(value: 0), releaseLock = DispatchSemaphore(value: 0)
      let observations = LockedRaceObservations<AcceptCaptureResult>()

      workers.enter()
      queue.async {
        defer { workers.leave() }
        do {
          try locker.database.write { db in
            try db.execute(sql: "UPDATE tasks SET updated_at_ms = updated_at_ms WHERE id = ?", arguments: [accepted.taskID.rawValue])
            lockHeld.signal()
            _ = releaseLock.wait(timeout: .now() + 3)
          }
        } catch let failure as RepositoryFailure { observations.append(.failure(failure)) }
        catch { observations.append(.failure(.unavailable)) }
      }
      XCTAssertEqual(lockHeld.wait(timeout: .now() + 1), .success)

      workers.enter()
      queue.async {
        defer { workers.leave() }
        do {
          observations.append(.success(try contender.acceptCapture(.init(envelope: capture(requestID: "busy", key: "busy", url: "https://busy.example/", body: "busy"), receivedAtMilliseconds: 2))))
        } catch let failure as RepositoryFailure { observations.append(.failure(failure)) }
        catch { observations.append(.failure(.unavailable)) }
      }

      XCTAssertEqual(workers.wait(timeout: .now() + 0.1), .timedOut)
      Thread.sleep(forTimeInterval: 2.1)
      releaseLock.signal()
      XCTAssertEqual(workers.wait(timeout: .now() + 3), .success, "bounded cleanup must exceed SQLite's 2-second busy timeout and close every worker")
    }
  }
}

private extension Array {
  var single: Element? { count == 1 ? first : nil }
}

private final class ConcurrencyWitness: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false, overlap = false, cancelled = false
  private var recorded: [Error] = []
  func writerStarted() { lock.withLock { active = true } }
  func writerFinished() { lock.withLock { active = false } }
  var writerIsActive: Bool { lock.withLock { active } }
  func readerObserved(writerActive: Bool) { if writerActive { lock.withLock { overlap = true } } }
  func record(_ error: Error) { lock.withLock { recorded.append(error) } }
  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  var overlapObserved: Bool { lock.withLock { overlap } }
  var errors: [Error] { lock.withLock { recorded } }
}

private enum RaceObservation<Value: Sendable>: Sendable {
  case success(Value)
  case failure(RepositoryFailure)
}

private final class LockedRaceObservations<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RaceObservation<Value>] = []
  func append(_ observation: RaceObservation<Value>) { lock.withLock { storage.append(observation) } }
  var values: [RaceObservation<Value>] { lock.withLock { storage } }
}

private func raceTwo<Value: Sendable>(
  _ first: @escaping @Sendable () throws -> Value,
  _ second: @escaping @Sendable () throws -> Value
) throws -> [RaceObservation<Value>] {
  let queue = DispatchQueue(label: "history-two-pool-race", attributes: .concurrent)
  let ready = DispatchGroup(), workers = DispatchGroup(), gate = DispatchSemaphore(value: 0)
  let observations = LockedRaceObservations<Value>()
  for operation in [first, second] {
    ready.enter(); workers.enter()
    queue.async {
      ready.leave(); gate.wait(); defer { workers.leave() }
      do { observations.append(.success(try operation())) }
      catch let failure as RepositoryFailure { observations.append(.failure(failure)) }
      catch { observations.append(.failure(.unavailable)) }
    }
  }
  guard ready.wait(timeout: .now() + 2) == .success else { throw RepositoryFailure.unavailable }
  gate.signal(); gate.signal()
  guard workers.wait(timeout: .now() + 10) == .success else { throw RepositoryFailure.unavailable }
  return observations.values
}

private func capture(requestID: String = "request", key: String? = "delivery", url: String = "https://example.test/article", body: String = "fixture body", characterCount: Int? = nil, title: String? = "Fixture") -> CaptureEnvelopeV1 {
  CaptureEnvelopeV1(version: 1, requestId: requestID, createdAt: "2026-07-15T04:00:00Z", idempotencyKey: key, source: .init(kind: "browser_capture", url: url, title: title, platform: "generic"), capture: .init(method: "rendered_dom", text: body, characterCount: characterCount ?? body.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"), evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false))
}

private func withRepository(dependencies: PersistenceDependencies = .live, _ body: (GRDBHistoryRepository, LocalDatabaseLocation) throws -> Void) throws {
  try withTemporaryLocation { location in
    let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
    defer { try? repository.database.close() }
    try body(repository, location)
  }
}

private func withTemporaryLocation(createDirectory: Bool = true, _ body: (LocalDatabaseLocation) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-history-tests-\(UUID().uuidString)", isDirectory: true)
  let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
  if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
  defer { try? FileManager.default.removeItem(at: root) }
  try body(LocalDatabaseLocation(directoryURL: directory))
}
