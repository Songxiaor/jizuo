import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

/// 本地导入 v2 在 App 层的链路：引用原文件的媒体记录能落库、能播放、能转写；
/// 原文件不见了给出「重新定位」；批量转写逐条走本机转写，临时音轨在完成、失败、
/// 取消后都被删掉。资料库、原文件都在临时目录里，转写器是替身，不调任何真实服务。
@MainActor
final class LocalImportReferenceTranscriptionTests: XCTestCase {
  private var base: URL!
  private var repository: GRDBHistoryRepository!
  private var store: LocalMediaStore!
  private var originalURL: URL!
  private var taskID: TaskID!

  override func setUp() async throws {
    try await super.setUp()
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-import-reference-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("AppSupport", isDirectory: true)
    let originals = base.appendingPathComponent("用户的文件", isDirectory: true)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    repository = try GRDBHistoryRepository.open(at: .init(applicationSupportRoot: root))
    store = LocalMediaStore(applicationSupportRoot: root)
    originalURL = originals.appendingPathComponent("讲座.mp3")
    try Data("fake-mp3-bytes-for-reference".utf8).write(to: originalURL)
    let sha = try LocalFileImportReader.contentSHA256(of: originalURL)
    let document = try LocalImportDocument.file(
      contentSHA256: sha, fileName: "讲座.mp3",
      text: LocalImportDocument.mediaPlaceholder(fileName: "讲座.mp3", durationSeconds: 12, hasVideo: false),
      completeness: "partial", method: "local_file_audio", fileDate: nil
    )
    let accepted = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: 1))
    taskID = accepted.taskID
    let asset = try store.externalReferenceAsset(
      fileURL: originalURL, taskID: accepted.taskID, snapshotID: accepted.snapshotID,
      contentSHA256: sha, byteSize: 28, durationSeconds: 12,
      platform: LocalImportSource.files.rawValue, createdAtMilliseconds: 2
    )
    // 走仓库既有的 attachMedia 校验：不改表、不加迁移也能存下。
    try repository.attachMedia(.init(asset: asset))
  }

  override func tearDown() async throws {
    try? repository.database.close()
    try? FileManager.default.removeItem(at: base)
    try await super.tearDown()
  }

  private func makeModel(_ transcriber: WorkspaceRecordingTranscriber) -> HistoryViewModel {
    let model = HistoryViewModel(mediaStore: store, videoTranscriber: transcriber)
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: false, unavailableCode: nil)
    return model
  }

  private func same(_ lhs: URL?, _ rhs: URL) -> Bool {
    guard let lhs else { return false }
    return lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func waitUntil(
    timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  func testReferencedOriginalPlaysWithoutACopy() async throws {
    let model = makeModel(.init(mode: .succeed))
    model.selectedTaskID = taskID
    await waitUntil { model.detailState == .loaded && model.localMediaFileURL != nil }
    XCTAssertTrue(same(model.localMediaFileURL, originalURL), "播放读的是原文件")
    XCTAssertNil(model.localMediaOriginalMissing)
    XCTAssertTrue(LocalMediaExport.isSupportedLocalFile(try XCTUnwrap(model.localMediaFileURL)), "mp3 也要能播、能另存")
    let mediaFiles = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaRoot.path)) ?? []
    XCTAssertTrue(mediaFiles.isEmpty, "Media/ 里不该有副本")
  }

  func testMissingOriginalOffersRelocationAndRelocatingRestoresPlayback() async throws {
    let rescued = base.appendingPathComponent("移动硬盘/讲座（找回）.mp3")
    try FileManager.default.createDirectory(at: rescued.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: originalURL, to: rescued)
    try FileManager.default.removeItem(at: originalURL)

    let model = makeModel(.init(mode: .succeed))
    model.selectedTaskID = taskID
    await waitUntil { model.detailState == .loaded && model.localMediaOriginalMissing != nil }
    XCTAssertNil(model.localMediaFileURL)
    XCTAssertNil(model.localMediaResolutionFailure, "不是「设置里重选文件夹」那种错")
    XCTAssertEqual(model.localMediaOriginalMissing?.fileName, "讲座.mp3")

    // 选错文件：内容不一样，拒绝并说明。
    let wrong = base.appendingPathComponent("移动硬盘/别的.mp3")
    try Data("another-file".utf8).write(to: wrong)
    model.relocateOriginalMedia(to: wrong)
    await waitUntil {
      if case .failed = model.originalRelocationState { return true }
      return false
    }
    XCTAssertNotNil(model.localMediaOriginalMissing)

    model.relocateOriginalMedia(to: rescued)
    await waitUntil { self.same(model.localMediaFileURL, rescued) }
    XCTAssertNil(model.localMediaOriginalMissing)
    XCTAssertEqual(model.originalRelocationState, .idle)
    XCTAssertTrue(ExternalMediaReference.isExternal(try XCTUnwrap(repository.mediaAsset(taskID: taskID))))
  }

  func testBatchTranscriptionReadsTheOriginalAndDeletesTheTemporaryTrack() async throws {
    let transcriber = WorkspaceRecordingTranscriber(mode: .succeed)
    let model = makeModel(transcriber)
    let outcome = await model.transcribeImportedMedia(taskID: taskID)
    XCTAssertEqual(outcome, .completed)
    XCTAssertTrue(same(transcriber.fileURLs.first, originalURL), "转写直接读原文件")
    let workspace = try XCTUnwrap(transcriber.workspaces.first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "临时音轨在转写结束后删掉")
    let detail = try repository.detail(taskID: taskID)
    XCTAssertEqual(detail.snapshots.last?.sourceKind, CapturedDocument.Origin.localTranscription.rawValue)
    XCTAssertEqual(detail.media?.transcriptionStatus, .completed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path), "原文件原样留着")

    let again = await model.transcribeImportedMedia(taskID: taskID)
    XCTAssertEqual(again, .alreadyTranscribed, "已转写的不重复转")
  }

  func testFailedTranscriptionAlsoDeletesTheTemporaryTrack() async throws {
    let transcriber = WorkspaceRecordingTranscriber(mode: .fail)
    let model = makeModel(transcriber)
    let outcome = await model.transcribeImportedMedia(taskID: taskID)
    guard case .failed = outcome else { return XCTFail("应当失败，实际 \(outcome)") }
    let workspace = try XCTUnwrap(transcriber.workspaces.first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
  }

  func testStoppingTheQueueCancelsAndDeletesTheTemporaryTrack() async throws {
    let transcriber = WorkspaceRecordingTranscriber(mode: .suspend)
    let model = makeModel(transcriber)
    let id = try XCTUnwrap(taskID)
    let running = Task { await model.transcribeImportedMedia(taskID: id) }
    await waitUntil { !transcriber.workspaces.isEmpty && model.transcriptionState == .transcribing }
    running.cancel()
    let outcome = await running.value
    XCTAssertEqual(outcome, .cancelled)
    let workspace = try XCTUnwrap(transcriber.workspaces.first)
    await waitUntil { !FileManager.default.fileExists(atPath: workspace.path) }
    await waitUntil { model.transcriptionState == .cancelled }
  }

  func testUnavailableModelDoesNotLeaveATemporaryFolder() async throws {
    let transcriber = WorkspaceRecordingTranscriber(mode: .succeed, modelState: .unavailable(.speechUnavailable))
    let model = makeModel(transcriber)
    let before = Set(temporaryTranscriptionFolders())
    let outcome = await model.transcribeImportedMedia(taskID: taskID)
    guard case .failed = outcome else { return XCTFail("应当失败，实际 \(outcome)") }
    await waitUntil { Set(self.temporaryTranscriptionFolders()).subtracting(before).isEmpty }
  }

  func testMissingOriginalFailsWithAReasonInsteadOfTranscribing() async throws {
    try FileManager.default.removeItem(at: originalURL)
    let transcriber = WorkspaceRecordingTranscriber(mode: .succeed)
    let model = makeModel(transcriber)
    let outcome = await model.transcribeImportedMedia(taskID: taskID)
    XCTAssertEqual(outcome, .failed(ExternalMediaReferenceError.originalMissing(lastKnownPath: nil).userMessage))
    XCTAssertTrue(transcriber.workspaces.isEmpty)
  }

  private func temporaryTranscriptionFolders() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
      .filter { $0.hasPrefix("linkdigest-transcription-") }
  }
}

/// 转写替身：记下读了哪个文件、用了哪个临时目录，并像真转写器一样往临时目录里写一份「抽出来的音轨」。
final class WorkspaceRecordingTranscriber: LocalVideoTranscribing, @unchecked Sendable {
  enum Mode { case succeed, fail, suspend }
  private let lock = NSLock()
  private let mode: Mode
  private let state: LocalSpeechModelState
  private var recordedWorkspaces: [URL] = []
  private var recordedFiles: [URL] = []

  init(mode: Mode, modelState: LocalSpeechModelState = .ready) {
    self.mode = mode
    state = modelState
  }

  var workspaces: [URL] { lock.withLock { recordedWorkspaces } }
  var fileURLs: [URL] { lock.withLock { recordedFiles } }

  func modelState(localeIdentifier _: String) async -> LocalSpeechModelState { state }
  func downloadModel(localeIdentifier _: String) async throws {}

  func transcribe(fileURL: URL, workspaceURL: URL, localeIdentifier _: String) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    lock.withLock {
      recordedWorkspaces.append(workspaceURL)
      recordedFiles.append(fileURL)
    }
    try? Data("extracted".utf8).write(to: workspaceURL.appendingPathComponent("extracted-audio.m4a"))
    let mode = mode
    return AsyncThrowingStream { continuation in
      switch mode {
      case .succeed:
        continuation.yield(.extractingAudio)
        continuation.yield(.transcribing)
        continuation.yield(.final("本机转写出来的文字"))
        continuation.finish()
      case .fail:
        continuation.yield(.extractingAudio)
        continuation.finish(throwing: LocalVideoTranscriptionError.recognitionFailed)
      case .suspend:
        let worker = Task {
          continuation.yield(.extractingAudio)
          continuation.yield(.transcribing)
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
