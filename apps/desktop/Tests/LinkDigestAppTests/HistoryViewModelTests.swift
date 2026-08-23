import Foundation
import GRDB
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

@MainActor
final class HistoryViewModelTests: XCTestCase {
  /// 能力授权（在线转写／转写整理／脑图）是持久记录：同意一次就不再弹确认框。
  /// 用例之间共用同一个域时，前一条点过的「同意」会让后一条该弹的框不弹，
  /// 断言随执行顺序时绿时红。每条用例开始前清空。
  override func setUp() {
    super.setUp()
    CapabilityConsent.revokeAll()
  }


  /// 导出必须拿到转写稿，并把它与配文分层标注。
  ///
  /// 这条用例守的核心仍是最初那个 bug：视频条目一定先有一条 browser_capture
  /// 快照（几十字的 caption），转写稿是之后追加的。一旦导出退回「优先非转写
  /// 快照」，抓一条视频 → 转写 → 导出 Markdown/纯文本/PDF/Word 或「拷贝全文」，
  /// 几千字的转写稿会一个字都不在，而阅读区和总结输入用的都是转写稿。
  ///
  /// 契约变更：本用例原来还断言「导出里不能出现 caption」。那在 2026-07-27
  /// 修这个 bug 时是对的——当时导出只该取转写稿。2026-08-21 的「配文与转写
  /// 分层」改了契约：两层都要带上，并各自标清楚是什么，让导出与阅读区一致。
  /// 那条断言从此与产品设计直接冲突，改为下面的分层断言。
  func testExportCarriesTranscriptAndLabelsItSeparatelyFromCaption() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-export-transcript-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let caption = "短标题党文案"
    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z",
        origin: .manualLink,
        url: "https://example.test/video-export",
        title: "一条视频",
        platform: "douyin",
        method: "rendered_dom",
        text: "---\nauthor: \"某作者\"\n---\n\n\(caption)",
        completeness: "complete",
        capturedAt: "2026-07-20T00:00:00Z",
        sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))
    let transcript = "这是完整的转写稿，内容远比 caption 长，是用户真正想导出的东西。"
    // 转写稿走的是 begin/completeTaskTranscription，不是 acceptCapture。
    let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
    let completion = try repository.completeTaskTranscription(.init(
      taskID: accepted.taskID,
      attempt: attempt,
      document: CapturedDocument(
        createdAt: "2026-07-20T00:01:00Z",
        origin: .localTranscription,
        url: "https://example.test/video-export",
        title: "一条视频",
        platform: "douyin",
        method: "speech_analyzer_local",
        text: transcript,
        completeness: "complete",
        capturedAt: "2026-07-20T00:01:00Z",
        sourceLabel: "本机转写"
      ),
      evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
      receivedAtMilliseconds: 3
    ))
    guard case .accepted = completion else { return XCTFail("转写稿应当落库") }

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == accepted.taskID && model.detailState == .loaded }

    let exported = try XCTUnwrap(model.composeExportMarkdown())
    // 原始 bug 的防线：转写稿必须在。
    XCTAssertTrue(exported.markdown.contains(transcript), "导出里没有转写稿：\(exported.markdown)")
    // 分层契约：配文也在，但两层各有标题，不能糊成一段。标题引用常量而不是
    // 写死文案，改文案时这条不该假失败。
    XCTAssertTrue(exported.markdown.contains(caption), "分层导出应当保留配文")
    let captionHeading = try XCTUnwrap(
      exported.markdown.range(of: LayeredSourceDocument.captionHeading),
      "配文层缺少标题：\(exported.markdown)"
    )
    let transcriptHeading = try XCTUnwrap(
      exported.markdown.range(of: LayeredSourceDocument.transcriptHeading),
      "转写层缺少标题：\(exported.markdown)"
    )
    // 顺序与阅读区一致：配文在前，转写在后。
    XCTAssertLessThan(captionHeading.lowerBound, transcriptHeading.lowerBound, "配文应排在转写之前")
    // frontmatter 仍应来自来源快照——转写稿没有作者字段。
    XCTAssertTrue(exported.markdown.contains("某作者"), "作者应取自来源快照")
  }

  /// 在笔记里打字后 800ms 内切换条目，那段编辑不能丢。
  ///
  /// 原实现有两处会静默丢数据：切条目时 `receiveDetail` 给 `taskNoteDraft` 赋新值
  /// 会触发编辑器的 onChange → `scheduleNoteSave(新条目)` → `cancel()` 掐掉上一条
  /// 尚未落库的写入；即使没被 cancel，`selectedTaskID == taskID` 那个守卫也已经
  /// 不成立。用户看到的是「输入后立刻切走，最后那段编辑消失」，而界面上明明写着
  /// 「笔记自动保存」。防抖窗口只有 800ms，手快就会中招，且丢了不会有任何提示。
  func testNoteSurvivesSwitchingItemsInsideTheDebounceWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-note-flush-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    func makeDocument(_ tag: String) -> CapturedDocument {
      CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z",
        origin: .manualLink,
        url: "https://example.test/note-\(tag)",
        title: "条目\(tag)",
        platform: "fixture",
        method: "fixture",
        text: "正文 \(tag)",
        completeness: "visible_only",
        capturedAt: "2026-07-20T00:00:00Z",
        sourceLabel: "fixture"
      )
    }
    let a = try repository.acceptCapture(.init(document: makeDocument("A"), receivedAtMilliseconds: 1))
    let b = try repository.acceptCapture(.init(document: makeDocument("B"), receivedAtMilliseconds: 2))

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    // 停在 A 上打字，立刻切到 B——不等 800ms 防抖。
    model.selectedTaskIDs = [a.taskID]
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }
    model.taskNoteDraft = "切换前写的笔记"
    model.scheduleNoteSave(taskID: a.taskID)
    model.selectedTaskIDs = [b.taskID]
    await waitUntil { model.selectedTaskID == b.taskID && model.detailState == .loaded }
    // 关键：模拟编辑器的 onChange。真实界面上，receiveDetail 把 taskNoteDraft 覆盖成
    // B 的笔记会触发 onChange → scheduleNoteSave(B)，正是这一步在原实现里 cancel 掉
    // 了 A 尚未落库的写入。不模拟它，这条测试就永远是绿的，抓不到任何东西。
    model.scheduleNoteSave(taskID: b.taskID)

    let store = try XCTUnwrap(HistoryApplicationService(repository: repository).annotationStore)
    var saved: String?
    for _ in 0..<40 {
      saved = try store.loadNote(taskID: a.taskID)
      if saved?.isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(saved, "切换前写的笔记", "防抖窗口内切换条目丢掉了笔记")
  }

  /// 摘录、笔记和 Token 账原来在 `receiveDetail` 里同步读，四次 SQLite 全压在主线程上，
  /// 切换文章时界面不出帧。现在它们和正文一起在后台读完再一次性铺上——这条测试守住
  /// 「换个搬运方式，屏幕上出现的东西不能少」。
  func testSwitchingItemsLoadsAnnotationsWithTheDetail() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-sideload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    func makeDocument(_ tag: String) -> CapturedDocument {
      CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
        url: "https://example.test/sideload-\(tag)", title: "条目\(tag)",
        platform: "fixture", method: "fixture", text: "正文 \(tag)",
        completeness: "visible_only", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture")
    }
    let a = try repository.acceptCapture(.init(document: makeDocument("A"), receivedAtMilliseconds: 1))
    let b = try repository.acceptCapture(.init(document: makeDocument("B"), receivedAtMilliseconds: 2))

    let service = HistoryApplicationService(repository: repository)
    let store = try XCTUnwrap(service.annotationStore)
    try store.saveNote(taskID: b.taskID, body: "B 的笔记", updatedAtMilliseconds: 10)
    try store.addExcerpt(
      .init(taskID: b.taskID, excerpt: "B 的摘录", createdAtMilliseconds: 11)
    )

    let model = HistoryViewModel()
    model.configure(history: service, isReadOnly: false, unavailableCode: nil)
    model.selectedTaskIDs = [a.taskID]
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }
    XCTAssertTrue(model.taskExcerpts.isEmpty)

    model.selectedTaskIDs = [b.taskID]
    await waitUntil { model.selectedTaskID == b.taskID && model.detailState == .loaded }
    XCTAssertEqual(model.taskNoteDraft, "B 的笔记")
    XCTAssertEqual(model.taskExcerpts.map(\.excerpt), ["B 的摘录"])
  }

  /// 上一条／下一条在当前列表里移动选中项，到两端停住。
  ///
  /// 不假设列表是新→旧还是旧→新：最早创建的那条必在某一端，从它出发只有一个方向可走；
  /// 朝可走方向连走两步到最新一条，那也是另一端；越过端点选中不变。
  func testSelectAdjacentMovesWithinListAndClampsAtEnds() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-adjacent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    func makeDocument(_ tag: String) -> CapturedDocument {
      CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
        url: "https://example.test/item-\(tag)", title: "条目\(tag)",
        platform: "fixture", method: "fixture", text: "正文 \(tag)",
        completeness: "visible_only", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture")
    }
    let a = try repository.acceptCapture(.init(document: makeDocument("A"), receivedAtMilliseconds: 1))
    _ = try repository.acceptCapture(.init(document: makeDocument("B"), receivedAtMilliseconds: 2))
    let c = try repository.acceptCapture(.init(document: makeDocument("C"), receivedAtMilliseconds: 3))

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.selectedTaskIDs = [a.taskID]
    await waitUntil { model.selectedTaskID == a.taskID }
    XCTAssertNotEqual(
      model.canSelectPrevious, model.canSelectNext,
      "最早的一条在列表端点：恰好一个方向可走")
    let toward = model.canSelectNext ? 1 : -1

    model.selectAdjacent(offset: toward)
    await waitUntil { model.selectedTaskID != a.taskID }
    model.selectAdjacent(offset: toward)
    await waitUntil { model.selectedTaskID == c.taskID }
    XCTAssertNotEqual(
      model.canSelectPrevious, model.canSelectNext,
      "最新的一条在另一端点：也恰好一个方向可走")

    model.selectAdjacent(offset: toward)
    XCTAssertEqual(model.selectedTaskID, c.taskID, "越过端点应当保持不动")
  }

  /// 收藏切换要真正反映到工具栏星标和侧栏「收藏」计数。
  ///
  /// 计数曾经恒为 0：`reloadNavigationCounts` 重建结构体时漏抄了 favorite 字段。
  /// 这类「重建时丢字段」不报错、不崩溃，只是数字不动，所以在 VM 层钉住。
  func testTogglingFavoriteUpdatesStarAndSidebarCount() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-fav-vm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let doc = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
      url: "https://example.test/fav", title: "条目",
      platform: "fixture", method: "fixture", text: "正文",
      completeness: "visible_only", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture")
    let accepted = try repository.acceptCapture(.init(document: doc, receivedAtMilliseconds: 1))

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == accepted.taskID && model.detailState == .loaded }
    XCTAssertFalse(model.isSelectedFavorite)

    model.toggleFavorite()
    await waitUntil { model.isSelectedFavorite }
    await waitUntil { model.navigationCounts.favorite == 1 }
    XCTAssertEqual(model.navigationCounts.favorite, 1, "收藏后侧栏计数必须变 1")

    model.toggleFavorite()
    await waitUntil { !model.isSelectedFavorite }
    await waitUntil { model.navigationCounts.favorite == 0 }
    XCTAssertEqual(model.navigationCounts.favorite, 0, "取消收藏后计数要回到 0")
  }

  func testSameHashRepairMakesHistoryResolveNewUserDirectoryFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-repair-\(UUID().uuidString)", isDirectory: true)
    let selectedRoot = root.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (suite, defaults) = try ephemeralDefaults("linkdigest-media-repair-")
    let preference = UserDefaultsMediaStoragePreferenceStore(
      defaults: defaults,
      createBookmark: { Data($0.path.utf8) },
      resolveBookmark: { data in
        guard let path = String(data: data, encoding: .utf8) else {
          throw MediaStoragePreferenceError.missingResource
        }
        return (URL(fileURLWithPath: path), false)
      }
    )
    try preference.saveDirectory(selectedRoot)
    let store = LocalMediaStore(applicationSupportRoot: root, storagePreference: preference)
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z",
      origin: .manualLink,
      url: "https://example.test/repaired-video",
      title: "修复本地视频",
      platform: "fixture",
      method: "fixture",
      text: "视频正文",
      completeness: "complete",
      capturedAt: "2026-07-20T00:00:00Z",
      sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    let body = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0])
    let sha = LocalMediaStore.contentSHA256(body)
    try repository.attachMedia(.init(asset: .init(
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID,
      relativePath: "\(sha).mov",
      fileBookmark: Data(root.appendingPathComponent("missing/\(sha).mov").path.utf8),
      contentSHA256: sha,
      byteSize: Int64(body.count),
      platform: "fixture",
      createdAtMilliseconds: 2
    )))

    let storedFile = try store.storeDetailed(data: body, preferredExtension: "mp4")
    try repository.attachMedia(.init(asset: .init(
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID,
      relativePath: storedFile.relativePath,
      fileBookmark: storedFile.fileBookmark,
      contentSHA256: storedFile.sha256,
      byteSize: Int64(body.count),
      durationSeconds: 12,
      platform: "fixture",
      author: "作者",
      createdAtMilliseconds: 3
    )))

    let model = HistoryViewModel(mediaStore: store)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.localMediaFileURL != nil }

    XCTAssertEqual(model.localMediaFileURL?.standardizedFileURL, storedFile.fileURL.standardizedFileURL)
    XCTAssertEqual(try repository.mediaAsset(taskID: accepted.taskID)?.fileBookmark, storedFile.fileBookmark)
    let mediaFiles = try FileManager.default.contentsOfDirectory(
      at: selectedRoot,
      includingPropertiesForKeys: [.isRegularFileKey]
    ).filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
    XCTAssertEqual(mediaFiles.map(\.standardizedFileURL), [storedFile.fileURL.standardizedFileURL])
  }

  func testDirectCurrentCaptureFavoriteDownloadsAndAttachesExactlyOnce() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-m2-favorite-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z",
      origin: .manualLink,
      url: "https://example.test/watch",
      title: "M2 direct",
      platform: "fixture",
      method: "dom",
      text: "视频正文",
      completeness: "visible_only",
      capturedAt: "2026-07-20T00:00:00Z",
      sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    let store = LocalMediaStore(applicationSupportRoot: root)
    let download = CountingFavoriteMediaDownload(store: store)
    let model = HistoryViewModel(
      mediaStore: store,
      mediaDownloadOperation: { media, taskID, snapshotID, pageURL in
        try await download.perform(
          media: media,
          taskID: taskID,
          snapshotID: snapshotID,
          pageURL: pageURL
        )
      }
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: document.url,
      canonicalURL: document.url,
      platform: "fixture",
      ephemeralPlaybackURL: "https://media.example.test/video.mp4",
      mimeType: "video/mp4",
      durationSeconds: 12,
      author: "作者",
      transcriptionCapability: .supported
    )

    await model.favoriteCurrentCaptureMedia(
      descriptor,
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID
    )
    await model.favoriteCurrentCaptureMedia(
      descriptor,
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID
    )

    await waitUntil { model.detailState == .loaded && model.localMediaFileURL != nil }
    let downloadCount = await download.callCount
    XCTAssertEqual(downloadCount, 1)
    XCTAssertEqual(model.remoteMediaFavoriteState, .saved)
    XCTAssertNotNil(try repository.mediaAsset(taskID: accepted.taskID))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(model.localMediaFileURL).path))
  }

  func testCapturedMediaAutoSaveFailureIsOwnedAndPresented() async {
    let row = makeRow(title: "Auto-save failure", updatedAt: 30)
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [row], nextCursor: nil),
      details: [row.taskID: makeDetail(for: row)]
    )
    let model = HistoryViewModel(mediaDownloadOperation: { _, _, _, _ in
      throw MediaDownloadError.insufficientDiskSpace
    })
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    await model.autoSaveCapturedMedia(
      .init(platform: "fixture", videoURL: "https://media.example.test/video.mp4"),
      taskID: row.taskID,
      snapshotID: makeDetail(for: row).snapshots[0].id,
      pageURL: "https://example.test/video"
    )

    XCTAssertEqual(
      model.capturedMediaAutoSaveStates[row.taskID],
      .failed(MediaDownloadError.insufficientDiskSpace.userMessage)
    )
    XCTAssertTrue(model.isCapturedMediaAutoSaveFailurePresented)
    XCTAssertTrue(model.capturedMediaAutoSaveFailureMessage.contains("磁盘空间不足"))
    XCTAssertTrue(model.capturedMediaAutoSaveFailureMessage.contains("历史正文仍已保存"))
  }

  func testCapturedMediaAutoSaveCompletionDoesNotTakeOverCurrentSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-auto-save-owner-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let first = try repository.acceptCapture(.init(
      document: capturedDocument(title: "First", url: "https://example.test/first"),
      receivedAtMilliseconds: 1
    ))
    let second = try repository.acceptCapture(.init(
      document: capturedDocument(title: "Second", url: "https://example.test/second"),
      receivedAtMilliseconds: 2
    ))
    let gate = MediaDownloadGate()
    let mediaHash = String(repeating: "a", count: 64)
    let asset = MediaAsset(
      taskID: first.taskID,
      snapshotID: first.snapshotID,
      relativePath: "\(mediaHash).mp4",
      fileBookmark: Data("auto-save-owner".utf8),
      contentSHA256: mediaHash,
      byteSize: 16,
      platform: "fixture",
      createdAtMilliseconds: 3
    )
    let model = HistoryViewModel(mediaDownloadOperation: { _, _, _, _ in
      await gate.perform(returning: asset)
    })
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded }
    model.selectedTaskID = first.taskID
    await waitUntil { model.detail?.task.id == first.taskID }

    let saveTask = Task { @MainActor in
      await model.autoSaveCapturedMedia(
        .init(platform: "fixture", videoURL: "https://media.example.test/video.mp4"),
        taskID: first.taskID,
        snapshotID: first.snapshotID,
        pageURL: "https://example.test/first"
      )
    }
    await gate.waitUntilEntered()
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    await gate.release()
    await saveTask.value

    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.detail?.task.id, second.taskID)
    XCTAssertEqual(model.capturedMediaAutoSaveStates[first.taskID], .saved)
    XCTAssertEqual(try repository.mediaAsset(taskID: first.taskID), asset)
  }

  func testDatabaseAttachFailureRollsBackOnlyNewlyCreatedSavedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-media-attach-rollback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let row = makeRow(title: "Attach failure", updatedAt: 30)
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [row], nextCursor: nil),
      details: [row.taskID: makeDetail(for: row)]
    )
    let store = LocalMediaStore(applicationSupportRoot: root)
    let downloader = VideoMediaDownloader(resources: RemoteTempResourceFetcher(), store: store)
    let model = HistoryViewModel(mediaStore: store, mediaDownloader: downloader)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/video",
      canonicalURL: "https://example.test/video",
      platform: "generic",
      ephemeralPlaybackURL: "https://media.example.test/video.mp4",
      mimeType: "video/mp4",
      transcriptionCapability: .supported
    )

    await model.favoriteCurrentCaptureMedia(
      descriptor,
      taskID: row.taskID,
      snapshotID: makeDetail(for: row).snapshots[0].id
    )

    guard case .failed = model.remoteMediaFavoriteState else {
      return XCTFail("attach failure should be user-visible")
    }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: store.mediaRoot,
      includingPropertiesForKeys: nil
    )) ?? []
    XCTAssertTrue(files.isEmpty, "new file must be removed when DB attach fails")
  }

  func testDeletingHistoryRetainsUserDirectoryMediaFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-user-media-delete-\(UUID().uuidString)", isDirectory: true)
    let external = root.appendingPathComponent("user-video.mp4")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("user-owned-video".utf8).write(to: external)
    defer { try? FileManager.default.removeItem(at: root) }
    let row = makeRow(title: "User media", updatedAt: 30)
    let asset = MediaAsset(
      taskID: row.taskID,
      relativePath: "\(String(repeating: "a", count: 64)).mp4",
      fileBookmark: Data("opaque-bookmark".utf8),
      contentSHA256: String(repeating: "a", count: 64),
      byteSize: 16,
      platform: "generic",
      createdAtMilliseconds: 1
    )
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [row], nextCursor: nil),
      details: [row.taskID: makeDetail(for: row)],
      mediaAssetValue: asset
    )
    let model = HistoryViewModel(mediaStore: LocalMediaStore(applicationSupportRoot: root))
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestDeletion()
    model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [row.taskID] }

    XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
  }

  func testEmptyAndPagedHistorySelectsFirstItemAndLoadsDetail() async {
    let first = makeRow(title: "第一条", updatedAt: 30), second = makeRow(title: "第二条", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first], nextCursor: cursor(for: first)), remainingPages: [first.taskID.rawValue: .init(rows: [second], nextCursor: nil)], details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded && model.detailState == .loaded }
    XCTAssertEqual(model.selectedTaskID, first.taskID)
    model.loadNextPageIfNeeded(after: first)
    await waitUntil { model.rows.count == 2 }
    XCTAssertEqual(model.rows.map(\.taskID), [first.taskID, second.taskID])
  }

  func testRapidSelectionCannotOverwriteNewerDetail() async {
    let first = makeRow(title: "慢详情", updatedAt: 30), second = makeRow(title: "新详情", updatedAt: 20)
    let blocker = DetailBlocker(taskID: first.taskID)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], blocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded }
    await blocker.waitUntilEntered()
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    blocker.release()
    await waitUntil { model.detail?.task.id == second.taskID }
    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.detail?.task.id, second.taskID)
  }

  func testReloadCancelsAPageRequestAndReleasesThePaginationState() async {
    let first = makeRow(title: "第一页", updatedAt: 30), second = makeRow(title: "下一页", updatedAt: 20)
    let blocker = PageBlocker()
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first], nextCursor: cursor(for: first)), remainingPages: [first.taskID.rawValue: .init(rows: [second], nextCursor: nil)], details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], pageBlocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.listState == .loaded }
    model.loadNextPageIfNeeded(after: first)
    await blocker.waitUntilEntered()
    XCTAssertTrue(model.isLoadingNextPage)
    model.reload()
    XCTAssertFalse(model.isLoadingNextPage)
    blocker.release()
    await waitUntil { model.listState == .loaded && model.rows == [first] }
  }

  func testDeletionNeedsConfirmationAndOnlyDeletesSelectedTask() async {
    let first = makeRow(title: "第一条", updatedAt: 30), second = makeRow(title: "第二条", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion(); XCTAssertTrue(model.isDeleteConfirmationPresented); XCTAssertEqual(repository.deletedTaskIDs, [])
    model.cancelDeletion(); XCTAssertEqual(repository.deletedTaskIDs, [])
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID] && model.rows.count == 1 }
    XCTAssertTrue(model.selectedTaskIDs.isEmpty)
    model.selectedTaskID = second.taskID
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID, second.taskID] && model.listState == .empty }
    XCTAssertNil(model.selectedTaskID)
  }

  func testSuccessfulTaskDeletionAlsoRemovesItsLocalReadmeImageDirectory() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-history-images.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let row = makeRow(title: "README", updatedAt: 30)
    let cacheDirectory = root.appendingPathComponent("LinkDigest/GitHubREADMEImages/\(row.taskID.rawValue)", isDirectory: true)
    try! FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try! Data("fixture".utf8).write(to: cacheDirectory.appendingPathComponent("image"))
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)])
    let model = HistoryViewModel(imageCache: .init(applicationSupportRoot: root))
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [row.taskID] && model.listState == .empty }
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.path))
  }

  func testOpeningHistoryBackfillsAnEmptyRemoteImageCache() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-history-image-backfill-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let imageURL = URL(string: "https://miro.medium.com/v2/resize:fit:212/article.png")!
    let document = CapturedDocument(
      createdAt: "2026-07-24T14:27:00Z",
      origin: .manualLink,
      url: "https://medium.com/example",
      title: "Medium article",
      platform: "medium",
      method: "dom",
      text: "正文\n\n![Medium article image](\(imageURL.absoluteString))",
      completeness: "complete",
      capturedAt: "2026-07-24T14:27:00Z",
      sourceLabel: "Medium"
    )
    let accepted = try repository.acceptCapture(
      .init(document: document, receivedAtMilliseconds: 1_774_363_620_000)
    )
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    let resources = HistoryImageResourceFetcher()
    let model = HistoryViewModel(
      imageCache: cache,
      imageResources: resources
    )

    model.configure(
      history: .init(repository: repository),
      isReadOnly: false,
      unavailableCode: nil
    )

    await waitUntil { model.localImageURLs.count == 1 }
    XCTAssertEqual(resources.requests.map(\.url), [imageURL])
    XCTAssertEqual(resources.requests.first?.headers["Referer"], "https://medium.com/")
    XCTAssertEqual(
      cache.localImageURLs(taskID: accepted.taskID, snapshotID: accepted.snapshotID),
      model.localImageURLs
    )
  }

  func testDeletionKeepsSharedLocalMediaWhenReferenceQueryFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-history-media.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let row = makeRow(title: "共享视频", updatedAt: 30)
    let store = LocalMediaStore(applicationSupportRoot: root)
    try store.ensureRoot()
    let relativePath = "shared-content.mp4"
    let fileURL = store.absoluteURL(relativePath: relativePath)
    try Data("shared-video".utf8).write(to: fileURL)
    let asset = MediaAsset(
      taskID: row.taskID,
      relativePath: relativePath,
      contentSHA256: "shared-content",
      byteSize: 12,
      platform: "douyin",
      createdAtMilliseconds: 1
    )
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [row], nextCursor: nil),
      details: [row.taskID: makeDetail(for: row)],
      mediaAssetValue: asset,
      mediaReferenceFailure: .unavailable
    )
    let model = HistoryViewModel(mediaStore: store)
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestDeletion()
    model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [row.taskID] && model.listState == .empty }

    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testDeletionFailureKeepsSelectionAndReadOnlyNeverDeletes() async {
    let row = makeRow(title: "不可删除", updatedAt: 30)
    let failing = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)], deleteFailure: .unavailable)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: failing), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion(); model.confirmDeletion()
    await waitUntil { model.isDeleteFailurePresented }
    XCTAssertEqual(model.selectedTaskID, row.taskID); XCTAssertEqual(model.deleteErrorCode, .writeFailed)
    let readOnly = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)])
    model.configure(
      history: HistoryApplicationService(repository: readOnly),
      isReadOnly: true,
      unavailableCode: nil,
      readOnlyReason: .futureSchema
    )
    await waitUntil { model.detailState == .loaded }
    XCTAssertEqual(model.historyReadOnlyReason, .futureSchema)
    XCTAssertFalse(model.canDelete); model.requestDeletion(); model.confirmDeletion(); XCTAssertEqual(readOnly.deletedTaskIDs, [])
  }

  func testDeletionUsesTaskCapturedWhenConfirmationWasPresented() async {
    let first = makeRow(title: "先选中", updatedAt: 30), second = makeRow(title: "后选中", updatedAt: 20)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }
    model.requestDeletion()
    XCTAssertTrue(model.isDeleteConfirmationPresented)
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    model.confirmDeletion()
    await waitUntil { repository.deletedTaskIDs == [first.taskID] }
    XCTAssertEqual(model.rows.map(\.taskID), [second.taskID])
    XCTAssertTrue(model.selectedTaskIDs.isEmpty)
  }

  func testBatchDeletionConfirmationReportsCountAndSkipsRunningTask() async {
    let first = makeRow(title: "正在生成", updatedAt: 30)
    let second = makeRow(title: "可删除", updatedAt: 20)
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [first, second], nextCursor: nil),
      details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)]
    )
    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.selectedTaskIDs = [first.taskID, second.taskID]
    XCTAssertNil(model.selectedTaskID)
    XCTAssertFalse(model.canExport)
    XCTAssertFalse(model.canEditTags)
    model.requestDeletion(protectedTaskIDs: [first.taskID])

    XCTAssertEqual(model.deletionConfirmationTitle, "确定删除选中的 2 条记录？")
    XCTAssertTrue(model.deletionConfirmationMessage.contains("其中 1 条正在生成，将被跳过"))
    model.confirmDeletion(protectedTaskIDs: [first.taskID])
    await waitUntil { repository.deletedTaskIDs == [second.taskID] }

    XCTAssertEqual(model.rows.map(\.taskID), [first.taskID])
    XCTAssertTrue(model.selectedTaskIDs.isEmpty)
    XCTAssertEqual(model.deleteOutcomeMessage, "已删除 1 条，1 条正在生成，已跳过。")
  }

  func testBatchDeletionReportsPartialFailureTruthfully() async {
    let first = makeRow(title: "成功", updatedAt: 30)
    let second = makeRow(title: "失败", updatedAt: 20)
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [first, second], nextCursor: nil),
      details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)],
      batchDeleteFailures: [second.taskID]
    )
    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.selectedTaskIDs = [first.taskID, second.taskID]
    model.requestDeletion()
    model.confirmDeletion()
    await waitUntil { model.isDeleteOutcomePresented }

    XCTAssertEqual(repository.deletedTaskIDs, [first.taskID])
    XCTAssertEqual(model.rows.map(\.taskID), [second.taskID])
    XCTAssertTrue(model.selectedTaskIDs.isEmpty)
    XCTAssertEqual(model.deleteOutcomeMessage, "已删除 1 条，1 条失败。")
  }

  func testWritableAndReadOnlyHistoryCanPrepareAndFinishOrCancelExport() async {
    let row = makeRow(title: "可导出", updatedAt: 30)
    let detail = makeDetail(for: row)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: detail])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.markdown)
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.exportFile?.format, .markdown)
    XCTAssertTrue(model.exportFile?.suggestedFilename.contains("可导出") == true)
    model.completeExportSave()
    XCTAssertFalse(model.isExportPanelPresented)
    XCTAssertNil(model.exportFile)

    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: true, unavailableCode: nil, readOnlyReason: .futureSchema)
    await waitUntil { model.detailState == .loaded }
    XCTAssertTrue(model.canExport)
    model.requestExport(.json)
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.exportFile?.format, .json)
    model.cancelExport()
    XCTAssertFalse(model.isExportPanelPresented)
    XCTAssertNil(model.exportFile)
    XCTAssertFalse(model.isExportSaveFailurePresented)
  }

  func testExportPreparationFailureIsSafeAndSaveFailureHasRecoveryState() async {
    let row = makeRow(title: "失败导出", updatedAt: 30)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)], exportFailure: .unavailable)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.plainText)
    await waitUntil { model.isExportPreparationFailurePresented }
    XCTAssertNil(model.exportFile)
    XCTAssertFalse(model.isExportPanelPresented)
    model.dismissExportPreparationFailure()
    XCTAssertFalse(model.isExportPreparationFailurePresented)

    model.failExportSave()
    XCTAssertTrue(model.isExportSaveFailurePresented)
    model.dismissExportSaveFailure()
    XCTAssertFalse(model.isExportSaveFailurePresented)
  }

  func testRapidSelectionCannotPresentOldExport() async {
    let first = makeRow(title: "慢导出", updatedAt: 30), second = makeRow(title: "新导出", updatedAt: 20)
    let blocker = ExportBlocker(taskID: first.taskID)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [first, second], nextCursor: nil), details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)], exportBlocker: blocker)
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    model.requestExport(.markdown)
    await blocker.waitUntilEntered()
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    model.requestExport(.json)
    blocker.release()
    await waitUntil { model.isExportPanelPresented }
    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.exportFile?.format, .json)
    XCTAssertTrue(model.exportFile?.suggestedFilename.contains("新导出") == true)
  }

  func testProtectedDeletionIsBlockedAtRequestAndConfirmationTime() async {
    let row = makeRow(title: "正在运行", updatedAt: 30)
    let repository = HistoryScreenRepository(firstPage: .init(rows: [row], nextCursor: nil), details: [row.taskID: makeDetail(for: row)])
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded }

    XCTAssertTrue(model.canDelete)
    XCTAssertFalse(model.canDelete(protectedTaskID: row.taskID))
    model.requestDeletion(protectedTaskID: row.taskID)
    XCTAssertFalse(model.isDeleteConfirmationPresented)
    XCTAssertEqual(repository.deletedTaskIDs, [])
    XCTAssertTrue(model.canDelete)

    model.requestDeletion()
    XCTAssertTrue(model.isDeleteConfirmationPresented)
    model.confirmDeletion(protectedTaskID: row.taskID)
    XCTAssertFalse(model.isDeleteConfirmationPresented)
    XCTAssertTrue(model.isProtectedDeletionAlertPresented)
    XCTAssertEqual(repository.deletedTaskIDs, [])
    XCTAssertTrue(model.canDelete)
  }

  func testManualTagEditingAndBoardFiltersUseRepositoryQueryState() async {
    let first = makeRow(title: "Swift 和 AI", updatedAt: 30)
    let second = makeRow(title: "Swift", updatedAt: 20)
    let third = makeRow(title: "AI", updatedAt: 10)
    let repository = TagHistoryScreenRepository(
      rows: [first, second, third],
      details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second), third.taskID: makeDetail(for: third)],
      tags: [first.taskID: [tag("Swift"), tag("AI")], second.taskID: [tag("Swift")], third.taskID: [tag("AI")]]
    )
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.availableTags.count == 2 }

    model.searchText = "Swift"
    await waitUntil { repository.filters.last?.searchText == "Swift" }
    let swift = try! XCTUnwrap(model.availableTags.first { $0.normalizedName == "swift" })
    let ai = try! XCTUnwrap(model.availableTags.first { $0.normalizedName == "ai" })
    model.toggleTag(swift, additive: false)
    await waitUntil { model.rows.map(\.taskID) == [first.taskID, second.taskID] }
    model.toggleTag(ai, additive: true)
    // 等 filters 而不是等 rows：rows 收敛到 [first] 也可能是**上一次**只筛
    // swift 的结果，此时带 ai 的查询还没发出去，紧接着断言 filters 就会读到
    // 旧的那条。等待条件必须和断言对象是同一个东西。
    await waitUntil(timeout: .seconds(5)) {
      repository.filters.last?.tagNormalizedNames == ["ai", "swift"]
    }
    await waitUntil(timeout: .seconds(5)) { model.rows.map(\.taskID) == [first.taskID] }
    XCTAssertEqual(repository.filters.last?.tagNormalizedNames, ["ai", "swift"])
    XCTAssertEqual(repository.filters.last?.searchText, "Swift")

    model.addTag("本地优先")
    await waitUntil { model.detail?.tags.map(\.name).contains("本地优先") == true }
    let local = try! XCTUnwrap(model.detail?.tags.first { $0.name == "本地优先" })
    model.removeTag(local)
    await waitUntil { model.detail?.tags.map(\.name).contains("本地优先") == false }
  }

  func testSearchThatHidesSelectionSelectsFirstVisibleResult() async {
    let first = makeRow(title: "Alpha", updatedAt: 30)
    let second = makeRow(title: "Beta", updatedAt: 20)
    let repository = TagHistoryScreenRepository(
      rows: [first, second],
      details: [first.taskID: makeDetail(for: first), second.taskID: makeDetail(for: second)],
      tags: [:]
    )
    let model = HistoryViewModel()
    model.configure(
      history: HistoryApplicationService(repository: repository),
      isReadOnly: false,
      unavailableCode: nil
    )
    await waitUntil { model.selectedTaskID == first.taskID && model.detail?.task.id == first.taskID }

    model.searchText = "Beta"

    await waitUntil {
      model.rows.map(\.taskID) == [second.taskID]
        && model.selectedTaskID == second.taskID
        && model.detail?.task.id == second.taskID
    }
    XCTAssertEqual(model.listState, .loaded)
  }

  func testAutomaticTagCommitRefreshesCurrentDetailAndAvailableChipsWithoutNavigation() async throws {
    try await withAutomaticTagHistory { repository, accepted, document in
      let history = HistoryApplicationService(repository: repository)
      let model = HistoryViewModel()
      model.configure(history: history, isReadOnly: false, unavailableCode: nil)
      await waitUntil { model.selectedTaskID == accepted.taskID && model.detailState == .loaded }
      let provider = AutomaticTagMetadataProvider(tagOutcome: .success("本地优先, Swift"))
      let events = MetadataEventCounter()
      let orchestrator = try metadataOrchestrator(
        provider: provider,
        history: history,
        onMetadataChanged: { taskID in
          await events.record(taskID)
          await model.historyMetadataChanged(taskID: taskID)
        }
      )
      let recorder = MetadataRunRecorder()
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)

      await orchestrator.start(request: request, capture: document) { runID, state in
        await recorder.record(runID: runID, state: state)
      }
      await waitUntilAsync { await recorder.last == .completed(intent: .summarize, text: "已完成的总结") }
      await waitUntil {
        provider.tagRequestCount == 1
          && model.selectedTaskID == accepted.taskID
          && model.detail?.tags.map(\.name) == ["Swift", "本地优先"]
          && model.availableTags.map(\.name) == ["Swift", "本地优先"]
      }

      let recordedEvents = await events.taskIDs
      XCTAssertEqual(recordedEvents, [accepted.taskID])
      XCTAssertEqual(model.listState, .loaded)
      XCTAssertEqual(model.rows.map(\.taskID), [accepted.taskID], "metadata refresh must not require navigation or a list reload")
    }
  }

  func testAutomaticTagFailurePublishesNoMetadataEventAndLeavesHistoryUIUnchanged() async throws {
    try await withAutomaticTagHistory { repository, accepted, document in
      let history = HistoryApplicationService(repository: repository)
      let model = HistoryViewModel()
      model.configure(history: history, isReadOnly: false, unavailableCode: nil)
      await waitUntil { model.selectedTaskID == accepted.taskID && model.detailState == .loaded }
      let provider = AutomaticTagMetadataProvider(tagOutcome: .failure)
      let events = MetadataEventCounter()
      let orchestrator = try metadataOrchestrator(
        provider: provider,
        history: history,
        onMetadataChanged: { taskID in
          await events.record(taskID)
          await model.historyMetadataChanged(taskID: taskID)
        }
      )
      let recorder = MetadataRunRecorder()
      let request = PersistentRunRequest(runID: RunID(), taskID: accepted.taskID, snapshotID: accepted.snapshotID, intent: .summarize)

      await orchestrator.start(request: request, capture: document) { runID, state in
        await recorder.record(runID: runID, state: state)
      }
      await waitUntilAsync { await recorder.last == .completed(intent: .summarize, text: "已完成的总结") }
      // 打标签失败后要等列表**真正 settle** 再断言：只等 30ms 会撞上一个竞态，
      // 列表刷新还在路上，断言就跑了。这两条来自 main 上的 f0938eb / 563ae21。
      await waitUntil(timeout: .seconds(5)) {
        provider.tagRequestCount == 1
          && model.detailState == .loaded
          && model.listState == .loaded
      }
      try? await Task.sleep(for: .milliseconds(50))
      await waitUntil { model.detailState == .loaded && model.listState == .loaded }

      let recordedEvents = await events.taskIDs
      XCTAssertEqual(recordedEvents, [])
      XCTAssertEqual(model.selectedTaskID, accepted.taskID)
      XCTAssertTrue(model.detail?.tags.isEmpty == true)
      XCTAssertTrue(model.availableTags.isEmpty)
      // 这里要的是「最终稳定在 loaded」，不是「此刻正好是 loaded」：断言与上面
      // 那次 waitUntil 之间仍可能插进一次排队的刷新，把状态短暂打回 loading。
      // 用例的主旨是上面几条——失败不发事件、不改 UI，加载态只是附带确认。
      await waitUntil(timeout: .seconds(5)) {
        model.detailState == .loaded && model.listState == .loaded
      }
    }
  }

  func testNonSelectedMetadataEventOnlyRefreshesChipsAndDoesNotCancelCurrentDetailRefresh() async throws {
    let a = makeRow(title: "A", updatedAt: 30)
    let b = makeRow(title: "B", updatedAt: 20)
    let repository = TagHistoryScreenRepository(
      rows: [a, b],
      details: [a.taskID: makeDetail(for: a), b.taskID: makeDetail(for: b)],
      tags: [:]
    )
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }

    _ = try repository.addTags(["A 标签"], to: a.taskID)
    let aRead = DetailReadBarrier()
    repository.enqueueDetailBarrier(aRead, for: a.taskID)
    model.historyMetadataChanged(taskID: a.taskID)
    await aRead.waitUntilEntered()

    _ = try repository.addTags(["B 标签"], to: b.taskID)
    model.historyMetadataChanged(taskID: b.taskID)
    aRead.release()

    await waitUntil {
      model.selectedTaskID == a.taskID
        && model.detail?.task.id == a.taskID
        && model.detail?.tags.map(\.name) == ["A 标签"]
        && model.availableTags.map(\.name) == ["A 标签", "B 标签"]
        && model.detailState == .loaded
    }
    XCTAssertEqual(model.detailState, .loaded)
  }

  func testStaleNormalDetailReadCannotOverwriteNewerMetadataDetail() async throws {
    let a = makeRow(title: "A", updatedAt: 30)
    let b = makeRow(title: "B", updatedAt: 20)
    let repository = TagHistoryScreenRepository(
      rows: [a, b],
      details: [a.taskID: makeDetail(for: a), b.taskID: makeDetail(for: b)],
      tags: [:]
    )
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }
    model.selectedTaskID = b.taskID
    await waitUntil { model.selectedTaskID == b.taskID && model.detail?.task.id == b.taskID }

    let staleNormalRead = DetailReadBarrier()
    repository.enqueueDetailBarrier(staleNormalRead, for: a.taskID)
    model.selectedTaskID = a.taskID
    await staleNormalRead.waitUntilEntered()

    _ = try repository.addTags(["新标签"], to: a.taskID)
    model.historyMetadataChanged(taskID: a.taskID)
    await waitUntil {
      model.detail?.task.id == a.taskID
        && model.detail?.tags.map(\.name) == ["新标签"]
        && model.detailState == .loaded
    }

    staleNormalRead.release()
    await waitUntil {
      model.selectedTaskID == a.taskID
        && model.detail?.task.id == a.taskID
        && model.detail?.tags.map(\.name) == ["新标签"]
        && model.detailState == .loaded
    }
  }

  func testRapidABAutomaticTagMetadataEventsKeepCurrentSelectionDetailAndTagsConsistent() async throws {
    let a = makeRow(title: "A", updatedAt: 30)
    let b = makeRow(title: "B", updatedAt: 20)
    let repository = TagHistoryScreenRepository(
      rows: [a, b],
      details: [a.taskID: makeDetail(for: a), b.taskID: makeDetail(for: b)],
      tags: [:]
    )
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }

    _ = try repository.addTags(["A 标签"], to: a.taskID)
    _ = try repository.addTags(["B 标签"], to: b.taskID)
    let aRead = DetailReadBarrier()
    repository.enqueueDetailBarrier(aRead, for: a.taskID)
    model.historyMetadataChanged(taskID: a.taskID)
    await aRead.waitUntilEntered()

    model.selectedTaskID = b.taskID
    model.historyMetadataChanged(taskID: b.taskID)
    aRead.release()

    await waitUntil {
      model.selectedTaskID == b.taskID
        && model.detail?.task.id == b.taskID
        && model.detail?.tags.map(\.name) == ["B 标签"]
        && model.availableTags.map(\.name) == ["A 标签", "B 标签"]
        && model.detailState == .loaded
    }
    XCTAssertFalse(model.detail?.tags.contains(tag("A 标签")) == true)
    XCTAssertEqual(model.detailState, .loaded)
  }

  func testMetadataTakeoverOfLoadingDetailFailureLeavesRetryableFailedState() async throws {
    let a = makeRow(title: "A", updatedAt: 30)
    let b = makeRow(title: "B", updatedAt: 20)
    let repository = TagHistoryScreenRepository(
      rows: [a, b],
      details: [a.taskID: makeDetail(for: a), b.taskID: makeDetail(for: b)],
      tags: [:]
    )
    let model = HistoryViewModel()
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.selectedTaskID == a.taskID && model.detailState == .loaded }
    model.selectedTaskID = b.taskID
    await waitUntil { model.selectedTaskID == b.taskID && model.detailState == .loaded }

    let ordinaryRead = DetailReadBarrier()
    repository.enqueueDetailBarrier(ordinaryRead, for: a.taskID)
    repository.enqueueDetailFailure(.unavailable, for: a.taskID)
    model.selectedTaskID = a.taskID
    await ordinaryRead.waitUntilEntered()
    XCTAssertEqual(model.detailState, .loading)

    model.historyMetadataChanged(taskID: a.taskID)
    await waitUntil { model.detailState == .failed && model.detailErrorCode != nil }
    XCTAssertNil(model.detail)

    ordinaryRead.release()
    model.retryDetail()
    await waitUntil { model.detail?.task.id == a.taskID && model.detailState == .loaded && model.detailErrorCode == nil }
  }

  func testModelDownloadRequiresExplicitSecondActionBeforeTranscribing() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .requiresDownload,
      scripts: [.events([.extractingAudio, .transcribing, .partial("实时文字"), .final("最终文字")])]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .awaitingModelDownload }
    XCTAssertTrue(fixture.model.isTranscriptionModelConfirmationPresented)
    XCTAssertEqual(transcriber.downloadCallCount, 0, "readiness probe must never install assets")

    fixture.model.confirmModelDownloadAndTranscribe()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(transcriber.downloadCallCount, 1)
  }

  func testPartialThenFinalTranscriptionCreatesLatestSnapshotAndCompletesMedia() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.extractingAudio, .transcribing, .partial("实时中文"), .final("完整中文转写")])]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(fixture.model.transcriptionText, "完整中文转写")
    let detail = try fixture.repository.detail(taskID: fixture.taskID)
    XCTAssertEqual(detail.snapshots.count, 2)
    XCTAssertEqual(detail.snapshots.last?.sourceKind, CapturedDocument.Origin.localTranscription.rawValue)
    XCTAssertEqual(detail.snapshots.last?.captureMethod, "speech_analyzer_local")
    XCTAssertEqual(detail.snapshots.last?.sourceLabel, "本机视频转写")
    XCTAssertEqual(detail.snapshots.last?.bodyText, "完整中文转写")
    XCTAssertEqual(detail.media?.transcriptionStatus, .completed)
    XCTAssertEqual(try fixture.repository.exportProjection(taskID: fixture.taskID).snapshots.last?.bodyText, "完整中文转写")
    XCTAssertEqual(transcriber.lastLocaleIdentifier, "zh_CN")
  }

  func testEnglishCaptionUsesEnglishSpeechLocaleForLocalTranscription() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.extractingAudio, .transcribing, .final("lecture transcript")])]
    )
    let fixture = try makeTranscriptionFixture(
      transcriber: transcriber,
      captionText: String(repeating: "Instead of watching Netflix tonight, watch this Stanford lecture. ", count: 2)
    )
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(transcriber.lastLocaleIdentifier, "en_US")
  }

  func testFailureCanRetryAndReadOnlyExplainsWhyTranscriptionIsBlocked() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [
        .failure(.recognitionFailed),
        .events([.extractingAudio, .transcribing, .final("重试成功")]),
      ]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil {
      if case .failed = fixture.model.transcriptionState { return true }
      return false
    }
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, .failed)
    fixture.model.retryTranscription()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(fixture.model.transcriptionText, "重试成功")

    fixture.model.configure(
      history: HistoryApplicationService(repository: fixture.repository),
      isReadOnly: true,
      unavailableCode: nil,
      readOnlyReason: .futureSchema
    )
    await waitUntil { fixture.model.detailState == .loaded }
    fixture.model.requestTranscription()
    guard case let .failed(message) = fixture.model.transcriptionState else {
      return XCTFail("read-only transcription should fail with an explanation")
    }
    XCTAssertTrue(message.contains("只读"))
  }

  func testCancellationReturnsMediaToNoneAndCanRetry() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [
        .suspended,
        .events([.extractingAudio, .transcribing, .final("取消后重试成功")]),
      ]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .extractingAudio }
    fixture.model.cancelTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
    XCTAssertEqual(
      try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus,
      TranscriptionStatus.none
    )

    fixture.model.retryTranscription()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(fixture.model.transcriptionText, "取消后重试成功")
  }

  func testSelectingBWhileATranscribesKeepsAAliveAndIsolatesBUI() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelStates: [.ready],
      scripts: [.suspended]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber, includesSecondTask: true)
    defer { fixture.close() }
    let b = try XCTUnwrap(fixture.otherTaskID)
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionText == "A partial" }

    fixture.model.selectedTaskID = b
    await waitUntil { fixture.model.detail?.task.id == b }
    XCTAssertTrue(fixture.model.transcriptionState(for: fixture.taskID).isActive)
    XCTAssertEqual(fixture.model.transcriptionText(for: fixture.taskID), "A partial")
    XCTAssertEqual(fixture.model.transcriptionState(for: b), .idle)
    XCTAssertEqual(fixture.model.transcriptionText(for: b), "")
    XCTAssertFalse(fixture.model.canTranscribeVideo, "only one transcription may own the shared worker")
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, .running)
    fixture.model.cancelTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
  }

  /// 转写 partial 拍点写进叶子模型（liveTranscriptionText），存储属性
  /// 保持最新；取消等清空路径要把叶子一并清掉，不留残影。
  func testTranscriptionPartialsSyncLeafModelAndCancellationClearsIt() async throws {
    let transcriber = ScriptedVideoTranscriber(modelState: .ready, scripts: [.suspended])
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionText == "A partial" }
    XCTAssertEqual(fixture.model.liveTranscriptionText.text, "A partial")

    fixture.model.cancelTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
    XCTAssertTrue(fixture.model.transcriptionText.isEmpty)
    XCTAssertTrue(fixture.model.liveTranscriptionText.text.isEmpty)
  }

  func testRepeatedConfigureWithSameHistoryDoesNotCancelOrClearTranscription() async throws {
    let transcriber = ScriptedVideoTranscriber(modelState: .ready, scripts: [.suspended])
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionText == "A partial" }
    let history = HistoryApplicationService(repository: fixture.repository)

    fixture.model.configure(history: history, isReadOnly: false, unavailableCode: nil)
    fixture.model.configure(history: history, isReadOnly: false, unavailableCode: nil)

    XCTAssertEqual(fixture.model.transcriptionText, "A partial")
    XCTAssertTrue(fixture.model.transcriptionState.isActive)
    XCTAssertEqual(fixture.model.transcriptionTaskID, fixture.taskID)
    XCTAssertEqual(transcriber.transcribeCallCount, 1)
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, .running)
    fixture.model.cancelTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
  }

  func testImageRecognitionContinuesAcrossSelectionAndReturnsToOwnerTask() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-ocr-owner-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = makeRow(title: "图片正文", updatedAt: 30)
    let second = makeRow(title: "另一条", updatedAt: 20)
    let firstDetail = makeDetail(for: first)
    let secondDetail = makeDetail(for: second)
    let snapshotID = try XCTUnwrap(firstDetail.snapshots.last?.id)
    let filename = String(repeating: "a", count: 64)
    let imageDirectory = root
      .appendingPathComponent("LinkDigest/GitHubREADMEImages", isDirectory: true)
      .appendingPathComponent(first.taskID.rawValue, isDirectory: true)
      .appendingPathComponent(snapshotID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageDirectory.appendingPathComponent(filename))
    try Data("{\"entries\":[{\"filename\":\"\(filename)\"}]}".utf8)
      .write(to: imageDirectory.appendingPathComponent("manifest.json"))
    let recognizer = GatedImageTextRecognizer()
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [first, second], nextCursor: nil),
      details: [first.taskID: firstDetail, second.taskID: secondDetail]
    )
    let model = HistoryViewModel(
      imageCache: .init(applicationSupportRoot: root),
      imageTextRecognizer: recognizer
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detail?.task.id == first.taskID && model.canRecognizeImageText }

    model.recognizeImageText()
    await recognizer.waitUntilEntered()
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }
    XCTAssertEqual(model.imageTextRecognitionState(for: first.taskID), .recognizing)
    XCTAssertEqual(model.imageTextRecognitionState(for: second.taskID), .idle)

    await recognizer.release("图片里的文字")
    await waitUntil { model.imageTextRecognitionState == .completed }
    XCTAssertEqual(model.recognizedImageText(for: first.taskID), "图片里的文字")
    XCTAssertEqual(model.recognizedImageText(for: second.taskID), "")
  }

  func testSelectionCleanupCannotOverwriteCompletionCommittedAtTerminalBarrier() async throws {
    let terminalBarrier = TerminalCommitBarrier()
    let statusObserver = TranscriptionStatusObserver()
    var dependencies = PersistenceDependencies.live
    dependencies.beforeTerminalCommit = { terminalBarrier.block() }
    let transcriber = ScriptedVideoTranscriber(
      modelStates: [.ready],
      scripts: [.events([.extractingAudio, .transcribing, .final("视频说明")])]
    )
    let fixture = try makeTranscriptionFixture(
      transcriber: transcriber,
      includesSecondTask: true,
      dependencies: dependencies,
      statusObserver: statusObserver
    )
    defer { fixture.close() }
    let b = try XCTUnwrap(fixture.otherTaskID)
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await terminalBarrier.waitUntilEntered()
    fixture.model.selectedTaskID = b
    terminalBarrier.release()

    await waitUntil {
      (try? fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus) == .completed
    }
    XCTAssertEqual(
      try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus,
      .completed,
      "selection changes must not enqueue cleanup for an owned transcription"
    )
    let detail = try fixture.repository.detail(taskID: fixture.taskID)
    XCTAssertEqual(detail.snapshots.count, 1, "matching transcript text reuses the original capture snapshot")
  }

  func testLateFailureFromCancelledReadinessCannotOverwriteNewCompletedAttempt() async throws {
    let transcriber = LateReadinessVideoTranscriber()
    let statusObserver = TranscriptionStatusObserver()
    let discardedObserver = DiscardedTranscriptionAttemptObserver()
    let fixture = try makeTranscriptionFixture(
      transcriber: transcriber,
      statusObserver: statusObserver,
      onDiscardedTranscriptionAttempt: { discardedObserver.record() }
    )
    defer { fixture.close() }
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }

    fixture.model.requestTranscription()
    await transcriber.waitUntilFirstReadinessEntered()
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, .completed)
    let attempts = statusObserver.attempts(taskID: fixture.taskID, status: .pending)
    XCTAssertEqual(attempts.count, 2)
    let oldAttempt = try XCTUnwrap(attempts.first)
    let newAttempt = try XCTUnwrap(attempts.last)

    transcriber.releaseFirstReadinessAsFailure()
    await discardedObserver.waitUntilRecorded()
    XCTAssertEqual(try fixture.repository.updateMediaTranscriptionStatus(
      taskID: fixture.taskID,
      attempt: oldAttempt,
      status: .failed
    ), .stale)
    XCTAssertEqual(
      try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus,
      .completed,
      "a cancelled attempt's late readiness failure must be a repository no-op"
    )
    let evidenceAttempt: String? = try fixture.repository.database.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT attempt_id FROM media_transcription_evidence WHERE task_id = ? ORDER BY completed_at_ms DESC, id DESC LIMIT 1",
        arguments: [fixture.taskID.rawValue]
      )
    }
    XCTAssertEqual(evidenceAttempt, newAttempt.id)
  }

  func testSelectingBWhileAWaitsForModelConfirmationKeepsAOwnedAndBlocksB() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelStates: [.requiresDownload],
      scripts: []
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber, includesSecondTask: true)
    defer { fixture.close() }
    let b = try XCTUnwrap(fixture.otherTaskID)
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .awaitingModelDownload }

    fixture.model.selectedTaskID = b
    await waitUntil { fixture.model.detail?.task.id == b }
    XCTAssertEqual(fixture.model.transcriptionState(for: fixture.taskID), .awaitingModelDownload)
    XCTAssertEqual(fixture.model.transcriptionState(for: b), .idle)
    XCTAssertTrue(fixture.model.isTranscriptionModelConfirmationPresented)
    XCTAssertFalse(fixture.model.canTranscribeVideo)
    fixture.model.selectedTaskID = fixture.taskID
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID }
    fixture.model.cancelModelDownloadConfirmation()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
  }

  func testCancelDuringSuspendedModelDownloadReturnsNone() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .requiresDownload,
      scripts: [],
      downloadSuspends: true
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .awaitingModelDownload }
    fixture.model.confirmModelDownloadAndTranscribe()
    await waitUntil { fixture.model.transcriptionState == .preparingModel }
    fixture.model.cancelTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, TranscriptionStatus.none)
  }

  func testStreamTypedCancelledMapsToNoneNotFailure() async throws {
    let transcriber = ScriptedVideoTranscriber(modelState: .ready, scripts: [.failure(.cancelled)])
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil { fixture.model.transcriptionState == .cancelled }
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, TranscriptionStatus.none)
  }

  func testRebuiltViewModelWithSameOrBackwardClockStillCompletesHigherGeneration() async throws {
    for secondNow in [Int64(100), 50] {
      let firstTranscriber = ScriptedVideoTranscriber(
        modelState: .ready,
        scripts: [.events([.extractingAudio, .transcribing, .final("第一次 ViewModel 正文")])]
      )
      let fixture = try makeTranscriptionFixture(transcriber: firstTranscriber, nowMilliseconds: { 100 })
      defer { fixture.close() }
      await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }
      fixture.model.requestTranscription()
      await waitUntil { fixture.model.transcriptionState == .completed }

      let rebuiltText = "重建后正文-\(secondNow)"
      let secondTranscriber = ScriptedVideoTranscriber(
        modelState: .ready,
        scripts: [.events([.extractingAudio, .transcribing, .final(rebuiltText)])]
      )
      let rebuilt = HistoryViewModel(
        mediaStore: fixture.store,
        videoTranscriber: secondTranscriber,
        nowMilliseconds: { secondNow }
      )
      rebuilt.configure(
        history: HistoryApplicationService(repository: fixture.repository),
        isReadOnly: false,
        unavailableCode: nil
      )
      await waitUntil { rebuilt.detailState == .loaded && rebuilt.canTranscribeVideo }
      rebuilt.requestTranscription()
      await waitUntil { rebuilt.transcriptionState == .completed }

      XCTAssertEqual(try fixture.repository.detail(taskID: fixture.taskID).snapshots.last?.bodyText, rebuiltText)
      let evidence = try fixture.repository.database.read { db in
        try Row.fetchAll(
          db,
          sql: "SELECT attempt_generation, completed_at_ms FROM media_transcription_evidence WHERE task_id = ? ORDER BY attempt_generation",
          arguments: [fixture.taskID.rawValue]
        )
      }
      XCTAssertEqual(evidence.map { $0["attempt_generation"] as Int64 }, [1, 2])
      XCTAssertEqual(evidence.map { $0["completed_at_ms"] as Int64 }, [100, secondNow])
    }
  }

  func testBeginFailuresNeverReachModelDownloadOrTranscription() async throws {
    for failure in [
      RepositoryFailure.notFound,
      .readOnly(.futureSchema),
      .injectedFailure,
    ] {
      let transcriber = ScriptedVideoTranscriber(
        modelState: .requiresDownload,
        scripts: [.events([.extractingAudio, .transcribing, .final("不应执行")])]
      )
      let fixture = try makeTranscriptionFixture(transcriber: transcriber)
      fixture.model.configure(
        history: HistoryApplicationService(repository: TranscriptionGateRepository(base: fixture.repository, beginFailure: failure)),
        isReadOnly: false,
        unavailableCode: nil
      )
      await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }
      fixture.model.requestTranscription()
      await waitUntil {
        if case .failed = fixture.model.transcriptionState { return true }
        return false
      }
      XCTAssertEqual(transcriber.modelStateCallCount, 0, "begin failure: \(failure)")
      XCTAssertEqual(transcriber.downloadCallCount, 0, "begin failure: \(failure)")
      XCTAssertEqual(transcriber.transcribeCallCount, 0, "begin failure: \(failure)")
      fixture.close()
    }
  }

  func testStaleCompletionNeverPublishesCompletedUI() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.extractingAudio, .transcribing, .final("迟到正文")])]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    fixture.model.configure(
      history: HistoryApplicationService(repository: TranscriptionGateRepository(base: fixture.repository, completionOverride: .stale)),
      isReadOnly: false,
      unavailableCode: nil
    )
    await waitUntil { fixture.model.detailState == .loaded && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await waitUntil {
      if case .failed = fixture.model.transcriptionState { return true }
      return false
    }

    XCTAssertNotEqual(fixture.model.transcriptionState, .completed)
    XCTAssertEqual(
      try fixture.repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM media_transcription_evidence") },
      0
    )
  }

  func testSelectionChangeAfterBeginCommitStillRunsOwnedTranscription() async throws {
    let barrier = BeginReturnBarrier()
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.extractingAudio, .transcribing, .final("切换后仍完成")])]
    )
    let fixture = try makeTranscriptionFixture(transcriber: transcriber, includesSecondTask: true)
    defer { fixture.close() }
    fixture.model.configure(
      history: HistoryApplicationService(repository: TranscriptionGateRepository(base: fixture.repository, beginBarrier: barrier)),
      isReadOnly: false,
      unavailableCode: nil
    )
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID && fixture.model.canTranscribeVideo }
    fixture.model.requestTranscription()
    await barrier.waitUntilEntered()

    fixture.model.selectedTaskID = try XCTUnwrap(fixture.otherTaskID)
    barrier.release()

    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(transcriber.modelStateCallCount, 1)
    XCTAssertEqual(transcriber.downloadCallCount, 0)
    XCTAssertEqual(transcriber.transcribeCallCount, 1)
    XCTAssertEqual(try fixture.repository.mediaAsset(taskID: fixture.taskID)?.transcriptionStatus, .completed)
  }

  func testRemoteDirectSuccessPersistsOnlyFinalAndCleansTempWithoutMediaAsset() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.extractingAudio, .transcribing, .partial("临时文字"), .final("远程最终转写")])]
    )
    let fixture = try makeRemoteTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    await waitUntil { fixture.model.detailState == .loaded }
    XCTAssertEqual(fixture.fetcher.callCount, 0, "preview/load must not fetch transcription media")

    fixture.model.requestRemoteTranscription(fixture.descriptor, taskID: fixture.taskID)
    await waitUntil { fixture.model.transcriptionState == .completed }
    XCTAssertEqual(fixture.fetcher.callCount, 1)
    XCTAssertEqual(fixture.model.transcriptionText, "远程最终转写")
    XCTAssertEqual(try fixture.repository.detail(taskID: fixture.taskID).snapshots.last?.bodyText, "远程最终转写")
    XCTAssertNil(try fixture.repository.mediaAsset(taskID: fixture.taskID))
    XCTAssertEqual(try fixture.repository.database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_transcription_evidence")
    }, 1)
    XCTAssertEqual(try fixture.repository.database.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM content_snapshots WHERE body_text = '临时文字'")
    }, 0)
    let databaseURL = fixture.repository.database.location.databaseURL
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      let bytes = try Data(contentsOf: url)
      XCTAssertNil(bytes.range(of: Data("signature=never-persist".utf8)))
      XCTAssertNil(bytes.range(of: Data("TranscriptionTemp".utf8)))
    }
    XCTAssertEqual(fixture.tempEntryCount, 0)
  }

  func testRemoteModelUnavailableAndCancelBothCleanTempAndRemainRetryable() async throws {
    let unavailable = try makeRemoteTranscriptionFixture(
      transcriber: ScriptedVideoTranscriber(modelState: .unavailable(.speechUnavailable), scripts: [])
    )
    defer { unavailable.close() }
    await waitUntil { unavailable.model.detailState == .loaded }
    unavailable.model.requestRemoteTranscription(unavailable.descriptor, taskID: unavailable.taskID)
    await waitUntil { if case .failed = unavailable.model.transcriptionState { return true }; return false }
    XCTAssertEqual(unavailable.tempEntryCount, 0)
    XCTAssertTrue(unavailable.model.canTranscribeCurrentCapture(unavailable.descriptor, taskID: unavailable.taskID))

    let cancelled = try makeRemoteTranscriptionFixture(
      transcriber: ScriptedVideoTranscriber(modelState: .ready, scripts: [.suspended])
    )
    defer { cancelled.close() }
    await waitUntil { cancelled.model.detailState == .loaded }
    cancelled.model.requestRemoteTranscription(cancelled.descriptor, taskID: cancelled.taskID)
    await waitUntil { cancelled.model.transcriptionState == .extractingAudio }
    cancelled.model.cancelTranscription()
    await waitUntil { cancelled.model.transcriptionState == .cancelled }
    XCTAssertEqual(cancelled.tempEntryCount, 0)
    XCTAssertEqual(try cancelled.repository.database.read {
      try String.fetchOne($0, sql: "SELECT status FROM task_transcription_attempts ORDER BY generation DESC LIMIT 1")
    }, "cancelled")
  }

  func testRemoteBeginFailurePerformsZeroNetworkModelAndASRWork() async throws {
    let transcriber = ScriptedVideoTranscriber(
      modelState: .ready,
      scripts: [.events([.final("不应执行")])]
    )
    let fixture = try makeRemoteTranscriptionFixture(transcriber: transcriber)
    defer { fixture.close() }
    fixture.model.configure(
      history: HistoryApplicationService(repository: TranscriptionGateRepository(
        base: fixture.repository,
        beginFailure: .injectedFailure
      )),
      isReadOnly: false,
      unavailableCode: nil
    )
    await waitUntil { fixture.model.detailState == .loaded }
    fixture.model.requestRemoteTranscription(fixture.descriptor, taskID: fixture.taskID)
    await waitUntil { if case .failed = fixture.model.transcriptionState { return true }; return false }
    XCTAssertEqual(fixture.fetcher.callCount, 0)
    XCTAssertEqual(transcriber.modelStateCallCount, 0)
    XCTAssertEqual(transcriber.downloadCallCount, 0)
    XCTAssertEqual(transcriber.transcribeCallCount, 0)
    XCTAssertEqual(fixture.tempEntryCount, 0)
  }

  func testRemoteSelectionSwitchKeepsPartialStateUntilExplicitCancellation() async throws {
    let transcriber = ScriptedVideoTranscriber(modelState: .ready, scripts: [.suspended])
    let fixture = try makeRemoteTranscriptionFixture(
      transcriber: transcriber,
      availableDiskBytes: { _ in Int64.max }
    )
    defer { fixture.close() }
    let other = try fixture.repository.acceptCapture(.init(document: .init(
      createdAt: "2026-07-20T00:01:00Z",
      origin: .manualLink,
      url: "https://example.test/other",
      title: "另一条历史",
      platform: "generic",
      method: "fixture",
      text: "另一条正文",
      completeness: "complete",
      capturedAt: "2026-07-20T00:01:00Z",
      sourceLabel: "fixture"
    ), receivedAtMilliseconds: 2))
    fixture.model.reload()
    await waitUntil { fixture.model.rows.count == 2 }
    fixture.model.reveal(taskID: fixture.taskID)
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID }

    fixture.model.requestRemoteTranscription(fixture.descriptor, taskID: fixture.taskID)
    await waitUntil { fixture.model.transcriptionText == "A partial" }
    fixture.model.selectedTaskID = other.taskID
    await waitUntil { fixture.model.detail?.task.id == other.taskID }
    XCTAssertTrue(fixture.model.transcriptionState(for: fixture.taskID).isActive)
    XCTAssertEqual(fixture.model.transcriptionText(for: fixture.taskID), "A partial")
    XCTAssertEqual(fixture.model.transcriptionState(for: other.taskID), .idle)
    XCTAssertGreaterThan(fixture.tempEntryCount, 0)
    fixture.model.selectedTaskID = fixture.taskID
    await waitUntil { fixture.model.detail?.task.id == fixture.taskID }
    fixture.model.cancelTranscription()
    await waitUntil { fixture.tempEntryCount == 0 }
    XCTAssertEqual(try fixture.repository.database.read {
      try String.fetchOne($0, sql: "SELECT status FROM task_transcription_attempts WHERE task_id = ?", arguments: [fixture.taskID.rawValue])
    }, "cancelled")
  }

  func testFaviconLoadingLimitsPeakConcurrencyToSix() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-favicon-limit.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = (0..<7).map { faviconRow(host: "limit\($0).example", updatedAt: Int64(100 - $0)) }
    let fetcher = DelayedFaviconResourceFetcher(blockedHosts: Set(rows.prefix(6).map(\.host)))
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: rows, nextCursor: nil),
      details: Dictionary(uniqueKeysWithValues: rows.map { ($0.taskID, makeDetail(for: $0)) })
    )
    let model = HistoryViewModel(
      faviconCache: WebsiteFaviconCache(applicationSupportRoot: root),
      faviconResources: fetcher
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)

    await waitUntilAsync { fetcher.blockedEntryCount == 6 }
    XCTAssertEqual(fetcher.peakConcurrency, 6)
    fetcher.releaseAll()
    await waitUntil { rows.allSatisfy { model.faviconImageURL(for: $0) != nil } }
    XCTAssertLessThanOrEqual(fetcher.peakConcurrency, 6)
  }

  func testBundledPlatformsSkipNetworkWhileCommunityPlatformFeedsSidebarFavicon() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-platform-favicon.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = faviconRow(host: "github.com", updatedAt: 2)
    let community = faviconRow(host: "news.ycombinator.com", updatedAt: 1)
    let fetcher = DelayedFaviconResourceFetcher(blockedHosts: [])
    let repository = HistoryScreenRepository(
      firstPage: .init(rows: [bundled, community], nextCursor: nil),
      details: [bundled.taskID: makeDetail(for: bundled), community.taskID: makeDetail(for: community)]
    )
    let model = HistoryViewModel(
      faviconCache: WebsiteFaviconCache(applicationSupportRoot: root),
      faviconResources: fetcher
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)

    await waitUntil { model.faviconImageURL(for: community) != nil }
    XCTAssertNil(model.faviconImageURL(for: bundled))
    XCTAssertNotNil(model.platformFavicon(forHost: "news.ycombinator.com"))
    XCTAssertFalse(fetcher.requestedHosts.contains("github.com"))
  }

  func testLateFaviconFromPreviousGenerationCannotPolluteReplacementRows() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-favicon-generation.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = faviconRow(host: "stale.example", updatedAt: 100)
    let fresh = faviconRow(host: "fresh.example", updatedAt: 200)
    let fetcher = DelayedFaviconResourceFetcher(blockedHosts: [stale.host])
    let cache = WebsiteFaviconCache(applicationSupportRoot: root)
    let oldRepository = HistoryScreenRepository(
      firstPage: .init(rows: [stale], nextCursor: nil),
      details: [stale.taskID: makeDetail(for: stale)]
    )
    let freshRepository = HistoryScreenRepository(
      firstPage: .init(rows: [fresh], nextCursor: nil),
      details: [fresh.taskID: makeDetail(for: fresh)]
    )
    let model = HistoryViewModel(faviconCache: cache, faviconResources: fetcher)
    model.configure(history: .init(repository: oldRepository), isReadOnly: false, unavailableCode: nil)
    await waitUntilAsync { fetcher.blockedEntryCount == 1 }

    model.configure(history: .init(repository: freshRepository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.faviconImageURL(for: fresh) != nil }
    fetcher.releaseAll()
    try? await Task.sleep(for: .milliseconds(30))

    XCTAssertNil(model.faviconImageURL(for: stale))
    XCTAssertNotNil(model.faviconImageURL(for: fresh))
  }

  private func waitUntil(timeout: Duration = .seconds(1), file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  private func waitUntilAsync(timeout: Duration = .seconds(1), file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @Sendable () async -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !(await condition()) && clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    let satisfied = await condition()
    XCTAssertTrue(satisfied, file: file, line: line)
  }

  func testLivePlaybackTranscriptionStreamsPartialsAndPersistsFinal() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
      url: "https://www.youtube.com/watch?v=aWrFppphs6w", title: "无字幕视频",
      platform: "youtube", method: "fixture", text: "# 无字幕视频\n\n_该视频未提供字幕，无法直接提取口播文字。_",
      completeness: "complete", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))

    let model = HistoryViewModel(
      livePlaybackTranscribe: { _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.transcribing)
          continuation.yield(.partial("大家好"))
          continuation.yield(.partial("大家好，今天讲"))
          continuation.yield(.final("大家好，今天讲本地优先。"))
          continuation.finish()
        }
      }
    )
    XCTAssertTrue(model.canLiveTranscribePlayback)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    let detail = try repository.detail(taskID: accepted.taskID)
    model.startLivePlaybackTranscription(detail: detail, platform: "youtube")
    await waitUntil { model.transcriptionState == .completed }

    // 转写文本落库为本机转写 snapshot。
    let after = try repository.detail(taskID: accepted.taskID)
    XCTAssertTrue(after.snapshots.contains { $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue && $0.bodyText.contains("本地优先") })
  }

  /// 实时转写中途发现语种不对，必须停下并且**不落库**。
  ///
  /// 这条路径拿不到本地文件，用不了「先听一小段再决定 locale」那套，只能边转
  /// 边判。配文是中文于是猜 zh_CN，视频里说的却是英文——Apple 的听写这时不是
  /// 准确率下降，而是吐出成串的拉丁碎片。那半段乱码一旦存下来会顶替阅读区的
  /// 原文，还会一路流到总结和翻译，让人以为是那两步坏了。
  func testLivePlaybackStopsAndDiscardsWhenTheSpokenLanguageDoesNotMatch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-live-mismatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    // 配文是中文，于是听写语言会猜成 zh_CN。
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
      url: "https://www.youtube.com/watch?v=mismatch01", title: "斯坦福讲座",
      platform: "youtube", method: "fixture",
      text: "斯坦福教授的人工智能讲座，全程高能，值得反复观看学习。",
      completeness: "complete", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))

    // 视频里说的是英文：zh_CN 模型吐出的是这种拉丁碎片（实测形态）。
    let gibberish = "about carer avisont AI and in peovisers ae us to do most this yellecture by myself but what I thought"
    let model = HistoryViewModel(
      livePlaybackTranscribe: { _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.transcribing)
          continuation.yield(.partial(gibberish))
          continuation.yield(.final(gibberish))
          continuation.finish()
        }
      }
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    let detail = try repository.detail(taskID: accepted.taskID)
    model.startLivePlaybackTranscription(detail: detail, platform: "youtube")
    await waitUntil {
      if case .failed = model.transcriptionState { return true }
      return false
    }

    // 那半段乱码不能落库。
    let after = try repository.detail(taskID: accepted.taskID)
    XCTAssertFalse(
      after.snapshots.contains { $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue },
      "语种判错时不该留下转写快照"
    )
    // 提示里要说人话，不能甩一个 zh_CN 给用户。
    if case let .failed(message) = model.transcriptionState {
      XCTAssertTrue(message.contains("中文"), "提示应说明听出来的内容不像哪种语言：\(message)")
      XCTAssertFalse(message.contains("zh_CN"), "不该把 locale 标识甩给用户：\(message)")
    } else {
      XCTFail("应当停在失败态")
    }
  }

  func testTranscriptTidyPersistsTidiedSnapshotAndKeepsOriginal() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-tidy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
      url: "https://example.test/video", title: "评测视频",
      platform: "douyin", method: "fixture", text: "占位正文",
      completeness: "complete", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    // 预置一份本机转写 snapshot 作为整理输入。
    let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
    let rawTranscript = "厚度只有9。7毫米大家可以感受一下这个 Fod8 的手感"
    _ = try repository.completeTaskTranscription(.init(
      taskID: accepted.taskID,
      attempt: attempt,
      document: CapturedDocument(
        createdAt: "2026-07-20T00:01:00Z", origin: .localTranscription,
        url: "https://example.test/video", title: "评测视频",
        platform: "douyin", method: "speech_analyzer_local", text: rawTranscript,
        completeness: "complete", capturedAt: "2026-07-20T00:01:00Z", sourceLabel: "本机视频转写"
      ),
      evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
      receivedAtMilliseconds: 3
    ))

    let tidier = RecordingTranscriptTidier(result: "厚度只有 9.7 毫米，大家可以感受一下这个 Fold8 的手感。")
    let model = HistoryViewModel(transcriptTidier: tidier)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertTrue(model.canTidyTranscript(taskID: accepted.taskID))
    model.requestTranscriptTidy(taskID: accepted.taskID, model: "tidy-model")
    XCTAssertTrue(model.isTranscriptTidyConfirmationPresented)
    model.confirmTranscriptTidy()
    await waitUntil { model.transcriptTidyState(for: accepted.taskID) == .completed }

    let sentText = await tidier.receivedText
    let sentModel = await tidier.receivedModel
    let sentContext = await tidier.receivedContext
    XCTAssertEqual(sentText, rawTranscript)
    XCTAssertEqual(sentModel, "tidy-model")
    XCTAssertEqual(sentContext, TranscriptTidyContext(title: "评测视频", caption: "占位正文"))
    XCTAssertEqual(
      model.transcriptTidyTokenSummary(for: accepted.taskID),
      "1200 tokens（输入 1000 / 输出 200）"
    )

    let after = try repository.detail(taskID: accepted.taskID)
    let transcripts = after.snapshots.filter {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    }
    // 原始转写稿保留，整理稿追加为最新 snapshot。
    XCTAssertTrue(transcripts.contains { $0.bodyText == rawTranscript })
    XCTAssertEqual(transcripts.last?.captureMethod, "openai_compatible_chat_tidy")
    XCTAssertTrue(transcripts.last?.bodyText.contains("Fold8") == true)
  }

  /// 部分分片失败时，不能用绿色「校对稿已保存」把它包装成完整成功。
  func testPartialTranscriptTidyUsesAnExplicitFailureState() {
    let outcome = TranscriptTidyOutcome(
      text: "第一段已校对\n\n第二段原文",
      promptTokens: 800,
      completionTokens: 600,
      totalTokens: 1_400,
      failedChunkCount: 1,
      chunkCount: 2
    )

    XCTAssertEqual(
      HistoryViewModel.tidyStateAfterSaving(outcome, style: .subtitles),
      .failed("校对未完整完成：2 段中有 1 段失败；已完成部分已保存，失败段保留原文。请重试。")
    )
    XCTAssertEqual(
      HistoryViewModel.tidyStateAfterSaving(outcome, style: .note),
      .failed("整理未完整完成：2 段中有 1 段失败；已完成部分已保存，失败段保留原文。请重试。")
    )
  }

  /// 笔记的整理排版走的是另一条路：改自己的正文，不产生转写快照。
  ///
  /// 复用转写那条路径会让一条笔记凭空多出一份「本机转写」来源——用户只是想让
  /// 只读资料库上，本地编辑一律不落库。
  ///
  /// 这不是一个按钮的事，是一类：改正文、改标题、换脑图配色分别走各自的入口，
  /// 谁漏了 `!isReadOnly` 谁就在只读资料库上真的写。改标题那条尤其隐蔽——打开一条
  /// 标题带 U+FFFC 的笔记时视图会自动调它清洗标题，**不需要任何用户操作**。
  /// 一条用例同时钉住三个入口，是为了让今后新增的写入路径没法只补其中一个。
  func testReadOnlyHistoryRejectsLocalEdits() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-readonly-edits-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let originalBody = "原始正文"
    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-21T00:00:00Z", origin: .manualLink,
        url: "https://example.test/readonly", title: "原始标题",
        platform: "web", method: "fixture", text: originalBody,
        completeness: "complete", capturedAt: "2026-08-21T00:00:00Z", sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))
    let outline = MindMapOutline(
      title: "原始标题", subtitle: nil,
      branches: [.init(title: "要点", leaves: ["一"])]
    )
    try repository.saveMindMap(TaskMindMapRecord(
      taskID: accepted.taskID,
      outline: outline,
      themeID: "classic",
      userEdited: false,
      provider: "test",
      model: "test",
      promptTokens: 1,
      completionTokens: 1,
      totalTokens: 2,
      createdAtMilliseconds: 2,
      updatedAtMilliseconds: 2
    ))

    // 先在**可写**模式下走一遍同样的调用。
    //
    // 这一段不是凑数：`saveEditedSnapshotText` 是排队异步落库的，只读那一段若不等满
    // 一个真实的写入窗口就断言，闸门全拆了测试也照样绿。先确认这条路真的会落库，
    // 下面的等待才有意义——第一版就是漏了这步，红验证时正文那条纹丝不动。
    let writableModel = HistoryViewModel()
    writableModel.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { writableModel.detailState == .loaded && writableModel.selectedTaskID == accepted.taskID }
    let snapshotID = try XCTUnwrap(writableModel.detail?.snapshots.last?.id)
    writableModel.saveEditedSnapshotText(
      taskID: accepted.taskID, snapshotID: snapshotID, bodyText: "可写时确实会落库"
    )
    await waitUntilAsync {
      ((try? repository.detail(taskID: accepted.taskID))?.snapshots
        .contains { $0.bodyText.contains("可写时确实会落库") }) == true
    }
    // 还原，让只读那一段从已知状态出发。
    writableModel.saveEditedSnapshotText(
      taskID: accepted.taskID, snapshotID: snapshotID, bodyText: originalBody
    )
    await waitUntilAsync {
      ((try? repository.detail(taskID: accepted.taskID))?.snapshots
        .contains { $0.bodyText.contains(originalBody) }) == true
    }

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: true, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }
    let storedTheme = try XCTUnwrap(repository.loadMindMap(taskID: accepted.taskID)).themeID

    model.saveEditedSnapshotText(taskID: accepted.taskID, snapshotID: snapshotID, bodyText: "被改过的正文")
    model.renameNote(taskID: accepted.taskID, title: "被改过的标题")
    model.updateMindMapTheme(taskID: accepted.taskID, themeID: "dark-code")

    // 断言的是「什么都没发生」，等不够就等于没测。上面那次可写写入是毫秒级落库的，
    // 这里给足一秒。
    try await Task.sleep(for: .seconds(1))
    let after = try repository.detail(taskID: accepted.taskID)
    // 标题挂在最新那条 snapshot 上，不在 task 上。
    XCTAssertEqual(after.snapshots.last?.title, "原始标题", "只读时不该改标题")
    XCTAssertTrue(
      after.snapshots.contains { $0.bodyText.contains(originalBody) },
      "只读时不该改正文"
    )
    XCTAssertFalse(
      after.snapshots.contains { $0.bodyText.contains("被改过的正文") },
      "只读时不该改正文"
    )
    XCTAssertEqual(
      try XCTUnwrap(repository.loadMindMap(taskID: accepted.taskID)).themeID,
      storedTheme,
      "只读时不该改脑图配色"
    )
  }

  /// 「校对字幕」必须和「模型校对」受同一道闸约束。
  ///
  /// 这条路会写库、还会把字幕正文连同标题配文发到外部聊天模型。它上线时用
  /// `style == .subtitles || canTidyTranscript(...)` 短路掉了整条前置检查，于是
  /// 只读资料库照样被写、正文照样被发出去。这里同时钉住三种状态，避免今后
  /// 只修其中一种。
  func testSubtitleTidyRespectsReadOnlyAndModelGates() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-subtitle-tidy-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-20T00:00:00Z", origin: .manualLink,
        url: "https://example.test/lecture", title: "讲座",
        platform: "bilibili", method: "fixture", text: "占位配文",
        completeness: "complete", capturedAt: "2026-08-20T00:00:00Z", sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))
    let rawSubtitles = "00:03 衡量的标准是完成该任务人类需要多长时间"
    _ = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-20T00:01:00Z", origin: .burnedInSubtitles,
        url: "https://example.test/lecture", title: "讲座",
        platform: "bilibili", method: "vision_ocr", text: rawSubtitles,
        completeness: "complete", capturedAt: "2026-08-20T00:01:00Z", sourceLabel: "画面字幕"
      ),
      receivedAtMilliseconds: 2
    ))

    // 只读：理由要说只读，且一个字都不能发出去。
    let readOnlyTidier = RecordingTranscriptTidier(result: "不该被调用")
    let readOnlyModel = HistoryViewModel(transcriptTidier: readOnlyTidier)
    readOnlyModel.configure(history: .init(repository: repository), isReadOnly: true, unavailableCode: nil)
    await waitUntil { readOnlyModel.detailState == .loaded && readOnlyModel.selectedTaskID == accepted.taskID }

    XCTAssertEqual(
      readOnlyModel.subtitleTidyUnavailableReason(taskID: accepted.taskID),
      "这份历史当前只能浏览"
    )
    XCTAssertFalse(readOnlyModel.canTidySubtitles(taskID: accepted.taskID))
    readOnlyModel.requestTranscriptTidy(taskID: accepted.taskID, model: "tidy-model", style: .subtitles)
    XCTAssertFalse(readOnlyModel.isTranscriptTidyConfirmationPresented, "只读时不该弹发送确认")
    XCTAssertEqual(
      readOnlyModel.transcriptTidyState(for: accepted.taskID),
      .failed("这份历史当前只能浏览")
    )
    let readOnlySent = await readOnlyTidier.receivedText
    XCTAssertNil(readOnlySent, "只读时不该把字幕正文发给模型")

    // 没配聊天模型：理由要指向设置，不能报「没有文稿」把人引偏。
    let unconfiguredModel = HistoryViewModel()
    unconfiguredModel.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil {
      unconfiguredModel.detailState == .loaded && unconfiguredModel.selectedTaskID == accepted.taskID
    }
    XCTAssertEqual(
      unconfiguredModel.subtitleTidyUnavailableReason(taskID: accepted.taskID),
      "需先在设置里配置聊天模型"
    )
    unconfiguredModel.requestTranscriptTidy(taskID: accepted.taskID, model: nil, style: .subtitles)
    XCTAssertEqual(
      unconfiguredModel.transcriptTidyState(for: accepted.taskID),
      .failed("需先在设置里配置聊天模型")
    )

    // 绿的一侧：条件齐了就必须能跑，别把功能整个焊死。
    let tidier = RecordingTranscriptTidier(result: "00:03 衡量的标准是完成该任务人类需要多长时间")
    let model = HistoryViewModel(transcriptTidier: tidier)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertNil(model.subtitleTidyUnavailableReason(taskID: accepted.taskID))
    XCTAssertTrue(model.canTidySubtitles(taskID: accepted.taskID))
    model.requestTranscriptTidy(taskID: accepted.taskID, model: "tidy-model", style: .subtitles)
    XCTAssertTrue(model.isTranscriptTidyConfirmationPresented)
    model.confirmTranscriptTidy()
    await waitUntil { model.transcriptTidyState(for: accepted.taskID) == .completed }
    let sentStyle = await tidier.receivedStyle
    let sentText = await tidier.receivedText
    XCTAssertEqual(sentStyle, .subtitles)
    XCTAssertEqual(sentText, rawSubtitles)
  }

  /// 没有画面字幕层时，理由要说「先去读字幕」，不能沿用听写那句「先完成转写」。
  func testSubtitleTidyReasonPointsAtReadingSubtitlesFirst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-subtitle-tidy-missing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-20T00:00:00Z", origin: .manualLink,
        url: "https://example.test/no-subtitles", title: "讲座",
        platform: "bilibili", method: "fixture", text: "占位配文",
        completeness: "complete", capturedAt: "2026-08-20T00:00:00Z", sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))
    let tidier = RecordingTranscriptTidier(result: "不该被调用")
    let model = HistoryViewModel(transcriptTidier: tidier)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertEqual(
      model.subtitleTidyUnavailableReason(taskID: accepted.taskID),
      "需先读取画面字幕，才有字幕可校对"
    )
    let sent = await tidier.receivedText
    XCTAssertNil(sent)
  }

  /// 自己写的东西排得整齐些，不该因此在记录里多出一个不存在的来源。
  func testNoteTidyRewritesItsOwnSnapshotWithoutCreatingATranscript() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-note-tidy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let messy = "# 标题正文黏在一起 1. 第一条 2. 第二条"
    let accepted = try repository.acceptCapture(.init(
      document: try UserNoteDocument.make(title: "灵感", body: messy),
      receivedAtMilliseconds: 1
    ))
    let tidied = "# 标题\n\n正文\n\n1. 第一条\n2. 第二条"
    let tidier = RecordingTranscriptTidier(result: tidied)
    let model = HistoryViewModel(transcriptTidier: tidier)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    // 笔记不在默认的「全部」列表里，先切到笔记区，否则选中项会被列表刷新清掉。
    model.selectScope(.notes)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertTrue(model.canTidyNote(taskID: accepted.taskID))
    model.requestNoteTidy(taskID: accepted.taskID, model: "tidy-model")
    await waitUntil { model.transcriptTidyState(for: accepted.taskID) == .completed }

    // 用的是笔记那套提示词，不是修转写错别字那套。
    let style = await tidier.receivedStyle
    let sentText = await tidier.receivedText
    XCTAssertEqual(style, .note)
    XCTAssertEqual(sentText, messy)

    let after = try repository.detail(taskID: accepted.taskID)
    XCTAssertEqual(after.snapshots.count, 1, "整理笔记不该新增快照，只改它自己那一份")
    XCTAssertEqual(after.snapshots.first?.sourceKind, CapturedDocument.Origin.userNote.rawValue)
    XCTAssertTrue(after.snapshots.first?.bodyText.contains("1. 第一条\n2. 第二条") == true)
  }

  /// 空笔记不能整理——没内容可整，按钮该是灰的且说得出原因。
  func testNoteTidyIsUnavailableWithAReasonWhenThereIsNoModel() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-note-tidy-off-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let accepted = try repository.acceptCapture(.init(
      document: try UserNoteDocument.make(body: "写了点东西"),
      receivedAtMilliseconds: 1
    ))
    // 没有配置整理模型。
    let model = HistoryViewModel(transcriptTidier: nil)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    model.selectScope(.notes)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertFalse(model.canTidyNote(taskID: accepted.taskID))
    XCTAssertNotNil(
      model.noteTidyUnavailableReason(taskID: accepted.taskID),
      "不可用就必须给得出理由，否则又是一个没人看得懂的灰按钮"
    )
  }

  func testTranscriptTidyFailureKeepsOriginalAndReportsError() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-tidy-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-20T00:00:00Z", origin: .manualLink,
      url: "https://example.test/video", title: "评测视频",
      platform: "douyin", method: "fixture", text: "占位正文",
      completeness: "complete", capturedAt: "2026-07-20T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    let attempt = try repository.beginTaskTranscription(taskID: accepted.taskID, createdAtMilliseconds: 2)
    _ = try repository.completeTaskTranscription(.init(
      taskID: accepted.taskID,
      attempt: attempt,
      document: CapturedDocument(
        createdAt: "2026-07-20T00:01:00Z", origin: .localTranscription,
        url: "https://example.test/video", title: "评测视频",
        platform: "douyin", method: "speech_analyzer_local", text: "原始转写",
        completeness: "complete", capturedAt: "2026-07-20T00:01:00Z", sourceLabel: "本机视频转写"
      ),
      evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: 3),
      receivedAtMilliseconds: 3
    ))

    let model = HistoryViewModel(transcriptTidier: FailingTranscriptTidier())
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    model.requestTranscriptTidy(taskID: accepted.taskID, model: nil)
    model.confirmTranscriptTidy()
    await waitUntil {
      if case .failed = model.transcriptTidyState(for: accepted.taskID) { return true }
      return false
    }
    XCTAssertEqual(
      model.transcriptTidyState(for: accepted.taskID),
      .failed(TranscriptTidyError.networkInterrupted.userMessage)
    )
    // 失败不落任何新 snapshot，原始转写稿完好。
    let after = try repository.detail(taskID: accepted.taskID)
    let transcripts = after.snapshots.filter {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    }
    XCTAssertEqual(transcripts.map(\.bodyText), ["原始转写"])
  }
}

extension HistoryViewModelTests {
  func testMindMapGenerationPersistsRecordAndThemeSwitchIsLocal() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-vm-mindmap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-23T00:00:00Z", origin: .manualLink,
      url: "https://example.test/mindmap", title: "评测视频",
      platform: "web", method: "fixture", text: "很长的正文内容，讲了外观和屏幕。",
      completeness: "complete", capturedAt: "2026-07-23T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))

    let outline = MindMapOutline(
      title: "评测视频", subtitle: nil,
      branches: [.init(title: "外观", leaves: ["很轻", "很薄"])],
      tags: ["折叠屏", "三星"]
    )
    let extractor = StubMindMapExtractor(outcome: .init(outline: outline, totalTokens: 640))
    let model = HistoryViewModel(mindMapExtractor: extractor)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    XCTAssertTrue(model.canGenerateMindMap(taskID: accepted.taskID))
    model.requestMindMapGeneration(taskID: accepted.taskID)
    XCTAssertTrue(model.isMindMapConfirmationPresented)
    model.confirmMindMapGeneration()
    await waitUntil { model.mindMapState(for: accepted.taskID) == .completed }
    XCTAssertEqual(model.mindMapRecord?.outline, outline)
    XCTAssertEqual(model.mindMapTokenSummary, "640 tokens")
    await waitUntilAsync { (try? repository.loadMindMap(taskID: accepted.taskID)) != nil }

    // 主题切换与编辑均为本地操作：抽取器只被调用一次。
    model.updateMindMapTheme(taskID: accepted.taskID, themeID: "dark-code")
    XCTAssertEqual(model.mindMapRecord?.themeID, "dark-code")
    let edited = MindMapOutline(
      title: "评测视频（改）", subtitle: nil, branches: outline.branches
    )
    model.updateMindMapOutline(taskID: accepted.taskID, outline: edited)
    XCTAssertEqual(model.mindMapRecord?.outline.title, "评测视频（改）")
    XCTAssertEqual(model.mindMapRecord?.userEdited, true)
    await waitUntilAsync {
      (try? repository.loadMindMap(taskID: accepted.taskID))??.userEdited == true
    }
    let calls = await extractor.callCount
    XCTAssertEqual(calls, 1)
    XCTAssertNotNil(model.mindMapSVG())
    XCTAssertNotNil(model.mindMapCombinedExportHTML())

    // 标签来自大纲的主题 tags 字段；分支标题（章节结构）绝不入标签。
    await waitUntilAsync {
      let names = (try? repository.allTags().map(\.name)) ?? []
      return names.contains("折叠屏") && names.contains("三星")
    }
    let tagNames = try repository.allTags().map(\.name)
    XCTAssertFalse(tagNames.contains("外观"))
  }

  /// 校对保存是「worker 写库 + 详情就地补丁」：主线程不写 SQLite，也不再
  /// 整条详情回读（自动保存每停笔一秒就可能触发，回读曾是打字卡顿的主要
  /// 来源）。锁定三件事：真的落了库、连续两次保存不乱序、当前详情投影
  /// （正文/字数/指纹）就地更新到位。
  func testSaveEditedSnapshotTextPersistsInOrderAndPatchesDetailInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-save-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }

    let accepted = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-07-20T00:00:00Z",
        origin: .manualLink,
        url: "https://example.test/save-edit",
        title: "待校对",
        platform: "web",
        method: "rendered_dom",
        text: "原始正文",
        completeness: "complete",
        capturedAt: "2026-07-20T00:00:00Z",
        sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))

    let model = HistoryViewModel()
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }
    guard let snapshot = model.detail?.snapshots.last else { return XCTFail("详情缺 snapshot") }

    // 连续两次保存（自动保存的常态）：以后写的一版为准，不许乱序回退。
    model.saveEditedSnapshotText(taskID: accepted.taskID, snapshotID: snapshot.id, bodyText: "第一版")
    model.saveEditedSnapshotText(taskID: accepted.taskID, snapshotID: snapshot.id, bodyText: "第二版校对稿")

    let service = HistoryApplicationService(repository: repository)
    await waitUntilAsync {
      (try? service.detail(taskID: accepted.taskID))?.snapshots.last?.bodyText == "第二版校对稿"
    }
    XCTAssertEqual(
      try service.detail(taskID: accepted.taskID).snapshots.last?.bodyText,
      "第二版校对稿"
    )
    XCTAssertNil(model.snapshotEditFailure)
    // 详情投影就地补丁：不整条回读也能立即看到新正文与派生字段。
    XCTAssertEqual(model.detail?.snapshots.last?.bodyText, "第二版校对稿")
    XCTAssertEqual(model.detail?.snapshots.last?.characterCount, "第二版校对稿".unicodeScalars.count)
    XCTAssertEqual(
      model.detail?.snapshots.last?.bodySHA256,
      SHA256CaptureFingerprinter().bodySHA256("第二版校对稿")
    )
  }
}

extension HistoryViewModelTests {
  func testAutoPipelineRunsSummarizeThenMindMapOnceForTextCapture() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-pipeline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let document = CapturedDocument(
      createdAt: "2026-07-23T00:00:00Z", origin: .manualLink,
      url: "https://example.test/pipeline", title: "文章",
      platform: "web", method: "fixture", text: "一篇讲折叠屏的文章正文。",
      completeness: "complete", capturedAt: "2026-07-23T00:00:00Z", sourceLabel: "fixture"
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))

    let outline = MindMapOutline(
      title: "折叠屏", subtitle: nil, branches: [.init(title: "要点", leaves: ["很薄"])]
    )
    let extractor = StubMindMapExtractor(outcome: .init(outline: outline, totalTokens: 100))
    let model = HistoryViewModel(mindMapExtractor: extractor)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.detailState == .loaded && model.selectedTaskID == accepted.taskID }

    let summarizeCalls = SummarizeCallCounter()
    model.startAutoPipeline(
      taskID: accepted.taskID,
      expectsMedia: false,
      transcribe: false, tidy: false, summarize: true, mindMap: true,
      tidyModel: nil,
      summarizeAction: { _ in await summarizeCalls.increment(); return false },
      isSummaryBusy: { false }
    )
    await waitUntil(timeout: .seconds(5)) { model.mindMapRecord != nil }
    let calls = await summarizeCalls.count
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(model.mindMapRecord?.outline, outline)

    // 同一任务不重复处理。
    model.startAutoPipeline(
      taskID: accepted.taskID,
      expectsMedia: false,
      transcribe: false, tidy: false, summarize: true, mindMap: true,
      tidyModel: nil,
      summarizeAction: { _ in await summarizeCalls.increment(); return false },
      isSummaryBusy: { false }
    )
    try? await Task.sleep(for: .milliseconds(400))
    let callsAfter = await summarizeCalls.count
    XCTAssertEqual(callsAfter, 1)
    let extractorCalls = await extractor.callCount
    XCTAssertEqual(extractorCalls, 1)
  }

  func testAutoPipelineQueuesRapidCapturesWithoutChangingUserSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-pipeline-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    defer { try? repository.database.close() }
    let first = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-15T00:00:00Z", origin: .manualLink,
        url: "https://example.test/pipeline/first", title: "第一条",
        platform: "web", method: "fixture", text: "第一条正文",
        completeness: "complete", capturedAt: "2026-08-15T00:00:00Z", sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 1
    ))
    let second = try repository.acceptCapture(.init(
      document: CapturedDocument(
        createdAt: "2026-08-15T00:00:01Z", origin: .manualLink,
        url: "https://example.test/pipeline/second", title: "第二条",
        platform: "web", method: "fixture", text: "第二条正文",
        completeness: "complete", capturedAt: "2026-08-15T00:00:01Z", sourceLabel: "fixture"
      ),
      receivedAtMilliseconds: 2
    ))
    let outline = MindMapOutline(
      title: "队列", subtitle: nil, branches: [.init(title: "要点", leaves: ["完成"])]
    )
    let extractor = StubMindMapExtractor(outcome: .init(outline: outline, totalTokens: 10))
    let recorder = AutoPipelineSummaryRecorder()
    let service = HistoryApplicationService(repository: repository)
    let model = HistoryViewModel(mindMapExtractor: extractor)
    model.configure(history: service, isReadOnly: false, unavailableCode: nil)
    await waitUntil { model.rows.count == 2 }
    model.selectedTaskID = second.taskID
    await waitUntil { model.detail?.task.id == second.taskID }

    for taskID in [first.taskID, second.taskID] {
      model.startAutoPipeline(
        taskID: taskID,
        expectsMedia: false,
        transcribe: false, tidy: false, summarize: true, mindMap: true,
        tidyModel: nil,
        summarizeAction: { detail in
          await recorder.record(detail.task.id)
          return false
        },
        isSummaryBusy: { false }
      )
    }

    await waitUntilAsync(timeout: .seconds(8)) { await extractor.callCount == 2 }
    let summarizedTaskIDs = await recorder.taskIDs
    XCTAssertEqual(summarizedTaskIDs, [first.taskID, second.taskID])
    XCTAssertNotNil(try service.mindMapStore?.loadMindMap(taskID: first.taskID))
    XCTAssertNotNil(try service.mindMapStore?.loadMindMap(taskID: second.taskID))
    XCTAssertEqual(model.selectedTaskID, second.taskID, "后台队列不得替用户切换当前详情")
  }
}

private actor SummarizeCallCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private actor AutoPipelineSummaryRecorder {
  private(set) var taskIDs: [TaskID] = []
  func record(_ taskID: TaskID) { taskIDs.append(taskID) }
}

private actor StubMindMapExtractor: MindMapExtracting {
  private let outcome: MindMapExtractionOutcome
  private(set) var callCount = 0

  init(outcome: MindMapExtractionOutcome) { self.outcome = outcome }

  func extractOutline(text: String, model: String?) async throws -> MindMapExtractionOutcome {
    callCount += 1
    return outcome
  }
}

private actor RecordingTranscriptTidier: TranscriptTidying {
  private let result: String
  private(set) var receivedText: String?
  private(set) var receivedModel: String?
  private(set) var receivedStyle: TidyStyle?
  private(set) var receivedContext: TranscriptTidyContext?

  init(result: String) { self.result = result }

  func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext,
    progress _: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    receivedText = text
    receivedModel = model
    receivedStyle = style
    receivedContext = context
    return TranscriptTidyOutcome(text: result, promptTokens: 1_000, completionTokens: 200, totalTokens: 1_200)
  }
}

private struct FailingTranscriptTidier: TranscriptTidying {
  func tidy(
    text _: String,
    model _: String?,
    style _: TidyStyle,
    context _: TranscriptTidyContext,
    progress _: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    throw TranscriptTidyError.networkInterrupted
  }
}

private actor CountingFavoriteMediaDownload {
  private let store: LocalMediaStore
  private(set) var callCount = 0

  init(store: LocalMediaStore) { self.store = store }

  func perform(
    media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    pageURL: String?
  ) throws -> MediaAsset {
    callCount += 1
    XCTAssertEqual(media.videoURL, "https://media.example.test/video.mp4")
    XCTAssertEqual(pageURL, "https://example.test/watch")
    let bytes = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
    let sha = LocalMediaStore.contentSHA256(bytes)
    let relativePath = "\(sha).mp4"
    try store.ensureRoot()
    try bytes.write(to: store.absoluteURL(relativePath: relativePath), options: .atomic)
    return MediaAsset(
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: relativePath,
      contentSHA256: sha,
      byteSize: Int64(bytes.count),
      durationSeconds: media.durationSeconds,
      platform: media.platform,
      author: media.author,
      createdAtMilliseconds: 2
    )
  }
}

private actor GatedImageTextRecognizer: LocalImageTextRecognizing {
  private var didEnter = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var resultWaiter: CheckedContinuation<String, Never>?

  func recognizeText(in _: [URL], languages _: [String]) async throws -> String {
    didEnter = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    waiters.forEach { $0.resume() }
    return await withCheckedContinuation { resultWaiter = $0 }
  }

  func waitUntilEntered() async {
    if didEnter { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release(_ text: String) {
    resultWaiter?.resume(returning: text)
    resultWaiter = nil
  }
}

private enum TranscriptionScript: Sendable {
  case events([LocalVideoTranscriptionEvent])
  case failure(LocalVideoTranscriptionError)
  case suspended
}

private final class ScriptedVideoTranscriber: LocalVideoTranscribing, @unchecked Sendable {
  private let lock = NSLock()
  private var readiness: [LocalSpeechModelState]
  private var pendingScripts: [TranscriptionScript]
  private var downloads = 0
  private var modelChecks = 0
  private var transcriptions = 0
  private var locales: [String] = []
  private let downloadSuspends: Bool

  init(modelState: LocalSpeechModelState, scripts: [TranscriptionScript], downloadSuspends: Bool = false) {
    readiness = [modelState]
    pendingScripts = scripts
    self.downloadSuspends = downloadSuspends
  }

  init(modelStates: [LocalSpeechModelState], scripts: [TranscriptionScript]) {
    readiness = modelStates
    pendingScripts = scripts
    downloadSuspends = false
  }

  var downloadCallCount: Int { lock.withLock { downloads } }
  var modelStateCallCount: Int { lock.withLock { modelChecks } }
  var transcribeCallCount: Int { lock.withLock { transcriptions } }
  var lastLocaleIdentifier: String? { lock.withLock { locales.last } }
  func modelState(localeIdentifier: String) async -> LocalSpeechModelState {
    lock.withLock {
      modelChecks += 1
      locales.append(localeIdentifier)
      return readiness.count > 1 ? readiness.removeFirst() : readiness.first ?? .unavailable(.speechUnavailable)
    }
  }
  func downloadModel(localeIdentifier: String) async throws {
    lock.withLock {
      downloads += 1
      locales.append(localeIdentifier)
    }
    if downloadSuspends { try await Task.sleep(for: .seconds(60)) }
  }
  func transcribe(fileURL _: URL, workspaceURL _: URL, localeIdentifier: String) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    let script = lock.withLock { () -> TranscriptionScript in
      transcriptions += 1
      locales.append(localeIdentifier)
      return pendingScripts.isEmpty ? .failure(.recognitionFailed) : pendingScripts.removeFirst()
    }
    return AsyncThrowingStream { continuation in
      switch script {
      case let .events(events):
        for event in events { continuation.yield(event) }
        continuation.finish()
      case let .failure(error):
        continuation.finish(throwing: error)
      case .suspended:
        let worker = Task {
          continuation.yield(.extractingAudio)
          continuation.yield(.partial("A partial"))
          do {
            try await Task.sleep(for: .seconds(60))
            continuation.finish()
          } catch {
            continuation.finish(throwing: LocalVideoTranscriptionError.cancelled)
          }
        }
        continuation.onTermination = { @Sendable _ in worker.cancel() }
      }
    }
  }
}

private final class LateReadinessVideoTranscriber: LocalVideoTranscribing, @unchecked Sendable {
  private let lock = NSLock()
  private var readinessCalls = 0
  private var firstContinuation: CheckedContinuation<LocalSpeechModelState, Never>?
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []

  func modelState(localeIdentifier _: String) async -> LocalSpeechModelState {
    let call = lock.withLock { () -> Int in
      readinessCalls += 1
      return readinessCalls
    }
    guard call == 1 else { return .ready }
    return await withCheckedContinuation { continuation in
      let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        firstContinuation = continuation
        let values = entryWaiters
        entryWaiters.removeAll()
        return values
      }
      waiters.forEach { $0.resume() }
    }
  }

  func waitUntilFirstReadinessEntered() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if firstContinuation != nil {
        lock.unlock()
        continuation.resume()
      } else {
        entryWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func releaseFirstReadinessAsFailure() {
    let continuation = lock.withLock { () -> CheckedContinuation<LocalSpeechModelState, Never>? in
      defer { firstContinuation = nil }
      return firstContinuation
    }
    continuation?.resume(returning: .unavailable(.speechUnavailable))
  }

  func downloadModel(localeIdentifier _: String) async throws {}

  func transcribe(fileURL _: URL, workspaceURL _: URL, localeIdentifier _: String) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.extractingAudio)
      continuation.yield(.transcribing)
      continuation.yield(.final("新 attempt 完成正文"))
      continuation.finish()
    }
  }
}

private final class TranscriptionStatusObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var observed: [(TaskID, TranscriptionAttemptToken, TranscriptionStatus)] = []
  private var waiters: [(TaskID, TranscriptionStatus, CheckedContinuation<Void, Never>)] = []

  func record(taskID: TaskID, attempt: TranscriptionAttemptToken, status: TranscriptionStatus) {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      observed.append((taskID, attempt, status))
      let matching = waiters.filter { $0.0 == taskID && $0.1 == status }.map(\.2)
      waiters.removeAll { $0.0 == taskID && $0.1 == status }
      return matching
    }
    continuations.forEach { $0.resume() }
  }

  func waitUntilObserved(taskID: TaskID, status: TranscriptionStatus) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if observed.contains(where: { $0.0 == taskID && $0.2 == status }) {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((taskID, status, continuation))
        lock.unlock()
      }
    }
  }

  func attempts(taskID: TaskID, status: TranscriptionStatus) -> [TranscriptionAttemptToken] {
    lock.withLock {
      observed.filter { $0.0 == taskID && $0.2 == status }.map(\.1)
    }
  }
}

private final class DiscardedTranscriptionAttemptObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func record() {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      recorded = true
      defer { waiters.removeAll() }
      return waiters
    }
    continuations.forEach { $0.resume() }
  }

  func waitUntilRecorded() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if recorded {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

private final class ObservedTranscriptionRepository: HistoryRepository, @unchecked Sendable {
  let base: GRDBHistoryRepository
  let observer: TranscriptionStatusObserver
  var accessMode: HistoryRepositoryAccessMode { base.accessMode }

  init(base: GRDBHistoryRepository, observer: TranscriptionStatusObserver) {
    self.base = base
    self.observer = observer
  }

  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult { try base.acceptCapture(command) }
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { try base.createRun(command) }
  func markRunRunning(_ command: MarkRunRunningCommand) throws { try base.markRunRunning(command) }
  func savePartialArtifact(_ command: SavePartialArtifactCommand) throws { try base.savePartialArtifact(command) }
  func finishRun(_ command: FinishRunCommand) throws { try base.finishRun(command) }
  func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int { try base.recoverInterruptedRuns(at: milliseconds) }
  func historyPage(limit: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage { try base.historyPage(limit: limit, after: cursor) }
  func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    try base.historyPage(limit: limit, after: cursor, filter: filter)
  }
  func detail(taskID: TaskID) throws -> HistoryDetailProjection { try base.detail(taskID: taskID) }
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection { try base.exportProjection(taskID: taskID) }
  func allTags() throws -> [HistoryTag] { try base.allTags() }
  func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] { try base.addTags(rawNames, to: taskID) }
  func removeTag(normalizedName: String, from taskID: TaskID) throws { try base.removeTag(normalizedName: normalizedName, from: taskID) }
  func deleteTask(taskID: TaskID) throws { try base.deleteTask(taskID: taskID) }
  func attachMedia(_ command: AttachMediaCommand) throws { try base.attachMedia(command) }
  func mediaAsset(taskID: TaskID) throws -> MediaAsset? { try base.mediaAsset(taskID: taskID) }
  func beginMediaTranscription(taskID: TaskID, mediaID: String) throws -> TranscriptionAttemptToken {
    let attempt = try base.beginMediaTranscription(taskID: taskID, mediaID: mediaID)
    observer.record(taskID: taskID, attempt: attempt, status: .pending)
    return attempt
  }
  func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult {
    let result = try base.updateMediaTranscriptionStatus(taskID: taskID, attempt: attempt, status: status)
    observer.record(taskID: taskID, attempt: attempt, status: TranscriptionStatus(rawValue: status.rawValue)!)
    return result
  }
  func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult {
    try base.completeMediaTranscription(command)
  }
  func beginTaskTranscription(taskID: TaskID, createdAtMilliseconds: Int64) throws -> TaskTranscriptionAttemptToken {
    return try base.beginTaskTranscription(taskID: taskID, createdAtMilliseconds: createdAtMilliseconds)
  }
  func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult {
    try base.updateTaskTranscriptionStatus(
      taskID: taskID, attempt: attempt, status: status, updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
  func completeTaskTranscription(_ command: CompleteTaskTranscriptionCommand) throws -> CompleteTaskTranscriptionResult {
    try base.completeTaskTranscription(command)
  }
  func isMediaContentReferenced(contentSHA256: String) throws -> Bool {
    try base.isMediaContentReferenced(contentSHA256: contentSHA256)
  }
}

private final class TranscriptionGateRepository: HistoryRepository, @unchecked Sendable {
  let base: GRDBHistoryRepository
  let beginFailure: RepositoryFailure?
  let completionOverride: CompleteMediaTranscriptionResult?
  let beginBarrier: BeginReturnBarrier?
  var accessMode: HistoryRepositoryAccessMode { base.accessMode }

  init(
    base: GRDBHistoryRepository,
    beginFailure: RepositoryFailure? = nil,
    completionOverride: CompleteMediaTranscriptionResult? = nil,
    beginBarrier: BeginReturnBarrier? = nil
  ) {
    self.base = base
    self.beginFailure = beginFailure
    self.completionOverride = completionOverride
    self.beginBarrier = beginBarrier
  }

  func acceptCapture(_ command: AcceptCaptureCommand) throws -> AcceptCaptureResult { try base.acceptCapture(command) }
  func createRun(_ command: CreateRunCommand) throws -> CreateRunResult { try base.createRun(command) }
  func markRunRunning(_ command: MarkRunRunningCommand) throws { try base.markRunRunning(command) }
  func savePartialArtifact(_ command: SavePartialArtifactCommand) throws { try base.savePartialArtifact(command) }
  func finishRun(_ command: FinishRunCommand) throws { try base.finishRun(command) }
  func recoverInterruptedRuns(at milliseconds: Int64) throws -> Int { try base.recoverInterruptedRuns(at: milliseconds) }
  func historyPage(limit: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage { try base.historyPage(limit: limit, after: cursor) }
  func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    try base.historyPage(limit: limit, after: cursor, filter: filter)
  }
  func detail(taskID: TaskID) throws -> HistoryDetailProjection { try base.detail(taskID: taskID) }
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection { try base.exportProjection(taskID: taskID) }
  func allTags() throws -> [HistoryTag] { try base.allTags() }
  func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] { try base.addTags(rawNames, to: taskID) }
  func removeTag(normalizedName: String, from taskID: TaskID) throws { try base.removeTag(normalizedName: normalizedName, from: taskID) }
  func deleteTask(taskID: TaskID) throws { try base.deleteTask(taskID: taskID) }
  func attachMedia(_ command: AttachMediaCommand) throws { try base.attachMedia(command) }
  func mediaAsset(taskID: TaskID) throws -> MediaAsset? { try base.mediaAsset(taskID: taskID) }
  func beginMediaTranscription(taskID: TaskID, mediaID: String) throws -> TranscriptionAttemptToken {
    if let beginFailure { throw beginFailure }
    let attempt = try base.beginMediaTranscription(taskID: taskID, mediaID: mediaID)
    beginBarrier?.block()
    return attempt
  }
  func updateMediaTranscriptionStatus(
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) throws -> TranscriptionStatusUpdateResult {
    try base.updateMediaTranscriptionStatus(taskID: taskID, attempt: attempt, status: status)
  }
  func completeMediaTranscription(_ command: CompleteMediaTranscriptionCommand) throws -> CompleteMediaTranscriptionResult {
    if let completionOverride { return completionOverride }
    return try base.completeMediaTranscription(command)
  }
  func beginTaskTranscription(taskID: TaskID, createdAtMilliseconds: Int64) throws -> TaskTranscriptionAttemptToken {
    if let beginFailure { throw beginFailure }
    return try base.beginTaskTranscription(taskID: taskID, createdAtMilliseconds: createdAtMilliseconds)
  }
  func updateTaskTranscriptionStatus(
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) throws -> TranscriptionStatusUpdateResult {
    try base.updateTaskTranscriptionStatus(
      taskID: taskID, attempt: attempt, status: status, updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
  func completeTaskTranscription(_ command: CompleteTaskTranscriptionCommand) throws -> CompleteTaskTranscriptionResult {
    try base.completeTaskTranscription(command)
  }
  func isMediaContentReferenced(contentSHA256: String) throws -> Bool {
    try base.isMediaContentReferenced(contentSHA256: contentSHA256)
  }
}

private struct TranscriptionFixture {
  let root: URL
  let repository: GRDBHistoryRepository
  let store: LocalMediaStore
  let model: HistoryViewModel
  let taskID: TaskID
  let otherTaskID: TaskID?
  func close() {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor
private func makeTranscriptionFixture(
  transcriber: any LocalVideoTranscribing,
  includesSecondTask: Bool = false,
  captionText: String = "视频说明",
  dependencies: PersistenceDependencies = .live,
  statusObserver: TranscriptionStatusObserver? = nil,
  onDiscardedTranscriptionAttempt: @escaping @Sendable () -> Void = {},
  nowMilliseconds: @escaping @Sendable () -> Int64 = { 1_752_883_200_000 }
) throws -> TranscriptionFixture {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("linkdigest-transcription-ui-\(UUID().uuidString)", isDirectory: true)
  let repository = try GRDBHistoryRepository.open(
    at: .init(applicationSupportRoot: root),
    dependencies: dependencies
  )
  let document = CapturedDocument(
    createdAt: "2026-07-19T00:00:00Z",
    origin: .manualLink,
    url: "https://www.douyin.com/video/1234567890123456789",
    title: "本机视频",
    platform: "douyin",
    method: "fixture",
    text: captionText,
    completeness: "complete",
    capturedAt: "2026-07-19T00:00:00Z",
    sourceLabel: "fixture"
  )
  let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
  let store = LocalMediaStore(applicationSupportRoot: root)
  try store.ensureRoot()
  let fixtureData = Data("local-video-fixture".utf8)
  let fixtureSHA = LocalMediaStore.contentSHA256(fixtureData)
  let fixtureRelativePath = "\(fixtureSHA).mp4"
  try fixtureData.write(to: store.absoluteURL(relativePath: fixtureRelativePath), options: .atomic)
  try repository.attachMedia(.init(asset: .init(
    taskID: accepted.taskID,
    snapshotID: accepted.snapshotID,
    relativePath: fixtureRelativePath,
    contentSHA256: fixtureSHA,
    byteSize: 19,
    durationSeconds: 12,
    platform: "douyin",
    author: "作者",
    createdAtMilliseconds: 2
  )))
  var otherTaskID: TaskID?
  if includesSecondTask {
    let other = CapturedDocument(
      createdAt: "2026-07-18T00:00:00Z", origin: .manualLink,
      url: "https://www.douyin.com/video/9876543210987654321", title: "B 视频",
      platform: "douyin", method: "fixture", text: "B 视频说明", completeness: "complete",
      capturedAt: "2026-07-18T00:00:00Z", sourceLabel: "fixture"
    )
    let acceptedOther = try repository.acceptCapture(.init(document: other, receivedAtMilliseconds: 0))
    let otherData = Data("other-local-video".utf8)
    let otherSHA = LocalMediaStore.contentSHA256(otherData)
    let otherRelativePath = "\(otherSHA).mp4"
    try otherData.write(to: store.absoluteURL(relativePath: otherRelativePath), options: .atomic)
    try repository.attachMedia(.init(asset: .init(
      taskID: acceptedOther.taskID, snapshotID: acceptedOther.snapshotID,
      relativePath: otherRelativePath, contentSHA256: otherSHA, byteSize: 17,
      durationSeconds: 8, platform: "douyin", author: "B 作者", createdAtMilliseconds: 1
    )))
    otherTaskID = acceptedOther.taskID
  }
  let model = HistoryViewModel(
    mediaStore: store,
    videoTranscriber: transcriber,
    onDiscardedTranscriptionAttempt: onDiscardedTranscriptionAttempt,
    nowMilliseconds: nowMilliseconds
  )
  let configuredRepository: any HistoryRepository
  if let statusObserver {
    configuredRepository = ObservedTranscriptionRepository(base: repository, observer: statusObserver)
  } else {
    configuredRepository = repository
  }
  model.configure(
    history: HistoryApplicationService(repository: configuredRepository),
    isReadOnly: false,
    unavailableCode: nil
  )
  return .init(root: root, repository: repository, store: store, model: model, taskID: accepted.taskID, otherTaskID: otherTaskID)
}

private struct RemoteTranscriptionFixture {
  let root: URL
  let repository: GRDBHistoryRepository
  let model: HistoryViewModel
  let taskID: TaskID
  let descriptor: MediaDescriptor
  let fetcher: RemoteTempResourceFetcher
  let tempStore: TranscriptionTempStore

  var tempEntryCount: Int {
    (try? FileManager.default.contentsOfDirectory(atPath: tempStore.tempRoot.path).count) ?? 0
  }

  func close() {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor
private func makeRemoteTranscriptionFixture(
  transcriber: any LocalVideoTranscribing,
  availableDiskBytes: (@Sendable (URL) throws -> Int64)? = nil
) throws -> RemoteTranscriptionFixture {
  let root = URL(
    fileURLWithPath: "/private/tmp/linkdigest-remote-transcription-ui-\(UUID().uuidString)",
    isDirectory: true
  )
  let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
  let document = CapturedDocument(
    createdAt: "2026-07-20T00:00:00Z",
    origin: .manualLink,
    url: "https://example.test/video",
    title: "远程视频",
    platform: "generic",
    method: "fixture",
    text: "页面正文",
    completeness: "complete",
    capturedAt: "2026-07-20T00:00:00Z",
    sourceLabel: "fixture"
  )
  let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
  let fetcher = RemoteTempResourceFetcher()
  let tempStore = TranscriptionTempStore(
    applicationSupportRoot: root,
    resources: fetcher,
    availableDiskBytes: availableDiskBytes
  )
  let model = HistoryViewModel(
    videoTranscriber: transcriber,
    transcriptionTempStore: tempStore,
    nowMilliseconds: { 1_753_017_600_000 }
  )
  model.configure(
    history: HistoryApplicationService(repository: repository),
    isReadOnly: false,
    unavailableCode: nil
  )
  let descriptor = MediaDescriptor(
    kind: .directFile,
    pageURL: "https://example.test/video",
    canonicalURL: "https://example.test/video",
    platform: "generic",
    ephemeralPlaybackURL: "https://media.example.test/video.mp4?signature=never-persist",
    mimeType: "video/mp4",
    durationSeconds: nil,
    transcriptionCapability: .supported
  )
  return .init(
    root: root,
    repository: repository,
    model: model,
    taskID: accepted.taskID,
    descriptor: descriptor,
    fetcher: fetcher,
    tempStore: tempStore
  )
}

private final class RemoteTempResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { calls += 1 }
    var body = Data([0, 0, 0, 24])
    body.append(contentsOf: Array("ftypisom".utf8))
    body.append(contentsOf: Array(repeating: 0, count: 12))
    return .init(url: request.url, statusCode: 200, contentType: "video/mp4", body: body)
  }
}

private final class HistoryImageResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [SafeResourceRequest] = []
  var requests: [SafeResourceRequest] { lock.withLock { seen } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { seen.append(request) }
    return .init(
      url: request.url,
      statusCode: 200,
      contentType: "image/png",
      body: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])
    )
  }
}

private final class DelayedFaviconResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let blockedHosts: Set<String>
  private var active = 0
  private var peak = 0
  private var blockedEntries = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var hosts: [String] = []

  init(blockedHosts: Set<String>) { self.blockedHosts = blockedHosts }

  var peakConcurrency: Int { lock.withLock { peak } }
  var blockedEntryCount: Int { lock.withLock { blockedEntries } }
  var requestedHosts: [String] { lock.withLock { hosts } }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    let shouldBlock = lock.withLock { () -> Bool in
      active += 1
      peak = max(peak, active)
      if let host = request.url.host { hosts.append(host) }
      return blockedHosts.contains(request.url.host ?? "")
    }
    defer { lock.withLock { active -= 1 } }
    if shouldBlock {
      await withCheckedContinuation { continuation in
        lock.withLock {
          blockedEntries += 1
          waiters.append(continuation)
        }
      }
    }
    return .init(
      url: request.url,
      statusCode: 200,
      contentType: "image/x-icon",
      body: Data([0x00, 0x00, 0x01, 0x00, 0x01])
    )
  }

  func releaseAll() {
    let values = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      defer { waiters.removeAll() }
      return waiters
    }
    values.forEach { $0.resume() }
  }
}

private enum AutomaticTagOutcome: Sendable { case success(String), failure }

private final class AutomaticTagMetadataProvider: ModelProvider, SummaryTagGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private let tagOutcome: AutomaticTagOutcome
  private var tagRequests = 0

  init(tagOutcome: AutomaticTagOutcome) { self.tagOutcome = tagOutcome }

  func stream(profile _: ProviderProfile, apiKey _: String, intent _: RunIntent) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.delta("已完成的总结"))
      continuation.yield(.completed)
      continuation.finish()
    }
  }

  func generateSummaryTags(profile _: ProviderProfile, apiKey _: String, summary: String) async throws -> String {
    XCTAssertEqual(summary, "已完成的总结")
    let outcome = lock.withLock { () -> AutomaticTagOutcome in
      tagRequests += 1
      return tagOutcome
    }
    switch outcome {
    case let .success(value): return value
    case .failure: throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    }
  }

  func cancelActiveStreams() {}
  var tagRequestCount: Int { lock.withLock { tagRequests } }
}

private actor MetadataEventCounter {
  private var values: [TaskID] = []
  func record(_ taskID: TaskID) { values.append(taskID) }
  var taskIDs: [TaskID] { values }
}

private actor MetadataRunRecorder {
  private var latest: RunState?
  func record(runID _: RunID, state: RunState) { latest = state }
  var last: RunState? { latest }
}

private actor MetadataProfileStore: ProviderProfileStore {
  let profile: ProviderProfile
  init(profile: ProviderProfile) { self.profile = profile }
  func load() async throws -> ProviderProfile? { profile }
  func save(_: ProviderProfile) async throws {}
  func delete() async throws {}
}

private actor MetadataSecretStore: SecretStore {
  func save(_: String, for _: SecretReference) async throws {}
  func read(_: SecretReference) async throws -> String? { "fixture-secret" }
  func contains(_: SecretReference) async throws -> Bool { true }
  func delete(_: SecretReference) async throws {}
}

private func metadataOrchestrator(
  provider: AutomaticTagMetadataProvider,
  history: HistoryApplicationService,
  onMetadataChanged: @escaping ModelRunOrchestrator.HistoryMetadataChangedHandler
) throws -> ModelRunOrchestrator {
  let profile = try ProviderProfile(baseURL: "https://example.test/v1", model: "fixture-model", secretReference: .init(rawValue: "fixture-reference"))
  return ModelRunOrchestrator(
    configurationService: .init(profileStore: MetadataProfileStore(profile: profile), secretStore: MetadataSecretStore()),
    provider: provider,
    history: history,
    onHistoryMetadataChanged: onMetadataChanged
  )
}

@MainActor
private func withAutomaticTagHistory(
  _ body: (GRDBHistoryRepository, AcceptCaptureResult, CapturedDocument) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-history-metadata.\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
  defer { try? repository.database.close() }
  let document = CapturedDocument(
    createdAt: "2026-07-18T00:00:00Z",
    origin: .manualLink,
    url: "https://example.test/history-metadata",
    title: "自动标签",
    platform: "test",
    method: "fixture",
    text: "供总结的原文",
    completeness: "complete",
    capturedAt: "2026-07-18T00:00:00Z",
    sourceLabel: "fixture"
  )
  let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
  try await body(repository, accepted, document)
}

private final class HistoryScreenRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let firstPage: HistoryPage, remainingPages: [String: HistoryPage], details: [TaskID: HistoryDetailProjection]
  private let blocker: DetailBlocker?, pageBlocker: PageBlocker?, exportBlocker: ExportBlocker?, deleteFailure: RepositoryFailure?, exportFailure: RepositoryFailure?
  private let batchDeleteFailures: Set<TaskID>
  private let mediaAssetValue: MediaAsset?, mediaReferenceFailure: RepositoryFailure?
  private let lock = NSLock(); private var deletes: [TaskID] = []
  init(firstPage: HistoryPage, remainingPages: [String: HistoryPage] = [:], details: [TaskID: HistoryDetailProjection], blocker: DetailBlocker? = nil, pageBlocker: PageBlocker? = nil, exportBlocker: ExportBlocker? = nil, deleteFailure: RepositoryFailure? = nil, exportFailure: RepositoryFailure? = nil, mediaAssetValue: MediaAsset? = nil, mediaReferenceFailure: RepositoryFailure? = nil, batchDeleteFailures: Set<TaskID> = []) { self.firstPage = firstPage; self.remainingPages = remainingPages; self.details = details; self.blocker = blocker; self.pageBlocker = pageBlocker; self.exportBlocker = exportBlocker; self.deleteFailure = deleteFailure; self.exportFailure = exportFailure; self.mediaAssetValue = mediaAssetValue; self.mediaReferenceFailure = mediaReferenceFailure; self.batchDeleteFailures = batchDeleteFailures }
  var deletedTaskIDs: [TaskID] { lock.withLock { deletes } }
  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws { throw RepositoryFailure.invalidInput }
  func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw RepositoryFailure.invalidInput }
  func finishRun(_: FinishRunCommand) throws { throw RepositoryFailure.invalidInput }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit _: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage { guard let cursor else { return firstPage }; pageBlocker?.block(); return remainingPages[cursor.taskID.rawValue] ?? .init(rows: [], nextCursor: nil) }
  func detail(taskID: TaskID) throws -> HistoryDetailProjection { if blocker?.taskID == taskID { blocker?.block() }; guard let detail = details[taskID] else { throw RepositoryFailure.notFound }; return detail }
  func exportProjection(taskID: TaskID) throws -> HistoryExportProjection {
    if exportBlocker?.taskID == taskID { exportBlocker?.block() }
    if let exportFailure { throw exportFailure }
    guard let detail = details[taskID] else { throw RepositoryFailure.notFound }
    return .init(task: detail.task, snapshots: detail.snapshots, runs: detail.runs)
  }
  func deleteTask(taskID: TaskID) throws { if let deleteFailure { throw deleteFailure }; lock.withLock { deletes.append(taskID) } }
  func deleteTasks(taskIDs: Set<TaskID>) throws -> BatchDeleteResult {
    if let deleteFailure { throw deleteFailure }
    let requested = taskIDs.sorted { $0.rawValue < $1.rawValue }
    let failed = requested.filter { batchDeleteFailures.contains($0) }
    let deleted = requested.filter { !batchDeleteFailures.contains($0) }
    lock.withLock { deletes.append(contentsOf: deleted) }
    return .init(requestedTaskIDs: requested, deletedTaskIDs: deleted, failedTaskIDs: failed)
  }
  func mediaAsset(taskID _: TaskID) throws -> MediaAsset? { mediaAssetValue }
  func isMediaContentReferenced(contentSHA256 _: String) throws -> Bool {
    if let mediaReferenceFailure { throw mediaReferenceFailure }
    return false
  }
}

private final class TagHistoryScreenRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .writable
  private let lock = NSLock()
  private let rows: [HistoryRowProjection]
  private let details: [TaskID: HistoryDetailProjection]
  private var taskTags: [TaskID: [HistoryTag]]
  private var recordedFilters: [HistoryListFilter] = []
  private var detailReadPlans: [TaskID: [DetailReadPlan]] = [:]

  init(rows: [HistoryRowProjection], details: [TaskID: HistoryDetailProjection], tags: [TaskID: [HistoryTag]]) {
    self.rows = rows; self.details = details; taskTags = tags
  }

  var filters: [HistoryListFilter] { lock.withLock { recordedFilters } }
  func enqueueDetailBarrier(_ barrier: DetailReadBarrier, for taskID: TaskID) {
    lock.withLock { detailReadPlans[taskID, default: []].append(.barrier(barrier)) }
  }
  func enqueueDetailFailure(_ failure: RepositoryFailure, for taskID: TaskID) {
    lock.withLock { detailReadPlans[taskID, default: []].append(.failure(failure)) }
  }
  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws { throw RepositoryFailure.invalidInput }
  func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw RepositoryFailure.invalidInput }
  func finishRun(_: FinishRunCommand) throws { throw RepositoryFailure.invalidInput }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func historyPage(limit: Int, after _: HistoryPageCursor?) throws -> HistoryPage { try historyPage(limit: limit, after: nil, filter: .none) }
  func historyPage(limit: Int, after _: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    lock.withLock { recordedFilters.append(filter) }
    let filtered = lock.withLock { () -> [HistoryRowProjection] in
      rows.filter { row in
        let names = Set((taskTags[row.taskID] ?? []).map(\.normalizedName))
        let query = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchesSearch = query.isEmpty
          || (row.title ?? "").lowercased().contains(query)
          || row.canonicalURL.lowercased().contains(query)
        return Set(filter.tagNormalizedNames).isSubset(of: names) && matchesSearch
      }
    }
    return .init(rows: Array(filtered.prefix(limit)), nextCursor: nil)
  }
  func detail(taskID: TaskID) throws -> HistoryDetailProjection {
    guard let value = details[taskID] else { throw RepositoryFailure.notFound }
    // Take the snapshot before blocking so a delayed ordinary detail read can
    // deterministically model a stale database response.
    let (tags, plan) = lock.withLock { () -> ([HistoryTag], DetailReadPlan?) in
      let plan = detailReadPlans[taskID]?.isEmpty == false ? detailReadPlans[taskID]?.removeFirst() : nil
      return (taskTags[taskID] ?? [], plan)
    }
    if case let .failure(failure) = plan { throw failure }
    if case let .barrier(barrier) = plan {
      barrier.block()
    }
    return .init(task: value.task, snapshots: value.snapshots, runs: value.runs, tags: tags)
  }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.notFound }
  func allTags() throws -> [HistoryTag] {
    lock.withLock {
      var seen = Set<String>()
      return taskTags.values.flatMap { $0 }
        .filter { seen.insert($0.normalizedName).inserted }
        .sorted { $0.normalizedName < $1.normalizedName }
    }
  }
  func addTags(_ rawNames: [String], to taskID: TaskID) throws -> [HistoryTag] {
    lock.withLock {
      var values = taskTags[taskID] ?? []
      for tag in HistoryTagNormalizer.normalizedTags(rawNames) where !values.contains(where: { $0.normalizedName == tag.normalizedName }) {
        guard values.count < HistoryTagNormalizer.maximumTagsPerTask else { break }
        values.append(tag)
      }
      taskTags[taskID] = values
      return values
    }
  }
  func removeTag(normalizedName: String, from taskID: TaskID) throws {
    lock.withLock { taskTags[taskID]?.removeAll { $0.normalizedName == normalizedName } }
  }
  func deleteTask(taskID _: TaskID) throws {}
}

private enum DetailReadPlan { case barrier(DetailReadBarrier), failure(RepositoryFailure) }
private final class BlockingRendezvous: @unchecked Sendable {
  private let condition = NSCondition()
  private var didEnter = false
  private var didRelease = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []

  func block() {
    condition.lock()
    didEnter = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    condition.unlock()
    waiters.forEach { $0.resume() }

    condition.lock()
    while !didRelease { condition.wait() }
    condition.unlock()
  }

  func waitUntilEntered() async {
    await withCheckedContinuation { continuation in
      condition.lock()
      if didEnter {
        condition.unlock()
        continuation.resume()
      } else {
        entryWaiters.append(continuation)
        condition.unlock()
      }
    }
  }

  func release() {
    condition.lock()
    didRelease = true
    condition.broadcast()
    condition.unlock()
  }
}
private final class DetailBlocker: @unchecked Sendable { let taskID: TaskID; private let rendezvous = BlockingRendezvous(); init(taskID: TaskID) { self.taskID = taskID }; func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private final class DetailReadBarrier: @unchecked Sendable { private let rendezvous = BlockingRendezvous(); func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private final class TerminalCommitBarrier: @unchecked Sendable { private let rendezvous = BlockingRendezvous(); func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private final class BeginReturnBarrier: @unchecked Sendable { private let rendezvous = BlockingRendezvous(); func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private final class PageBlocker: @unchecked Sendable { private let rendezvous = BlockingRendezvous(); func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private final class ExportBlocker: @unchecked Sendable { let taskID: TaskID; private let rendezvous = BlockingRendezvous(); init(taskID: TaskID) { self.taskID = taskID }; func block() { rendezvous.block() }; func waitUntilEntered() async { await rendezvous.waitUntilEntered() }; func release() { rendezvous.release() } }
private actor MediaDownloadGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func perform(returning asset: MediaAsset) async -> MediaAsset {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      if released {
        continuation.resume()
      } else {
        releaseContinuation = continuation
      }
    }
    return asset
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    released = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
private func faviconRow(host: String, updatedAt: Int64) -> HistoryRowProjection {
  .init(
    taskID: TaskID(), title: host, canonicalURL: "https://\(host)/article", host: host,
    sourceLabel: "网页", latestRunKind: nil, latestRunStatus: nil, latestModel: nil,
    updatedAtMilliseconds: updatedAt, latestRunAtMilliseconds: nil, usageCost: .unknown, artifactPreview: nil
  )
}
private func makeRow(title: String, updatedAt: Int64) -> HistoryRowProjection { .init(taskID: TaskID(), title: title, canonicalURL: "https://example.test/\(updatedAt)", host: "example.test", sourceLabel: "网页", latestRunKind: .summarize, latestRunStatus: .completed, latestModel: "fixture-model", updatedAtMilliseconds: updatedAt, latestRunAtMilliseconds: updatedAt, usageCost: .unknown, artifactPreview: "fixture") }
private func capturedDocument(title: String, url: String) -> CapturedDocument {
  .init(
    createdAt: "2026-07-21T00:00:00Z",
    origin: .manualLink,
    url: url,
    title: title,
    platform: "fixture",
    method: "fixture",
    text: "正文",
    completeness: "complete",
    capturedAt: "2026-07-21T00:00:00Z",
    sourceLabel: "fixture"
  )
}
private func cursor(for row: HistoryRowProjection) -> HistoryPageCursor { .init(updatedAtMilliseconds: row.updatedAtMilliseconds, taskID: row.taskID) }
private func makeDetail(for row: HistoryRowProjection) -> HistoryDetailProjection { let snapshot = ContentSnapshot(id: ContentSnapshotID(), taskID: row.taskID, sequence: 1, envelopeCreatedAtMilliseconds: 1, capturedAtMilliseconds: 1, sourceKind: "web", sourceURL: row.canonicalURL, title: row.title, platform: "fixture", captureMethod: "page", completeness: "complete", bodyText: "fixture body", characterCount: 12, bodySHA256: String(repeating: "a", count: 64), sourceLabel: "网页", usedCookie: false); return .init(task: .init(id: row.taskID, canonicalURL: row.canonicalURL, canonicalizationVersion: 1, createdAtMilliseconds: 1, updatedAtMilliseconds: row.updatedAtMilliseconds), snapshots: [snapshot], runs: []) }
private func tag(_ value: String) -> HistoryTag { HistoryTag(rawValue: value)! }
