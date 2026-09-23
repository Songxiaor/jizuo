import Foundation
import GRDB
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 本机导入素材落库后，要像其它来源一样出现在资料、平台分组里，
/// 并且能挂音频、存回转写稿。
final class LocalImportPersistenceTests: XCTestCase {
  private func withTemporaryLocation(_ body: (LocalDatabaseLocation) throws -> Void) throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/linkdigest-local-import-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(LocalDatabaseLocation(directoryURL: directory))
  }

  private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  func testVoiceMemoAppearsAsItsOwnPlatformAndInAllMaterials() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let document = try LocalImportDocument.voiceMemo(
        recordingID: "REC-1", title: "选题灵感", recordedAt: Date(), durationSeconds: 30
      )
      let taskID = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: now)).taskID

      let platforms = try repository.navigationCounts().platforms
      XCTAssertEqual(platforms.first { $0.host == "voicememos" }?.count, 1)

      let filtered = try repository.historyPage(limit: 50, after: nil, filter: .init(hosts: ["voicememos"]))
      XCTAssertEqual(filtered.rows.map(\.taskID), [taskID])
      XCTAssertEqual(filtered.rows.first?.host, "voicememos")

      let all = try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .all))
      XCTAssertTrue(all.rows.contains { $0.taskID == taskID })
      let notes = try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .notes))
      XCTAssertFalse(notes.rows.contains { $0.taskID == taskID })
    }
  }

  func testReimportingSameRecordingDoesNotDuplicate() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let first = try LocalImportDocument.voiceMemo(recordingID: "REC-2", title: "a", recordedAt: nil, durationSeconds: nil)
      let second = try LocalImportDocument.voiceMemo(recordingID: "REC-2", title: "a", recordedAt: nil, durationSeconds: nil)
      let a = try repository.acceptCapture(.init(document: first, receivedAtMilliseconds: now))
      let b = try repository.acceptCapture(.init(document: second, receivedAtMilliseconds: now + 1))
      XCTAssertEqual(a.taskID, b.taskID)
      XCTAssertFalse(b.taskWasCreated)
      XCTAssertEqual(try repository.taskID(forCanonicalURL: CanonicalURL(first.url)), a.taskID)
    }
  }

  /// 录音挂上音频 → 开始转写 → 转写稿存回同一条目。这条链断了，
  /// 语音备忘录就只剩一段听不了、转不了的占位文字。
  func testVoiceMemoAudioCanBeAttachedAndTranscriptSavedBack() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }
      let document = try LocalImportDocument.voiceMemo(recordingID: "REC-3", title: "访谈", recordedAt: nil, durationSeconds: 12)
      let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: now))
      let sha = String(repeating: "b", count: 64)
      let asset = MediaAsset(
        taskID: accepted.taskID, snapshotID: accepted.snapshotID,
        relativePath: "\(sha).mp4", contentSHA256: sha, byteSize: 1_024,
        durationSeconds: 12, platform: "voicememos", createdAtMilliseconds: now
      )
      try repository.attachMedia(.init(asset: asset))
      XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.relativePath, "\(sha).mp4")

      let attempt = try repository.beginMediaTranscription(taskID: accepted.taskID, mediaID: asset.id)
      let finishedAt = now + 10
      let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(finishedAt) / 1000))
      let transcript = CapturedDocument(
        createdAt: timestamp, origin: .localTranscription, url: document.url, title: "访谈",
        platform: "voicememos", method: "speech_analyzer_local", text: "今天聊了三个选题。",
        completeness: "complete", capturedAt: timestamp, sourceLabel: "本机视频转写"
      )
      let result = try repository.completeMediaTranscription(.init(
        taskID: accepted.taskID, attempt: attempt, document: transcript,
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh-CN", language: "zh", completedAtMilliseconds: finishedAt),
        receivedAtMilliseconds: finishedAt
      ))
      guard case .accepted = result else { return XCTFail("转写稿没有存回：\(result)") }
      let detail = try repository.detail(taskID: accepted.taskID)
      XCTAssertTrue(detail.snapshots.contains { $0.bodyText == "今天聊了三个选题。" })
    }
  }
}

/// 「未使用」= 没带「已使用」标签的资料；素材类型就是普通标签，能按标签筛。
final class MaterialScopeTests: XCTestCase {
  func testUnusedScopeAndCountFollowTheUsedTag() throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-material-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    // 用手动导入的本地文件做样例：语音备忘录、备忘录是批量同步的旧档案，按设计不进收件箱。
    func add(_ id: String) throws -> TaskID {
      let sha = String(repeating: id.lowercased() == "a" ? "a" : "b", count: 64)
      return try repository.acceptCapture(.init(
        document: LocalImportDocument.file(
          contentSHA256: sha, fileName: "\(id).md", text: "正文 \(id)", completeness: "complete",
          method: "local_file_text", fileDate: nil
        ),
        receivedAtMilliseconds: now
      )).taskID
    }
    let a = try add("A"), b = try add("B")
    let note = try repository.acceptCapture(.init(document: UserNoteDocument.make(title: "笔记", body: "不算资料"), receivedAtMilliseconds: now)).taskID
    _ = try repository.addTags(["灵感"], to: note)
    // 侧栏浏览不含笔记；MCP 按素材类型取灵感时要带上笔记。
    XCTAssertTrue(try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["灵感"])).rows.isEmpty)
    XCTAssertEqual(try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["灵感"], includesNotes: true)).rows.map(\.taskID), [note])
    XCTAssertEqual(try repository.navigationCounts().unused, 2)

    _ = try repository.addTags([MaterialCatalog.usedTagName, "金句"], to: a)
    let unused = try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .unused)).rows.map(\.taskID)
    XCTAssertEqual(unused, [b])
    XCTAssertEqual(try repository.navigationCounts().unused, 1)

    let quotes = try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["金句"])).rows.map(\.taskID)
    XCTAssertEqual(quotes, [a])
    // 组合：未使用的金句——a 已用过，所以为空。
    XCTAssertTrue(try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["金句"], scope: .unused)).rows.isEmpty)
  }

  /// 批量同步的旧档案（语音备忘录、备忘录）不进收件箱和待总结；MCP 取素材时照常包含；
  /// 存入时间可以挪回原始日期，但只往前挪。
  func testArchiveImportsStayOutOfInboxAndCanBeBackdated() throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-archive-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let memo = try repository.acceptCapture(.init(
      document: LocalImportDocument.voiceMemo(recordingID: "M", title: "录音", recordedAt: nil, durationSeconds: 3),
      receivedAtMilliseconds: now
    )).taskID
    let file = try repository.acceptCapture(.init(
      document: LocalImportDocument.file(
        contentSHA256: String(repeating: "c", count: 64), fileName: "a.md", text: "正文",
        completeness: "complete", method: "local_file_text", fileDate: nil
      ),
      receivedAtMilliseconds: now
    )).taskID

    let counts = try repository.navigationCounts()
    XCTAssertEqual(counts.all, 2)
    XCTAssertEqual(counts.unused, 1)
    XCTAssertEqual(counts.unsummarized, 1)
    XCTAssertEqual(try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .unused)).rows.map(\.taskID), [file])
    XCTAssertEqual(
      Set(try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .unused, includesArchivesInScopes: true)).rows.map(\.taskID)),
      [memo, file]
    )

    _ = try repository.addTags([MaterialCatalog.usedTagName], to: memo)
    XCTAssertEqual(try repository.navigationCounts().used, 1)

    let original = now - 400 * 86_400_000
    try repository.alignArchiveTaskTime(taskID: memo, originalMilliseconds: original)
    XCTAssertEqual(try repository.navigationCounts().recent, 1, "挪回一年前后，不再算「最近 7 天」")
    // 只往前挪：再给一个更晚的时间不会把它推回来。
    try repository.alignArchiveTaskTime(taskID: memo, originalMilliseconds: now)
    XCTAssertEqual(try repository.navigationCounts().recent, 1)
  }
}
