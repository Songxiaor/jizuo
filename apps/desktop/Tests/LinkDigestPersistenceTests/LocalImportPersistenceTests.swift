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

/// 侧栏按「谁说的」（自有 / 外部）和「是什么」（形式）分类（2026-09-24）；
/// 素材类型仍是普通标签；「已使用」只留给 MCP 的 unused_only。
final class MaterialScopeTests: XCTestCase {
  private func withRepository(_ body: (GRDBHistoryRepository, Int64) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-material-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    try body(repository, Int64(Date().timeIntervalSince1970 * 1000))
  }

  private func file(_ repository: GRDBHistoryRepository, _ c: Character, text: String? = nil, now: Int64) throws -> TaskID {
    try repository.acceptCapture(.init(
      document: LocalImportDocument.file(
        contentSHA256: String(repeating: c, count: 64), fileName: "\(c).md", text: text ?? "正文 \(c)",
        completeness: "complete", method: "local_file_text", fileDate: nil
      ),
      receivedAtMilliseconds: now
    )).taskID
  }

  private func memo(_ repository: GRDBHistoryRepository, now: Int64) throws -> TaskID {
    try repository.acceptCapture(.init(
      document: LocalImportDocument.voiceMemo(recordingID: "M", title: "录音", recordedAt: nil, durationSeconds: 3),
      receivedAtMilliseconds: now
    )).taskID
  }

  private func ids(_ repository: GRDBHistoryRepository, _ filter: HistoryListFilter) throws -> Set<TaskID> {
    Set(try repository.historyPage(limit: 50, after: nil, filter: filter).rows.map(\.taskID))
  }

  /// 默认规则：笔记、语音备忘录算自有，拖进来的文件算外部；自有 + 外部 = 全部。
  func testOwnershipDefaultsAddUpToTotal() throws {
    try withRepository { repository, now in
      let doc = try file(repository, "a", now: now)
      let recording = try memo(repository, now: now)
      let note = try repository.acceptCapture(.init(document: UserNoteDocument.make(title: "笔记", body: "自己写的"), receivedAtMilliseconds: now)).taskID

      let counts = try repository.navigationCounts()
      XCTAssertEqual(counts.total, 3)
      XCTAssertEqual(counts.own, 2)
      XCTAssertEqual(counts.external, 1)
      XCTAssertEqual(counts.own + counts.external, counts.total)
      XCTAssertEqual(counts.all, 2, "MCP 统计的 all 仍只数抓来的资料，不含笔记")
      XCTAssertEqual(try ids(repository, .init(scope: .own, includesNotes: true)), [recording, note])
      XCTAssertEqual(try ids(repository, .init(scope: .external, includesNotes: true)), [doc])
      XCTAssertEqual(try ids(repository, .init(scope: .all, includesNotes: true)), [doc, recording, note])
    }
  }

  /// 手动改归属落在两个保留标签上，优先于默认规则；和默认一致时两个标签都摘掉。
  func testManualOwnershipOverridesTheDefault() throws {
    try withRepository { repository, now in
      let doc = try file(repository, "a", now: now)
      let recording = try memo(repository, now: now)

      _ = try repository.addTags([ContentOwnership.ownTagName], to: doc)
      _ = try repository.addTags([ContentOwnership.externalTagName], to: recording)
      XCTAssertEqual(try ids(repository, .init(scope: .own, includesNotes: true)), [doc])
      XCTAssertEqual(try ids(repository, .init(scope: .external, includesNotes: true)), [recording])
      let counts = try repository.navigationCounts()
      XCTAssertEqual(counts.own, 1)
      XCTAssertEqual(counts.external, 1)

      try repository.removeTag(normalizedName: ContentOwnership.ownTagNormalizedName, from: doc)
      XCTAssertEqual(try ids(repository, .init(scope: .external, includesNotes: true)), [doc, recording])
    }
  }

  /// 形式按抓取时已有的信息判定：录音、文档、图片、音频文件、笔记。
  func testFormsAreDerivedByRules() throws {
    try withRepository { repository, now in
      let doc = try file(repository, "a", now: now)
      let image = try file(repository, "b", text: LocalImportDocument.imageBody(fileName: "b.png", reference: "linkdigest-local://localfiles/b", recognizedText: nil), now: now)
      let audioFile = try file(repository, "c", text: LocalImportDocument.mediaPlaceholder(fileName: "c.m4a", durationSeconds: 3, hasVideo: false), now: now)
      let videoFile = try file(repository, "d", text: LocalImportDocument.mediaPlaceholder(fileName: "d.mov", durationSeconds: 3, hasVideo: true), now: now)
      let recording = try memo(repository, now: now)
      let note = try repository.acceptCapture(.init(document: UserNoteDocument.make(title: "笔记", body: "自己写的"), receivedAtMilliseconds: now)).taskID
      // 旧版图片导入第一份快照只有识别文字；同一文件重新导入后按最新一份算图片。
      let reimported = try file(repository, "e", text: "旧版识别文字", now: now)
      XCTAssertEqual(try file(repository, "e", text: LocalImportDocument.imageBody(fileName: "e.png", reference: "linkdigest-local://localfiles/e", recognizedText: nil), now: now + 1), reimported)

      func form(_ value: ContentForm) throws -> Set<TaskID> {
        try ids(repository, .init(scope: .all, includesNotes: true, form: value))
      }
      XCTAssertEqual(try form(.document), [doc])
      XCTAssertEqual(try form(.image), [image, reimported])
      XCTAssertEqual(try form(.audio), [audioFile, recording])
      XCTAssertEqual(try form(.video), [videoFile])
      XCTAssertEqual(try form(.note), [note])
      XCTAssertEqual(try form(.article), [])

      let counts = try repository.navigationCounts().forms
      XCTAssertEqual(counts.map(\.form), [.video, .audio, .image, .document, .note], "只列有内容的形式，顺序同 ContentForm")
      XCTAssertEqual(counts.first { $0.form == .audio }?.count, 2)
      XCTAssertEqual(counts.reduce(0) { $0 + $1.count }, try repository.navigationCounts().total)
    }
  }

  /// 素材类型仍是普通标签；MCP 的 unused_only 仍按「已使用」排除。
  func testMaterialTagsAndMCPUnusedFilter() throws {
    try withRepository { repository, now in
      let a = try file(repository, "a", now: now), b = try file(repository, "b", now: now)
      let note = try repository.acceptCapture(.init(document: UserNoteDocument.make(title: "笔记", body: "不算资料"), receivedAtMilliseconds: now)).taskID
      _ = try repository.addTags(["灵感"], to: note)
      XCTAssertTrue(try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["灵感"])).rows.isEmpty)
      XCTAssertEqual(try ids(repository, .init(tagNames: ["灵感"], includesNotes: true)), [note])

      _ = try repository.addTags([MaterialCatalog.usedTagName, "金句"], to: a)
      XCTAssertEqual(try ids(repository, .init(excludesUsed: true)), [b])
      XCTAssertEqual(try ids(repository, .init(tagNames: ["金句"])), [a])
      XCTAssertTrue(try ids(repository, .init(tagNames: ["金句"], excludesUsed: true)).isEmpty)
    }
  }

  /// 旧档案（语音备忘录、备忘录）不进待总结；存入时间可以挪回原始日期，但只往前挪。
  func testArchiveImportsStayOutOfUnsummarizedAndCanBeBackdated() throws {
    try withRepository { repository, now in
      let recording = try memo(repository, now: now)
      _ = try file(repository, "c", now: now)
      XCTAssertEqual(try repository.navigationCounts().unsummarized, 1)

      let original = now - 400 * 86_400_000
      try repository.alignArchiveTaskTime(taskID: recording, originalMilliseconds: original)
      XCTAssertEqual(try repository.navigationCounts().recent, 1, "挪回一年前后，不再算「最近 7 天」")
      try repository.alignArchiveTaskTime(taskID: recording, originalMilliseconds: now)
      XCTAssertEqual(try repository.navigationCounts().recent, 1)
    }
  }

  /// 标签管理：改名、改成已有名字即合并、多选合并、删除只摘标签；系统标记不可动。
  func testTagManagementRenameMergeAndDelete() throws {
    try withRepository { repository, now in
      let a = try file(repository, "a", now: now), b = try file(repository, "b", now: now), c = try file(repository, "c", now: now)
      _ = try repository.addTags(["AI 编程", "开源"], to: a)
      _ = try repository.addTags(["AI编程"], to: b)
      _ = try repository.addTags(["AI编程", "AI 编程", "工具"], to: c)
      func names(_ id: TaskID) throws -> Set<String> { Set(try repository.detail(taskID: id).tags.map(\.name)) }

      // 改成已有的名字 = 合并；两个都挂着的条目只留一个。
      XCTAssertEqual(try repository.renameTag(normalizedName: "ai 编程", to: "AI编程").name, "AI编程")
      XCTAssertEqual(try names(a), ["AI编程", "开源"])
      XCTAssertEqual(try names(c), ["AI编程", "工具"])
      XCTAssertEqual(try repository.historyPage(limit: 50, after: nil, filter: .init(tagNames: ["AI编程"])).rows.count, 3)

      // 纯改名。
      XCTAssertEqual(try repository.renameTag(normalizedName: "开源", to: "开源项目").name, "开源项目")
      XCTAssertEqual(try names(a), ["AI编程", "开源项目"])

      // 多选合并到一个新名字。
      _ = try repository.mergeTags(["开源项目", "工具"], into: "开源工具")
      XCTAssertEqual(try names(a), ["AI编程", "开源工具"])
      XCTAssertEqual(try names(c), ["AI编程", "开源工具"])
      XCTAssertFalse(try repository.allTags().map(\.name).contains("工具"))

      // 删除只摘标签，资料都在。
      XCTAssertEqual(try repository.deleteTagEverywhere(normalizedName: "ai编程"), 3)
      XCTAssertEqual(try names(b), [])
      XCTAssertEqual(try repository.navigationCounts().total, 3)

      // 系统标记不能改名、合并、删除，也不能被改成。
      _ = try repository.addTags([MaterialCatalog.usedTagName], to: b)
      XCTAssertThrowsError(try repository.deleteTagEverywhere(normalizedName: MaterialCatalog.usedTagNormalizedName))
      XCTAssertThrowsError(try repository.renameTag(normalizedName: "开源工具", to: "自有"))
      XCTAssertThrowsError(try repository.mergeTags([MaterialCatalog.usedTagNormalizedName], into: "开源工具"))
      XCTAssertEqual(try names(b), [MaterialCatalog.usedTagName])
    }
  }
}
