import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

/// 导入控制器端到端：文件夹展开 → 确认 → 逐个落库（音视频只引用原文件）→ 下载来源判外部 →
/// 「合集」挂钩按自然排序回调 → 导入后本机转写排队。资料库、偏好、原文件都在临时位置，
/// 转写器是替身，不读用户的真实资料、不调任何在线服务。
@MainActor
final class LocalImportControllerFolderTests: XCTestCase {
  private var base: URL!
  private var repository: GRDBHistoryRepository!
  private var store: LocalMediaStore!
  private var defaultsSuite: String!

  override func setUp() async throws {
    try await super.setUp()
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-import-controller-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("AppSupport", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    store = LocalMediaStore(applicationSupportRoot: root)
    defaultsSuite = "local-import-controller-tests-\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: base)
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    try await super.tearDown()
  }

  private struct Wiring {
    let controller: LocalImportController
    let historyModel: HistoryViewModel
    let manual: ManualLinkViewModel
  }

  private func wire(transcriber: WorkspaceRecordingTranscriber? = nil) throws -> Wiring {
    let history = HistoryApplicationService(repository: repository)
    let historyModel = HistoryViewModel(mediaStore: store, videoTranscriber: transcriber)
    historyModel.configure(history: history, isReadOnly: false, unavailableCode: nil)
    let manual = ManualLinkViewModel(
      captureService: .init(fetcher: OfflineFetcher()),
      userDefaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    )
    manual.configure(
      history: history,
      storageWriteGate: StorageWriteGate(initialAvailability: .writable),
      nowMilliseconds: { 1_759_100_000_000 },
      captureSink: { _ in }
    )
    let controller = LocalImportController(
      mediaStore: store,
      imageCache: nil,
      voiceMemos: VoiceMemosLibrary(recordingsDirectory: base.appendingPathComponent("no-voice-memos")),
      appleNotes: AppleNotesLibrary()
    )
    controller.configure(history: history, manualLink: manual, historyModel: historyModel)
    return Wiring(controller: controller, historyModel: historyModel, manual: manual)
  }

  private func write(_ relative: String, _ text: String) throws -> URL {
    let url = base.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func quarantine(_ url: URL, agent: String) throws {
    let value = Data("0083;66f8a1b2;\(agent);9D5A1F3C-0000-4000-8000-000000000000".utf8)
    let result = url.withUnsafeFileSystemRepresentation { path in
      value.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, value.count, 0, 0) }
    }
    guard result == 0 else { throw XCTSkip("这个卷不支持扩展属性") }
  }

  private func waitUntil(
    timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  private func finishedSummary(_ controller: LocalImportController) -> LocalImportController.Summary? {
    if case let .finished(_, summary, _) = controller.phase { return summary }
    return nil
  }

  private func confirmingPlan(_ controller: LocalImportController) -> LocalImportController.ImportPlan? {
    if case let .confirming(plan) = controller.phase { return plan }
    return nil
  }

  private func title(_ taskID: TaskID) throws -> String? {
    try repository.detail(taskID: taskID).snapshots.first?.title
  }

  func testFolderImportConfirmsThenImportsInNaturalOrderAndJudgesDownloadsExternal() async throws {
    let wiring = try wire()
    let controller = wiring.controller
    let folder = base.appendingPathComponent("课程", isDirectory: true)
    _ = try write("课程/10 结尾.txt", "第十节的讲义")
    _ = try write("课程/2 中间.txt", "第二节的讲义")
    _ = try write("课程/01 开头.md", "# 开头\n\n第一节")
    let downloaded = try write("课程/子目录/资料.txt", "从微信下载来的资料")
    try quarantine(downloaded, agent: "WeChat")
    _ = try write("课程/电影.mkv", "not supported")

    var callbacks: [(String, URL, [TaskID])] = []
    controller.onFolderImported = { name, url, ids in callbacks.append((name, url, ids)) }

    controller.importFiles([folder])
    await waitUntil { self.confirmingPlan(controller) != nil }
    let plan = try XCTUnwrap(confirmingPlan(controller))
    XCTAssertEqual(plan.scan.entries.count, 4)
    XCTAssertEqual(plan.scan.count(.document), 4)
    XCTAssertFalse(plan.offersTranscription, "没有音视频就不问要不要转写")
    XCTAssertEqual(LocalImportConfirmationView.countsText(plan.scan).hasPrefix("找到 4 个文件（文档 4 个），共"), true)

    controller.confirmImport(transcribe: false)
    await waitUntil { self.finishedSummary(controller) != nil }
    let summary = try XCTUnwrap(finishedSummary(controller))
    XCTAssertEqual(summary.added, 4)
    XCTAssertEqual(summary.failures.count, 1)
    XCTAssertTrue(summary.failures[0].hasPrefix("课程/电影.mkv：暂不支持 .mkv 视频"))

    // 挂钩：一个顶层文件夹一次，按自然排序。
    XCTAssertEqual(callbacks.count, 1)
    XCTAssertEqual(callbacks.first?.0, "课程")
    let ordered = try XCTUnwrap(callbacks.first?.2)
    XCTAssertEqual(try ordered.map(title), ["01 开头", "2 中间", "10 结尾", "资料"])

    // 归属：下载来的判外部（贴「外部」、记来源），其余默认自有、不贴标签。
    let downloadedItem = try XCTUnwrap(summary.ownership.first { $0.name == "课程/子目录/资料.txt" })
    XCTAssertEqual(downloadedItem.ownership, .external)
    XCTAssertEqual(downloadedItem.source, "微信下载")
    XCTAssertEqual(summary.ownership.filter { $0.ownership == .own }.count, 3)
    XCTAssertEqual(LocalImportOwnershipList.summaryLine(summary.ownership), "1 个判为外部（微信下载）、3 个判为自有。判错了可以点「改」。")
    let downloadedDetail = try repository.detail(taskID: downloadedItem.id)
    XCTAssertEqual(downloadedDetail.tags.map(\.name), [ContentOwnership.externalTagName])
    XCTAssertEqual(downloadedDetail.snapshots.first?.sourceLabel, "本地文件（下载自 WeChat）")
    let ownDetail = try repository.detail(taskID: ordered[0])
    XCTAssertTrue(ownDetail.tags.isEmpty)
    XCTAssertEqual(ownDetail.snapshots.first?.sourceLabel, LocalFileProvenance.plainSourceLabel)

    // 「改」：外部 → 自有，两个保留标签都摘掉。
    controller.toggleOwnership(downloadedItem.id)
    XCTAssertEqual(finishedSummary(controller)?.ownership.first { $0.id == downloadedItem.id }?.ownership, .own)
    await waitUntil { (try? self.repository.detail(taskID: downloadedItem.id).tags.isEmpty) == true }

    // 再导一次：全部去重命中，挂钩照样按同一顺序回调（含已有条目）。
    controller.isPresented = false
    controller.importFiles([folder])
    await waitUntil { self.confirmingPlan(controller) != nil }
    controller.confirmImport(transcribe: false)
    await waitUntil { self.finishedSummary(controller) != nil }
    XCTAssertEqual(finishedSummary(controller)?.skipped, 4)
    XCTAssertEqual(callbacks.count, 2)
    XCTAssertEqual(callbacks.last?.2, ordered)
  }

  func testMediaIsReferencedNotCopiedAndQueuedForLocalTranscription() async throws {
    let transcriber = WorkspaceRecordingTranscriber(mode: .succeed)
    let wiring = try wire(transcriber: transcriber)
    let controller = wiring.controller
    let audio = base.appendingPathComponent("录音/会议.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeWAV(at: audio, seconds: 1)
    let before = try Data(contentsOf: audio)

    controller.importFiles([audio])
    await waitUntil { self.confirmingPlan(controller) != nil }
    XCTAssertEqual(confirmingPlan(controller)?.offersTranscription, true, "有音视频才出现「导入后转写」")
    controller.confirmImport(transcribe: true)
    // 只有一个文件：直接打开，不弹结果；转写在后台排队。
    await waitUntil { controller.phase == .idle }
    await waitUntil(timeout: .seconds(15)) { controller.transcriptionQueue?.isRunning == false }
    let status = try XCTUnwrap(controller.transcriptionQueue)
    XCTAssertEqual(status.total, 1)
    XCTAssertEqual(status.succeeded, 1)
    XCTAssertTrue(status.failures.isEmpty)
    XCTAssertEqual(LocalImportTranscriptionBadge.finishedText(status), "转写完成 1/1")

    let taskID = try XCTUnwrap(try repository.taskID(forCanonicalURL: CanonicalURL.localImport(
      source: LocalImportSource.files.rawValue, identifier: LocalFileImportReader.contentSHA256(of: audio)
    )))
    let asset = try XCTUnwrap(try repository.mediaAsset(taskID: taskID))
    XCTAssertTrue(ExternalMediaReference.isExternal(asset), "媒体记录是引用原文件")
    XCTAssertEqual(asset.transcriptionStatus, .completed)
    let copies = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaRoot.path)) ?? []
    XCTAssertTrue(copies.isEmpty, "Media/ 里不该有副本")
    XCTAssertEqual(try Data(contentsOf: audio), before, "原文件一个字节都不动")
    XCTAssertEqual(transcriber.fileURLs.map { $0.resolvingSymlinksInPath().path }, [audio.resolvingSymlinksInPath().path])
    XCTAssertTrue(transcriber.workspaces.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "临时音轨已删")

    controller.dismissTranscriptionQueue()
    XCTAssertNil(controller.transcriptionQueue)
  }

  /// 全部转写成功后，右下角「转写完成」自己收起（2026-10-04：原来一直挂着，要手动点 ×）。
  func testFinishedTranscriptionBadgeDismissesItself() async throws {
    let saved = LocalImportController.finishedBadgeSeconds
    LocalImportController.finishedBadgeSeconds = 0.3
    defer { LocalImportController.finishedBadgeSeconds = saved }
    let wiring = try wire(transcriber: WorkspaceRecordingTranscriber(mode: .succeed))
    let controller = wiring.controller
    let audio = base.appendingPathComponent("录音/自动收起.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeWAV(at: audio, seconds: 1)
    controller.importFiles([audio])
    await waitUntil { self.confirmingPlan(controller) != nil }
    controller.confirmImport(transcribe: true)
    await waitUntil(timeout: .seconds(15)) { controller.transcriptionQueue?.isRunning == false }
    await waitUntil(timeout: .seconds(5)) { controller.transcriptionQueue == nil }
    XCTAssertNil(controller.transcriptionQueue)
  }

  func testSingleDocumentImportsWithoutConfirmation() async throws {
    let wiring = try wire()
    let controller = wiring.controller
    let note = try write("随手.txt", "一段自己写的文字")
    controller.importFiles([note])
    await waitUntil { controller.phase == .idle && (try? self.repository.historyPage(limit: 5, after: nil).rows.count) == 1 }
    XCTAssertNil(controller.transcriptionQueue)
  }

  private func makeWAV(at url: URL, seconds: Double) throws {
    let sampleRate = 16_000.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw XCTSkip("无法创建音频格式")
    }
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw XCTSkip("无法创建缓冲") }
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] {
      for index in 0..<Int(frames) {
        channel[index] = 0.1 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
      }
    }
    try file.write(from: buffer)
  }
}

/// 导入本地文件不会联网；万一走到抓取，这个替身也只报错不出网。
private struct OfflineFetcher: WebPageFetcher {
  func fetch(url _: URL) async throws -> WebPageFetchResult {
    throw ManualLinkError.invalidURL
  }
}
