import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestPersistence

final class LibraryBackupManagerTests: XCTestCase {
  func testBackupArchiveContainsValidatedSnapshotAndInternalMedia() throws {
    try withTemporaryRoot { root in
      let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
      _ = try repository.acceptCapture(.init(
        envelope: testCapture(requestID: "one", url: "https://example.test/one", title: "One"),
        receivedAtMilliseconds: 1
      ))
      let media = root.appendingPathComponent("LinkDigest/Media", isDirectory: true)
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      try Data("video-fixture".utf8).write(to: media.appendingPathComponent("fixture.mp4"))
      try repository.database.close()

      let manager = fixedManager(root: root)
      let archive = root.appendingPathComponent("backup.linkdigestbackup")
      let inspection = try manager.createBackup(at: archive)

      XCTAssertEqual(inspection.manifest.formatVersion, 1)
      XCTAssertEqual(inspection.manifest.database.path, "database/history.sqlite")
      XCTAssertEqual(inspection.database.counts.tasks, 1)
      XCTAssertEqual(inspection.manifest.media.map(\.path), ["Media/fixture.mp4"])
      XCTAssertEqual(try manager.inspectBackup(at: archive), inspection)
    }
  }

  func testRestoreStagesAutomaticCurrentBackupAndAppliesOnlyBeforeReopen() throws {
    let fileManager = FileManager.default
    try withTemporaryRoot { sourceRoot in
      let sourceRepository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: sourceRoot))
      for index in 0..<2 {
        _ = try sourceRepository.acceptCapture(.init(
          envelope: testCapture(
            requestID: "source-\(index)",
            url: "https://source.example/\(index)",
            title: "Source \(index)"
          ),
          receivedAtMilliseconds: Int64(index + 1)
        ))
      }
      let sourceMedia = sourceRoot.appendingPathComponent("LinkDigest/Media", isDirectory: true)
      try fileManager.createDirectory(at: sourceMedia, withIntermediateDirectories: true)
      try Data("restored-media".utf8).write(to: sourceMedia.appendingPathComponent("restored.mp4"))
      try sourceRepository.database.close()
      let sourceManager = fixedManager(root: sourceRoot)
      let sourceArchive = sourceRoot.appendingPathComponent("source.linkdigestbackup")
      _ = try sourceManager.createBackup(at: sourceArchive)

      try withTemporaryRoot { currentRoot in
        let currentRepository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: currentRoot))
        _ = try currentRepository.acceptCapture(.init(
          envelope: testCapture(
            requestID: "current",
            url: "https://current.example/only",
            title: "Current"
          ),
          receivedAtMilliseconds: 10
        ))

        let currentManager = fixedManager(root: currentRoot)
        let scheduled = try currentManager.scheduleRestore(from: sourceArchive)
        XCTAssertEqual(scheduled.itemCount, 2)
        XCTAssertEqual(
          try currentManager.inspectBackup(at: scheduled.automaticBackupURL).database.counts.tasks,
          1,
          "恢复前自动备份必须保存当前库，而不是所选备份"
        )
        XCTAssertEqual(
          try DatabaseMaintenance(database: currentRepository.database).counts().tasks,
          1,
          "安排恢复时不能覆盖仍被 App 持有的 SQLite"
        )
        try currentRepository.database.close()

        let applied = try XCTUnwrap(currentManager.applyPendingRestoreIfNeeded())
        XCTAssertEqual(applied.itemCount, 2)
        let restored = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: currentRoot))
        XCTAssertEqual(try DatabaseMaintenance(database: restored.database).counts().tasks, 2)
        try restored.database.close()
        XCTAssertEqual(
          try Data(contentsOf: currentRoot.appendingPathComponent("LinkDigest/Media/restored.mp4")),
          Data("restored-media".utf8)
        )
        XCTAssertNil(try currentManager.applyPendingRestoreIfNeeded())
      }
    }
  }

  func testRestoreRejectsManifestChecksumMismatchBeforeCreatingAutomaticBackup() throws {
    try withTemporaryRoot { root in
      let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
      _ = try repository.acceptCapture(.init(
        envelope: testCapture(requestID: "safe", url: "https://example.test/safe", title: "Safe"),
        receivedAtMilliseconds: 1
      ))
      try repository.database.close()
      let manager = fixedManager(root: root)
      let valid = root.appendingPathComponent("valid.linkdigestbackup")
      _ = try manager.createBackup(at: valid)

      let extracted = root.appendingPathComponent("tamper", isDirectory: true)
      try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
      try ZipArchiveTool().extractArchive(at: valid, to: extracted)
      let database = extracted.appendingPathComponent("LinkDigestBackup/database/history.sqlite")
      let handle = try FileHandle(forWritingTo: database)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("tamper".utf8))
      try handle.close()
      let tampered = root.appendingPathComponent("tampered.linkdigestbackup")
      try ZipArchiveTool().createArchive(
        from: extracted.appendingPathComponent("LinkDigestBackup"),
        at: tampered
      )

      XCTAssertThrowsError(try manager.scheduleRestore(from: tampered)) { error in
        XCTAssertEqual(error as? LibraryBackupError, .checksumMismatch)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: manager.automaticBackupsDirectoryURL.path))
    }
  }

  func testBatchExportReportsEveryItemAndDisambiguatesDuplicateTitles() async throws {
    try await withTemporaryRootAsync { root in
      let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
      var firstTaskID: TaskID?
      for index in 0..<2 {
        let accepted = try repository.acceptCapture(.init(
          envelope: testCapture(
            requestID: "export-\(index)",
            url: "https://export.example/\(index)",
            title: "Same Title"
          ),
          receivedAtMilliseconds: Int64(index + 1)
        ))
        if firstTaskID == nil { firstTaskID = accepted.taskID }
      }
      let projection = try repository.exportProjection(taskID: XCTUnwrap(firstTaskID))
      let suggested = try HistoryExportRenderer.render(projection, as: .markdown).suggestedFilename
      var usedNames = Set<String>()
      let firstFilename = HistoryBatchExporter.uniqueFilename(
        suggestedFilename: suggested,
        usedLowercasedNames: &usedNames
      )
      let secondFilename = HistoryBatchExporter.uniqueFilename(
        suggestedFilename: suggested,
        usedLowercasedNames: &usedNames
      )
      let recorder = ProgressRecorder()
      let output = root.appendingPathComponent("exports", isDirectory: true)
      let report = try await HistoryBatchExporter(
        history: HistoryApplicationService(repository: repository)
      ).exportMarkdown(to: output) { progress in
        await recorder.append(progress)
      }
      XCTAssertEqual(report.exportedCount, 2)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(),
        [firstFilename, secondFilename].sorted()
      )
      let progress = await recorder.values()
      XCTAssertEqual(progress.map(\.completed), [0, 1, 2])
      XCTAssertTrue(progress.allSatisfy { $0.total == 2 })
      try repository.database.close()
    }
  }
}

private actor ProgressRecorder {
  private var progress: [HistoryBatchExportProgress] = []
  func append(_ value: HistoryBatchExportProgress) { progress.append(value) }
  func values() -> [HistoryBatchExportProgress] { progress }
}

private func fixedManager(root: URL) -> LibraryBackupManager {
  LibraryBackupManager(
    applicationSupportRoot: root,
    now: { Date(timeIntervalSince1970: 1_800_000_000) },
    appVersion: { ("1.2.3", "45") }
  )
}

private func testCapture(requestID: String, url: String, title: String) -> CaptureEnvelopeV1 {
  let body = "fixture body \(requestID)"
  return CaptureEnvelopeV1(
    version: 1,
    requestId: requestID,
    createdAt: "2026-07-15T04:00:00Z",
    idempotencyKey: requestID,
    source: .init(kind: "browser_capture", url: url, title: title, platform: "generic"),
    capture: .init(
      method: "rendered_dom",
      text: body,
      characterCount: body.unicodeScalars.count,
      completeness: "full_article",
      capturedAt: "2026-07-15T04:00:00Z"
    ),
    evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false)
  )
}

private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "linkdigest-library-backup-tests-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func withTemporaryRootAsync(_ body: (URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "linkdigest-library-export-tests-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}
