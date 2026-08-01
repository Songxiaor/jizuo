import Foundation
import XCTest
import GRDB
import LinkDigestCore
@testable import LinkDigestPersistence

final class HistoryMigrationAndFaultTests: XCTestCase {
  func testContainsCanonicalURLUsesExactVersionedCanonicalKey() throws {
    try withRepository { repository, _ in
      try repository.database.write { db in
        try db.execute(
          sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, ?, 1, 1)",
          arguments: ["11111111-1111-1111-1111-111111111111", "https://example.test/article", CanonicalURL.version]
        )
      }
      XCTAssertTrue(try repository.containsCanonicalURL(CanonicalURL("https://EXAMPLE.test/article#fragment")))
      XCTAssertFalse(try repository.containsCanonicalURL(CanonicalURL("https://example.test/article?different=1")))
    }
  }

  func testEmptyDatabaseMigratesDirectlyTo008AndRejectsExtraHyphenUUIDs() throws {
    try withRepository { repository, _ in
      XCTAssertEqual(repository.accessMode, .writable)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      let sql = try repository.database.read { db in
        try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_schema WHERE type = 'table' AND name IN ('tasks','content_snapshots','runs','artifacts','capture_deliveries','tags','task_tags','media_assets','media_transcription_evidence','task_transcription_attempts','task_transcription_evidence')")
      }
      XCTAssertEqual(sql.count, 11)
      for row in sql where ["tasks", "content_snapshots", "runs", "artifacts"].contains(row["name"] as String) {
        let tableSQL: String = row["sql"]
        XCTAssertTrue(tableSQL.contains("WITHOUT ROWID"))
        XCTAssertTrue(tableSQL.contains("length(replace(id, '-', '')) = 32"))
        XCTAssertTrue(tableSQL.contains("replace(id, '-', '') NOT GLOB '*[^0-9a-f]*'"))
      }
      let snapshotSQL: String = sql.first { ($0["name"] as String) == "content_snapshots" }!["sql"]
      XCTAssertFalse(snapshotSQL.contains("length(body_text)"))
      let taskTagsSQL: String = sql.first { ($0["name"] as String) == "task_tags" }!["sql"]
      XCTAssertTrue(taskTagsSQL.contains("REFERENCES tasks(id) ON DELETE CASCADE"))
      let evidenceSQL: String = sql.first { ($0["name"] as String) == "media_transcription_evidence" }!["sql"]
      XCTAssertTrue(evidenceSQL.contains("REFERENCES media_assets(id, task_id) ON DELETE CASCADE"))
      XCTAssertTrue(evidenceSQL.contains("REFERENCES content_snapshots(task_id, id) ON DELETE CASCADE"))
      XCTAssertFalse(evidenceSQL.contains("body_text"))
      XCTAssertFalse(evidenceSQL.contains("relative_path"))
      XCTAssertFalse(evidenceSQL.contains("source_url"))
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

  func testExistingVersionOneDatabaseMigratesForwardWithoutLosingTasks() throws {
    try withTemporaryLocation { location in
      let legacy = try DatabaseQueue(path: location.databaseURL.path)
      try legacy.write { db in
        try Migration001.apply(to: db, beforeCommit: {})
        try db.execute(sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, 1, 1)", arguments: ["11111111-1111-1111-1111-111111111111", "https://example.test/legacy"])
      }
      try legacy.close()

      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      XCTAssertEqual(try repository.historyPage(limit: 10, after: nil).rows.map(\.canonicalURL), ["https://example.test/legacy"])
      XCTAssertEqual(try repository.allTags(), [])
    }
  }

  func testExistingVersionThreeDatabaseMigratesTo004WithoutLosingTasks() throws {
    try withTemporaryLocation { location in
      let versionThree = try DatabaseQueue(path: location.databaseURL.path)
      try versionThree.write { db in
        try Migration001.apply(to: db, beforeCommit: {})
        try Migration002.apply(to: db)
        try Migration003.apply(to: db)
        try db.execute(
          sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, ?, 1, 1, 1)",
          arguments: ["33333333-3333-3333-3333-333333333333", "https://example.test/version-three"]
        )
        try db.execute(
          sql: "INSERT INTO media_assets (id, task_id, relative_path, content_sha256, byte_size, platform, transcription_status, created_at_ms) VALUES (?, ?, ?, ?, 1, 'fixture', 'none', 2)",
          arguments: [
            "44444444-4444-4444-4444-444444444444",
            "33333333-3333-3333-3333-333333333333",
            "\(String(repeating: "4", count: 64)).mp4",
            String(repeating: "4", count: 64),
          ]
        )
      }
      try versionThree.close()

      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      XCTAssertEqual(
        try repository.historyPage(limit: 10, after: nil).rows.map(\.canonicalURL),
        ["https://example.test/version-three"]
      )
      XCTAssertEqual(
        try repository.database.read {
          try String.fetchOne($0, sql: "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = 'media_transcription_evidence'")
        },
        "media_transcription_evidence"
      )
      let migratedMedia = try repository.database.read { db in
        try Row.fetchOne(db, sql: "SELECT transcription_status, transcription_attempt_generation, file_bookmark FROM media_assets")
      }
      XCTAssertEqual(migratedMedia?["transcription_status"] as String?, "none")
      XCTAssertNil(migratedMedia?["transcription_attempt_generation"] as Int64?)
      XCTAssertNil(migratedMedia?["file_bookmark"] as Data?)
    }
  }

  func test007MigratesTo008WithoutRebuildingForeignKeyGraphOrLosingRows() throws {
    try withTemporaryLocation { location in
      let versionSeven = try DatabaseQueue(path: location.databaseURL.path)
      let taskID = "11111111-1111-1111-1111-111111111111"
      let snapshotID = "22222222-2222-2222-2222-222222222222"
      let runID = "33333333-3333-3333-3333-333333333333"
      let mediaID = "44444444-4444-4444-4444-444444444444"
      let body = "legacy version seven"
      try versionSeven.write { db in
        try Migration001.apply(to: db, beforeCommit: {})
        try Migration002.apply(to: db)
        try Migration003.apply(to: db)
        try Migration004.apply(to: db)
        try Migration005.apply(to: db)
        try Migration006.apply(to: db)
        try Migration007.apply(to: db)
        try db.execute(
          sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, 'https://example.test/v7', 1, 1, 1)",
          arguments: [taskID]
        )
        try db.execute(
          sql: "INSERT INTO content_snapshots (id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title, platform, capture_method, completeness, body_text, character_count, body_sha256, source_label, used_cookie) VALUES (?, ?, 1, 1, 1, 'browser_capture', 'https://example.test/v7', 'V7', 'generic', 'rendered_dom', 'full_article', ?, ?, ?, 'Current page DOM', 0)",
          arguments: [snapshotID, taskID, body, body.unicodeScalars.count, SHA256CaptureFingerprinter().bodySHA256(body)]
        )
        try db.execute(
          sql: "INSERT INTO capture_deliveries (delivery_key, capture_contract_version, request_id, payload_sha256, task_id, snapshot_id, received_at_ms) VALUES ('capture:v1:req:v7', 1, 'v7', ?, ?, ?, 1)",
          arguments: [String(repeating: "a", count: 64), taskID, snapshotID]
        )
        try db.execute(
          sql: "INSERT INTO runs (id, task_id, snapshot_id, idempotency_key, kind, status, created_at_ms) VALUES (?, ?, ?, 'v7-run', 'summarize', 'completed', 1)",
          arguments: [runID, taskID, snapshotID]
        )
        try db.execute(
          sql: "INSERT INTO media_assets (id, task_id, snapshot_id, relative_path, content_sha256, byte_size, platform, transcription_status, created_at_ms) VALUES (?, ?, ?, ?, ?, 1, 'fixture', 'none', 1)",
          arguments: [mediaID, taskID, snapshotID, "\(String(repeating: "b", count: 64)).mp4", String(repeating: "b", count: 64)]
        )
      }
      try versionSeven.close()

      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT used_cookie_v2 FROM content_snapshots") }, 0)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM runs") }, 1)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_assets") }, 1)
      XCTAssertTrue(try repository.database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
      XCTAssertFalse(try repository.detail(taskID: TaskID(taskID)!).snapshots[0].usedCookie)
    }
  }

  func testV2CookieEvidenceRoundTripsTrueAndFalseWithoutChangingLegacyColumn() throws {
    try withRepository { repository, _ in
      let falseEnvelope = v2Capture(
        media: v2Media(), requestID: "cookie-false", key: "cookie-false",
        url: "https://example.test/cookie-false", body: "false evidence"
      )
      let falseAccepted = try repository.acceptCapture(.init(envelope: falseEnvelope, receivedAtMilliseconds: 1))
      var trueEnvelope = v2Capture(
        media: v2Media(), requestID: "cookie-true", key: "cookie-true",
        url: "https://www.douyin.com/video/7655224917603994914", body: "true evidence"
      )
      trueEnvelope = CaptureEnvelopeV2(
        requestId: trueEnvelope.requestId,
        createdAt: trueEnvelope.createdAt,
        idempotencyKey: trueEnvelope.idempotencyKey,
        source: trueEnvelope.source,
        capture: trueEnvelope.capture,
        evidence: .init(sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true),
        media: trueEnvelope.media
      )
      let trueAccepted = try repository.acceptCapture(.init(envelope: trueEnvelope, receivedAtMilliseconds: 2))

      XCTAssertFalse(try repository.detail(taskID: falseAccepted.taskID).snapshots[0].usedCookie)
      let trueSnapshot = try repository.detail(taskID: trueAccepted.taskID).snapshots[0]
      XCTAssertTrue(trueSnapshot.usedCookie)
      XCTAssertEqual(trueSnapshot.sourceLabel, "Current page DOM + same-origin session detail")
      let stored = try repository.database.read { db in
        try Row.fetchOne(db, sql: "SELECT used_cookie, used_cookie_v2 FROM content_snapshots WHERE task_id = ?", arguments: [trueAccepted.taskID.rawValue])
      }
      XCTAssertEqual(stored?["used_cookie"] as Int?, 0)
      XCTAssertEqual(stored?["used_cookie_v2"] as Int?, 1)
    }
  }

  func testSameBodySessionFallbackUpgradesExistingSnapshotEvidenceWithoutDuplicatingBody() throws {
    try withRepository { repository, _ in
      let url = "https://www.douyin.com/video/7655224917603994914"
      let falseEnvelope = v2Capture(
        media: v2Media(platform: "douyin"), requestID: "same-body-false", key: "same-body-false",
        url: url, body: "same captured body"
      )
      let first = try repository.acceptCapture(.init(envelope: falseEnvelope, receivedAtMilliseconds: 1))
      let trueEnvelope = CaptureEnvelopeV2(
        requestId: "same-body-true",
        createdAt: falseEnvelope.createdAt,
        idempotencyKey: "same-body-true",
        source: falseEnvelope.source,
        capture: falseEnvelope.capture,
        evidence: .init(sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true),
        media: falseEnvelope.media
      )
      let second = try repository.acceptCapture(.init(envelope: trueEnvelope, receivedAtMilliseconds: 2))

      XCTAssertEqual(second.snapshotID, first.snapshotID)
      XCTAssertFalse(second.snapshotWasCreated)
      let snapshots = try repository.detail(taskID: first.taskID).snapshots
      XCTAssertEqual(snapshots.count, 1)
      XCTAssertTrue(snapshots[0].usedCookie)
      XCTAssertEqual(snapshots[0].sourceLabel, "Current page DOM + same-origin session detail")
    }
  }

  func test004SchemaIsAppendOnlyProviderNeutralAndAttemptIdempotent() throws {
    try withRepository { repository, _ in
      let columns = try repository.database.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(media_transcription_evidence)")
          .map { $0["name"] as String }
      }
      XCTAssertEqual(Set(columns), Set([
        "id", "media_id", "task_id", "snapshot_id", "attempt_id", "attempt_generation", "source", "engine",
        "provider", "model", "locale_identifier", "language", "completed_at_ms",
      ]))
      let tableSQL = try repository.database.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'media_transcription_evidence'"
        )
      }
      XCTAssertTrue(tableSQL?.contains("UNIQUE (media_id, attempt_id)") == true)
      XCTAssertTrue(tableSQL?.contains("UNIQUE (task_id, attempt_generation)") == true)
      XCTAssertFalse(tableSQL?.contains("source = 'on_device'") == true)
      XCTAssertFalse(tableSQL?.contains("engine = 'apple_speech_analyzer'") == true)
    }
  }

  func test008ReopenIsIdempotentAndFutureSchemaIsReadOnly() throws {
    try withTemporaryLocation { location in
      let first = try LocalDatabase.open(at: location)
      try first.write { try $0.execute(sql: "PRAGMA user_version = \(LocalDatabase.latestSchemaVersion + 1)") }
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
      try upgrader.write { try $0.execute(sql: "PRAGMA user_version = \(LocalDatabase.latestSchemaVersion + 1)") }
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
      XCTAssertEqual(try recovered.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      try recovered.close()
    }
  }

  func test004MigratesTo005PreservingV1RowsAndAcceptingV2Provenance() throws {
    try withTemporaryLocation { location in
      let versionFour = try DatabaseQueue(path: location.databaseURL.path)
      let v1 = capture(requestID: "migration-v1", key: "migration-v1", body: "legacy body")
      let legacyTask = "11111111-1111-1111-1111-111111111111"
      let legacySnapshot = "22222222-2222-2222-2222-222222222222"
      try versionFour.write { db in
        try Migration001.apply(to: db, beforeCommit: {})
        try Migration002.apply(to: db)
        try Migration003.apply(to: db)
        try Migration004.apply(to: db)
        try db.execute(sql: "INSERT INTO tasks (id, canonical_url, canonicalization_version, created_at_ms, updated_at_ms) VALUES (?, 'https://example.test/legacy', 1, 1, 1)", arguments: [legacyTask])
        try db.execute(sql: "INSERT INTO content_snapshots (id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title, platform, capture_method, completeness, body_text, character_count, body_sha256, source_label, used_cookie) VALUES (?, ?, 1, 1, 1, 'browser_capture', 'https://example.test/legacy', 'Legacy', 'generic', 'rendered_dom', 'full_article', 'legacy body', 11, ?, 'Fixture DOM', 0)", arguments: [legacySnapshot, legacyTask, SHA256CaptureFingerprinter().bodySHA256("legacy body")])
        try db.execute(sql: "INSERT INTO capture_deliveries (delivery_key, capture_contract_version, request_id, payload_sha256, task_id, snapshot_id, received_at_ms) VALUES ('capture:v1:id:migration-v1', 1, ?, ?, ?, ?, 1)", arguments: [v1.requestId, SHA256CaptureFingerprinter().semanticPayloadSHA256(v1), legacyTask, legacySnapshot])
      }
      try versionFour.close()

      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, LocalDatabase.latestSchemaVersion)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT capture_contract_version FROM capture_deliveries WHERE request_id = ?", arguments: [v1.requestId]) }, 1)
      let legacyReplay = try repository.acceptCapture(.init(envelope: v1, receivedAtMilliseconds: 2))
      XCTAssertTrue(legacyReplay.deliveryWasReplayed)
      XCTAssertEqual(legacyReplay.taskID.rawValue, legacyTask)

      let envelopeV2 = v2Capture(
        media: v2Media(),
        requestID: "migration-v2",
        key: "migration-v2",
        url: "https://example.test/v2",
        body: "version two"
      )
      let acceptedV2 = try repository.acceptCapture(.init(envelope: envelopeV2, receivedAtMilliseconds: 3))
      let replayedV2 = try repository.acceptCapture(.init(envelope: envelopeV2, receivedAtMilliseconds: 4))
      XCTAssertEqual(replayedV2.taskID, acceptedV2.taskID)
      XCTAssertTrue(replayedV2.deliveryWasReplayed)
      XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT capture_contract_version FROM capture_deliveries WHERE request_id = 'migration-v2'") }, 2)
    }
  }

  func testDetailHadMediaDescriptorTracksV2ContractNotPlatform() throws {
    try withRepository { repository, _ in
      let pureText = try repository.acceptCapture(
        .init(envelope: capture(requestID: "text-x", key: "text-x", url: "https://x.com/user/status/1", body: "text only post"), receivedAtMilliseconds: 1)
      )
      XCTAssertFalse(
        try repository.detail(taskID: pureText.taskID).hadMediaDescriptor,
        "V1 pure-text must not claim a media descriptor"
      )

      // X (and any platform) with V2 MediaDescriptor must surface the durable fact.
      let xVideo = try repository.acceptCapture(
        .init(
          envelope: v2Capture(
            media: v2Media(
              platform: "x",
              ephemeralPlaybackURL: "https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/clip.mp4"
            ),
            requestID: "x-video",
            key: "x-video",
            url: "https://x.com/user/status/2",
            body: "post with video"
          ),
          receivedAtMilliseconds: 2
        )
      )
      XCTAssertTrue(try repository.detail(taskID: xVideo.taskID).hadMediaDescriptor)

      let genericVideo = try repository.acceptCapture(
        .init(
          envelope: v2Capture(
            media: v2Media(platform: "generic"),
            requestID: "generic-video",
            key: "generic-video",
            url: "https://example.test/watch/3",
            body: "generic page with video"
          ),
          receivedAtMilliseconds: 3
        )
      )
      XCTAssertTrue(try repository.detail(taskID: genericVideo.taskID).hadMediaDescriptor)
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

final class HistoryTagPersistenceTests: XCTestCase {
  func testNewCaptureGetsOneDeterministicSourceTagAndReplayDoesNotDuplicateIt() throws {
    try withRepository { repository, _ in
      let value = CaptureEnvelopeV1(
        version: 1, requestId: "wechat-source", createdAt: "2026-07-15T04:00:00Z", idempotencyKey: "wechat-source",
        source: .init(kind: "browser_capture", url: "https://mp.weixin.qq.com/s/example", title: "Fixture", platform: "wechat"),
        capture: .init(method: "rendered_dom", text: "fixture body", characterCount: 12, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"),
        evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
      )
      let accepted = try repository.acceptCapture(.init(envelope: value, receivedAtMilliseconds: 1))
      let replay = try repository.acceptCapture(.init(envelope: value, receivedAtMilliseconds: 2))
      // Platform is first-class navigation state; captures no longer attach
      // automatic platform tags.
      XCTAssertTrue(try repository.detail(taskID: accepted.taskID).tags.isEmpty)
      XCTAssertEqual(replay.taskID, accepted.taskID)
      XCTAssertTrue(try repository.allTags().isEmpty)
    }
  }

  func testNormalizationDeduplicationAndPerTaskLimitAreEnforced() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let tooLong = String(repeating: "长", count: 21)
      let firstTen = (1 ... 12).map { "标签\($0)" }
      let assigned = try repository.addTags(["  Swift  ", "swift", "", tooLong] + firstTen, to: accepted.taskID)

      XCTAssertEqual(assigned.map(\.name), ["Swift"] + Array(firstTen.prefix(9)))
      XCTAssertEqual(assigned.count, HistoryTagNormalizer.maximumTagsPerTask)
      XCTAssertEqual(assigned.filter { $0.normalizedName == "swift" }.count, 1)
      XCTAssertEqual(try repository.allTags().count, HistoryTagNormalizer.maximumTagsPerTask)
    }
  }

  func testSQLIntersectionFilteringAndTaskDeletionCleanAssociations() throws {
    try withRepository { repository, _ in
      let swiftAI = try repository.acceptCapture(.init(envelope: capture(requestID: "tag-one", key: "tag-one", url: "https://example.test/tag-one", body: "one"), receivedAtMilliseconds: 10))
      let swiftOnly = try repository.acceptCapture(.init(envelope: capture(requestID: "tag-two", key: "tag-two", url: "https://example.test/tag-two", body: "two"), receivedAtMilliseconds: 20))
      let aiOnly = try repository.acceptCapture(.init(envelope: capture(requestID: "tag-three", key: "tag-three", url: "https://example.test/tag-three", body: "three"), receivedAtMilliseconds: 30))
      _ = try repository.addTags(["Swift", "AI"], to: swiftAI.taskID)
      _ = try repository.addTags(["Swift"], to: swiftOnly.taskID)
      _ = try repository.addTags(["AI"], to: aiOnly.taskID)

      XCTAssertEqual(
        try repository.historyPage(limit: 20, after: nil, filter: .init(tagNames: ["swift"])).rows.map(\.taskID),
        [swiftOnly.taskID, swiftAI.taskID]
      )
      XCTAssertEqual(
        try repository.historyPage(limit: 20, after: nil, filter: .init(tagNames: ["AI", "SWIFT"])).rows.map(\.taskID),
        [swiftAI.taskID],
        "multiple tags are SQL intersection filters, not in-memory union filters"
      )
      XCTAssertEqual(
        try repository.historyPage(limit: 20, after: nil, filter: .init(tagNames: ["Swift"], searchText: "tag-two")).rows.map(\.taskID),
        [swiftOnly.taskID],
        "search remains an independent SQL predicate alongside tag filters"
      )
      XCTAssertTrue(try repository.historyPage(limit: 20, after: nil, filter: .init(tagNames: ["missing"])).rows.isEmpty)

      try repository.deleteTask(taskID: swiftAI.taskID)
      let associations = try repository.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_tags WHERE task_id = ?", arguments: [swiftAI.taskID.rawValue])
      }
      XCTAssertEqual(associations, 0)
      XCTAssertEqual(try repository.allTags().map(\.name), ["AI", "Swift"])
    }
  }

  func testNavigationCountsAndPlatformTagSearchFiltersStayInsideSQLite() throws {
    try withRepository { repository, _ in
      let now = Int64(Date().timeIntervalSince1970 * 1_000)
      let summarized = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "nav-summarized", key: "nav-summarized",
          url: "https://www2.douyin.com/video/1", body: "短视频正文", title: "短视频"
        ),
        receivedAtMilliseconds: now
      ))
      let target = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "nav-target", key: "nav-target",
          url: "https://m.example.test/article", body: "目标正文", title: "Needle 标题"
        ),
        receivedAtMilliseconds: now + 1
      ))
      _ = try repository.addTags(["专题"], to: target.taskID)
      let run = try repository.createRun(.init(
        taskID: summarized.taskID,
        snapshotID: summarized.snapshotID,
        idempotencyKey: "nav-complete",
        kind: .summarize,
        createdAtMilliseconds: now + 2
      ))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: now + 3, provider: .init()))
      try repository.finishRun(.init(
        runID: run.runID,
        status: .completed,
        finishedAtMilliseconds: now + 4,
        artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "总结完成")
      ))

      let counts = try repository.navigationCounts()
      XCTAssertEqual(counts.all, 2)
      XCTAssertEqual(counts.recent, 2)
      XCTAssertEqual(counts.unsummarized, 1, "NOT EXISTS must exclude any task that has a successful artifact")
      XCTAssertEqual(counts.platforms, [
        .init(host: "douyin.com", count: 1),
        .init(host: "example.test", count: 1),
      ])
      XCTAssertEqual(counts.tags, [.init(tag: HistoryTag(rawValue: "专题")!, count: 1)])

      let combined = try repository.historyPage(
        limit: 20,
        after: nil,
        filter: .init(
          tagNames: ["专题"],
          hosts: ["www.example.test"],
          scope: .recent,
          searchText: "Needle"
        )
      )
      XCTAssertEqual(combined.rows.map(\.taskID), [target.taskID], "host + tag + scope + search are SQL AND predicates")
      XCTAssertEqual(
        try repository.historyPage(limit: 20, after: nil, filter: .init(scope: .unsummarized)).rows.map(\.taskID),
        [target.taskID]
      )
    }
  }

  func testManualRemovalAndExportProjectionIncludeTags() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      _ = try repository.addTags(["本地优先", "Swift"], to: accepted.taskID)
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.tags.map(\.name), ["Swift", "本地优先"])

      try repository.removeTag(normalizedName: "SWIFT", from: accepted.taskID)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).tags.map(\.name), ["本地优先"])
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).tags.map(\.name), ["本地优先"])
    }
  }
}

final class HistoryRepositoryCaptureTests: XCTestCase {
  func testPreexistingBrowserWireDeliveryReplaysAfterReopen() throws {
    try withTemporaryLocation { location in
      let envelope = capture(requestID: "legacy-request", key: "legacy-delivery", url: "https://example.test/legacy", body: "legacy body")
      let first = try GRDBHistoryRepository.open(at: location)
      let accepted = try first.acceptCapture(.init(envelope: envelope, receivedAtMilliseconds: 1))
      try first.database.close()

      // This row represents a database written before the manual-document
      // path existed. Reopening must preserve its capture:v1 key and digest.
      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      let replay = try reopened.acceptCapture(.init(envelope: envelope, receivedAtMilliseconds: 2))
      XCTAssertTrue(replay.deliveryWasReplayed)
      XCTAssertEqual(replay.taskID, accepted.taskID)
      XCTAssertEqual(replay.snapshotID, accepted.snapshotID)
    }
  }

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

  func testV2EverySafeMediaFieldConflictsWhileOnlyTransientFieldsReplay() throws {
    try withRepository { repository, _ in
      let safeMediaPairs: [(String, MediaDescriptor, MediaDescriptor)] = [
        ("kind", v2Media(kind: .directFile), v2Media(kind: .hls)),
        ("pageURL", v2Media(), v2Media(pageURL: "https://example.test/watch?page=safe-change")),
        ("canonicalURL", v2Media(), v2Media(canonicalURL: "https://example.test/watch/canonical-change")),
        ("platform", v2Media(), v2Media(platform: "douyin")),
        ("mimeType", v2Media(), v2Media(mimeType: "video/quicktime")),
        ("posterURL", v2Media(), v2Media(posterURL: "https://images.example.test/poster-safe-change.jpg")),
        ("durationSeconds", v2Media(), v2Media(durationSeconds: 99.5)),
        ("author", v2Media(), v2Media(author: "Safe Author Change")),
        ("transcriptionCapability", v2Media(), v2Media(transcriptionCapability: .conditional)),
        (
          "failureReason",
          v2Media(kind: .browserSessionOnly, ephemeralPlaybackURL: nil, failureReason: .unknown),
          v2Media(kind: .browserSessionOnly, ephemeralPlaybackURL: nil, failureReason: .multipleCandidates)
        ),
        ("candidateCount", v2Media(), v2Media(candidateCount: 3)),
        ("selectionReason", v2Media(), v2Media(selectionReason: .nearestViewportCenter)),
        ("playbackState", v2Media(), v2Media(playbackState: .playing)),
      ]
      for (index, pair) in safeMediaPairs.enumerated() {
        let key = "v2-safe-field-\(index)"
        let accepted = try repository.acceptCapture(.init(
          envelope: v2Capture(media: pair.1, requestID: key, key: key),
          receivedAtMilliseconds: Int64(20 + index * 2)
        ))
        XCTAssertThrowsError(try repository.acceptCapture(.init(
          envelope: v2Capture(media: pair.2, requestID: "transport-retry-\(index)", key: key),
          receivedAtMilliseconds: Int64(21 + index * 2)
        )), "safe media field \(pair.0) must conflict") {
          XCTAssertEqual($0 as? RepositoryFailure, .captureIdempotencyConflict)
        }
        XCTAssertFalse(accepted.deliveryWasReplayed)
      }

      let transientBase = v2Capture(
        media: v2Media(),
        requestID: "v2-transient-base",
        key: "v2-transient-only"
      )
      let accepted = try repository.acceptCapture(.init(
        envelope: transientBase,
        receivedAtMilliseconds: 60
      ))
      let transientOnly = v2Capture(media: v2Media(
        ephemeralPlaybackURL: "https://media.example.test/changed-signed-url.mp4",
        expiresAt: "2026-07-20T00:02:00Z"
      ), requestID: "v2-transient-retry", key: "v2-transient-only")
      let replay = try repository.acceptCapture(.init(
        envelope: transientOnly,
        receivedAtMilliseconds: 61
      ))
      XCTAssertTrue(replay.deliveryWasReplayed)
      XCTAssertEqual(replay.taskID, accepted.taskID)
    }
  }

  func testCaptureCommandConstructorsProduceClosedNonMixableProvenance() throws {
    let v1 = try AcceptCaptureCommand(envelope: capture(), receivedAtMilliseconds: 1)
    let v2 = try AcceptCaptureCommand(envelope: v2Capture(media: v2Media()), receivedAtMilliseconds: 2)
    let localDocument = CapturedDocument(
      requestID: "manual", createdAt: "2026-07-20T00:00:00Z", idempotencyKey: "manual",
      origin: .manualLink, url: "https://example.test/manual", title: "Manual", platform: "manual",
      method: "public_html", text: "manual body", completeness: "best_effort",
      capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "manual fixture"
    )
    let local = try AcceptCaptureCommand(document: localDocument, receivedAtMilliseconds: 3)

    XCTAssertEqual(v1.provenance.captureContractVersion, 1)
    XCTAssertTrue(v1.provenance.deliveryKey.hasPrefix("capture:v1:"))
    XCTAssertEqual(v2.provenance.captureContractVersion, 2)
    XCTAssertTrue(v2.provenance.deliveryKey.hasPrefix("capture:v2:"))
    XCTAssertEqual(local.provenance.captureContractVersion, 1)
    XCTAssertTrue(local.provenance.deliveryKey.hasPrefix("manual:v1:"))
    XCTAssertEqual(
      Set(Mirror(reflecting: v2).children.compactMap(\.label)),
      Set(["document", "provenance", "receivedAtMilliseconds"])
    )
  }

  func testPublicCaptureCommandFactoriesRejectInvalidWireAndBrowserDocumentManualization() throws {
    let validV1 = capture()
    let wrongVersionV1 = CaptureEnvelopeV1(
      version: 2,
      requestId: validV1.requestId,
      createdAt: validV1.createdAt,
      idempotencyKey: validV1.idempotencyKey,
      source: validV1.source,
      capture: validV1.capture,
      evidence: validV1.evidence,
      media: validV1.media
    )
    XCTAssertThrowsError(try AcceptCaptureCommand(
      envelope: wrongVersionV1,
      receivedAtMilliseconds: 4
    ))

    let invalidMediaV2 = v2Capture(media: v2Media(
      kind: .directFile,
      ephemeralPlaybackURL: nil
    ))
    XCTAssertThrowsError(try AcceptCaptureCommand(
      envelope: invalidMediaV2,
      receivedAtMilliseconds: 5
    ))

    let wrongVersionV2 = CaptureEnvelopeV2(
      version: 1,
      requestId: invalidMediaV2.requestId,
      createdAt: invalidMediaV2.createdAt,
      idempotencyKey: invalidMediaV2.idempotencyKey,
      source: invalidMediaV2.source,
      capture: invalidMediaV2.capture,
      evidence: invalidMediaV2.evidence,
      media: invalidMediaV2.media
    )
    XCTAssertThrowsError(try AcceptCaptureCommand(
      envelope: wrongVersionV2,
      receivedAtMilliseconds: 6
    ))

    XCTAssertThrowsError(try AcceptCaptureCommand(
      document: CapturedDocument(wire: validV1),
      receivedAtMilliseconds: 7
    ))
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
      let usage = RunUsageCost(inputTokens: nil, outputTokens: 7, totalTokens: nil, costAmountMicros: 1200, costCurrencyCode: "USD")
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

  func testHistoryRowReadsMetadataFromLatestSourceSnapshotNotLaterTranscription() throws {
    try withRepository { repository, _ in
      let source = "---\nauthor: \"来源作者\"\npublished: \"2026-07-20T00:00:00.000Z\"\n---\n\n" + String(repeating: "😀", count: 3_000)
      let accepted = try repository.acceptCapture(.init(envelope: capture(body: source), receivedAtMilliseconds: 1))
      let transcriptionID = ContentSnapshotID()
      try repository.database.write { db in
        let body = "转写正文"
        try db.execute(sql: """
          INSERT INTO content_snapshots (
            id, task_id, sequence, envelope_created_at_ms, captured_at_ms, source_kind, source_url, title,
            platform, capture_method, completeness, body_text, character_count, body_sha256, source_label,
            used_cookie, used_cookie_v2
          ) VALUES (?, ?, 2, 2, 2, 'local_transcription', ?, '转写', 'douyin', 'speech_analyzer_local', 'complete', CAST(? AS TEXT), ?, ?, '本机视频转写', 0, 0)
          """, arguments: [transcriptionID.rawValue, accepted.taskID.rawValue, "https://example.test/article", Data(body.utf8), body.unicodeScalars.count, SHA256CaptureFingerprinter().bodySHA256(body)])
      }

      let row = try XCTUnwrap(repository.historyPage(limit: 1, after: nil).rows.single)
      XCTAssertEqual(row.author, "来源作者")
      XCTAssertEqual(row.published, "2026-07-20T00:00:00.000Z")
      XCTAssertEqual(row.title, "Fixture")
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
      XCTAssertThrowsError(try injected.finishRun(.init(runID: run.runID, status: .completed, finishedAtMilliseconds: 4, artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: "must rollback"), usageCost: RunUsageCost(totalTokens: 9)))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
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

  func testBatchDeleteReportsMissingIDsWithoutLeavingOrphans() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(
        envelope: capture(requestID: "batch-delete-a", key: "batch-delete-a", url: "https://example.test/batch-a"),
        receivedAtMilliseconds: 1
      ))
      let second = try repository.acceptCapture(.init(
        envelope: capture(requestID: "batch-delete-b", key: "batch-delete-b", url: "https://example.test/batch-b"),
        receivedAtMilliseconds: 2
      ))
      let run = try repository.createRun(.init(
        taskID: first.taskID,
        snapshotID: first.snapshotID,
        idempotencyKey: "batch-delete-run",
        kind: .summarize,
        createdAtMilliseconds: 3
      ))
      try repository.markRunRunning(.init(runID: run.runID, startedAtMilliseconds: 4, provider: .init()))
      try repository.finishRun(.init(
        runID: run.runID,
        status: .completed,
        finishedAtMilliseconds: 5,
        artifact: .init(contentFormat: .plainText, completeness: .complete, bodyText: "done")
      ))
      let missing = TaskID()

      let result = try repository.deleteTasks(taskIDs: [first.taskID, missing])

      XCTAssertEqual(result.requestedTaskIDs, [first.taskID, missing].sorted { $0.rawValue < $1.rawValue })
      XCTAssertEqual(result.deletedTaskIDs, [first.taskID])
      XCTAssertEqual(result.failedTaskIDs, [missing])
      XCTAssertThrowsError(try repository.detail(taskID: first.taskID))
      XCTAssertNoThrow(try repository.detail(taskID: second.taskID))
      let remaining = try DatabaseMaintenance(database: repository.database).counts()
      XCTAssertEqual(remaining.tasks, 1)
      XCTAssertEqual(remaining.runs, 0)
      XCTAssertEqual(remaining.artifacts, 0)
    }
  }

  func testBatchDeleteRollsBackEveryTaskWhenSecondDeleteFails() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(
        envelope: capture(requestID: "batch-rollback-a", key: "batch-rollback-a", url: "https://example.test/rollback-a"),
        receivedAtMilliseconds: 1
      ))
      let second = try repository.acceptCapture(.init(
        envelope: capture(requestID: "batch-rollback-b", key: "batch-rollback-b", url: "https://example.test/rollback-b"),
        receivedAtMilliseconds: 2
      ))
      try repository.database.write { db in
        try db.execute(sql: """
          CREATE TRIGGER fail_second_batch_delete
          BEFORE DELETE ON tasks
          WHEN OLD.id = '\(second.taskID.rawValue)'
          BEGIN
            SELECT RAISE(ABORT, 'injected batch delete failure');
          END
          """)
      }

      XCTAssertThrowsError(try repository.deleteTasks(taskIDs: [first.taskID, second.taskID]))
      XCTAssertNoThrow(try repository.detail(taskID: first.taskID))
      XCTAssertNoThrow(try repository.detail(taskID: second.taskID))
      XCTAssertEqual(try DatabaseMaintenance(database: repository.database).counts().tasks, 2)
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

  /// 写连接必须保留 SQLite 默认的 autocheckpoint 阈值。
  ///
  /// 2026-07-27 之前这里是 `PRAGMA wal_autocheckpoint = 0`，配上生产代码零
  /// checkpoint 调用方，WAL 跨会话只增不减：实测 Syc 本机主库停在 364KB（7-19），
  /// WAL 却长到 12.9MB。旧注释以为「干净退出时 SQLite 会 checkpoint」兜得住，但
  /// App 的退出钩子从不调用 `LocalDatabase.close()`，那个前提根本没发生过。
  /// 这条断言钉住阈值不再被改回 0——它不报错、不崩溃，只有去量 WAL 文件才看得见。
  func testWritableConnectionKeepsSQLiteDefaultAutocheckpointThreshold() throws {
    try withRepository { repository, location in
      let threshold = try repository.database.read { db in
        try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint")
      }
      XCTAssertEqual(
        threshold, 1000,
        "写连接的 autocheckpoint 阈值不是 SQLite 默认的 1000；关掉它会让 WAL 跨会话单调增长")

      // 阈值只是配置，还要确认它真的会触发：写够页数后 WAL 不应无界增长。
      for index in 0..<400 {
        _ = try repository.acceptCapture(
          .init(
            envelope: capture(
              requestID: "autockpt-\(index)",
              key: "autockpt-\(index)",
              url: "https://autockpt.example/\(index)",
              body: String(repeating: "y", count: 4096)),
            receivedAtMilliseconds: Int64(index + 1)))
      }
      let mainSize = try FileManager.default
        .attributesOfItem(atPath: location.databaseURL.path)[.size] as? Int ?? 0
      // 判据是**主库有没有被写进去**，不是 WAL 文件有没有变小：PASSIVE checkpoint
      // 把帧合并进主库后会保留 WAL 文件原大小供复用，只有 TRUNCATE 才截断。第一版
      // 断言写成 `walSize < mainSize`，修复版自己就红了（WAL 3.88MB > 主库 2.19MB）
      // ——那是 SQLite 的正常行为，不是缺陷。
      // 实测：默认阈值下主库涨到约 2.19MB；把 autocheckpoint 关回 0 时主库停在初始
      // 大小，数据全积在 WAL 里，因此 1MB 这条线能干净区分两者。
      XCTAssertGreaterThan(
        mainSize, 1_000_000,
        "写入约 1.6MB 后主库只有 \(mainSize) 字节，说明 checkpoint 从未发生、数据全积在 WAL 里")
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

final class MediaTranscriptionPersistenceTests: XCTestCase {
  func testSameHashReplayRepairsLocationWithoutReplacingIdentityOrTranscriptionState() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let sha = String(repeating: "e", count: 64)
      let original = MediaAsset(
        taskID: first.taskID,
        snapshotID: first.snapshotID,
        relativePath: "\(sha).mov",
        fileBookmark: Data("stale-bookmark".utf8),
        contentSHA256: sha,
        byteSize: 1_024,
        durationSeconds: 10,
        platform: "old-platform",
        author: "old-author",
        createdAtMilliseconds: 2
      )
      try repository.attachMedia(.init(asset: original))
      try repository.database.write { db in
        try db.execute(
          sql: "UPDATE media_assets SET transcription_status = 'completed' WHERE id = ?",
          arguments: [original.id]
        )
      }
      let second = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "repair-request",
          key: "repair-delivery",
          body: "new snapshot body"
        ),
        receivedAtMilliseconds: 3
      ))
      XCTAssertEqual(second.taskID, first.taskID)
      XCTAssertNotEqual(second.snapshotID, first.snapshotID)

      let repaired = MediaAsset(
        taskID: first.taskID,
        snapshotID: second.snapshotID,
        relativePath: "\(sha).mp4",
        fileBookmark: Data("fresh-bookmark".utf8),
        contentSHA256: sha,
        byteSize: 4_096,
        durationSeconds: 25,
        platform: "douyin",
        author: "new-author",
        createdAtMilliseconds: 4
      )
      try repository.attachMedia(.init(asset: repaired))
      try repository.attachMedia(.init(asset: repaired))

      let stored = try XCTUnwrap(try repository.mediaAsset(taskID: first.taskID))
      XCTAssertEqual(stored.id, original.id, "repair must preserve durable media identity")
      XCTAssertEqual(stored.snapshotID, second.snapshotID)
      XCTAssertEqual(stored.relativePath, repaired.relativePath)
      XCTAssertEqual(stored.fileBookmark, repaired.fileBookmark)
      XCTAssertEqual(stored.byteSize, repaired.byteSize)
      XCTAssertEqual(stored.durationSeconds, repaired.durationSeconds)
      XCTAssertEqual(stored.platform, repaired.platform)
      XCTAssertEqual(stored.author, repaired.author)
      XCTAssertEqual(stored.transcriptionStatus, .completed)
      XCTAssertEqual(stored.createdAtMilliseconds, original.createdAtMilliseconds)
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne(
          $0,
          sql: "SELECT COUNT(*) FROM media_assets WHERE task_id = ? AND content_sha256 = ?",
          arguments: [first.taskID.rawValue, sha]
        )
      }, 1)
    }
  }

  func testAttachMediaRoundTripsOptionalFileBookmark() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let bookmark = Data("opaque-security-scope-bookmark".utf8)
      let asset = MediaAsset(
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        relativePath: "\(String(repeating: "d", count: 64)).mp4",
        fileBookmark: bookmark,
        contentSHA256: String(repeating: "d", count: 64),
        byteSize: 2_048,
        platform: "fixture",
        createdAtMilliseconds: 2
      )

      try repository.attachMedia(.init(asset: asset))

      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.fileBookmark, bookmark)
    }
  }

  func testAttachMediaRejectsCompletedAndLeavesNoRow() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let completed = MediaAsset(
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        relativePath: "\(String(repeating: "c", count: 64)).mp4",
        contentSHA256: String(repeating: "c", count: 64),
        byteSize: 2_048,
        platform: "douyin",
        transcriptionStatus: .completed,
        createdAtMilliseconds: 2
      )

      XCTAssertThrowsError(try repository.attachMedia(.init(asset: completed))) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidStateTransition)
      }
      XCTAssertNil(try repository.mediaAsset(taskID: accepted.taskID))
    }
  }

  func testStatusMutationContractCannotExpressPendingOrCompleted() {
    XCTAssertEqual(
      TranscriptionStatusMutation.allCases.map(\.rawValue),
      ["running", "none", "failed"]
    )
  }

  func testConsecutiveBeginAllocatesStrictlyIncreasingDatabaseGenerations() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let mediaID = try XCTUnwrap(try repository.mediaAsset(taskID: accepted.taskID)?.id)

      let first = try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)
      let second = try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)

      XCTAssertEqual(first.mediaID, mediaID)
      XCTAssertEqual(first.generation, 1)
      XCTAssertEqual(second.generation, 2)
      XCTAssertNotEqual(first.id, second.id)
      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus, .pending)
      XCTAssertEqual(
        try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: first, status: .running),
        .stale
      )
      XCTAssertEqual(
        try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: second, status: .running),
        .applied
      )
    }
  }

  func testGenerationOverflowFailsClosedWithoutReplacingOwner() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let mediaID = try XCTUnwrap(try repository.mediaAsset(taskID: accepted.taskID)?.id)
      try repository.database.write { db in
        try db.execute(
          sql: "UPDATE media_assets SET transcription_attempt_id = ?, transcription_attempt_generation = ?, transcription_status = 'pending' WHERE id = ? AND task_id = ?",
          arguments: ["ffffffff-ffff-ffff-ffff-ffffffffffff", Int64.max, mediaID, accepted.taskID.rawValue]
        )
      }

      XCTAssertThrowsError(try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)) {
        XCTAssertEqual($0 as? RepositoryFailure, .invalidStateTransition)
      }
      let owner = try repository.database.read { db in
        try Row.fetchOne(db, sql: "SELECT transcription_attempt_id, transcription_attempt_generation, transcription_status FROM media_assets WHERE id = ?", arguments: [mediaID])
      }
      XCTAssertEqual(owner?["transcription_attempt_id"] as String?, "ffffffff-ffff-ffff-ffff-ffffffffffff")
      XCTAssertEqual(owner?["transcription_attempt_generation"] as Int64?, Int64.max)
      XCTAssertEqual(owner?["transcription_status"] as String?, "pending")
    }
  }

  func testTwoRepositoriesConcurrentBeginAllocateUniqueMonotonicGenerations() throws {
    try withTemporaryLocation { location in
      let firstRepository = try GRDBHistoryRepository.open(at: location)
      defer { try? firstRepository.database.close() }
      let accepted = try firstRepository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try firstRepository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let mediaID = try XCTUnwrap(try firstRepository.mediaAsset(taskID: accepted.taskID)?.id)
      let secondRepository = try GRDBHistoryRepository.open(at: location)
      defer { try? secondRepository.database.close() }
      let recorder = TranscriptionAttemptRecorder()
      let group = DispatchGroup()

      for repository in [firstRepository, secondRepository] {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          defer { group.leave() }
          do {
            recorder.record(.success(try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)))
          } catch let failure as RepositoryFailure {
            recorder.record(.failure(failure))
          } catch {
            recorder.record(.failure(.unavailable))
          }
        }
      }

      XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
      XCTAssertEqual(recorder.failures, [])
      XCTAssertEqual(recorder.attempts.map(\.generation).sorted(), [1, 2])
      XCTAssertEqual(Set(recorder.attempts.map(\.id)).count, 2)
    }
  }

  func testReopenAllocatesHigherOwnerAndEveryOldTerminalPathIsStale() throws {
    try withTemporaryLocation { location in
      let firstRepository = try GRDBHistoryRepository.open(at: location)
      let accepted = try firstRepository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try firstRepository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let mediaID = try XCTUnwrap(try firstRepository.mediaAsset(taskID: accepted.taskID)?.id)
      let oldAttempt = try firstRepository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)
      XCTAssertEqual(try firstRepository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: oldAttempt, status: .running), .applied)
      try firstRepository.database.close()

      let reopened = try GRDBHistoryRepository.open(at: location)
      defer { try? reopened.database.close() }
      let newAttempt = try reopened.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)
      XCTAssertEqual(newAttempt.generation, oldAttempt.generation + 1)
      for status in [TranscriptionStatusMutation.running, .failed, .none] {
        XCTAssertEqual(
          try reopened.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: oldAttempt, status: status),
          .stale
        )
      }
      XCTAssertEqual(
        try reopened.completeMediaTranscription(.init(
          taskID: accepted.taskID,
          attempt: oldAttempt,
          document: transcription(url: "https://example.test/article", text: "迟到旧正文"),
          evidence: completionEvidence(completedAtMilliseconds: 4),
          receivedAtMilliseconds: 4
        )),
        .stale
      )
      XCTAssertEqual(try reopened.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: newAttempt, status: .running), .applied)
      _ = try acceptedResult(reopened.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: newAttempt,
        document: transcription(url: "https://example.test/article", text: "新 owner 正文"),
        evidence: completionEvidence(completedAtMilliseconds: 5),
        receivedAtMilliseconds: 5
      )))
      XCTAssertEqual(try reopened.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: oldAttempt, status: .failed), .stale)
      XCTAssertEqual(try reopened.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus, .completed)
      XCTAssertEqual(try reopened.detail(taskID: accepted.taskID).snapshots.last?.bodyText, "新 owner 正文")
    }
  }

  func testEffectiveSnapshotUsesGenerationWhenCompletionWallClockMovesBackward() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let first = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: first, status: .running), .applied)
      _ = try acceptedResult(repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: first,
        document: transcription(url: "https://example.test/article", text: "较早 generation"),
        evidence: completionEvidence(completedAtMilliseconds: 100),
        receivedAtMilliseconds: 100
      )))
      let second = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: second, status: .running), .applied)
      let secondResult = try acceptedResult(repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: second,
        document: transcription(url: "https://example.test/article", text: "较新 generation"),
        evidence: completionEvidence(completedAtMilliseconds: 50),
        receivedAtMilliseconds: 50
      )))

      XCTAssertEqual(second.generation, first.generation + 1)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.last?.id, secondResult.snapshotID)
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).snapshots.last?.bodyText, "较新 generation")
    }
  }

  func testOlderSnapshotReusedByLatestEvidenceBecomesEffectiveLatestEverywhere() throws {
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(
        envelope: capture(requestID: "snapshot-a", key: "snapshot-a", body: "原子转写正文", title: "A 标题"),
        receivedAtMilliseconds: 1
      ))
      let second = try repository.acceptCapture(.init(
        envelope: capture(requestID: "snapshot-b", key: "snapshot-b", body: "后来正文 B", title: "B 标题"),
        receivedAtMilliseconds: 2
      ))
      XCTAssertEqual(first.taskID, second.taskID)
      try repository.attachMedia(.init(asset: media(taskID: first.taskID, snapshotID: first.snapshotID)))
      let attempt = try begin(repository, taskID: first.taskID)
      XCTAssertEqual(
        try repository.updateMediaTranscriptionStatus(taskID: first.taskID, attempt: attempt, status: .running),
        .applied
      )

      let completed = try acceptedResult(repository.completeMediaTranscription(.init(
        taskID: first.taskID,
        attempt: attempt,
        document: transcription(url: "https://example.test/article"),
        evidence: completionEvidence(),
        receivedAtMilliseconds: 3
      )))

      XCTAssertEqual(completed.snapshotID, first.snapshotID)
      XCTAssertFalse(completed.snapshotWasCreated)
      let detail = try repository.detail(taskID: first.taskID)
      XCTAssertEqual(detail.snapshots.count, 2)
      XCTAssertEqual(Set(detail.snapshots.map(\.sequence)), Set([1, 2]))
      XCTAssertEqual(detail.snapshots.last?.id, first.snapshotID)
      XCTAssertEqual(detail.snapshots.last?.bodyText, "原子转写正文")
      let export = try repository.exportProjection(taskID: first.taskID)
      XCTAssertEqual(export.snapshots.last?.id, first.snapshotID)
      let markdown = String(decoding: try HistoryExportRenderer.render(export, as: .markdown).data, as: UTF8.self)
      XCTAssertTrue(markdown.contains("原子转写正文"))
      XCTAssertFalse(markdown.contains("后来正文 B"))
      XCTAssertEqual(
        try repository.historyPage(limit: 10, after: nil, filter: .init(searchText: "A 标题")).rows.map(\.taskID),
        [first.taskID]
      )
      XCTAssertTrue(
        try repository.historyPage(limit: 10, after: nil, filter: .init(searchText: "B 标题")).rows.isEmpty
      )
    }
  }

  func testCleanupToNoneOnlyClearsInFlightStatusAndMissingMediaStillFails() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))

      let pendingAttempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(
        try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: pendingAttempt, status: .none),
        .applied
      )
      XCTAssertEqual(
        try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus,
        TranscriptionStatus.none
      )

      let runningAttempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: runningAttempt, status: .running), .applied)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: runningAttempt, status: .none), .applied)
      XCTAssertEqual(
        try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus,
        TranscriptionStatus.none
      )

      let failedAttempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: failedAttempt, status: .failed), .applied)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: failedAttempt, status: .none), .stale)
      XCTAssertEqual(
        try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus,
        .failed,
        "cleanup treats a failed row as terminal"
      )

      let completedAttempt = try begin(repository, taskID: accepted.taskID)
      _ = try repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: completedAttempt,
        document: transcription(url: "https://example.test/article"),
        evidence: completionEvidence(),
        receivedAtMilliseconds: 3
      ))
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: completedAttempt, status: .none), .stale)
      XCTAssertEqual(
        try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus,
        .completed,
        "selection cleanup must not overwrite a committed terminal status"
      )

      let taskWithoutMedia = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "without-media",
          key: "without-media",
          url: "https://example.test/without-media"
        ),
        receivedAtMilliseconds: 2
      ))
      XCTAssertThrowsError(
        try repository.updateMediaTranscriptionStatus(
          taskID: taskWithoutMedia.taskID,
          attempt: transcriptionAttempt(5, mediaID: UUID().uuidString.lowercased()),
          status: .none
        )
      ) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
    }
  }

  func testCompletionReusesOriginalSnapshotWhenTranscriptBodyMatches() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(body: "原子转写正文"),
        receivedAtMilliseconds: 1
      ))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let attempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: attempt, status: .running), .applied)

      let completed = try acceptedResult(repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: attempt,
        document: transcription(url: "https://example.test/article"),
        evidence: completionEvidence(),
        receivedAtMilliseconds: 3
      )))

      XCTAssertEqual(completed.snapshotID, accepted.snapshotID)
      XCTAssertFalse(completed.snapshotWasCreated)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.count, 1)
      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus, .completed)
      let evidence = try repository.database.read { db in
        try Row.fetchOne(db, sql: "SELECT * FROM media_transcription_evidence WHERE task_id = ?", arguments: [accepted.taskID.rawValue])
      }
      XCTAssertEqual(evidence?["snapshot_id"] as String?, accepted.snapshotID.rawValue)
      XCTAssertEqual(evidence?["source"] as String?, "on_device")
      XCTAssertEqual(evidence?["engine"] as String?, "apple_speech_analyzer")
      XCTAssertEqual(evidence?["provider"] as String?, "apple")
      XCTAssertNil(evidence?["model"] as String?)
      XCTAssertEqual(evidence?["locale_identifier"] as String?, "zh_CN")
      XCTAssertEqual(evidence?["language"] as String?, "zh")
      XCTAssertEqual(evidence?["completed_at_ms"] as Int64?, 3)
      XCTAssertEqual(evidence?["attempt_generation"] as Int64?, attempt.generation)
    }
  }

  func testSecondAttemptWithSameHashAppendsEvidenceAndCurrentAttemptReplayIsIdempotent() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))

      let firstAttempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: firstAttempt, status: .running), .applied)
      let firstCommand = CompleteMediaTranscriptionCommand(
        taskID: accepted.taskID,
        attempt: firstAttempt,
        document: transcription(url: "https://example.test/article", text: "相同成功转写"),
        evidence: completionEvidence(completedAtMilliseconds: 3),
        receivedAtMilliseconds: 3
      )
      _ = try acceptedResult(repository.completeMediaTranscription(firstCommand))

      let secondAttempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: secondAttempt, status: .running), .applied)
      let secondCommand = CompleteMediaTranscriptionCommand(
        taskID: accepted.taskID,
        attempt: secondAttempt,
        document: transcription(url: "https://example.test/article", text: "相同成功转写"),
        evidence: completionEvidence(completedAtMilliseconds: 5),
        receivedAtMilliseconds: 5
      )
      _ = try acceptedResult(repository.completeMediaTranscription(secondCommand))

      let replay = try repository.completeMediaTranscription(secondCommand)
      guard case let .replay(replayed) = replay else { return XCTFail("current completed attempt must replay") }
      XCTAssertTrue(replayed.deliveryWasReplayed)
      XCTAssertEqual(try repository.completeMediaTranscription(firstCommand), .stale)
      let evidenceRows = try repository.database.read { db in
        try Row.fetchAll(
          db,
          sql: "SELECT id, attempt_id, attempt_generation, source, engine, provider, model, locale_identifier, language FROM media_transcription_evidence WHERE task_id = ? ORDER BY attempt_generation, id",
          arguments: [accepted.taskID.rawValue]
        )
      }
      XCTAssertEqual(evidenceRows.count, 2)
      XCTAssertEqual(Set(evidenceRows.map { $0["attempt_id"] as String }), Set([firstAttempt.id, secondAttempt.id]))
      XCTAssertEqual(evidenceRows.map { $0["attempt_generation"] as Int64 }, [1, 2])
      XCTAssertEqual(Set(evidenceRows.map { $0["id"] as String }).count, 2)
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["source"] as String) == "on_device" })
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["engine"] as String) == "apple_speech_analyzer" })
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["provider"] as String?) == "apple" })
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["model"] as String?) == nil })
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["locale_identifier"] as String?) == "zh_CN" })
      XCTAssertTrue(evidenceRows.allSatisfy { ($0["language"] as String?) == "zh" })

      let other = try repository.acceptCapture(.init(
        envelope: capture(
          requestID: "cross-task",
          key: "cross-task",
          url: "https://example.test/other-task",
          body: "other"
        ),
        receivedAtMilliseconds: 6
      ))
      let mediaID = try XCTUnwrap(try repository.mediaAsset(taskID: accepted.taskID)?.id)
      XCTAssertThrowsError(try repository.database.write { db in
        try db.execute(
          sql: "INSERT INTO media_transcription_evidence (id, media_id, task_id, snapshot_id, attempt_id, attempt_generation, source, engine, completed_at_ms) VALUES (?, ?, ?, ?, ?, 99, 'fixture', 'fixture', 7)",
          arguments: [
            UUID().uuidString.lowercased(),
            mediaID,
            other.taskID.rawValue,
            other.snapshotID.rawValue,
            UUID().uuidString.lowercased(),
          ]
        )
      })
      XCTAssertEqual(
        try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_transcription_evidence") },
        2
      )
    }
  }

  func testBeginAndStatusUpdatesUseExactMediaOwnershipAndMissingRowsFail() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      let asset = MediaAsset(
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        relativePath: "\(String(repeating: "a", count: 64)).mp4",
        contentSHA256: String(repeating: "a", count: 64),
        byteSize: 1_024,
        platform: "douyin",
        transcriptionStatus: .none,
        createdAtMilliseconds: 2
      )
      try repository.attachMedia(.init(asset: asset))

      let attempt = try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: asset.id)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: attempt, status: .running), .applied)
      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus, .running)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).media?.transcriptionStatus, .running)

      XCTAssertThrowsError(
        try repository.beginMediaTranscription(taskID: TaskID(), mediaID: asset.id)
      ) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
      XCTAssertThrowsError(
        try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: UUID().uuidString.lowercased())
      ) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
      XCTAssertThrowsError(
        try repository.updateMediaTranscriptionStatus(
          taskID: TaskID(),
          attempt: attempt,
          status: .running
        )
      ) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
    }
  }

  func testAtomicCompletionRollsBackSnapshotWhenTerminalHookFails() throws {
    try withTemporaryLocation { location in
      var dependencies = PersistenceDependencies.live
      dependencies.beforeTerminalCommit = { throw RepositoryFailure.injectedFailure }
      let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
      defer { try? repository.database.close() }
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      try repository.attachMedia(.init(asset: media(taskID: accepted.taskID, snapshotID: accepted.snapshotID)))
      let attempt = try begin(repository, taskID: accepted.taskID)
      XCTAssertEqual(try repository.updateMediaTranscriptionStatus(taskID: accepted.taskID, attempt: attempt, status: .running), .applied)

      XCTAssertThrowsError(try repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: attempt,
        document: transcription(url: "https://example.test/article"),
        evidence: completionEvidence(),
        receivedAtMilliseconds: 3
      ))) { XCTAssertEqual($0 as? RepositoryFailure, .injectedFailure) }
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.count, 1)
      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.transcriptionStatus, TranscriptionStatus.running)
      XCTAssertEqual(
        try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_transcription_evidence") },
        0
      )
    }
  }

  func testAtomicCompletionWithoutMediaCreatesNoSnapshot() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(envelope: capture(), receivedAtMilliseconds: 1))
      XCTAssertThrowsError(try repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: transcriptionAttempt(1, mediaID: UUID().uuidString.lowercased()),
        document: transcription(url: "https://example.test/article"),
        evidence: completionEvidence(),
        receivedAtMilliseconds: 3
      ))) { XCTAssertEqual($0 as? RepositoryFailure, .notFound) }
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.count, 1)
    }
  }

  private func media(taskID: TaskID, snapshotID: ContentSnapshotID) -> MediaAsset {
    MediaAsset(
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: "\(String(repeating: "b", count: 64)).mp4",
      contentSHA256: String(repeating: "b", count: 64),
      byteSize: 2_048,
      platform: "douyin",
      createdAtMilliseconds: 2
    )
  }

  private func transcription(url: String, text: String = "原子转写正文") -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-07-19T00:00:00Z",
      origin: .localTranscription,
      url: url,
      title: "转写",
      platform: "douyin",
      method: "speech_analyzer_local",
      text: text,
      completeness: "complete",
      capturedAt: "2026-07-19T00:00:00Z",
      sourceLabel: "本机视频转写"
    )
  }

  private func completionEvidence(completedAtMilliseconds: Int64 = 3) -> TranscriptionCompletionEvidence {
    .appleSpeechAnalyzer(
      localeIdentifier: "zh_CN",
      language: "zh",
      completedAtMilliseconds: completedAtMilliseconds
    )
  }

  private func begin(_ repository: GRDBHistoryRepository, taskID: TaskID) throws -> TranscriptionAttemptToken {
    let mediaID = try XCTUnwrap(try repository.mediaAsset(taskID: taskID)?.id)
    return try repository.beginMediaTranscription(taskID: taskID, mediaID: mediaID)
  }

  private func acceptedResult(_ result: CompleteMediaTranscriptionResult) throws -> AcceptCaptureResult {
    guard case let .accepted(accepted) = result else {
      XCTFail("completion should be accepted, got \(result)")
      throw RepositoryFailure.invalidStateTransition
    }
    return accepted
  }

  private func transcriptionAttempt(_ index: Int, mediaID: String, generation: Int64? = nil) -> TranscriptionAttemptToken {
    let suffix = String(format: "%012d", index)
    return .init(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-\(suffix)",
      mediaID: mediaID,
      generation: generation ?? Int64(index)
    )
  }
}

final class TaskTranscriptionPersistenceTests: XCTestCase {
  func testGenerationMakesOlderAttemptStaleAndBeginContainsNoRemoteMaterial() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(requestID: "task-owner", key: "task-owner"),
        receivedAtMilliseconds: 1
      ))
      let first = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
      let second = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 3)
      XCTAssertEqual(first.generation, 1)
      XCTAssertEqual(second.generation, 2)
      XCTAssertEqual(
        try repository.updateTaskTranscriptionStatus(
          taskID: accepted.taskID, attempt: first, status: .running, updatedAtMilliseconds: 4
        ),
        .stale
      )
      XCTAssertEqual(
        try repository.updateTaskTranscriptionStatus(
          taskID: accepted.taskID, attempt: second, status: .running, updatedAtMilliseconds: 5
        ),
        .applied
      )
      let stored = try repository.database.read { db in
        try String.fetchAll(db, sql: "SELECT id || ':' || status FROM task_transcription_attempts ORDER BY generation")
      }.joined(separator: "|")
      XCTAssertFalse(stored.contains("https://"))
      XCTAssertFalse(stored.contains("TranscriptionTemp"))
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_assets")
      }, 0)
    }
  }

  func testAtomicFinalIsEffectiveLatestAndSameBodyReusesSnapshotWithEvidence() throws {
    try withRepository { repository, _ in
      let envelope = capture(
        requestID: "task-complete", key: "task-complete",
        url: "https://example.test/article", body: "fixture body"
      )
      let accepted = try repository.acceptCapture(.init(envelope: envelope, receivedAtMilliseconds: 1))
      let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
      let result = try repository.completeTaskTranscription(.init(
        taskID: accepted.taskID,
        attempt: attempt,
        document: transcription(text: "最终转写正文"),
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
        receivedAtMilliseconds: 3
      ))
      guard case let .accepted(completed) = result else { return XCTFail("completion should apply") }
      XCTAssertTrue(completed.snapshotWasCreated)
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.last?.bodyText, "最终转写正文")
      XCTAssertEqual(try repository.exportProjection(taskID: accepted.taskID).snapshots.last?.bodyText, "最终转写正文")

      let next = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 4)
      let same = try repository.completeTaskTranscription(.init(
        taskID: accepted.taskID,
        attempt: next,
        document: transcription(text: "最终转写正文"),
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 5),
        receivedAtMilliseconds: 5
      ))
      guard case let .accepted(reused) = same else { return XCTFail("same-body completion should apply") }
      XCTAssertFalse(reused.snapshotWasCreated)
      XCTAssertEqual(reused.snapshotID, completed.snapshotID)
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_transcription_evidence")
      }, 2)
      XCTAssertEqual(try repository.database.read {
        try String.fetchOne($0, sql: "SELECT status FROM task_transcription_attempts WHERE id = ?", arguments: [next.id])
      }, "completed")
    }
  }

  func testTerminalFailureRollsBackSnapshotEvidenceAndCompletedState() throws {
    var dependencies = PersistenceDependencies.live
    let gate = AtomicFailureGate()
    dependencies.beforeTerminalCommit = { if gate.shouldFail { throw RepositoryFailure.injectedFailure } }
    try withRepository(dependencies: dependencies) { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(requestID: "task-rollback", key: "task-rollback"),
        receivedAtMilliseconds: 1
      ))
      let originalCount = try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM content_snapshots") ?? 0
      }
      let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
      gate.shouldFail = true
      XCTAssertThrowsError(try repository.completeTaskTranscription(.init(
        taskID: accepted.taskID,
        attempt: attempt,
        document: transcription(text: "不得半保存"),
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
        receivedAtMilliseconds: 3
      )))
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM content_snapshots")
      }, originalCount)
      XCTAssertEqual(try repository.database.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_transcription_evidence")
      }, 0)
      XCTAssertEqual(try repository.database.read {
        try String.fetchOne($0, sql: "SELECT status FROM task_transcription_attempts WHERE id = ?", arguments: [attempt.id])
      }, "pending")
    }
  }

  func testMediaAndTransientAttemptsShareOneOwnerSequenceAndEffectiveLatest() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(requestID: "cross-owner", key: "cross-owner", url: "https://example.test/article"),
        receivedAtMilliseconds: 1
      ))
      let mediaID = UUID().uuidString.lowercased()
      try repository.attachMedia(.init(asset: .init(
        id: mediaID,
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        relativePath: "\(String(repeating: "c", count: 64)).mp4",
        contentSHA256: String(repeating: "c", count: 64),
        byteSize: 12,
        platform: "generic",
        createdAtMilliseconds: 2
      )))
      let transient = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 3)
      let media = try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: mediaID)
      XCTAssertEqual(transient.generation, 1)
      XCTAssertEqual(media.generation, 2)
      XCTAssertEqual(try repository.updateTaskTranscriptionStatus(
        taskID: accepted.taskID, attempt: transient, status: .running, updatedAtMilliseconds: 4
      ), .stale)
      _ = try repository.completeMediaTranscription(.init(
        taskID: accepted.taskID,
        attempt: media,
        document: transcription(text: "永久媒体较新正文"),
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 5),
        receivedAtMilliseconds: 5
      ))
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).snapshots.last?.bodyText, "永久媒体较新正文")

      let newestTransient = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 6)
      XCTAssertEqual(newestTransient.generation, 3)
      _ = try repository.completeTaskTranscription(.init(
        taskID: accepted.taskID,
        attempt: newestTransient,
        document: transcription(text: "临时直连最新正文"),
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 4),
        receivedAtMilliseconds: 4
      ))
      XCTAssertEqual(
        try repository.detail(taskID: accepted.taskID).snapshots.last?.bodyText,
        "临时直连最新正文",
        "generation, not wall-clock time, decides effective latest"
      )
    }
  }

  private func transcription(text: String) -> CapturedDocument {
    .init(
      createdAt: "2026-07-20T00:00:00Z",
      origin: .localTranscription,
      url: "https://example.test/article",
      title: "转写",
      platform: "generic",
      method: "speech_analyzer_local",
      text: text,
      completeness: "complete",
      capturedAt: "2026-07-20T00:00:00Z",
      sourceLabel: "本机视频转写"
    )
  }
}

private final class AtomicFailureGate: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var shouldFail: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

private final class TranscriptionAttemptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<TranscriptionAttemptToken, RepositoryFailure>] = []

  func record(_ result: Result<TranscriptionAttemptToken, RepositoryFailure>) {
    lock.withLock { results.append(result) }
  }

  var attempts: [TranscriptionAttemptToken] {
    lock.withLock { results.compactMap { try? $0.get() } }
  }

  var failures: [RepositoryFailure] {
    lock.withLock {
      results.compactMap {
        guard case let .failure(failure) = $0 else { return nil }
        return failure
      }
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

final class SnapshotBodyEditTests: XCTestCase {
  func testUpdateSnapshotBodyTextRewritesBodyAndDerivedColumnsInPlace() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(requestID: "edit-a", key: "edit-a", body: "原始转写正文，有错别字。"),
        receivedAtMilliseconds: 10
      ))
      let corrected = "校对后的转写正文。\n\n分段也修好了。"
      try repository.updateSnapshotBodyText(
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        bodyText: corrected,
        updatedAtMilliseconds: 99
      )
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertEqual(detail.snapshots.count, 1)
      XCTAssertEqual(detail.snapshots[0].bodyText, corrected)
      XCTAssertEqual(detail.snapshots[0].id, accepted.snapshotID)
      XCTAssertEqual(detail.task.updatedAtMilliseconds, 99)
      let stored = try repository.database.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT character_count, body_sha256 FROM content_snapshots WHERE id = ?",
          arguments: [accepted.snapshotID.rawValue]
        )
      }
      XCTAssertEqual(stored?["character_count"] as Int?, corrected.unicodeScalars.count)
      XCTAssertEqual(
        stored?["body_sha256"] as String?,
        SHA256CaptureFingerprinter().bodySHA256(corrected)
      )
    }
  }

  func testUpdateSnapshotBodyTextForUnknownSnapshotThrowsNotFoundWithoutTouchingTask() throws {
    try withRepository { repository, _ in
      let accepted = try repository.acceptCapture(.init(
        envelope: capture(requestID: "edit-b", key: "edit-b"),
        receivedAtMilliseconds: 10
      ))
      XCTAssertThrowsError(try repository.updateSnapshotBodyText(
        taskID: accepted.taskID,
        snapshotID: ContentSnapshotID(UUID()),
        bodyText: "不应写入",
        updatedAtMilliseconds: 99
      )) { error in
        XCTAssertEqual(error as? RepositoryFailure, .notFound)
      }
      XCTAssertEqual(try repository.detail(taskID: accepted.taskID).task.updatedAtMilliseconds, 10)
    }
  }
}

private func capture(requestID: String = "request", key: String? = "delivery", url: String = "https://example.test/article", body: String = "fixture body", characterCount: Int? = nil, title: String? = "Fixture") -> CaptureEnvelopeV1 {
  CaptureEnvelopeV1(version: 1, requestId: requestID, createdAt: "2026-07-15T04:00:00Z", idempotencyKey: key, source: .init(kind: "browser_capture", url: url, title: title, platform: "generic"), capture: .init(method: "rendered_dom", text: body, characterCount: characterCount ?? body.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"), evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false))
}

private func v2Capture(
  media: MediaDescriptor,
  requestID: String = "v2-safe-digest",
  key: String = "v2-safe-digest",
  url: String = "https://example.test/watch",
  body: String = "fixture v2 body"
) -> CaptureEnvelopeV2 {
  CaptureEnvelopeV2(
    requestId: requestID,
    createdAt: "2026-07-20T00:00:00Z",
    idempotencyKey: key,
    source: .init(kind: "browser_capture", url: url, title: "Fixture V2", platform: "generic"),
    capture: .init(method: "rendered_dom", text: body, characterCount: body.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z"),
    evidence: .init(sourceLabel: "Current page DOM", usedCookie: false),
    media: media
  )
}

private func v2Media(
  kind: MediaKind = .directFile,
  pageURL: String = "https://example.test/watch?snapshot=base",
  canonicalURL: String = "https://example.test/watch",
  platform: String = "generic",
  ephemeralPlaybackURL: String? = "https://media.example.test/signed-base.mp4",
  mimeType: String? = "video/mp4",
  posterURL: String? = "https://images.example.test/poster-base.jpg",
  durationSeconds: Double? = 12.5,
  author: String? = "Fixture Author",
  expiresAt: String? = "2026-07-20T00:01:00Z",
  transcriptionCapability: TranscriptionCapability = .supported,
  failureReason: MediaFailureReason? = nil,
  candidateCount: Int? = 2,
  selectionReason: MediaSelectionReason? = .singleCandidate,
  playbackState: MediaPlaybackState? = .paused
) -> MediaDescriptor {
  .init(
    kind: kind,
    pageURL: pageURL,
    canonicalURL: canonicalURL,
    platform: platform,
    ephemeralPlaybackURL: ephemeralPlaybackURL,
    mimeType: mimeType,
    posterURL: posterURL,
    durationSeconds: durationSeconds,
    author: author,
    expiresAt: expiresAt,
    transcriptionCapability: transcriptionCapability,
    failureReason: failureReason,
    candidateCount: candidateCount,
    selectionReason: selectionReason,
    playbackState: playbackState
  )
}

private func withRepository(dependencies: PersistenceDependencies = .live, _ body: (GRDBHistoryRepository, LocalDatabaseLocation) throws -> Void) throws {
  try withTemporaryLocation { location in
    let repository = try GRDBHistoryRepository.open(at: location, dependencies: dependencies)
    defer { try? repository.database.close() }
    try body(repository, location)
  }
}

/// 建一个用完即弃的库位置。internal 而非 private：工作台那组测试在另一个文件里，
/// 复制一份一模一样的辅助函数只会让两处慢慢长歪。
func withTemporaryLocation(createDirectory: Bool = true, _ body: (LocalDatabaseLocation) throws -> Void) throws {
  let root = URL(fileURLWithPath: "/private/tmp/linkdigest-history-tests-\(UUID().uuidString)", isDirectory: true)
  let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
  if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
  defer { try? FileManager.default.removeItem(at: root) }
  try body(LocalDatabaseLocation(directoryURL: directory))
}

final class MindMapPersistenceTests: XCTestCase {
  private func openRepository() throws -> (GRDBHistoryRepository, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-mindmap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    return (repository, root)
  }

  private func acceptTask(_ repository: GRDBHistoryRepository) throws -> TaskID {
    let document = CapturedDocument(
      createdAt: "2026-07-23T00:00:00Z", origin: .manualLink,
      url: "https://example.test/mindmap", title: "样例",
      platform: "web", method: "fixture", text: "正文",
      completeness: "complete", capturedAt: "2026-07-23T00:00:00Z", sourceLabel: "fixture"
    )
    return try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1)).taskID
  }

  func testSaveLoadUpsertAndCascadeDelete() throws {
    let (repository, root) = try openRepository()
    defer { try? repository.database.close(); try? FileManager.default.removeItem(at: root) }
    let taskID = try acceptTask(repository)
    let outline = MindMapOutline(
      title: "主题", subtitle: "来源",
      branches: [.init(title: "分支", leaves: ["要点一", "要点二"])]
    )
    try repository.saveMindMap(.init(
      taskID: taskID, outline: outline, themeID: "minimal-light",
      totalTokens: 800, createdAtMilliseconds: 10, updatedAtMilliseconds: 10
    ))
    let loaded = try XCTUnwrap(repository.loadMindMap(taskID: taskID))
    XCTAssertEqual(loaded.outline, outline)
    XCTAssertEqual(loaded.themeID, "minimal-light")
    XCTAssertEqual(loaded.totalTokens, 800)
    XCTAssertFalse(loaded.userEdited)

    // Upsert：编辑后的保存覆盖同任务的旧图。
    let edited = MindMapOutline(title: "改后主题", subtitle: nil, branches: outline.branches)
    try repository.saveMindMap(.init(
      taskID: taskID, outline: edited, themeID: "dark-code", userEdited: true,
      totalTokens: 800, createdAtMilliseconds: 10, updatedAtMilliseconds: 20
    ))
    let reloaded = try XCTUnwrap(repository.loadMindMap(taskID: taskID))
    XCTAssertEqual(reloaded.outline.title, "改后主题")
    XCTAssertEqual(reloaded.themeID, "dark-code")
    XCTAssertTrue(reloaded.userEdited)

    // 删除任务级联清理脑图。
    try repository.deleteTask(taskID: taskID)
    XCTAssertNil(try repository.loadMindMap(taskID: taskID))
  }

  func testSaveRejectsUnknownTask() throws {
    let (repository, root) = try openRepository()
    defer { try? repository.database.close(); try? FileManager.default.removeItem(at: root) }
    let outline = MindMapOutline(title: "主题", subtitle: nil, branches: [.init(title: "b", leaves: [])])
    XCTAssertThrowsError(try repository.saveMindMap(.init(
      taskID: TaskID(UUID()), outline: outline, themeID: "minimal-light",
      createdAtMilliseconds: 1, updatedAtMilliseconds: 1
    )))
  }
}

final class TokenLedgerPersistenceTests: XCTestCase {
  func testAppendAndTotalsSumAcrossOperationsAndCascadeDelete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-ledger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-23T00:00:00Z", origin: .manualLink,
      url: "https://example.test/ledger", title: "样例",
      platform: "web", method: "fixture", text: "正文",
      completeness: "complete", capturedAt: "2026-07-23T00:00:00Z", sourceLabel: "fixture"
    )
    let taskID = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1)).taskID

    try repository.appendTokenUsage(.init(
      taskID: taskID, operation: "transcript_tidy",
      promptTokens: 3_200, completionTokens: 4_626, totalTokens: 7_826, createdAtMilliseconds: 2
    ))
    try repository.appendTokenUsage(.init(
      taskID: taskID, operation: "mind_map",
      promptTokens: 891, completionTokens: 755, totalTokens: 1_646, createdAtMilliseconds: 3
    ))
    let totals = try repository.ledgerTokenTotals(taskID: taskID)
    XCTAssertEqual(totals, .init(promptTokens: 4_091, completionTokens: 5_381, totalTokens: 9_472))

    // 未知任务拒收；删任务级联清账。
    XCTAssertThrowsError(try repository.appendTokenUsage(.init(
      taskID: TaskID(UUID()), operation: "mind_map",
      promptTokens: 1, completionTokens: 1, totalTokens: 2, createdAtMilliseconds: 4
    )))
    try repository.deleteTask(taskID: taskID)
    XCTAssertEqual(try repository.ledgerTokenTotals(taskID: taskID).totalTokens, 0)
  }
}

final class AnnotationPersistenceTests: XCTestCase {
  func testNoteUpsertClearAndExcerptLifecycleWithCascade() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-annotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-23T00:00:00Z", origin: .manualLink,
      url: "https://example.test/annotation", title: "样例",
      platform: "web", method: "fixture", text: "正文",
      completeness: "complete", capturedAt: "2026-07-23T00:00:00Z", sourceLabel: "fixture"
    )
    let taskID = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1)).taskID

    // 笔记 upsert；空内容即删除记录。
    try repository.saveNote(taskID: taskID, body: "第一版想法", updatedAtMilliseconds: 2)
    try repository.saveNote(taskID: taskID, body: "修订后的想法", updatedAtMilliseconds: 3)
    XCTAssertEqual(try repository.loadNote(taskID: taskID), "修订后的想法")
    try repository.saveNote(taskID: taskID, body: "   ", updatedAtMilliseconds: 4)
    XCTAssertNil(try repository.loadNote(taskID: taskID))

    // 摘录：追加有序、可删除、未知任务拒收。
    let first = TaskExcerpt(taskID: taskID, excerpt: "值得记住的一句", createdAtMilliseconds: 5)
    let second = TaskExcerpt(taskID: taskID, excerpt: "另一句", createdAtMilliseconds: 6)
    try repository.addExcerpt(first)
    try repository.addExcerpt(second)
    XCTAssertEqual(try repository.listExcerpts(taskID: taskID).map(\.excerpt), ["值得记住的一句", "另一句"])
    try repository.deleteExcerpt(id: first.id, taskID: taskID)
    XCTAssertEqual(try repository.listExcerpts(taskID: taskID).map(\.excerpt), ["另一句"])
    XCTAssertThrowsError(try repository.addExcerpt(
      TaskExcerpt(taskID: TaskID(UUID()), excerpt: "孤儿", createdAtMilliseconds: 7)
    ))

    // 删任务级联清空批注。
    try repository.saveNote(taskID: taskID, body: "临终笔记", updatedAtMilliseconds: 8)
    try repository.deleteTask(taskID: taskID)
    XCTAssertNil(try repository.loadNote(taskID: taskID))
    XCTAssertTrue(try repository.listExcerpts(taskID: taskID).isEmpty)
  }
  func testMediaAssetsReturnsEveryRowNotJustTheNewest() throws {
    // media_assets 的唯一键是 (task_id, content_sha256)，同一任务可以有多行：
    // 重抓后字节不同、B 站合流成功与失败产出不同 sha。删除任务时若只查最新一条
    // （mediaAsset 是 ORDER BY created_at_ms DESC LIMIT 1），其余文件的 DB 行随
    // CASCADE 消失、磁盘文件却留下来，成为再也没人能发现的孤儿。
    try withRepository { repository, _ in
      let first = try repository.acceptCapture(.init(
        envelope: capture(requestID: "multi-asset", key: "multi-asset-delivery", body: "body"),
        receivedAtMilliseconds: 1
      ))
      let shas = [String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
      for (index, sha) in shas.enumerated() {
        try repository.attachMedia(.init(asset: MediaAsset(
          taskID: first.taskID,
          snapshotID: first.snapshotID,
          relativePath: "\(sha).mp4",
          fileBookmark: nil,
          contentSHA256: sha,
          byteSize: 1_024,
          durationSeconds: 10,
          platform: "douyin",
          author: nil,
          createdAtMilliseconds: Int64(10 + index)
        )))
      }

      let newestOnly = try XCTUnwrap(try repository.mediaAsset(taskID: first.taskID))
      XCTAssertEqual(newestOnly.contentSHA256, shas[2], "mediaAsset 按设计只给最新一条")

      let all = try repository.mediaAssets(taskID: first.taskID)
      XCTAssertEqual(
        Set(all.map(\.contentSHA256)), Set(shas),
        "删除清理必须能看到全部资产，否则旧文件永久泄漏")
      XCTAssertEqual(
        Set(try repository.mediaRelativePaths(taskID: first.taskID)),
        Set(shas.map { "\($0).mp4" }))
    }
  }

}

/// 笔记必须能真正落库。
///
/// 之前的测试只验到「能组装成 AcceptCaptureCommand」，恰好停在故障点之前：
/// `provenanceIsConsistent` 的 switch 里没有 .userNote 分支，落到 default 直接
/// return false，落库以 stateConflict 失败——而界面上只表现为「点新建没有任何
/// 反应」。测试必须穿过整条写入路径才拦得住这类问题。
final class UserNoteIngestTests: XCTestCase {
  func testUserNoteIsAcceptedAndAppearsInNotesScope() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let document = try UserNoteDocument.make(title: "灵感", body: "先写一句")
      let command = try AcceptCaptureCommand(document: document, receivedAtMilliseconds: 1_760_000_000_000)

      // 这一步就是「点新建」真正做的事。
      _ = try repository.acceptCapture(command)

      // 笔记只出现在 .notes 里，不污染其它作用域。
      let notes = try repository.historyPage(limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .notes))
      XCTAssertEqual(notes.rows.count, 1)
      XCTAssertTrue(notes.rows[0].canonicalURL.hasPrefix("linkdigest-note:"))

      let all = try repository.historyPage(limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .all))
      XCTAssertTrue(all.rows.isEmpty, "笔记不该出现在「全部」里——那是抓取内容的区域")

      let counts = try repository.navigationCounts()
      XCTAssertEqual(counts.notes, 1)
      XCTAssertEqual(counts.all, 0)
    }
  }

  /// 搜索要能找到笔记，哪怕当前不在「我的笔记」区。
  ///
  /// 分区是为了浏览时互不打扰；搜索是「我想不起来它在哪」，此时还要求用户先
  /// 答对它是笔记还是网页，等于把搜索本该解决的问题当成了前提。
  func testSearchReachesNotesFromAnyScope() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "灵感", body: "盲派格局的判断方法"),
        receivedAtMilliseconds: 1
      ))

      let hit = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?,
        filter: HistoryListFilter(scope: .all, searchText: "盲派")
      )
      XCTAssertEqual(hit.rows.count, 1, "在「全部」里搜正文也该命中笔记")

      // 没有搜索词时仍然分区：浏览「全部」不该被自己的草稿打断。
      let browsing = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .all)
      )
      XCTAssertTrue(browsing.rows.isEmpty)

      // 搜不中的词不该把笔记带出来。
      let miss = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?,
        filter: HistoryListFilter(scope: .all, searchText: "完全无关的词")
      )
      XCTAssertTrue(miss.rows.isEmpty)
    }
  }

  /// 列表行要能看出笔记里写了什么，而不只是标题加日期。
  func testNoteRowCarriesABodyPreviewAndItsOwnHost() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(
          title: "AI 时代的创作",
          body: "# AI 时代的创作\n\n先构建知识库，再让模型基于它产出候选。"
        ),
        receivedAtMilliseconds: 1
      ))

      let page = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .notes)
      )
      let row = try XCTUnwrap(page.rows.first)
      // host 有值，列表行才不会拿空串去查图标、落进首字母兜底画出个方块。
      XCTAssertEqual(row.host, HistoryPlatformDisplay.noteHost)
      let preview = try XCTUnwrap(row.artifactPreview)
      XCTAssertTrue(preview.contains("先构建知识库"))
      XCTAssertFalse(preview.hasPrefix("#"), "标题就在预览正上方，不该再念一遍")
    }
  }

  /// 双链按标题找到目标笔记。
  func testWikiLinkResolvesANoteByTitle() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let target = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "知识库构建", body: "正文"),
        receivedAtMilliseconds: 1
      ))

      XCTAssertEqual(try repository.noteID(matchingTitle: "知识库构建"), target.taskID)
      // 大小写与首尾空白不参与匹配：否则链接会因为记错大小写而经常断掉。
      XCTAssertEqual(try repository.noteID(matchingTitle: "  知识库构建 "), target.taskID)
      XCTAssertNil(try repository.noteID(matchingTitle: "不存在的标题"))
      XCTAssertNil(try repository.noteID(matchingTitle: "   "))
    }
  }

  /// 双链只在笔记之间成立，不该链到抓来的网页上。
  func testWikiLinkNeverResolvesToACapturedPage() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: CapturedDocument(
          createdAt: "2026-08-01T00:00:00Z", origin: .manualLink,
          url: "https://example.test/a", title: "一篇网页",
          platform: "web", method: "fixture", text: "正文",
          completeness: "complete", capturedAt: "2026-08-01T00:00:00Z", sourceLabel: "网页"
        ),
        receivedAtMilliseconds: 1
      ))

      XCTAssertNil(
        try repository.noteID(matchingTitle: "一篇网页"),
        "抓来的网页标题是抓取时定的，用户从没给它起过名字"
      )
    }
  }

  /// 反向链接：哪些笔记链到了这条。
  func testBacklinksListNotesThatPointHere() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "知识库构建", body: "被指向的那条"),
        receivedAtMilliseconds: 1
      ))
      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "内容生产流程", body: "先看 [[知识库构建]] 再往下"),
        receivedAtMilliseconds: 2
      ))
      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "无关的一条", body: "没有链接"),
        receivedAtMilliseconds: 3
      ))
      // 只是正文里提到了这几个字，没写成链接，不算反链。
      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "只是提到", body: "我在做知识库构建这件事"),
        receivedAtMilliseconds: 4
      ))

      let backlinks = try repository.notesLinking(toTitle: "知识库构建")
      XCTAssertEqual(backlinks.map(\.title), ["内容生产流程"])
    }
  }

  /// SQL 的 LIKE 只是粗筛，真正判定交给 WikiLink——否则两处口径会分家。
  func testBacklinkFilteringRejectsCoincidentalBracketText() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "甲", body: "目标"),
        receivedAtMilliseconds: 1
      ))
      // 粗筛的 `%[[%甲%]]%` 会捞到它，但它链的是「乙」，不是「甲」。
      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "干扰项", body: "[[乙]] 里提到了甲 [[丙]]"),
        receivedAtMilliseconds: 2
      ))

      XCTAssertTrue(try repository.notesLinking(toTitle: "甲").isEmpty)
    }
  }

  func testNoteTitlesFeedTheLinkCompletion() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "先写的", body: "a"),
        receivedAtMilliseconds: 1
      ))
      _ = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(title: "后写的", body: "b"),
        receivedAtMilliseconds: 2
      ))
      // 最近更新的排前面：补全时先看到的应该是手头正在写的那些。
      XCTAssertEqual(try repository.noteTitles(), ["后写的", "先写的"])
    }
  }

  /// 删除笔记走的是和抓取记录同一个通道，但从没验证过。
  func testDeletingANoteRemovesItAndItsCount() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let accepted = try repository.acceptCapture(.init(
        document: try UserNoteDocument.make(body: "要删掉的笔记"),
        receivedAtMilliseconds: 1
      ))
      _ = try repository.addTags(["灵感"], to: accepted.taskID)

      let result = try repository.deleteTasks(taskIDs: [accepted.taskID])
      XCTAssertEqual(result.deletedTaskIDs, [accepted.taskID])
      XCTAssertTrue(result.failedTaskIDs.isEmpty)

      let remaining = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .notes)
      )
      XCTAssertTrue(remaining.rows.isEmpty)
      XCTAssertEqual(try repository.navigationCounts().notes, 0)
    }
  }

  /// 笔记标题可改，并且列表里立刻是新名字。
  func testRenamingANoteIsPersistedAndVisibleInTheList() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let accepted = try repository.acceptCapture(
        try AcceptCaptureCommand(
          document: try UserNoteDocument.make(body: "先写一句"),
          receivedAtMilliseconds: 1_760_000_000_000
        )
      )
      try repository.updateTaskTitle(
        taskID: accepted.taskID,
        title: "AI 时代的创作",
        updatedAtMilliseconds: 1_760_000_100_000
      )

      let page = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?, filter: HistoryListFilter(scope: .notes)
      )
      XCTAssertEqual(page.rows.first?.title, "AI 时代的创作")
    }
  }

  /// 改一条不存在的记录必须报 `notFound`，而不是静默无事发生。
  ///
  /// 这里断言具体的错误值而不只是「抛了东西」：SQL 写错时（比如改了一张没有
  /// title 列的表）抛出的是 `unavailable`，只断言 throws 的话测试照样绿。
  func testRenamingAMissingTaskFails() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      XCTAssertThrowsError(
        try repository.updateTaskTitle(
          taskID: TaskID(), title: "无中生有", updatedAtMilliseconds: 1_760_000_000_000
        )
      ) { error in
        XCTAssertEqual(error as? RepositoryFailure, .notFound)
      }
    }
  }
}

/// 每日笔记的幂等性。
///
/// 「今天」这个入口一天里会被点很多次，每次都必须落到同一条笔记上。这不是靠
/// 应用层先查一次再决定——那在竞态下会产生两条；而是靠同一天解析出同一个
/// canonical URL，让 tasks 的 UNIQUE 约束来保证。
final class DailyNoteIdempotencyTests: XCTestCase {
  func testSameDayAlwaysResolvesToOneNote() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let day = Date(timeIntervalSince1970: 1_785_600_000)
      let first = try repository.acceptCapture(
        try AcceptCaptureCommand(
          document: try UserNoteDocument.makeDaily(date: day),
          receivedAtMilliseconds: 1_785_600_000_000
        )
      )
      // 同一天再点一次——必须回到同一条，而不是新建。
      let second = try repository.acceptCapture(
        try AcceptCaptureCommand(
          document: try UserNoteDocument.makeDaily(date: day),
          receivedAtMilliseconds: 1_785_600_100_000
        )
      )
      XCTAssertEqual(first.taskID, second.taskID, "同一天必须落到同一条笔记")

      let notes = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?,
        filter: HistoryListFilter(scope: .notes)
      )
      XCTAssertEqual(notes.rows.count, 1, "重复点「今天」不该堆出多条")
    }
  }

  func testDifferentDaysGetTheirOwnNotes() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let day = Date(timeIntervalSince1970: 1_785_600_000)
      let nextDay = day.addingTimeInterval(86_400)
      _ = try repository.acceptCapture(try AcceptCaptureCommand(
        document: try UserNoteDocument.makeDaily(date: day), receivedAtMilliseconds: 1))
      _ = try repository.acceptCapture(try AcceptCaptureCommand(
        document: try UserNoteDocument.makeDaily(date: nextDay), receivedAtMilliseconds: 2))

      let notes = try repository.historyPage(
        limit: 10, after: nil as HistoryPageCursor?,
        filter: HistoryListFilter(scope: .notes)
      )
      XCTAssertEqual(notes.rows.count, 2)
    }
  }

  /// 标题要能被人一眼认出，也要能被搜索命中。
  func testDailyTitleIsAReadableDate() {
    let day = Date(timeIntervalSince1970: 1_785_600_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    XCTAssertEqual(UserNoteDocument.dailyTitle(for: day, calendar: calendar), "2026-08-02")
  }
}
