import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 独立复核补充（2026-11-11）：A 明说没测的几条——
/// 入队去重、批量回调的触发范围、`automatic:` 下模型未下载直接失败、用户停止后日志清空。
/// 资料库与媒体都在临时目录，转写器是替身，不碰真实数据、不调网络。
@MainActor
final class AutoTranscriptionSupplementTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var repository: GRDBHistoryRepository!
  private var store: LocalMediaStore!
  private var defaultsSuite: String!

  override func setUp() async throws {
    try await super.setUp()
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("auto-transcription-supplement-\(UUID().uuidString)", isDirectory: true)
    root = base.appendingPathComponent("AppSupport", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    store = LocalMediaStore(applicationSupportRoot: root)
    defaultsSuite = "auto-transcription-supplement-\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: base)
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    try await super.tearDown()
  }

  // MARK: - 日志本身

  func testRegisteringAgainDoesNotResetAttempts() throws {
    let id = TaskID()
    let first = AutoTranscriptionJournal(applicationSupportRoot: root)
    first.register(id)
    first.noteAttempt(id)

    // 重新读文件再登记（等价于启动时 resume 又登记了一次）：次数不能被清零。
    let second = AutoTranscriptionJournal(applicationSupportRoot: root)
    second.register(id)
    XCTAssertEqual(second.resumableTaskIDs(), [id], "登记不应重置已记下的尝试次数")
    second.noteAttempt(id)

    let third = AutoTranscriptionJournal(applicationSupportRoot: root)
    XCTAssertFalse(third.resumableTaskIDs().contains(id), "重新登记后仍受两次上限约束")
  }

  func testCorruptJournalIsIgnoredInsteadOfBlockingStartup() throws {
    let url = root.appendingPathComponent(AutoTranscriptionJournal.fileName)
    try Data("不是 JSON {{{".utf8).write(to: url)

    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    XCTAssertEqual(journal.pendingCount, 0, "坏文件当作空队列，不能让启动挂掉")

    let id = TaskID()
    journal.register(id)
    XCTAssertEqual(AutoTranscriptionJournal(applicationSupportRoot: root).resumableTaskIDs(), [id], "坏文件之后还能正常写")
  }

  // MARK: - 入队去重

  func testAutomaticEnqueueDedupesWithResumeAndRepeatedCalls() throws {
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let controller = makeController()
    controller.autoTranscriptionJournal = journal
    let id = TaskID()
    journal.register(id)

    controller.resumeAutomaticTranscriptions()
    XCTAssertEqual(controller.transcriptionQueue?.total, 1, "启动恢复只排一次")
    XCTAssertEqual(journal.pendingCount, 1)

    controller.enqueueAutomaticTranscription(taskID: id, name: "重复")
    XCTAssertEqual(controller.transcriptionQueue?.total, 1, "已在排的不再重复入队")
    controller.enqueueAutomaticTranscription(taskID: id, name: "再来一次")
    XCTAssertEqual(controller.transcriptionQueue?.total, 1)
    XCTAssertEqual(journal.pendingCount, 1)
  }

  // MARK: - automatic: 遇到要下载模型

  func testAutomaticTranscriptionFailsFastWhenModelNeedsDownload() async throws {
    let id = try makeTaskWithPlayableMedia()
    let transcriber = CountingTranscriber(modelState: .requiresDownload)
    let model = HistoryViewModel(mediaStore: store, videoTranscriber: transcriber)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)

    let outcome = await model.transcribeImportedMedia(taskID: id, automatic: true)

    XCTAssertEqual(outcome, .failed(HistoryViewModel.automaticModelDownloadNeededMessage))
    XCTAssertEqual(transcriber.downloadCallCount, 0, "自动转写不能替用户开始下载模型")
    XCTAssertEqual(transcriber.transcribeCallCount, 0)
    XCTAssertEqual(model.isTranscriptionModelConfirmationPresented, false, "确认框要收起来，后台不能干等")
    XCTAssertNotEqual(try repository.mediaAsset(taskID: id)?.transcriptionStatus, .completed)
    XCTAssertNil(try repository.detail(taskID: id).snapshots.last.flatMap { snapshot in
      snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue ? snapshot : nil
    })
  }

  func testManualTranscriptionStillShowsTheDownloadPrompt() async throws {
    // 同一个替身、不传 automatic：应当停在「等确认下载」，而不是直接判失败。
    let id = try makeTaskWithPlayableMedia()
    let transcriber = CountingTranscriber(modelState: .requiresDownload)
    let model = HistoryViewModel(mediaStore: store, videoTranscriber: transcriber)
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)

    let running = Task { await model.transcribeImportedMedia(taskID: id) }
    await waitUntil { model.transcriptionState == .awaitingModelDownload }
    XCTAssertTrue(model.isTranscriptionModelConfirmationPresented)
    XCTAssertEqual(transcriber.downloadCallCount, 0, "没点确认之前也不能下载")
    model.cancelModelDownloadConfirmation()
    _ = await running.value
  }

  // MARK: - 用户停止后日志清空

  func testUserStopClearsJournalAndDoesNotResumeNextLaunch() async throws {
    let id = try makeTaskWithPlayableMedia()
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let transcriber = CountingTranscriber(modelState: .ready, mode: .suspend)
    let (controller, _) = try makeWiredController(transcriber: transcriber)
    controller.autoTranscriptionJournal = journal

    controller.enqueueAutomaticTranscription(taskID: id, name: "排着的视频")
    await waitUntil { controller.transcriptionQueue?.isRunning == true }
    XCTAssertEqual(journal.pendingCount, 1)

    controller.stopTranscriptionQueue()
    await waitUntil { controller.transcriptionQueue?.wasStopped == true }

    XCTAssertEqual(journal.pendingCount, 0, "用户停止＝放弃，日志里不能再留")
    XCTAssertEqual(AutoTranscriptionJournal(applicationSupportRoot: root).pendingCount, 0, "下次启动也不会再自动转")
    XCTAssertEqual(controller.transcriptionQueue?.isRunning, false)
  }

  // MARK: - 批量回调的触发范围

  func testBatchVideoCallbackFiresForMCPLinksButNotForSingleSave() async throws {
    let manual = try makeManualWithMediaWiring().manual
    var fired: [TaskID] = []
    manual.onBatchVideoDownloaded = { fired.append($0) }

    let mcpURL = "https://example.test/videos/21"
    let results = try manual.enqueueMCPLinks([mcpURL], downloadsVideo: true)
    XCTAssertEqual(results.first?["status"], "queued")
    await waitUntil(timeout: .seconds(8)) { fired.count == 1 }
    XCTAssertEqual(fired.count, 1, "MCP 加入并下载了视频的条目要交一次给自动转写")
    let mcpTaskID = try XCTUnwrap(fired.first)
    XCTAssertNotNil(try repository.detail(taskID: mcpTaskID).media, "回调时视频必须已经挂上")

    // 同一个模型、同一个替身：界面上普通保存不归自动转写管，回调不能再响一次。
    let manualURL = "https://example.test/videos/22"
    manual.input = manualURL
    manual.submit()
    await waitUntil(timeout: .seconds(8)) {
      manual.pendingCaptures.isEmpty || manual.pendingCaptures.contains { if case .failed = $0.phase { true } else { false } }
    }
    XCTAssertTrue(manual.pendingCaptures.isEmpty, "界面保存不该停在失败：\(manual.pendingCaptures)")
    let canonical = try CanonicalURL(manualURL)
    var savedID: TaskID?
    let clock = ContinuousClock(), deadline = clock.now + .seconds(8)
    while savedID == nil, clock.now < deadline {
      savedID = try repository.taskID(forCanonicalURL: canonical)
      if let id = savedID, try repository.detail(taskID: id).media == nil {
        savedID = nil
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    XCTAssertNotNil(savedID, "界面保存应当照常入库并挂上视频")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(fired.count, 1, "单条手动保存不该触发批量自动转写回调")
  }

  // MARK: - 自动转写不带起付费校对

  func testAutomaticTranscriptionNeverTriggersPaidTidyButManualStillDoes() async throws {
    let automaticID = try makeTaskWithPlayableMedia(tag: "-auto")
    let manualID = try makeTaskWithPlayableMedia(tag: "-manual")
    let tidier = CountingTidier()
    let model = HistoryViewModel(
      mediaStore: store,
      videoTranscriber: CountingTranscriber(modelState: .ready),
      transcriptTidier: tidier
    )
    model.configure(history: .init(repository: repository), isReadOnly: false, unavailableCode: nil)

    // 自动队列转完：界面层照常调「转写完成后接着校对」，模型层必须拦住，校对模型 0 次。
    let autoOutcome = await model.transcribeImportedMedia(taskID: automaticID, automatic: true)
    XCTAssertEqual(autoOutcome, .completed)
    model.continueWithTidyAfterTranscription(taskID: automaticID, autoTidyEnabled: true, model: nil)
    try await Task.sleep(for: .milliseconds(400))
    let afterAutomatic = await tidier.callCount
    XCTAssertEqual(afterAutomatic, 0, "批量/自动转写完成后不能调用付费校对模型")

    // 普通（非 automatic）转写完成：设置开着自动校对，行为和以前一样，会校对一次。
    let manualOutcome = await model.transcribeImportedMedia(taskID: manualID)
    XCTAssertEqual(manualOutcome, .completed)
    model.continueWithTidyAfterTranscription(taskID: manualID, autoTidyEnabled: true, model: nil)
    await waitUntil { await tidier.callCount == 1 }
  }

  // MARK: - 关掉自动转写立刻生效

  func testSwitchOffBlocksEnqueueAndClearsJournalOnResume() throws {
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let controller = makeController()
    controller.autoTranscriptionJournal = journal
    controller.isAutomaticTranscriptionEnabled = { false }

    controller.enqueueAutomaticTranscription(taskID: TaskID(), name: "关着开关时进来的")
    XCTAssertNil(controller.transcriptionQueue, "开关关着不排队")
    XCTAssertEqual(journal.pendingCount, 0)

    let leftover = TaskID()
    journal.register(leftover)
    controller.resumeAutomaticTranscriptions()
    XCTAssertNil(controller.transcriptionQueue, "开关关着，启动恢复也不再转")
    XCTAssertEqual(journal.pendingCount, 0, "日志要清空")
    XCTAssertEqual(AutoTranscriptionJournal(applicationSupportRoot: root).pendingCount, 0)
  }

  func testSwitchOffBeforeWorkerTakesTheItemSkipsIt() async throws {
    let id = try makeTaskWithPlayableMedia()
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let transcriber = CountingTranscriber(modelState: .ready)
    let (controller, historyModel) = try makeWiredController(transcriber: transcriber)
    controller.autoTranscriptionJournal = journal
    defer { withExtendedLifetime(historyModel) {} }
    var enabled = true
    controller.isAutomaticTranscriptionEnabled = { enabled }

    controller.enqueueAutomaticTranscription(taskID: id, name: "刚排上的视频")
    enabled = false  // worker 还没取条目就被关掉
    await waitUntil { controller.transcriptionQueue == nil || controller.transcriptionQueue?.isRunning == false }

    XCTAssertEqual(transcriber.transcribeCallCount, 0, "worker 每轮取条目前要再看开关")
    XCTAssertEqual(journal.pendingCount, 0)
    XCTAssertNil(controller.transcriptionQueue, "一条都没转，不留「完成 0/0」")
  }

  func testTurningSwitchOffDropsQueuedAutomaticItemsButKeepsManualOnes() async throws {
    let runningID = try makeTaskWithPlayableMedia(tag: "-1")
    let queuedAutoID = try makeTaskWithPlayableMedia(tag: "-2")
    let manualID = try makeTaskWithPlayableMedia(tag: "-3")
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let transcriber = CountingTranscriber(modelState: .ready, mode: .suspend)
    let (controller, historyModel) = try makeWiredController(transcriber: transcriber)
    controller.autoTranscriptionJournal = journal
    defer { withExtendedLifetime(historyModel) {} }
    var enabled = true
    controller.isAutomaticTranscriptionEnabled = { enabled }

    controller.enqueueAutomaticTranscription(taskID: runningID, name: "正在转的")
    await waitUntil { transcriber.transcribeCallCount == 1 }
    controller.enqueueAutomaticTranscription(taskID: queuedAutoID, name: "排着的自动项")
    controller.transcribeBacklog([(manualID, "用户点的全部转写")])
    XCTAssertEqual(controller.transcriptionQueue?.total, 3)
    XCTAssertEqual(journal.pendingCount, 2)

    enabled = false
    controller.automaticTranscriptionTurnedOff()

    XCTAssertEqual(journal.pendingCount, 0, "排着的自动项连同日志一起清掉")
    XCTAssertEqual(controller.transcriptionQueue?.total, 2, "只剩正在转的那条和用户手动排的那条")
    controller.stopTranscriptionQueue()
    await waitUntil { controller.transcriptionQueue?.wasStopped == true }
    XCTAssertEqual(transcriber.transcribeCallCount, 1, "被清掉的自动项从没开始转")
  }

  // MARK: - 被打断不算确定失败

  func testInterruptedAutomaticItemStaysInJournalWithoutCountingAsFailure() async throws {
    let id = try makeTaskWithPlayableMedia()
    let otherID = try makeTaskWithPlayableMedia(tag: "-other")
    let journal = AutoTranscriptionJournal(applicationSupportRoot: root)
    let transcriber = CountingTranscriber(modelState: .ready, mode: .suspend)
    let (controller, historyModel) = try makeWiredController(transcriber: transcriber)
    controller.autoTranscriptionJournal = journal

    controller.enqueueAutomaticTranscription(taskID: id, name: "会被打断的")
    await waitUntil { transcriber.transcribeCallCount == 1 }
    // 用户在阅读页对另一条手动转写，顶掉了队列里这一条。
    historyModel.selectedTaskID = otherID
    await waitUntil { historyModel.detail?.task.id == otherID && historyModel.canTranscribeVideo == false || historyModel.detail?.task.id == otherID }
    historyModel.requestTranscription()
    await waitUntil { controller.transcriptionQueue?.finished == 1 }

    XCTAssertEqual(controller.transcriptionQueue?.failures.isEmpty, true, "被打断不当作失败展示")
    XCTAssertEqual(journal.pendingCount, 1, "留在日志里，下次启动再试")
    let fresh = AutoTranscriptionJournal(applicationSupportRoot: root)
    XCTAssertEqual(fresh.resumableTaskIDs(), [id])
    fresh.noteAttempt(id)
    fresh.noteAttempt(id)
    XCTAssertTrue(AutoTranscriptionJournal(applicationSupportRoot: root).resumableTaskIDs().isEmpty, "到 2 次上限就不再自动试")
    controller.stopTranscriptionQueue()
    historyModel.cancelTranscription()
  }

  // MARK: - 搭场景

  private func makeController() -> LocalImportController {
    LocalImportController(
      mediaStore: store,
      imageCache: nil,
      voiceMemos: VoiceMemosLibrary(recordingsDirectory: base.appendingPathComponent("no-voice-memos")),
      appleNotes: AppleNotesLibrary()
    )
  }

  private func makeWiredController(transcriber: any LocalVideoTranscribing) throws -> (LocalImportController, HistoryViewModel) {
    let history = HistoryApplicationService(repository: repository)
    let historyModel = HistoryViewModel(mediaStore: store, videoTranscriber: transcriber)
    historyModel.configure(history: history, isReadOnly: false, unavailableCode: nil)
    let manual = ManualLinkViewModel(
      captureService: .init(fetcher: SupplementOfflineFetcher()),
      clipboard: SupplementClipboard(),
      userDefaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    )
    manual.configure(
      history: history,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1_759_100_000_000 },
      captureSink: { _ in }
    )
    let controller = makeController()
    controller.configure(history: history, manualLink: manual, historyModel: historyModel)
    return (controller, historyModel)
  }

  private func makeTaskWithPlayableMedia(tag: String = "") throws -> TaskID {
    let original = base.appendingPathComponent("用户的视频\(tag).mp4")
    let bytes = Data("fake-mp4-bytes\(tag)".utf8)
    try bytes.write(to: original)
    let sha = try LocalFileImportReader.contentSHA256(of: original)
    let document = try LocalImportDocument.file(
      contentSHA256: sha, fileName: "用户的视频\(tag).mp4",
      text: LocalImportDocument.mediaPlaceholder(fileName: "用户的视频\(tag).mp4", durationSeconds: 30, hasVideo: true),
      completeness: "partial", method: "local_file_video", fileDate: nil
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    let asset = try store.externalReferenceAsset(
      fileURL: original, taskID: accepted.taskID, snapshotID: accepted.snapshotID,
      contentSHA256: sha, byteSize: Int64(bytes.count), durationSeconds: 30,
      platform: LocalImportSource.files.rawValue, createdAtMilliseconds: 2
    )
    try repository.attachMedia(.init(asset: asset))
    return accepted.taskID
  }

  private func makeManualWithMediaWiring() throws -> (manual: ManualLinkViewModel, historyModel: HistoryViewModel) {
    let history = HistoryApplicationService(repository: repository)
    let mediaStore = try XCTUnwrap(store)
    let historyModel = HistoryViewModel(
      mediaStore: mediaStore,
      mediaDownloadOperation: { _, taskID, snapshotID, _ in
        let stored = try mediaStore.storeDetailed(data: Data("fake-mp4-bytes".utf8), preferredExtension: "mp4")
        return MediaAsset(
          taskID: taskID,
          snapshotID: snapshotID,
          relativePath: stored.relativePath,
          fileBookmark: stored.fileBookmark,
          contentSHA256: stored.sha256,
          byteSize: 14,
          platform: "douyin",
          createdAtMilliseconds: 1
        )
      }
    )
    historyModel.configure(history: history, isReadOnly: false, unavailableCode: nil)
    let manual = ManualLinkViewModel(
      captureService: .init(fetcher: SupplementOfflineFetcher(), sourceAdapters: [SupplementMediaAdapter()]),
      clipboard: SupplementClipboard(),
      onMediaCaptured: { media, taskID, snapshotID, pageURL in
        _ = await historyModel.ingestCapturedMedia(media, taskID: taskID, snapshotID: snapshotID, pageURL: pageURL)
      },
      userDefaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    )
    manual.configure(
      history: history,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1_759_100_000_000 },
      captureSink: { _ in }
    )
    return (manual, historyModel)
  }

  private func waitUntil(
    timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping () async -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !(await condition()), clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    let ok = await condition()
    XCTAssertTrue(ok, file: file, line: line)
  }

  private func waitUntil(
    timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

/// 转写替身：数清下载模型与真正转写各被调用几次。
private final class CountingTranscriber: LocalVideoTranscribing, @unchecked Sendable {
  enum Mode { case succeed, suspend }

  private let lock = NSLock()
  private let state: LocalSpeechModelState
  private let mode: Mode
  private var downloads = 0
  private var transcriptions = 0

  init(modelState: LocalSpeechModelState, mode: Mode = .succeed) {
    state = modelState
    self.mode = mode
  }

  var downloadCallCount: Int { lock.withLock { downloads } }
  var transcribeCallCount: Int { lock.withLock { transcriptions } }

  func modelState(localeIdentifier _: String) async -> LocalSpeechModelState { state }

  func downloadModel(localeIdentifier _: String) async throws {
    lock.withLock { downloads += 1 }
  }

  func transcribe(fileURL _: URL, workspaceURL _: URL, localeIdentifier _: String) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    lock.withLock { transcriptions += 1 }
    let mode = mode
    return AsyncThrowingStream { continuation in
      switch mode {
      case .succeed:
        continuation.yield(.extractingAudio)
        continuation.yield(.final("本机转写出来的文字"))
        continuation.finish()
      case .suspend:
        let worker = Task {
          continuation.yield(.extractingAudio)
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

private actor CountingTidier: TranscriptTidying {
  private(set) var callCount = 0

  func tidy(
    text: String,
    model _: String?,
    style _: TidyStyle,
    context _: TranscriptTidyContext,
    progress _: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    callCount += 1
    return TranscriptTidyOutcome(text: text, promptTokens: 1, completionTokens: 1, totalTokens: 2)
  }
}

/// 不联网的网页读取器：这些用例只走抖音渲染分支，fetcher 不该被调用。
private struct SupplementOfflineFetcher: WebPageFetcher {
  func fetch(url _: URL) async throws -> WebPageFetchResult {
    throw ManualLinkError.network
  }
}

private struct SupplementClipboard: ClipboardReading {
  func string() -> String? { nil }
}

/// 带视频的作品：走抖音分支，正文与 media 都由替身给出。
/// 带视频的作品：来源适配器直接给出正文与 media，免去网页与评论读取。
/// 用 example.test 而不是抖音，是因为抖音地址会自动去读评论区，测试里不该联网。
private struct SupplementMediaAdapter: SourceAdapting {
  func takesOwnership(of url: URL) -> Bool { url.host == "example.test" }
  func capture(url: URL) async throws -> CapturedDocument {
    CapturedDocument(
      createdAt: "2026-11-11T00:00:00Z",
      origin: .manualLink,
      url: url.absoluteString,
      title: "批量保存的视频",
      platform: "web",
      method: "fixture_adapter",
      text: "# 批量保存的视频\n\n这是替身给出的正文，够长以便通过提取检查。",
      completeness: "best_effort",
      capturedAt: "2026-11-11T00:00:00Z",
      sourceLabel: "fixture",
      media: .init(platform: "web", videoURL: "https://media.example.test/video.mp4")
    )
  }
}
