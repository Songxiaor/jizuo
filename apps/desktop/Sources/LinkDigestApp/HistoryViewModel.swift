import Combine
import Foundation
import LinkDigestAdapters
import LinkDigestCore

enum HistoryListState: Equatable { case idle, loading, empty, loaded, failed }
enum HistoryDetailState: Equatable { case idle, loading, loaded, failed }
enum TranscriptionUIState: Equatable {
  case idle
  case preparingMedia
  case checkingModel
  case awaitingModelDownload
  case preparingModel
  case extractingAudio
  case transcribing
  case completed
  case cancelled
  case failed(String)

  var isActive: Bool {
    switch self {
    case .preparingMedia, .checkingModel, .awaitingModelDownload, .preparingModel, .extractingAudio, .transcribing: true
    default: false
    }
  }
}
enum ImageTextRecognitionUIState: Equatable {
  case idle
  case recognizing
  case completed
  case cancelled
  case failed(String)
}
enum TranscriptTidyUIState: Equatable {
  case idle
  case running
  case completed
  case cancelled
  case failed(String)

  var isActive: Bool { self == .running }
}
private enum PageResult: Sendable { case success(HistoryPage), failure(StorageErrorCode) }
private enum DetailResult: Sendable { case success(HistoryDetailProjection), failure(StorageErrorCode) }
private enum DeleteResult: Sendable {
  case success(BatchDeleteResult, media: [MediaAsset])
  case failure(StorageErrorCode)
}
private enum ExportResult: Sendable { case success(HistoryExportFile), failure }
private enum TagsResult: Sendable { case success([HistoryTag]), failure }
private enum NavigationCountsResult: Sendable { case success(HistoryNavigationCounts), failure }
private enum TagMutationResult: Sendable { case success, failure(StorageErrorCode) }
private enum BeginTranscriptionPersistenceResult: Sendable {
  case success(TranscriptionAttemptToken)
  case failure(StorageErrorCode)
}
private enum BeginTaskTranscriptionPersistenceResult: Sendable {
  case success(TaskTranscriptionAttemptToken)
  case failure(StorageErrorCode)
}
private enum TranscriptionPersistenceResult: Sendable {
  case applied
  case stale
  case replay
  case failure(StorageErrorCode)
}

/// The one serial, non-MainActor boundary for all synchronous repository work.
/// SwiftUI state remains on MainActor while SQLite never executes there.
private actor HistoryRepositoryWorker {
  func delete(_ history: HistoryApplicationService, taskIDs: Set<TaskID>) -> DeleteResult {
    do {
      let media = taskIDs.compactMap { try? history.mediaAsset(taskID: $0) }
      return .success(try history.deleteTasks(taskIDs: taskIDs), media: media)
    }
    catch { return .failure(HistoryViewModel.storageCode(for: error, context: .write)) }
  }

  func export(_ history: HistoryApplicationService, taskID: TaskID, format: HistoryExportFormat) -> ExportResult {
    do { return .success(try HistoryExportRenderer.render(history.exportProjection(taskID: taskID), as: format)) }
    catch { return .failure }
  }

  func tags(_ history: HistoryApplicationService) -> TagsResult {
    do { return .success(try history.allTags()) }
    catch { return .failure }
  }

  func navigationCounts(_ history: HistoryApplicationService) -> NavigationCountsResult {
    do { return .success(try history.navigationCounts()) }
    catch { return .failure }
  }

  func addTag(_ history: HistoryApplicationService, rawName: String, taskID: TaskID) -> TagMutationResult {
    do { _ = try history.addTags([rawName], to: taskID); return .success }
    catch { return .failure(HistoryViewModel.storageCode(for: error, context: .write)) }
  }

  func removeTag(_ history: HistoryApplicationService, normalizedName: String, taskID: TaskID) -> TagMutationResult {
    do { try history.removeTag(normalizedName: normalizedName, from: taskID); return .success }
    catch { return .failure(HistoryViewModel.storageCode(for: error, context: .write)) }
  }

  func beginTranscription(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    mediaID: String
  ) -> BeginTranscriptionPersistenceResult {
    do {
      return .success(try history.beginMediaTranscription(taskID: taskID, mediaID: mediaID))
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func beginTaskTranscription(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    createdAtMilliseconds: Int64
  ) -> BeginTaskTranscriptionPersistenceResult {
    do {
      return .success(try history.beginTaskTranscription(
        taskID: taskID,
        createdAtMilliseconds: createdAtMilliseconds
      ))
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func updateTranscriptionStatus(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    status: TranscriptionStatusMutation
  ) -> TranscriptionPersistenceResult {
    do {
      switch try history.updateMediaTranscriptionStatus(taskID: taskID, attempt: attempt, status: status) {
      case .applied: return .applied
      case .stale: return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func updateTaskTranscriptionStatus(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    status: TaskTranscriptionStatusMutation,
    updatedAtMilliseconds: Int64
  ) -> TranscriptionPersistenceResult {
    do {
      switch try history.updateTaskTranscriptionStatus(
        taskID: taskID,
        attempt: attempt,
        status: status,
        updatedAtMilliseconds: updatedAtMilliseconds
      ) {
      case .applied: return .applied
      case .stale: return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func saveTranscription(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TranscriptionAttemptToken,
    detail: HistoryDetailProjection,
    text: String,
    receivedAtMilliseconds: Int64
  ) -> TranscriptionPersistenceResult {
    let timestamp = ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: Double(receivedAtMilliseconds) / 1_000)
    )
    let latest = detail.snapshots.last
    let document = CapturedDocument(
      createdAt: timestamp,
      origin: .localTranscription,
      url: detail.task.canonicalURL,
      title: latest?.title,
      platform: detail.media?.platform ?? latest?.platform ?? "local_video",
      method: "speech_analyzer_local",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "本机视频转写"
    )
    do {
      let result = try history.completeMediaTranscription(.init(
        taskID: taskID, attempt: attempt, document: document,
        evidence: .appleSpeechAnalyzer(localeIdentifier: "zh_CN", language: "zh", completedAtMilliseconds: receivedAtMilliseconds),
        receivedAtMilliseconds: receivedAtMilliseconds
      ))
      switch result {
      case let .accepted(accepted):
        guard accepted.taskID == taskID else { throw RepositoryFailure.invalidInput }
        return .applied
      case let .replay(replayed):
        guard replayed.taskID == taskID else { throw RepositoryFailure.invalidInput }
        return .replay
      case .stale:
        return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func saveTaskTranscription(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    detail: HistoryDetailProjection,
    text: String,
    platform: String,
    receivedAtMilliseconds: Int64
  ) -> TranscriptionPersistenceResult {
    let timestamp = ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: Double(receivedAtMilliseconds) / 1_000)
    )
    let document = CapturedDocument(
      createdAt: timestamp,
      origin: .localTranscription,
      url: detail.task.canonicalURL,
      title: detail.snapshots.last?.title,
      platform: platform,
      method: "speech_analyzer_local",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "本机视频转写"
    )
    do {
      switch try history.completeTaskTranscription(.init(
        taskID: taskID,
        attempt: attempt,
        document: document,
        evidence: .appleSpeechAnalyzer(
          localeIdentifier: "zh_CN",
          language: "zh",
          completedAtMilliseconds: receivedAtMilliseconds
        ),
        receivedAtMilliseconds: receivedAtMilliseconds
      )) {
      case let .accepted(value):
        guard value.taskID == taskID else { throw RepositoryFailure.invalidInput }
        return .applied
      case let .replay(value):
        guard value.taskID == taskID else { throw RepositoryFailure.invalidInput }
        return .replay
      case .stale:
        return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  func saveOnlineTaskTranscription(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    detail: HistoryDetailProjection,
    text: String,
    platform: String,
    provider: String,
    model: String,
    receivedAtMilliseconds: Int64
  ) -> TranscriptionPersistenceResult {
    let timestamp = ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: Double(receivedAtMilliseconds) / 1_000)
    )
    let document = CapturedDocument(
      createdAt: timestamp,
      origin: .localTranscription,
      url: detail.task.canonicalURL,
      title: detail.snapshots.last?.title,
      platform: platform,
      method: "openai_compatible_audio_transcriptions",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "在线视频转写"
    )
    do {
      switch try history.completeTaskTranscription(.init(
        taskID: taskID,
        attempt: attempt,
        document: document,
        evidence: .onlineSpeechToText(
          provider: provider,
          model: model,
          language: "zh",
          completedAtMilliseconds: receivedAtMilliseconds
        ),
        receivedAtMilliseconds: receivedAtMilliseconds
      )) {
      case let .accepted(value): return value.taskID == taskID ? .applied : .failure(.writeFailed)
      case let .replay(value): return value.taskID == taskID ? .replay : .failure(.writeFailed)
      case .stale: return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }

  /// Persists a tidy pass as a fresh transcript snapshot. The pre-tidy
  /// snapshot stays untouched in history, so tidying is always reversible.
  func saveTidiedTranscript(
    _ history: HistoryApplicationService,
    taskID: TaskID,
    attempt: TaskTranscriptionAttemptToken,
    detail: HistoryDetailProjection,
    text: String,
    platform: String,
    model: String,
    receivedAtMilliseconds: Int64
  ) -> TranscriptionPersistenceResult {
    let timestamp = ISO8601DateFormatter().string(
      from: Date(timeIntervalSince1970: Double(receivedAtMilliseconds) / 1_000)
    )
    let document = CapturedDocument(
      createdAt: timestamp,
      origin: .localTranscription,
      url: detail.task.canonicalURL,
      title: detail.snapshots.last?.title,
      platform: platform,
      method: "openai_compatible_chat_tidy",
      text: text,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "转写整理稿"
    )
    do {
      switch try history.completeTaskTranscription(.init(
        taskID: taskID,
        attempt: attempt,
        document: document,
        evidence: .onlineTextTidy(
          provider: "configured_provider",
          model: model,
          completedAtMilliseconds: receivedAtMilliseconds
        ),
        receivedAtMilliseconds: receivedAtMilliseconds
      )) {
      case let .accepted(value): return value.taskID == taskID ? .applied : .failure(.writeFailed)
      case let .replay(value): return value.taskID == taskID ? .replay : .failure(.writeFailed)
      case .stale: return .stale
      }
    } catch {
      return .failure(HistoryViewModel.storageCode(for: error, context: .write))
    }
  }
}

private struct TranscriptionContext {
  let taskID: TaskID
  let detail: HistoryDetailProjection
  let fileURL: URL
  let workspaceURL: URL
  let attempt: TranscriptionAttemptToken
}

private struct RemoteTranscriptionContext {
  let taskID: TaskID
  let detail: HistoryDetailProjection
  let descriptor: MediaDescriptor
  let fileURL: URL
  let workspaceURL: URL
  let attempt: TaskTranscriptionAttemptToken
  let tempAttemptID: String
}

private struct PendingOnlineTranscriptionContext {
  let taskID: TaskID
  let detail: HistoryDetailProjection
  /// 已解析的音频源：捕获现场的 HTTPS 流，或已存任务的本机视频文件。
  /// 两者都只在本机提取音频分片后上传，媒体本体不发给模型商家。
  let mediaURL: URL
  let platform: String
  let model: String
}

private struct PendingTranscriptTidyContext {
  let taskID: TaskID
  let detail: HistoryDetailProjection
  /// 待整理的转写正文；只发送文字本身，不发送媒体或链接。
  let text: String
  let platform: String
  /// nil 表示继承设置页的总结模型。
  let model: String?
}

enum RemoteMediaFavoriteState: Equatable {
  case idle
  case saving
  case saved
  case failed(String)

  var isSaving: Bool { self == .saving }
}

@MainActor
final class HistoryViewModel: ObservableObject {
  @Published private(set) var rows: [HistoryRowProjection] = []
  @Published var selectedTaskIDs: Set<TaskID> = [] {
    didSet {
      let previous = Self.singleSelection(in: oldValue)
      let current = selectedTaskID
      if current != previous {
        remoteMediaFavoriteState = .idle
        loadDetailForSelection()
      }
    }
  }
  var selectedTaskID: TaskID? {
    get { Self.singleSelection(in: selectedTaskIDs) }
    set { selectedTaskIDs = newValue.map { [$0] } ?? [] }
  }
  @Published private(set) var detail: HistoryDetailProjection?
  /// 转写校对保存失败的人话提示；nil 表示无待展示错误。
  @Published private(set) var snapshotEditFailure: String?
  @Published private(set) var listState: HistoryListState = .idle
  @Published private(set) var detailState: HistoryDetailState = .idle
  @Published private(set) var isLoadingNextPage = false
  @Published private(set) var isReadOnly = false
  @Published private(set) var historyReadOnlyReason: RepositoryRecoveryReason?
  @Published private(set) var blockingErrorCode: StorageErrorCode?
  @Published private(set) var listErrorCode: StorageErrorCode?
  @Published private(set) var detailErrorCode: StorageErrorCode?
  @Published private(set) var deleteErrorCode: StorageErrorCode?
  @Published var isDeleteConfirmationPresented = false
  @Published var isDeleteFailurePresented = false
  @Published var isProtectedDeletionAlertPresented = false
  @Published var isDeleteOutcomePresented = false
  @Published private(set) var deleteOutcomeMessage = ""
  @Published private(set) var isDeleting = false
  @Published private(set) var isPreparingExport = false
  @Published private(set) var exportFile: HistoryExportFile?
  @Published var isExportPanelPresented = false
  @Published var isExportPreparationFailurePresented = false
  @Published var isExportSaveFailurePresented = false
  @Published private(set) var localImageURLs: [URL] = []
  @Published private(set) var localMediaFileURL: URL?
  @Published private(set) var localMediaResolutionFailure: String?
  @Published private(set) var faviconImageURLs: [TaskID: URL] = [:]
  @Published var searchText = "" { didSet { scheduleSearchReload() } }
  @Published private(set) var availableTags: [HistoryTag] = []
  @Published private(set) var selectedTagNormalizedNames: Set<String> = []
  @Published private(set) var navigationCounts = HistoryNavigationCounts()
  @Published private(set) var selectedHosts: Set<String> = []
  @Published private(set) var selectedScope: HistoryListScope = .all
  @Published var showsAllNavigationTags = false
  @Published private(set) var tagErrorCode: StorageErrorCode?
  @Published private(set) var transcriptionState: TranscriptionUIState = .idle
  @Published private(set) var transcriptionText = ""
  @Published private(set) var transcriptionTaskID: TaskID?
  @Published private(set) var transcriptionUsesOnlineService = false
  @Published private(set) var imageTextRecognitionState: ImageTextRecognitionUIState = .idle
  @Published private(set) var recognizedImageText = ""
  @Published private(set) var imageTextRecognitionTaskID: TaskID?
  @Published private(set) var transcriptionCleanupFailure: String?
  @Published var isTranscriptionModelConfirmationPresented = false
  @Published var isOnlineTranscriptionConfirmationPresented = false
  @Published private(set) var transcriptTidyState: TranscriptTidyUIState = .idle
  @Published private(set) var transcriptTidyTaskID: TaskID?
  @Published var isTranscriptTidyConfirmationPresented = false
  /// 展示用 token 摘要；evidence 表列固定，本轮不入库。
  @Published private(set) var transcriptTidyTokenSummary: String?
  @Published private(set) var remoteMediaFavoriteState: RemoteMediaFavoriteState = .idle
  @Published private(set) var capturedMediaAutoSaveStates: [TaskID: RemoteMediaFavoriteState] = [:]
  @Published private(set) var capturedMediaAutoSaveFailureMessage = ""
  @Published var isCapturedMediaAutoSaveFailurePresented = false

  private let worker = HistoryRepositoryWorker()
  private let imageCache: GitHubREADMEImageCache?
  private let mediaStore: LocalMediaStore?
  private let mediaDownloader: VideoMediaDownloader?
  private let mediaDownloadOperation: (@Sendable (
    _ media: CaptureMedia,
    _ taskID: TaskID,
    _ snapshotID: ContentSnapshotID,
    _ pageURL: String?
  ) async throws -> MediaAsset)?
  private let faviconCache: WebsiteFaviconCache?
  private let faviconResources: (any SafeResourceFetching)?
  private let videoTranscriber: (any LocalVideoTranscribing)?
  private let imageTextRecognizer: (any LocalImageTextRecognizing)?
  private let onlineAudioTranscriber: (any OnlineAudioTranscribing)?
  private let transcriptTidier: (any TranscriptTidying)?
  private let transcriptionTempStore: TranscriptionTempStore?
  /// 内嵌播放器实时音频转写（YouTube 无字幕视频）；注入以便测试。
  /// 第二参数是优雅停止信号：yield 即关流、保存已转写文本（非硬取消）。
  private let livePlaybackTranscribe: (@Sendable (String, AsyncStream<Void>) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>)?
  /// 当前实时转写的停止信号；停止/视频播完时 yield。
  private var livePlaybackStopContinuation: AsyncStream<Void>.Continuation?
  private let nowMilliseconds: @Sendable () -> Int64
  private let onDiscardedTranscriptionAttempt: @Sendable () -> Void
  private var history: HistoryApplicationService?
  private var hasConfiguredHistory = false
  private var nextCursor: HistoryPageCursor?
  private var configurationGeneration = UUID()
  private var listRequestID = UUID()
  private var detailRequestID = UUID()
  private var deleteRequestID = UUID()
  private var exportRequestID = UUID()
  private(set) var pendingDeletionTaskIDs: Set<TaskID> = []
  private(set) var pendingProtectedDeletionTaskIDs: Set<TaskID> = []
  private var pageTask: Task<Void, Never>?
  private var detailTask: Task<Void, Never>?
  private var deleteTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var faviconTask: Task<Void, Never>?
  private var tagsTask: Task<Void, Never>?
  private var navigationCountsTask: Task<Void, Never>?
  private var tagMutationTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var transcriptionTask: Task<Void, Never>?
  private var imageTextRecognitionTask: Task<Void, Never>?
  private var imageTextRecognitionRequestID = UUID()
  private var transcriptionRequestID = UUID()
  private var pendingTranscriptionContext: TranscriptionContext?
  private var pendingRemoteTranscriptionContext: RemoteTranscriptionContext?
  private var pendingOnlineTranscriptionContext: PendingOnlineTranscriptionContext?
  private var transcriptTidyTask: Task<Void, Never>?
  private var transcriptTidyRequestID = UUID()
  private var pendingTranscriptTidyContext: PendingTranscriptTidyContext?
  private var cleanupRetryAttemptID: String?
  private var localMediaLease: SecurityScopedURLLease?

  init(
    imageCache: GitHubREADMEImageCache? = nil,
    mediaStore: LocalMediaStore? = nil,
    mediaDownloader: VideoMediaDownloader? = nil,
    mediaDownloadOperation: (@Sendable (
      _ media: CaptureMedia,
      _ taskID: TaskID,
      _ snapshotID: ContentSnapshotID,
      _ pageURL: String?
    ) async throws -> MediaAsset)? = nil,
    faviconCache: WebsiteFaviconCache? = nil,
    faviconResources: (any SafeResourceFetching)? = nil,
    videoTranscriber: (any LocalVideoTranscribing)? = nil,
    imageTextRecognizer: (any LocalImageTextRecognizing)? = nil,
    onlineAudioTranscriber: (any OnlineAudioTranscribing)? = nil,
    transcriptTidier: (any TranscriptTidying)? = nil,
    transcriptionTempStore: TranscriptionTempStore? = nil,
    livePlaybackTranscribe: (@Sendable (String, AsyncStream<Void>) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>)? = nil,
    startupTranscriptionCleanupFailure: String? = nil,
    onDiscardedTranscriptionAttempt: @escaping @Sendable () -> Void = {},
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.imageCache = imageCache
    self.mediaStore = mediaStore
    self.mediaDownloader = mediaDownloader
    self.mediaDownloadOperation = mediaDownloadOperation
    self.faviconCache = faviconCache
    self.faviconResources = faviconResources
    self.videoTranscriber = videoTranscriber
    self.imageTextRecognizer = imageTextRecognizer
    self.onlineAudioTranscriber = onlineAudioTranscriber
    self.transcriptTidier = transcriptTidier
    self.transcriptionTempStore = transcriptionTempStore
    self.livePlaybackTranscribe = livePlaybackTranscribe
    transcriptionCleanupFailure = startupTranscriptionCleanupFailure
    self.onDiscardedTranscriptionAttempt = onDiscardedTranscriptionAttempt
    self.nowMilliseconds = nowMilliseconds
  }

  deinit { pageTask?.cancel(); detailTask?.cancel(); deleteTask?.cancel(); exportTask?.cancel(); faviconTask?.cancel(); tagsTask?.cancel(); navigationCountsTask?.cancel(); tagMutationTask?.cancel(); searchTask?.cancel(); transcriptionTask?.cancel(); imageTextRecognitionTask?.cancel(); transcriptTidyTask?.cancel() }

  var canDelete: Bool { history != nil && !isReadOnly && !selectedTaskIDs.isEmpty && !isDeleting }
  var canExport: Bool { history != nil && selectedTaskID != nil && !isPreparingExport }
  func canDelete(protectedTaskIDs: Set<TaskID>) -> Bool {
    guard canDelete else { return false }
    return !selectedTaskIDs.subtracting(protectedTaskIDs).isEmpty
  }
  func canDelete(protectedTaskID: TaskID?) -> Bool {
    canDelete(protectedTaskIDs: Set(protectedTaskID.map { [$0] } ?? []))
  }
  var canRetryList: Bool { history != nil && blockingErrorCode == nil }
  var canEditTags: Bool { history != nil && !isReadOnly && selectedTaskID != nil && !isDeleting }
  var canTranscribeVideo: Bool {
    history != nil && videoTranscriber != nil && !isReadOnly && detail?.media != nil
      && localMediaFileURL?.isFileURL == true && !transcriptionState.isActive
  }
  var canRecognizeImageText: Bool {
    imageTextRecognizer != nil && !localImageURLs.isEmpty && imageTextRecognitionState != .recognizing
  }

  var selectedTaskCount: Int { selectedTaskIDs.count }
  var pendingDeletionCount: Int { pendingDeletionTaskIDs.count }
  var pendingProtectedDeletionCount: Int { pendingProtectedDeletionTaskIDs.count }
  var deletionConfirmationTitle: String {
    pendingDeletionCount == 1 ? "删除这条历史记录？" : "确定删除选中的 \(pendingDeletionCount) 条记录？"
  }
  var deletionConfirmationMessage: String {
    var message = pendingDeletionCount == 1
      ? "此操作只删除本机的这条记录，无法撤销。"
      : "此操作只删除本机的这些记录，无法撤销。"
    if pendingProtectedDeletionCount > 0 {
      message += " 其中 \(pendingProtectedDeletionCount) 条正在生成，将被跳过。"
    }
    return message
  }

  func transcriptionState(for taskID: TaskID) -> TranscriptionUIState {
    transcriptionTaskID == taskID ? transcriptionState : .idle
  }

  func transcriptionText(for taskID: TaskID) -> String {
    transcriptionTaskID == taskID ? transcriptionText : ""
  }

  func imageTextRecognitionState(for taskID: TaskID) -> ImageTextRecognitionUIState {
    imageTextRecognitionTaskID == taskID ? imageTextRecognitionState : .idle
  }

  func recognizedImageText(for taskID: TaskID) -> String {
    imageTextRecognitionTaskID == taskID ? recognizedImageText : ""
  }

  func recognizeImageText() {
    guard let imageTextRecognizer, canRecognizeImageText, let taskID = selectedTaskID else {
      imageTextRecognitionState = .failed(LocalImageTextRecognitionError.noImages.userMessage)
      return
    }
    let urls = localImageURLs
    let requestID = UUID()
    imageTextRecognitionRequestID = requestID
    imageTextRecognitionTask?.cancel()
    imageTextRecognitionTaskID = taskID
    recognizedImageText = ""
    imageTextRecognitionState = .recognizing
    imageTextRecognitionTask = Task { [weak self] in
      do {
        let text = try await imageTextRecognizer.recognizeText(
          in: urls,
          languages: ["zh-Hans", "zh-Hant", "en-US"]
        )
        try Task.checkCancellation()
        guard let self,
              self.imageTextRecognitionRequestID == requestID,
              self.imageTextRecognitionTaskID == taskID else { return }
        self.recognizedImageText = text
        self.imageTextRecognitionState = .completed
      } catch is CancellationError {
        guard let self, self.imageTextRecognitionRequestID == requestID else { return }
        self.imageTextRecognitionState = .cancelled
      } catch let error as LocalImageTextRecognitionError {
        guard let self, self.imageTextRecognitionRequestID == requestID else { return }
        self.imageTextRecognitionState = error == .cancelled ? .cancelled : .failed(error.userMessage)
      } catch {
        guard let self, self.imageTextRecognitionRequestID == requestID else { return }
        self.imageTextRecognitionState = .failed(LocalImageTextRecognitionError.recognitionFailed.userMessage)
      }
    }
  }

  func cancelImageTextRecognition() {
    imageTextRecognitionRequestID = UUID()
    imageTextRecognitionTask?.cancel()
    imageTextRecognitionTask = nil
    imageTextRecognitionState = .cancelled
  }
  func canTranscribeCurrentCapture(_ descriptor: MediaDescriptor, taskID: TaskID) -> Bool {
    guard history != nil,
          videoTranscriber != nil,
          transcriptionTempStore != nil,
          !isReadOnly,
          selectedTaskID == taskID,
          detail?.task.id == taskID,
          descriptor.kind == .directFile,
          descriptor.transcriptionCapability != .unavailable,
          !transcriptionState.isActive,
          descriptor.durationSeconds.map({ $0 <= TranscriptionTempStore.maximumDurationSeconds }) ?? true,
          let rawURL = descriptor.ephemeralPlaybackURL,
          URL(string: rawURL)?.scheme?.lowercased() == "https"
    else { return false }
    guard let expiresAt = descriptor.expiresAt else { return true }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    guard let expiry = fractional.date(from: expiresAt) ?? whole.date(from: expiresAt) else { return false }
    return expiry > Date()
  }
  func canTranscribeCurrentCaptureOnline(_ descriptor: MediaDescriptor, taskID: TaskID, model: String?) -> Bool {
    guard history != nil,
          onlineAudioTranscriber != nil,
          !isReadOnly,
          selectedTaskID == taskID,
          detail?.task.id == taskID,
          descriptor.kind == .directFile,
          !transcriptionState.isActive,
          model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          let rawURL = descriptor.ephemeralPlaybackURL,
          URL(string: rawURL)?.scheme?.lowercased() == "https"
    else { return false }
    guard let expiresAt = descriptor.expiresAt else { return true }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    guard let expiry = fractional.date(from: expiresAt) ?? whole.date(from: expiresAt) else { return false }
    return expiry > Date()
  }
  var hasActiveFilter: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !selectedTagNormalizedNames.isEmpty
      || !selectedHosts.isEmpty
      || selectedScope != .all
  }
  var hasCategoryFilter: Bool { !selectedHosts.isEmpty || !selectedTagNormalizedNames.isEmpty }
  func faviconImageURL(for row: HistoryRowProjection) -> URL? { faviconImageURLs[row.taskID] }

  func beginBootstrapLoading() {
    guard history == nil, blockingErrorCode == nil else { return }
    listState = .loading
    detailState = .loading
  }

  func configure(
    history: HistoryApplicationService?,
    isReadOnly: Bool,
    unavailableCode: StorageErrorCode?,
    readOnlyReason: RepositoryRecoveryReason? = nil
  ) {
    if hasConfiguredHistory,
       history?.storageIdentity == self.history?.storageIdentity,
       self.isReadOnly == isReadOnly,
       blockingErrorCode == unavailableCode,
       historyReadOnlyReason == (isReadOnly ? readOnlyReason : nil) {
      return
    }
    hasConfiguredHistory = true
    configurationGeneration = UUID()
    pageTask?.cancel(); detailTask?.cancel(); deleteTask?.cancel(); faviconTask?.cancel(); tagsTask?.cancel(); navigationCountsTask?.cancel(); tagMutationTask?.cancel(); searchTask?.cancel(); transcriptionTask?.cancel(); imageTextRecognitionTask?.cancel(); invalidateExportPreparation()
    self.history = history; self.isReadOnly = isReadOnly
    historyReadOnlyReason = isReadOnly ? readOnlyReason : nil
    blockingErrorCode = unavailableCode
    rows = []; selectedTaskIDs = []; detail = nil; localImageURLs = []; localMediaFileURL = nil; localMediaLease = nil; localMediaResolutionFailure = nil; faviconImageURLs = [:]; nextCursor = nil
    availableTags = []; navigationCounts = .init(); selectedTagNormalizedNames = []; selectedHosts = []; selectedScope = .all; showsAllNavigationTags = false; searchText = ""
    listErrorCode = nil; detailErrorCode = nil; deleteErrorCode = nil; tagErrorCode = nil
    pendingDeletionTaskIDs = []; pendingProtectedDeletionTaskIDs = []
    isDeleteConfirmationPresented = false; isDeleteFailurePresented = false; isProtectedDeletionAlertPresented = false
    isDeleteOutcomePresented = false; deleteOutcomeMessage = ""
    isLoadingNextPage = false; isDeleting = false
    transcriptionRequestID = UUID()
    transcriptionState = .idle; transcriptionText = ""; transcriptionTaskID = nil; isTranscriptionModelConfirmationPresented = false; pendingTranscriptionContext = nil
    transcriptionUsesOnlineService = false
    isOnlineTranscriptionConfirmationPresented = false; pendingOnlineTranscriptionContext = nil
    imageTextRecognitionRequestID = UUID(); imageTextRecognitionState = .idle; recognizedImageText = ""; imageTextRecognitionTaskID = nil
    remoteMediaFavoriteState = .idle
    capturedMediaAutoSaveStates = [:]
    capturedMediaAutoSaveFailureMessage = ""
    isCapturedMediaAutoSaveFailurePresented = false
    guard history != nil else { listState = .failed; detailState = .idle; return }
    reload()
  }

  func reload() {
    guard let history else { return }
    let generation = configurationGeneration, requestID = UUID()
    let filter = listFilter
    listRequestID = requestID; pageTask?.cancel(); isLoadingNextPage = false
    listState = .loading; listErrorCode = nil; nextCursor = nil
    pageTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.pageResult(history, cursor: nil, filter: filter)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveInitialPage(result, generation: generation, requestID: requestID)
    }
    reloadAvailableTags(reloadsListIfSelectedTagsDisappear: false)
    reloadNavigationCounts()
  }

  func loadNextPageIfNeeded(after row: HistoryRowProjection) {
    guard rows.last?.taskID == row.taskID, let cursor = nextCursor, !isLoadingNextPage, let history else { return }
    let generation = configurationGeneration, requestID = listRequestID, filter = listFilter
    isLoadingNextPage = true; listErrorCode = nil
    pageTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.pageResult(history, cursor: cursor, filter: filter)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveNextPage(result, generation: generation, requestID: requestID)
    }
  }

  func retryList() { guard canRetryList else { return }; reload() }
  func retryDetail() { loadDetailForSelection() }
  func reveal(taskID: TaskID) { selectedTaskID = taskID; reload() }

  func requestTranscription() {
    transcriptionUsesOnlineService = false
    guard let history, let videoTranscriber, let detail, let fileURL = localMediaFileURL else {
      transcriptionState = .failed("找不到可转写的本机视频。")
      return
    }
    guard !isReadOnly else {
      transcriptionState = .failed("历史记录当前为只读模式，不能保存转写结果。请恢复可写存储后重试。")
      return
    }
    guard fileURL.isFileURL else {
      transcriptionState = .failed(LocalVideoTranscriptionError.invalidLocalFile.userMessage)
      return
    }

    transcriptionTask?.cancel()
    let requestID = UUID()
    transcriptionRequestID = requestID
    guard let mediaID = detail.media?.id else {
      transcriptionState = .failed("找不到可转写的本机视频。")
      return
    }
    transcriptionTaskID = detail.task.id
    transcriptionText = ""
    transcriptionState = .checkingModel
    transcriptionTask = Task { [weak self, worker] in
      guard self?.transcriptionRequestID == requestID else { return }
      let began = await worker.beginTranscription(
        history,
        taskID: detail.task.id,
        mediaID: mediaID
      )
      guard case let .success(attempt) = began else {
        guard !Task.isCancelled, self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = .failed("无法更新本机转写状态，请检查历史存储后重试。")
        return
      }
      let workspaceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("linkdigest-transcription-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
      let context = TranscriptionContext(
        taskID: detail.task.id,
        detail: detail,
        fileURL: fileURL,
        workspaceURL: workspaceURL,
        attempt: attempt
      )
      guard !Task.isCancelled, self?.transcriptionRequestID == requestID else {
        _ = await worker.updateTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: context.attempt,
          status: .none
        )
        self?.onDiscardedTranscriptionAttempt()
        return
      }
      self?.pendingTranscriptionContext = context
      let modelState = await videoTranscriber.modelState(localeIdentifier: "zh_CN")
      guard !Task.isCancelled, self?.transcriptionRequestID == requestID else {
        _ = await worker.updateTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: context.attempt,
          status: .none
        )
        self?.onDiscardedTranscriptionAttempt()
        return
      }
      switch modelState {
      case .ready:
        await self?.runTranscription(context: context, history: history, transcriber: videoTranscriber, requestID: requestID)
      case .requiresDownload:
        guard !Task.isCancelled, self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = .awaitingModelDownload
        self?.isTranscriptionModelConfirmationPresented = true
      case let .unavailable(error):
        guard self?.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: context.attempt,
          status: .failed
        )
        guard self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = .failed(error.userMessage)
      }
    }
  }

  func requestRemoteTranscription(_ descriptor: MediaDescriptor, taskID: TaskID) {
    transcriptionUsesOnlineService = false
    guard let history, let videoTranscriber, let tempStore = transcriptionTempStore,
          let detail, detail.task.id == taskID, selectedTaskID == taskID else {
      transcriptionState = .failed("找不到可转写的当前视频。")
      return
    }
    guard !isReadOnly else {
      transcriptionState = .failed("历史记录当前为只读模式，不能保存转写结果。请恢复可写存储后重试。")
      return
    }
    guard canTranscribeCurrentCapture(descriptor, taskID: taskID) else {
      if descriptor.kind == .hls {
        transcriptionState = .failed("当前 Debug 暂不支持 HLS 转写；请使用直连 MP4/MOV。")
      } else if descriptor.durationSeconds.map({ $0 > TranscriptionTempStore.maximumDurationSeconds }) == true {
        transcriptionState = .failed(LocalVideoTranscriptionError.mediaTooLong.userMessage)
      } else {
        transcriptionState = .failed("当前视频不能安全进行本机转写，请回到浏览器重新发送直连视频。")
      }
      return
    }

    transcriptionTask?.cancel()
    let requestID = UUID()
    transcriptionRequestID = requestID
    transcriptionTaskID = taskID
    transcriptionText = ""
    transcriptionUsesOnlineService = false
    transcriptionState = .preparingMedia
    transcriptionTask = Task { [weak self, worker] in
      guard let self, self.transcriptionRequestID == requestID else { return }
      let createdAt = self.nowMilliseconds()
      let began = await worker.beginTaskTranscription(
        history,
        taskID: taskID,
        createdAtMilliseconds: createdAt
      )
      guard case let .success(attempt) = began else {
        guard !Task.isCancelled, self.transcriptionRequestID == requestID else { return }
        self.transcriptionState = .failed("无法创建本机转写任务；没有下载媒体，也没有启动语音识别。")
        return
      }
      guard !Task.isCancelled, self.transcriptionRequestID == requestID else {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        return
      }
      do {
        let temp = try await tempStore.prepare(descriptor: descriptor)
        // Keep the larger download strictly attempt-scoped, then hand the
        // lightweight M4A to Apple's local transcriber. If an unusual
        // container cannot export, the transcriber receives the original
        // video and retains its existing local fallback behavior.
        let transcriptionInputURL: URL
        do {
          transcriptionInputURL = try await AppleSpeechVideoTranscriber.extractAudio(
            from: temp.fileURL,
            workspaceURL: temp.workspaceURL
          )
        } catch {
          transcriptionInputURL = temp.fileURL
        }
        let context = RemoteTranscriptionContext(
          taskID: taskID,
          detail: detail,
          descriptor: descriptor,
          fileURL: transcriptionInputURL,
          workspaceURL: temp.workspaceURL,
          attempt: attempt,
          tempAttemptID: temp.attemptID
        )
        guard !Task.isCancelled, self.transcriptionRequestID == requestID else {
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: taskID, attempt: attempt, status: .cancelled,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          self.cleanupRemoteTranscription(context)
          return
        }
        self.pendingRemoteTranscriptionContext = context
        self.transcriptionState = .checkingModel
        let modelState = await videoTranscriber.modelState(localeIdentifier: "zh_CN")
        guard !Task.isCancelled, self.transcriptionRequestID == requestID else {
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: taskID, attempt: attempt, status: .cancelled,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          self.cleanupRemoteTranscription(context)
          return
        }
        switch modelState {
        case .ready:
          await self.runRemoteTranscription(
            context: context, history: history, transcriber: videoTranscriber, requestID: requestID
          )
        case .requiresDownload:
          self.transcriptionState = .awaitingModelDownload
          self.isTranscriptionModelConfirmationPresented = true
        case let .unavailable(error):
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: taskID, attempt: attempt, status: .failed,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          self.transcriptionState = .failed(error.userMessage)
          self.cleanupRemoteTranscription(context)
        }
      } catch let error as TranscriptionTempStoreError {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        if case let .cleanupFailed(attemptID) = error {
          self.cleanupRetryAttemptID = attemptID
          self.transcriptionCleanupFailure = error.userMessage
        }
        self.transcriptionState = .failed(error.userMessage)
      } catch let error as LocalVideoTranscriptionError {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.transcriptionState = .failed(error.userMessage)
      } catch let error as MediaDownloadError {
        let terminal: TaskTranscriptionStatusMutation = error == .cancelled ? .cancelled : .failed
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: terminal,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.transcriptionState = error == .cancelled ? .cancelled : .failed(error.userMessage)
      } catch {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.transcriptionState = .failed(TranscriptionTempStoreError.unavailable.userMessage)
      }
    }
  }

  /// Online fallback for a large direct-file capture. Nothing is sent until
  /// the confirmation alert calls `confirmOnlineTranscription`.
  func requestOnlineTranscription(_ descriptor: MediaDescriptor, taskID: TaskID, model: String?) {
    guard let detail, detail.task.id == taskID,
          let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
          canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: model),
          let rawURL = descriptor.ephemeralPlaybackURL,
          let mediaURL = URL(string: rawURL) else {
      transcriptionState = .failed(OnlineAudioTranscriptionError.modelNotConfigured.userMessage)
      return
    }
    pendingOnlineTranscriptionContext = .init(
      taskID: taskID,
      detail: detail,
      mediaURL: mediaURL,
      platform: descriptor.platform,
      model: model
    )
    isOnlineTranscriptionConfirmationPresented = true
  }

  /// 已存任务的本机视频也能走在线转写：音频分片从本地文件提取后上传，
  /// 拿到 Whisper 级准确率和完整标点。与捕获现场共用同意弹窗与保存链路。
  func canTranscribeLocalMediaOnline(taskID: TaskID, model: String?) -> Bool {
    history != nil
      && onlineAudioTranscriber != nil
      && !isReadOnly
      && detail?.task.id == taskID
      && localMediaFileURL?.isFileURL == true
      && !transcriptionState.isActive
      && model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  func requestOnlineTranscriptionFromLocalMedia(taskID: TaskID, model: String?) {
    guard let detail, detail.task.id == taskID,
          let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
          canTranscribeLocalMediaOnline(taskID: taskID, model: model),
          let fileURL = localMediaFileURL else {
      transcriptionState = .failed(OnlineAudioTranscriptionError.modelNotConfigured.userMessage)
      return
    }
    pendingOnlineTranscriptionContext = .init(
      taskID: taskID,
      detail: detail,
      mediaURL: fileURL,
      platform: detail.media?.platform ?? detail.snapshots.last?.platform ?? "local_video",
      model: model
    )
    isOnlineTranscriptionConfirmationPresented = true
  }

  func cancelOnlineTranscriptionConfirmation() {
    isOnlineTranscriptionConfirmationPresented = false
    pendingOnlineTranscriptionContext = nil
  }

  func transcriptTidyState(for taskID: TaskID) -> TranscriptTidyUIState {
    transcriptTidyTaskID == taskID ? transcriptTidyState : .idle
  }

  func transcriptTidyTokenSummary(for taskID: TaskID) -> String? {
    transcriptTidyTaskID == taskID ? transcriptTidyTokenSummary : nil
  }

  private static func tidyTokenSummary(_ outcome: TranscriptTidyOutcome) -> String? {
    guard let total = outcome.totalTokens else { return nil }
    if let prompt = outcome.promptTokens, let completion = outcome.completionTokens {
      return "\(total) tokens（输入 \(prompt) / 输出 \(completion)）"
    }
    return "\(total) tokens"
  }

  /// The latest persisted transcript snapshot. Tidy re-reads it from the
  /// detail projection instead of the streaming buffer so a tidy after
  /// relaunch works on exactly what history shows.
  private static func latestTranscriptText(in detail: HistoryDetailProjection) -> String? {
    let text = detail.snapshots.last(where: {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    })?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }

  /// 刚完成的转写优先用流式缓冲：detail 快照要等一次异步刷新才包含新稿，
  /// 「转写后自动整理」不能因为这个窗口而空转。
  private func tidySourceText(taskID: TaskID) -> String? {
    if transcriptionTaskID == taskID, transcriptionState == .completed {
      let text = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return text }
    }
    guard let detail, detail.task.id == taskID else { return nil }
    return Self.latestTranscriptText(in: detail)
  }

  func canTidyTranscript(taskID: TaskID) -> Bool {
    guard let detail, history != nil, transcriptTidier != nil, !isReadOnly,
          detail.task.id == taskID,
          !transcriptionState(for: taskID).isActive,
          !transcriptTidyState(for: taskID).isActive else { return false }
    return tidySourceText(taskID: taskID) != nil
  }

  func requestTranscriptTidy(taskID: TaskID, model: String?) {
    guard let detail, detail.task.id == taskID, canTidyTranscript(taskID: taskID),
          let text = tidySourceText(taskID: taskID) else {
      transcriptTidyTaskID = taskID
      transcriptTidyState = .failed(TranscriptTidyError.emptyTranscript.userMessage)
      return
    }
    pendingTranscriptTidyContext = .init(
      taskID: taskID,
      detail: detail,
      text: text,
      platform: detail.media?.platform ?? detail.snapshots.last?.platform ?? "local_video",
      model: model?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    isTranscriptTidyConfirmationPresented = true
  }

  func cancelTranscriptTidyConfirmation() {
    isTranscriptTidyConfirmationPresented = false
    pendingTranscriptTidyContext = nil
  }

  func confirmTranscriptTidy() {
    isTranscriptTidyConfirmationPresented = false
    guard let history, let transcriptTidier, let context = pendingTranscriptTidyContext,
          selectedTaskID == context.taskID else {
      pendingTranscriptTidyContext = nil
      transcriptTidyState = .failed(TranscriptTidyError.emptyTranscript.userMessage)
      return
    }
    pendingTranscriptTidyContext = nil
    transcriptTidyTask?.cancel()
    let requestID = UUID()
    transcriptTidyRequestID = requestID
    transcriptTidyTaskID = context.taskID
    transcriptTidyState = .running
    transcriptTidyTokenSummary = nil
    transcriptTidyTask = Task { [weak self, worker] in
      guard let self, self.transcriptTidyRequestID == requestID else { return }
      let began = await worker.beginTaskTranscription(
        history,
        taskID: context.taskID,
        createdAtMilliseconds: self.nowMilliseconds()
      )
      guard case let .success(attempt) = began else {
        guard self.transcriptTidyRequestID == requestID else { return }
        self.transcriptTidyState = .failed("无法创建整理任务；文字没有发送。")
        return
      }
      let running = await worker.updateTaskTranscriptionStatus(
        history,
        taskID: context.taskID,
        attempt: attempt,
        status: .running,
        updatedAtMilliseconds: self.nowMilliseconds()
      )
      guard self.transcriptTidyRequestID == requestID, case .applied = running else {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: context.taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        return
      }
      do {
        let outcome = try await transcriptTidier.tidy(text: context.text, model: context.model)
        try Task.checkCancellation()
        guard self.transcriptTidyRequestID == requestID else { return }
        let persisted = await worker.saveTidiedTranscript(
          history,
          taskID: context.taskID,
          attempt: attempt,
          detail: context.detail,
          text: outcome.text,
          platform: context.platform,
          model: context.model ?? "configured_model",
          receivedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptTidyRequestID == requestID else { return }
        switch persisted {
        case .applied:
          self.transcriptTidyState = .completed
          self.transcriptTidyTokenSummary = Self.tidyTokenSummary(outcome)
          self.refreshDetailAfterTranscription(taskID: context.taskID)
        case .replay, .stale:
          self.transcriptTidyState = .failed("这次整理已被更新的请求替代，请重试。")
        case .failure:
          self.transcriptTidyState = .failed("整理结果未能保存到本机历史，请重试。原始转写稿未受影响。")
        }
      } catch {
        let cancelled = error is CancellationError || (error as? TranscriptTidyError) == .cancelled
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: context.taskID, attempt: attempt,
          status: cancelled ? .cancelled : .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptTidyRequestID == requestID else { return }
        if cancelled {
          self.transcriptTidyState = .cancelled
        } else if let failure = error as? TranscriptTidyError {
          self.transcriptTidyState = .failed(failure.userMessage)
        } else {
          self.transcriptTidyState = .failed(TranscriptTidyError.responseRejected.userMessage)
        }
      }
    }
  }

  func confirmOnlineTranscription() {
    isOnlineTranscriptionConfirmationPresented = false
    guard let history, let onlineAudioTranscriber, let context = pendingOnlineTranscriptionContext,
          selectedTaskID == context.taskID else {
      pendingOnlineTranscriptionContext = nil
      transcriptionState = .failed(OnlineAudioTranscriptionError.mediaURLInvalid.userMessage)
      return
    }
    let mediaURL = context.mediaURL
    pendingOnlineTranscriptionContext = nil
    transcriptionTask?.cancel()
    let requestID = UUID()
    transcriptionRequestID = requestID
    transcriptionTaskID = context.taskID
    transcriptionText = ""
    transcriptionUsesOnlineService = true
    transcriptionState = .preparingMedia
    transcriptionTask = Task { [weak self, worker] in
      guard let self, self.transcriptionRequestID == requestID else { return }
      let began = await worker.beginTaskTranscription(
        history,
        taskID: context.taskID,
        createdAtMilliseconds: self.nowMilliseconds()
      )
      guard case let .success(attempt) = began else {
        guard self.transcriptionRequestID == requestID else { return }
        self.transcriptionState = .failed("无法创建在线转写任务；媒体没有发送。")
        return
      }
      let running = await worker.updateTaskTranscriptionStatus(
        history,
        taskID: context.taskID,
        attempt: attempt,
        status: .running,
        updatedAtMilliseconds: self.nowMilliseconds()
      )
      guard self.transcriptionRequestID == requestID, case .applied = running else {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: context.taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        return
      }
      self.transcriptionState = .transcribing
      do {
        let text = try await onlineAudioTranscriber.transcribe(
          remoteMediaURL: mediaURL,
          model: context.model,
          language: "zh"
        )
        try Task.checkCancellation()
        guard self.transcriptionRequestID == requestID else { return }
        self.transcriptionText = text
        let completedAt = self.nowMilliseconds()
        let persisted = await worker.saveOnlineTaskTranscription(
          history,
          taskID: context.taskID,
          attempt: attempt,
          detail: context.detail,
          text: text,
          platform: context.platform,
          provider: "configured_provider",
          model: context.model,
          receivedAtMilliseconds: completedAt
        )
        guard self.transcriptionRequestID == requestID else { return }
        switch persisted {
        case .applied:
          self.transcriptionState = .completed
          self.refreshDetailAfterTranscription(taskID: context.taskID)
        case .replay, .stale:
          self.transcriptionState = .failed("这次在线转写已被更新的请求替代，请重试。")
        case .failure:
          self.transcriptionState = .failed("在线转写文字未能保存到本机历史，请重试。")
        }
      } catch {
        let cancelled = error is CancellationError || (error as? OnlineAudioTranscriptionError) == .cancelled
        _ = await worker.updateTaskTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: attempt,
          status: cancelled ? .cancelled : .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptionRequestID == requestID else { return }
        if cancelled {
          self.transcriptionState = .cancelled
        } else if let online = error as? OnlineAudioTranscriptionError {
          self.transcriptionState = .failed(online.userMessage)
        } else {
          self.transcriptionState = .failed(OnlineAudioTranscriptionError.networkInterrupted.userMessage)
        }
      }
    }
  }

  /// This is the only UI path allowed to call model installation.
  func confirmModelDownloadAndTranscribe() {
    isTranscriptionModelConfirmationPresented = false
    if let context = pendingRemoteTranscriptionContext {
      confirmRemoteModelDownloadAndTranscribe(context)
      return
    }
    guard let history, let videoTranscriber, let context = pendingTranscriptionContext else { return }
    let requestID = transcriptionRequestID
    transcriptionTask?.cancel()
    transcriptionState = .preparingModel
    transcriptionTask = Task { [weak self, worker] in
      do {
        try await videoTranscriber.downloadModel(localeIdentifier: "zh_CN")
        try Task.checkCancellation()
        await self?.runTranscription(context: context, history: history, transcriber: videoTranscriber, requestID: requestID)
      } catch is CancellationError {
        guard self?.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: .none)
        guard self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = .cancelled
      } catch let error as LocalVideoTranscriptionError {
        let status: TranscriptionStatusMutation = error == .cancelled ? .none : .failed
        guard self?.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: status)
        guard self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = error == .cancelled ? .cancelled : .failed(error.userMessage)
      } catch {
        guard self?.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: .failed)
        guard self?.transcriptionRequestID == requestID else { return }
        self?.transcriptionState = .failed(LocalVideoTranscriptionError.modelDownloadFailed.userMessage)
      }
    }
  }

  func cancelModelDownloadConfirmation() {
    isTranscriptionModelConfirmationPresented = false
    if let context = pendingRemoteTranscriptionContext, let history {
      let requestID = transcriptionRequestID
      transcriptionTask = Task { [weak self, worker] in
        guard let self, self.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTaskTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: context.attempt,
          status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptionRequestID == requestID else { return }
        self.transcriptionState = .cancelled
        self.cleanupRemoteTranscription(context)
      }
      return
    }
    guard let history, let context = pendingTranscriptionContext else {
      transcriptionState = .idle
      return
    }
    let requestID = transcriptionRequestID
    transcriptionTask = Task { [weak self, worker] in
      guard self?.transcriptionRequestID == requestID else { return }
      _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: .none)
      guard self?.transcriptionRequestID == requestID else { return }
      self?.transcriptionState = .cancelled
    }
  }

  func cancelTranscription() {
    isTranscriptionModelConfirmationPresented = false
    transcriptionTask?.cancel()
  }

  func retryTranscription() { requestTranscription() }

  func retryRemoteTranscription(_ descriptor: MediaDescriptor, taskID: TaskID) {
    requestRemoteTranscription(descriptor, taskID: taskID)
  }

  func retryTranscriptionCleanup() {
    guard let store = transcriptionTempStore else { return }
    do {
      if let attemptID = cleanupRetryAttemptID, attemptID != "startup" {
        try store.cleanup(attemptID: attemptID)
      } else {
        try store.cleanupAll()
      }
      cleanupRetryAttemptID = nil
      transcriptionCleanupFailure = nil
    } catch let error as TranscriptionTempStoreError {
      transcriptionCleanupFailure = error.userMessage
    } catch {
      transcriptionCleanupFailure = TranscriptionTempStoreError.unavailable.userMessage
    }
  }

  var canFavoriteCurrentCaptureMedia: Bool {
    history != nil && !isReadOnly && detail != nil && localMediaFileURL == nil
      && remoteMediaFavoriteState != .saving && remoteMediaFavoriteState != .saved
  }

  func favoriteCurrentCaptureMedia(
    _ descriptor: MediaDescriptor,
    taskID: TaskID,
    snapshotID: ContentSnapshotID
  ) async {
    guard selectedTaskID == taskID, detail?.task.id == taskID else { return }
    guard canFavoriteCurrentCaptureMedia else { return }
    guard let media = CurrentCaptureMediaPreview.favoriteMedia(descriptor) else {
      remoteMediaFavoriteState = .failed(
        CurrentCaptureMediaPreview.favoriteUnavailableMessage(descriptor)
      )
      return
    }

    remoteMediaFavoriteState = .saving
    do {
      let asset = try await downloadAndAttachMedia(
        media,
        taskID: taskID,
        snapshotID: snapshotID,
        pageURL: descriptor.pageURL
      )
      revealAttachedMedia(asset, taskID: taskID)
      guard selectedTaskID == taskID else { return }
      remoteMediaFavoriteState = .saved
    } catch let error as MediaDownloadError {
      guard selectedTaskID == taskID else { return }
      remoteMediaFavoriteState = .failed(error.userMessage)
    } catch {
      guard selectedTaskID == taskID else { return }
      remoteMediaFavoriteState = .failed("保存失败。本地历史没有附加视频，请检查视频存储设置后重试。")
    }
  }

  private func confirmRemoteModelDownloadAndTranscribe(_ context: RemoteTranscriptionContext) {
    guard let history, let videoTranscriber else { return }
    let requestID = transcriptionRequestID
    transcriptionTask?.cancel()
    transcriptionState = .preparingModel
    transcriptionTask = Task { [weak self, worker] in
      guard let self else { return }
      do {
        try await videoTranscriber.downloadModel(localeIdentifier: "zh_CN")
        try Task.checkCancellation()
        await self.runRemoteTranscription(
          context: context,
          history: history,
          transcriber: videoTranscriber,
          requestID: requestID
        )
      } catch {
        guard self.transcriptionRequestID == requestID else { return }
        let cancelled = error is CancellationError || (error as? LocalVideoTranscriptionError) == .cancelled
        _ = await worker.updateTaskTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: context.attempt,
          status: cancelled ? .cancelled : .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptionRequestID == requestID else { return }
        self.transcriptionState = cancelled
          ? .cancelled
          : .failed((error as? LocalVideoTranscriptionError)?.userMessage
            ?? LocalVideoTranscriptionError.modelDownloadFailed.userMessage)
        self.cleanupRemoteTranscription(context)
      }
    }
  }

  private func runRemoteTranscription(
    context: RemoteTranscriptionContext,
    history: HistoryApplicationService,
    transcriber: any LocalVideoTranscribing,
    requestID: UUID
  ) async {
    guard transcriptionRequestID == requestID else { return }
    let running = await worker.updateTaskTranscriptionStatus(
      history,
      taskID: context.taskID,
      attempt: context.attempt,
      status: .running,
      updatedAtMilliseconds: nowMilliseconds()
    )
    guard transcriptionRequestID == requestID else {
      _ = await worker.updateTaskTranscriptionStatus(
        history,
        taskID: context.taskID,
        attempt: context.attempt,
        status: .cancelled,
        updatedAtMilliseconds: nowMilliseconds()
      )
      cleanupRemoteTranscription(context)
      return
    }
    guard case .applied = running else {
      transcriptionState = .failed("无法更新本机转写状态，请检查历史存储后重试。")
      cleanupRemoteTranscription(context)
      return
    }

    do {
      var finalText = ""
      for try await event in transcriber.transcribe(fileURL: context.fileURL, workspaceURL: context.workspaceURL, localeIdentifier: "zh_CN") {
        try Task.checkCancellation()
        guard transcriptionRequestID == requestID else { return }
        switch event {
        case .extractingAudio: transcriptionState = .extractingAudio
        case .transcribing: transcriptionState = .transcribing
        case let .partial(text): transcriptionText = text
        case let .final(text): finalText = text; transcriptionText = text
        }
      }
      try Task.checkCancellation()
      let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw LocalVideoTranscriptionError.emptyTranscript }
      guard transcriptionRequestID == requestID else { return }
      let completedAt = nowMilliseconds()
      let persisted = await worker.saveTaskTranscription(
        history,
        taskID: context.taskID,
        attempt: context.attempt,
        detail: context.detail,
        text: trimmed,
        platform: context.descriptor.platform,
        receivedAtMilliseconds: completedAt
      )
      guard transcriptionRequestID == requestID else { return }
      switch persisted {
      case .applied:
        transcriptionState = .completed
        pendingRemoteTranscriptionContext = nil
        refreshDetailAfterTranscription(taskID: context.taskID)
      case .replay, .stale:
        onDiscardedTranscriptionAttempt()
        transcriptionState = .failed("这次转写已被更新的请求替代，请重试。")
      case .failure:
        throw RepositoryFailure.unavailable
      }
      cleanupRemoteTranscription(context)
    } catch {
      guard transcriptionRequestID == requestID else {
        cleanupRemoteTranscription(context)
        return
      }
      let cancelled = error is CancellationError || (error as? LocalVideoTranscriptionError) == .cancelled
      _ = await worker.updateTaskTranscriptionStatus(
        history,
        taskID: context.taskID,
        attempt: context.attempt,
        status: cancelled ? .cancelled : .failed,
        updatedAtMilliseconds: nowMilliseconds()
      )
      guard transcriptionRequestID == requestID else {
        cleanupRemoteTranscription(context)
        return
      }
      if cancelled {
        transcriptionState = .cancelled
      } else if let local = error as? LocalVideoTranscriptionError {
        transcriptionState = .failed(local.userMessage)
      } else {
        transcriptionState = .failed("转写文字未能保存到本机历史，请检查存储后重试。")
      }
      cleanupRemoteTranscription(context)
    }
  }

  private func cleanupRemoteTranscription(_ context: RemoteTranscriptionContext) {
    guard let store = transcriptionTempStore else { return }
    do {
      try store.cleanup(attemptID: context.tempAttemptID)
      if cleanupRetryAttemptID == context.tempAttemptID {
        cleanupRetryAttemptID = nil
        transcriptionCleanupFailure = nil
      }
    } catch let error as TranscriptionTempStoreError {
      cleanupRetryAttemptID = context.tempAttemptID
      transcriptionCleanupFailure = error.userMessage
    } catch {
      cleanupRetryAttemptID = context.tempAttemptID
      transcriptionCleanupFailure = TranscriptionTempStoreError.unavailable.userMessage
    }
  }

  private func runTranscription(
    context: TranscriptionContext,
    history: HistoryApplicationService,
    transcriber: any LocalVideoTranscribing,
    requestID: UUID
  ) async {
    guard transcriptionRequestID == requestID else { return }
    let running = await worker.updateTranscriptionStatus(
      history,
      taskID: context.taskID,
      attempt: context.attempt,
      status: .running
    )
    guard transcriptionRequestID == requestID else {
      _ = await worker.updateTranscriptionStatus(
        history,
        taskID: context.taskID,
        attempt: context.attempt,
        status: .none
      )
      onDiscardedTranscriptionAttempt()
      return
    }
    guard case .applied = running else {
      transcriptionState = .failed("无法更新本机转写状态，请检查历史存储后重试。")
      return
    }
    do {
      var finalText = ""
      for try await event in transcriber.transcribe(fileURL: context.fileURL, workspaceURL: context.workspaceURL, localeIdentifier: "zh_CN") {
        try Task.checkCancellation()
        guard transcriptionRequestID == requestID else { return }
        switch event {
        case .extractingAudio: transcriptionState = .extractingAudio
        case .transcribing: transcriptionState = .transcribing
        case let .partial(text): transcriptionText = text
        case let .final(text): finalText = text; transcriptionText = text
        }
      }
      try Task.checkCancellation()
      let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw LocalVideoTranscriptionError.emptyTranscript }
      guard transcriptionRequestID == requestID else { return }
      let completedAtMilliseconds = nowMilliseconds()
      let persisted = await worker.saveTranscription(
        history,
        taskID: context.taskID,
        attempt: context.attempt,
        detail: context.detail,
        text: trimmed,
        receivedAtMilliseconds: completedAtMilliseconds
      )
      guard transcriptionRequestID == requestID else { return }
      switch persisted {
      case .applied:
        break
      case .replay, .stale:
        onDiscardedTranscriptionAttempt()
        transcriptionState = .failed("这次转写已被更新的请求替代，请重试。")
        return
      case .failure:
        throw RepositoryFailure.unavailable
      }
      transcriptionState = .completed
      pendingTranscriptionContext = nil
      refreshDetailAfterTranscription(taskID: context.taskID)
    } catch is CancellationError {
      guard transcriptionRequestID == requestID else { return }
      _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: .none)
      guard transcriptionRequestID == requestID else { return }
      transcriptionState = .cancelled
    } catch let error as LocalVideoTranscriptionError {
      let status: TranscriptionStatusMutation = error == .cancelled ? .none : .failed
      guard transcriptionRequestID == requestID else { return }
      _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: status)
      guard transcriptionRequestID == requestID else { return }
      transcriptionState = error == .cancelled ? .cancelled : .failed(error.userMessage)
    } catch {
      guard transcriptionRequestID == requestID else { return }
      _ = await worker.updateTranscriptionStatus(history, taskID: context.taskID, attempt: context.attempt, status: .failed)
      guard transcriptionRequestID == requestID else { return }
      transcriptionState = .failed("转写文字未能保存到本机历史，请检查存储后重试。")
    }
    try? FileManager.default.removeItem(at: context.workspaceURL)
  }

  /// Refreshes only durable metadata changed outside a direct History UI
  /// action (for example a successful automatic-tag side request). It does
  /// not rerun the paged list query or alter any Run/UI error state.
  func historyMetadataChanged(taskID: TaskID) {
    // Global chips are independent of the selected detail. In particular, a
    // background task's automatic tags must never take ownership of, cancel,
    // or otherwise disturb the detail currently being viewed.
    reloadAvailableTags(reloadsListIfSelectedTagsDisappear: false)
    reloadNavigationCounts()
    guard selectedTaskID == taskID, let history else { return }

    // Metadata and ordinary selection reads share one identity and one task.
    // A late ordinary read therefore cannot overwrite this fresher metadata.
    let generation = configurationGeneration, requestID = UUID()
    detailRequestID = requestID
    detailTask?.cancel()
    detailTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Self.detailResult(history, taskID: taskID)
      }.value
      guard !Task.isCancelled else { return }
      // This request replaced the ordinary detail request, so it must also
      // complete that request's visible state machine on both success/failure.
      self?.receiveDetail(result, taskID: taskID, generation: generation, requestID: requestID)
    }
  }
  func toggleTag(_ tag: HistoryTag, additive: Bool) {
    let key = tag.normalizedName
    if additive {
      if selectedTagNormalizedNames.contains(key) { selectedTagNormalizedNames.remove(key) }
      else { selectedTagNormalizedNames.insert(key) }
    } else if selectedTagNormalizedNames == [key] {
      selectedTagNormalizedNames = []
    } else {
      selectedTagNormalizedNames = [key]
    }
    selectedHosts = []
    selectedScope = .all
    reload()
  }

  func selectScope(_ scope: HistoryListScope) {
    selectedScope = scope
    selectedHosts = []
    selectedTagNormalizedNames = []
    reload()
  }

  func selectHost(_ host: String) {
    let normalized = HistoryHostNormalizer.normalized(host)
    guard !normalized.isEmpty else { return }
    if selectedHosts == [normalized] {
      selectedHosts = []
    } else {
      selectedHosts = [normalized]
    }
    selectedScope = .all
    selectedTagNormalizedNames = []
    reload()
  }

  /// 侧边栏"待分类"聚合：一次筛选全部非知名平台的杂项来源。
  /// 再次点击同一组合时取消筛选，与单平台的开关行为一致。
  func selectHosts(_ hosts: [String]) {
    let normalized = Set(hosts.map(HistoryHostNormalizer.normalized).filter { !$0.isEmpty })
    guard !normalized.isEmpty else { return }
    if selectedHosts == normalized {
      selectedHosts = []
    } else {
      selectedHosts = normalized
    }
    selectedScope = .all
    selectedTagNormalizedNames = []
    reload()
  }

  func addTag(_ rawName: String) {
    guard
      let history,
      let taskID = selectedTaskID,
      canEditTags,
      HistoryTagNormalizer.normalized(rawName) != nil
    else { return }
    let generation = configurationGeneration
    tagMutationTask?.cancel(); tagErrorCode = nil
    tagMutationTask = Task { [weak self, worker] in
      let result = await worker.addTag(history, rawName: rawName, taskID: taskID)
      guard !Task.isCancelled else { return }
      self?.receiveTagMutation(result, taskID: taskID, generation: generation)
    }
  }

  func removeTag(_ tag: HistoryTag) {
    guard let history, let taskID = selectedTaskID, canEditTags else { return }
    let generation = configurationGeneration
    tagMutationTask?.cancel(); tagErrorCode = nil
    tagMutationTask = Task { [weak self, worker] in
      let result = await worker.removeTag(history, normalizedName: tag.normalizedName, taskID: taskID)
      guard !Task.isCancelled else { return }
      self?.receiveTagMutation(result, taskID: taskID, generation: generation)
    }
  }

  func suggestedTags(matching input: String, excluding assigned: [HistoryTag]) -> [HistoryTag] {
    let needle = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let assignedNames = Set(assigned.map(\.normalizedName))
    return availableTags.filter {
      !assignedNames.contains($0.normalizedName)
        && (needle.isEmpty || $0.name.lowercased().contains(needle))
    }
  }
  func requestExport(_ format: HistoryExportFormat) {
    guard let history, let taskID = selectedTaskID, !isPreparingExport else { return }
    let generation = configurationGeneration, requestID = UUID()
    exportRequestID = requestID
    isPreparingExport = true; exportFile = nil
    isExportPanelPresented = false; isExportPreparationFailurePresented = false; isExportSaveFailurePresented = false
    exportTask = Task { [weak self, worker] in
      let result = await worker.export(history, taskID: taskID, format: format)
      guard !Task.isCancelled else { return }
      self?.receiveExport(result, taskID: taskID, generation: generation, requestID: requestID)
    }
  }

  /// 拷贝全文与富格式导出共用：与 .md 导出同源的完整 Markdown 及文件名。
  /// 同步读仓库（导出投影很小）；失败返回 nil 由调用方走既有导出失败提示。
  /// 导出/拷贝全文用的**干净正文**——与 App 阅读区一致：只含标题、最小
  /// frontmatter（作者/发布/来源）与正文，不含 Core 档案的运行记录、导出
  /// 版本、UTC 捕获时间等内部元数据。优先原文 snapshot（非转写），回退最新。
  func composeExportMarkdown() -> (baseFilename: String, markdown: String)? {
    guard let detail else { return nil }
    let transcriptionKind = CapturedDocument.Origin.localTranscription.rawValue
    let snapshot = detail.snapshots.last(where: { $0.sourceKind != transcriptionKind })
      ?? detail.snapshots.last
    guard let snapshot else { return nil }
    let note = MarkdownNoteFrontmatter.parse(snapshot.bodyText)
    let body = note.body.isEmpty ? snapshot.bodyText : note.body
    func nonEmpty(_ value: String?) -> String? {
      guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
      return trimmed
    }
    let title = nonEmpty(snapshot.title)
      ?? CapturedDocumentTitle.display(nil, for: detail.task.canonicalURL)

    var lines: [String] = ["---", "title: \(yamlQuoted(title))", "source: \(yamlQuoted(detail.task.canonicalURL))"]
    if let author = nonEmpty(note.author) { lines.append("author: \(yamlQuoted(author))") }
    if let published = nonEmpty(note.published) { lines.append("published: \(yamlQuoted(published))") }
    lines.append("---")
    lines.append("")
    lines.append("# \(title)")
    lines.append("")
    lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))

    let base = sanitizedExportFilename(title)
    return (base, lines.joined(separator: "\n"))
  }

  private func yamlQuoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  private func sanitizedExportFilename(_ title: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = cleaned.isEmpty ? "导出" : String(cleaned.prefix(80))
    return bounded
  }

  func cancelExport() { invalidateExportPreparation() }
  func completeExportSave() {
    exportFile = nil
    isExportPanelPresented = false
    isExportSaveFailurePresented = false
  }
  func failExportSave() {
    exportFile = nil
    isExportPanelPresented = false
    isExportSaveFailurePresented = true
  }
  func dismissExportPreparationFailure() { isExportPreparationFailurePresented = false }
  func dismissExportSaveFailure() { isExportSaveFailurePresented = false }
  func requestDeletion(protectedTaskIDs: Set<TaskID> = []) {
    guard canDelete else { return }
    let protected = selectedTaskIDs.intersection(protectedTaskIDs)
    guard selectedTaskIDs.subtracting(protected).isEmpty == false else {
      isProtectedDeletionAlertPresented = true
      return
    }
    pendingDeletionTaskIDs = selectedTaskIDs
    pendingProtectedDeletionTaskIDs = protected
    isDeleteConfirmationPresented = true
  }
  func requestDeletion(protectedTaskID: TaskID?) {
    requestDeletion(protectedTaskIDs: Set(protectedTaskID.map { [$0] } ?? []))
  }

  func cancelDeletion() {
    pendingDeletionTaskIDs = []
    pendingProtectedDeletionTaskIDs = []
    isDeleteConfirmationPresented = false
  }
  func dismissDeleteFailure() { isDeleteFailurePresented = false }
  func dismissProtectedDeletionAlert() { isProtectedDeletionAlertPresented = false }
  func dismissDeleteOutcome() { isDeleteOutcomePresented = false; deleteOutcomeMessage = "" }

  func confirmDeletion(protectedTaskIDs: Set<TaskID> = []) {
    guard !pendingDeletionTaskIDs.isEmpty, let history, !isReadOnly, !isDeleting else {
      pendingDeletionTaskIDs = []
      pendingProtectedDeletionTaskIDs = []
      isDeleteConfirmationPresented = false
      return
    }
    let protected = pendingDeletionTaskIDs.intersection(protectedTaskIDs)
    let taskIDs = pendingDeletionTaskIDs.subtracting(protected)
    guard !taskIDs.isEmpty else {
      pendingDeletionTaskIDs = []
      pendingProtectedDeletionTaskIDs = []
      isDeleteConfirmationPresented = false
      isProtectedDeletionAlertPresented = true
      return
    }
    let generation = configurationGeneration, requestID = UUID()
    deleteRequestID = requestID; isDeleteConfirmationPresented = false; isDeleting = true; deleteErrorCode = nil
    deleteTask = Task { [weak self, worker] in
      let result = await worker.delete(history, taskIDs: taskIDs)
      if case let .success(batch, mediaToCleanup) = result, let store = self?.mediaStore {
        // Fail closed: if the repository cannot prove the content hash is no
        // longer referenced, retain the shared file for a later safe cleanup.
        var checkedHashes: Set<String> = []
        for asset in mediaToCleanup
        where batch.deletedTaskIDs.contains(asset.taskID)
          && checkedHashes.insert(asset.contentSHA256).inserted {
          do {
            let stillReferenced = try history.isMediaContentReferenced(contentSHA256: asset.contentSHA256)
            store.deleteFileIfUnreferenced(asset: asset, stillReferenced: stillReferenced)
          } catch {
            // The task row is already deleted, but an uncertain reference query
            // must never be converted into permission to unlink shared media.
          }
        }
      }
      guard !Task.isCancelled else { return }
      self?.receiveDeletion(
        result,
        protectedCount: protected.count,
        generation: generation,
        requestID: requestID
      )
    }
  }
  func confirmDeletion(protectedTaskID: TaskID?) {
    confirmDeletion(protectedTaskIDs: Set(protectedTaskID.map { [$0] } ?? []))
  }

  private func receiveInitialPage(_ result: PageResult, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == listRequestID else { return }
    switch result {
    case let .success(page):
      rows = page.rows; nextCursor = page.nextCursor; listState = page.rows.isEmpty ? .empty : .loaded
      loadFavicons(for: page.rows, generation: generation)
      if page.rows.isEmpty {
        selectedTaskIDs = []; detail = nil; detailState = .idle
      } else if selectedTaskIDs.isEmpty {
        selectedTaskID = rows.first?.taskID
      } else {
        let visible = Set(rows.map(\.taskID))
        selectedTaskIDs.formIntersection(visible)
        if selectedTaskID != nil { loadDetailForSelection() }
        else { detail = nil; detailState = .idle }
      }
    case let .failure(code):
      listState = .failed; listErrorCode = code; rows = []; selectedTaskIDs = []; detail = nil; detailState = .idle
    }
  }

  private func receiveNextPage(_ result: PageResult, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == listRequestID else { return }
    isLoadingNextPage = false
    switch result {
    case let .success(page):
      let existing = Set(rows.map(\.taskID)); let additions = page.rows.filter { !existing.contains($0.taskID) }
      rows.append(contentsOf: additions); nextCursor = page.nextCursor
      loadFavicons(for: additions, generation: generation)
    case let .failure(code): listErrorCode = code
    }
  }

  private func loadDetailForSelection() {
    invalidateExportPreparation()
    localMediaLease = nil
    localMediaFileURL = nil
    localMediaResolutionFailure = nil
    guard let history, let taskID = selectedTaskID else {
      detail = nil
      localImageURLs = []
      localMediaFileURL = nil
      detailState = .idle
      return
    }
    let generation = configurationGeneration, requestID = UUID()
    detailRequestID = requestID; detailTask?.cancel(); detail = nil; detailErrorCode = nil; detailState = .loading
    detailTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.detailResult(history, taskID: taskID)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveDetail(result, taskID: taskID, generation: generation, requestID: requestID)
    }
  }

  /// 用户校对转写文本后的原地保存：成功即刷新详情，失败给人话反馈。
  func saveEditedSnapshotText(taskID: TaskID, snapshotID: ContentSnapshotID, bodyText: String) {
    guard let history else { return }
    do {
      try history.updateSnapshotBodyText(
        taskID: taskID,
        snapshotID: snapshotID,
        bodyText: bodyText,
        updatedAtMilliseconds: nowMilliseconds()
      )
      snapshotEditFailure = nil
      refreshDetailAfterTranscription(taskID: taskID)
    } catch {
      snapshotEditFailure = "无法保存修改，请检查历史存储后重试。"
    }
  }

  func dismissSnapshotEditFailure() { snapshotEditFailure = nil }

  var canLiveTranscribePlayback: Bool { livePlaybackTranscribe != nil }

  /// YouTube 无字幕视频：捕获内嵌播放器音频实时转写。调用方须先让视频
  /// 开始播放。转写文本落库为该任务的本机转写 snapshot（与抖音同路径）。
  func startLivePlaybackTranscription(detail: HistoryDetailProjection, platform: String) {
    guard let history, let livePlaybackTranscribe else { return }
    let taskID = detail.task.id
    transcriptionTask?.cancel()
    livePlaybackStopContinuation?.finish()
    let requestID = UUID()
    transcriptionRequestID = requestID
    transcriptionTaskID = taskID
    transcriptionText = ""
    transcriptionUsesOnlineService = false
    transcriptionState = .transcribing
    let (stopSignal, stopContinuation) = AsyncStream.makeStream(of: Void.self)
    livePlaybackStopContinuation = stopContinuation
    transcriptionTask = Task { [weak self, worker] in
      guard let self, self.transcriptionRequestID == requestID else { return }
      let createdAt = self.nowMilliseconds()
      let began = await worker.beginTaskTranscription(history, taskID: taskID, createdAtMilliseconds: createdAt)
      guard case let .success(attempt) = began else {
        guard !Task.isCancelled, self.transcriptionRequestID == requestID else { return }
        self.transcriptionState = .failed("无法创建本机转写任务。")
        return
      }
      do {
        var latest = ""
        for try await event in livePlaybackTranscribe("zh_CN", stopSignal) {
          try Task.checkCancellation()
          guard self.transcriptionRequestID == requestID else { break }
          switch event {
          case .partial(let text):
            latest = text
            self.transcriptionText = text
          case .final(let text):
            latest = text
          case .transcribing:
            self.transcriptionState = .transcribing
          case .extractingAudio:
            break
          }
        }
        guard !Task.isCancelled, self.transcriptionRequestID == requestID else {
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: taskID, attempt: attempt, status: .cancelled,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          return
        }
        let trimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: taskID, attempt: attempt, status: .cancelled,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          self.transcriptionState = .failed("未识别到语音，请确认视频正在播放且有声音。")
          return
        }
        let received = self.nowMilliseconds()
        _ = await worker.saveTaskTranscription(
          history, taskID: taskID, attempt: attempt, detail: detail,
          text: trimmed, platform: platform, receivedAtMilliseconds: received
        )
        self.livePlaybackStopContinuation = nil
        self.transcriptionState = .completed
        self.refreshDetailAfterTranscription(taskID: taskID)
      } catch is CancellationError {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
      } catch let error as AppAudioLiveTranscriber.LiveTranscriptionError where error == .screenRecordingPermissionDenied {
        guard self.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.transcriptionState = .failed("已弹出「录屏与系统录音」授权。请在系统对话框或“系统设置 → 隐私与安全性 → 录屏与系统录音”中打开 LinkDigest Debug，然后退出并重开 App，再点「实时转写」。")
      } catch {
        guard self.transcriptionRequestID == requestID else { return }
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.transcriptionState = .failed("转写失败，请确认视频正在播放且有声音后重试。")
      }
    }
  }

  /// 优雅停止：发停止信号让转写器关流、保存已转写文本，而不是硬取消丢弃。
  /// 视频播完或用户点「停止转写」都走这里。
  func stopLivePlaybackTranscription() {
    livePlaybackStopContinuation?.finish()
    livePlaybackStopContinuation = nil
  }

  private func refreshDetailAfterTranscription(taskID: TaskID) {
    guard selectedTaskID == taskID, let history else { return }
    let generation = configurationGeneration, requestID = UUID()
    detailRequestID = requestID
    detailTask?.cancel()
    detailTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.detailResult(history, taskID: taskID)
      }.value
      guard !Task.isCancelled else { return }
      self?.receiveDetail(
        result,
        taskID: taskID,
        generation: generation,
        requestID: requestID
      )
    }
  }

  private func receiveDetail(_ result: DetailResult, taskID: TaskID, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == detailRequestID, selectedTaskID == taskID else { return }
    switch result {
    case let .success(value):
      detail = value
      if let snapshotID = value.snapshots.last?.id {
        localImageURLs = imageCache?.localImageURLs(taskID: taskID, snapshotID: snapshotID) ?? []
      } else { localImageURLs = [] }
      if let media = value.media, let mediaStore {
        do {
          let lease = try mediaStore.resolve(media)
          localMediaLease = lease
          localMediaFileURL = lease.url
          localMediaResolutionFailure = nil
        } catch let error as MediaStoragePreferenceError {
          localMediaLease = nil
          localMediaFileURL = nil
          localMediaResolutionFailure = error.userMessage
        } catch {
          localMediaLease = nil
          localMediaFileURL = nil
          localMediaResolutionFailure = "已保存的视频不可用，请检查文件位置。"
        }
      } else {
        localMediaLease = nil
        localMediaFileURL = nil
        localMediaResolutionFailure = nil
      }
      detailState = .loaded
    case let .failure(code):
      detail = nil
      localImageURLs = []
      localMediaFileURL = nil
      localMediaLease = nil
      localMediaResolutionFailure = nil
      detailErrorCode = code
      detailState = .failed
    }
  }

  private func receiveDeletion(
    _ result: DeleteResult,
    protectedCount: Int,
    generation: UUID,
    requestID: UUID
  ) {
    guard generation == configurationGeneration, requestID == deleteRequestID else { return }
    isDeleting = false; pendingDeletionTaskIDs = []; pendingProtectedDeletionTaskIDs = []
    switch result {
    case let .success(batch, _):
      let deleted = Set(batch.deletedTaskIDs)
      batch.deletedTaskIDs.forEach { imageCache?.delete(taskID: $0) }
      rows.removeAll { deleted.contains($0.taskID) }
      selectedTaskIDs = []
      if rows.isEmpty {
        listState = .empty
        detail = nil
        localImageURLs = []
        localMediaFileURL = nil
        detailState = .idle
      }
      let failedCount = batch.failedTaskIDs.count
      if failedCount > 0 || protectedCount > 0 {
        var parts = ["已删除 \(batch.deletedTaskIDs.count) 条"]
        if failedCount > 0 { parts.append("\(failedCount) 条失败") }
        if protectedCount > 0 { parts.append("\(protectedCount) 条正在生成，已跳过") }
        deleteOutcomeMessage = parts.joined(separator: "，") + "。"
        isDeleteOutcomePresented = true
      }
      reloadAvailableTags()
      reloadNavigationCounts()
    case let .failure(code): deleteErrorCode = code; isDeleteFailurePresented = true
    }
  }

  /// Immediately downloads a signed media URL and attaches the local asset.
  /// Fail-open: text capture already committed; missing video only hides the player card.
  @discardableResult
  func ingestCapturedMedia(
    _ media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    pageURL: String? = nil
  ) async -> Bool {
    do {
      let asset = try await downloadAndAttachMedia(
        media,
        taskID: taskID,
        snapshotID: snapshotID,
        pageURL: pageURL
      )
      revealAttachedMedia(asset, taskID: taskID)
      return true
    } catch {
      // Keep the history row; playback is optional for Loop V-1 resilience.
      if selectedTaskID == taskID {
        loadDetailForSelection()
      }
      return false
    }
  }

  /// Saves an opt-in browser capture without taking over the user's current selection.
  /// State stays keyed to the capture task so completion cannot be mistaken for another row.
  func autoSaveCapturedMedia(
    _ media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    pageURL: String? = nil
  ) async {
    capturedMediaAutoSaveStates[taskID] = .saving
    do {
      let asset = try await downloadAndAttachMedia(
        media,
        taskID: taskID,
        snapshotID: snapshotID,
        pageURL: pageURL
      )
      capturedMediaAutoSaveStates[taskID] = .saved
      if selectedTaskID == taskID {
        revealAttachedMedia(asset, taskID: taskID)
      }
    } catch let error as MediaDownloadError {
      receiveCapturedMediaAutoSaveFailure(error.userMessage, taskID: taskID)
    } catch {
      receiveCapturedMediaAutoSaveFailure(
        "保存失败。本地历史没有附加视频，请检查视频存储设置后重试。",
        taskID: taskID
      )
    }
  }

  func dismissCapturedMediaAutoSaveFailure() {
    isCapturedMediaAutoSaveFailurePresented = false
  }

  private func receiveCapturedMediaAutoSaveFailure(_ message: String, taskID: TaskID) {
    capturedMediaAutoSaveStates[taskID] = .failed(message)
    capturedMediaAutoSaveFailureMessage = "视频自动保存失败：\(message) 历史正文仍已保存，可回到该条记录重试。"
    isCapturedMediaAutoSaveFailurePresented = true
    if selectedTaskID == taskID {
      loadDetailForSelection()
    }
  }

  private func downloadAndAttachMedia(
    _ media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    pageURL: String?
  ) async throws -> MediaAsset {
    guard let history else { throw RepositoryFailure.unavailable }
    let asset: MediaAsset
    if let mediaDownloadOperation {
      asset = try await mediaDownloadOperation(media, taskID, snapshotID, pageURL)
      try history.attachMedia(.init(asset: asset))
    } else {
      guard let mediaDownloader else { throw RepositoryFailure.unavailable }
      let result = try await mediaDownloader.downloadAndStoreResult(
        media: media,
        taskID: taskID,
        snapshotID: snapshotID,
        pageURL: pageURL
      )
      do {
        try history.attachMedia(.init(asset: result.asset))
      } catch {
        mediaStore?.rollbackCreatedFile(result.storedFile)
        throw error
      }
      asset = (try history.mediaAsset(taskID: taskID)) ?? result.asset
    }
    return asset
  }

  private func revealAttachedMedia(_ asset: MediaAsset, taskID: TaskID) {
    guard let mediaStore else { return }
    // Always refresh the open detail so the existing local AVKit card appears.
    if selectedTaskID == taskID {
      if let lease = try? mediaStore.resolve(asset) {
        localMediaLease = lease
        localMediaFileURL = lease.url
        localMediaResolutionFailure = nil
      }
      loadDetailForSelection()
    } else {
      reveal(taskID: taskID)
    }
  }

  private func receiveExport(_ result: ExportResult, taskID: TaskID, generation: UUID, requestID: UUID) {
    guard generation == configurationGeneration, requestID == exportRequestID, selectedTaskID == taskID else { return }
    isPreparingExport = false
    switch result {
    case let .success(file):
      exportFile = file
      isExportPanelPresented = true
    case .failure:
      exportFile = nil
      isExportPreparationFailurePresented = true
    }
  }

  private func invalidateExportPreparation() {
    exportTask?.cancel()
    exportRequestID = UUID()
    isPreparingExport = false
    exportFile = nil
    isExportPanelPresented = false
  }

  private var listFilter: HistoryListFilter {
    .init(
      tagNames: selectedTagNormalizedNames.sorted(),
      hosts: selectedHosts.sorted(),
      scope: selectedScope,
      searchText: searchText
    )
  }

  private static func singleSelection(in taskIDs: Set<TaskID>) -> TaskID? {
    taskIDs.count == 1 ? taskIDs.first : nil
  }

  private func scheduleSearchReload() {
    guard history != nil else { return }
    searchTask?.cancel()
    let generation = configurationGeneration
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled, generation == self?.configurationGeneration else { return }
      self?.reload()
    }
  }

  private func reloadAvailableTags(reloadsListIfSelectedTagsDisappear: Bool = true) {
    guard let history else { return }
    let generation = configurationGeneration
    tagsTask?.cancel()
    tagsTask = Task { [weak self, worker] in
      let result = await worker.tags(history)
      guard !Task.isCancelled else { return }
      self?.receiveAvailableTags(
        result,
        generation: generation,
        reloadsListIfSelectedTagsDisappear: reloadsListIfSelectedTagsDisappear
      )
    }
  }

  private func reloadNavigationCounts() {
    guard let history else { return }
    let generation = configurationGeneration
    navigationCountsTask?.cancel()
    navigationCountsTask = Task { [weak self, worker] in
      let result = await worker.navigationCounts(history)
      guard !Task.isCancelled, generation == self?.configurationGeneration else { return }
      if case let .success(counts) = result {
        // Legacy captures carried automatic platform tags; the 平台 section
        // above already covers them, so keep the tag list content-only.
        self?.navigationCounts = HistoryNavigationCounts(
          all: counts.all,
          recent: counts.recent,
          unsummarized: counts.unsummarized,
          platforms: counts.platforms,
          tags: counts.tags.filter {
            !HistoryTagNormalizer.platformSynonymNormalizedNames.contains($0.tag.normalizedName)
          }
        )
      }
    }
  }

  private func receiveAvailableTags(
    _ result: TagsResult,
    generation: UUID,
    reloadsListIfSelectedTagsDisappear: Bool
  ) {
    guard generation == configurationGeneration else { return }
    guard case let .success(tags) = result else { return }
    availableTags = tags
    let known = Set(tags.map(\.normalizedName))
    let retained = selectedTagNormalizedNames.intersection(known)
    guard retained != selectedTagNormalizedNames else { return }
    selectedTagNormalizedNames = retained
    if reloadsListIfSelectedTagsDisappear { reload() }
  }

  private func receiveTagMutation(_ result: TagMutationResult, taskID: TaskID, generation: UUID) {
    guard generation == configurationGeneration, selectedTaskID == taskID else { return }
    switch result {
    case .success:
      loadDetailForSelection()
      reloadAvailableTags()
      reloadNavigationCounts()
    case let .failure(code):
      tagErrorCode = code
    }
  }

  private func loadFavicons(for rows: [HistoryRowProjection], generation: UUID) {
    guard let faviconCache, let faviconResources else { return }
    let candidates = rows.filter { $0.host.lowercased() != "github.com" && faviconImageURLs[$0.taskID] == nil }
    guard !candidates.isEmpty else { return }
    faviconTask?.cancel()
    faviconTask = Task { [weak self, faviconCache, faviconResources] in
      await withTaskGroup(of: (TaskID, URL?).self) { group in
        var next = candidates.makeIterator()

        func enqueueNext() {
          guard let row = next.next(), let sourceURL = URL(string: row.canonicalURL) else { return }
          group.addTask {
            guard !Task.isCancelled else { return (row.taskID, nil) }
            let localURL = await faviconCache.localImageURL(
              fetchingIfNeededFor: sourceURL,
              resources: faviconResources
            )
            return (row.taskID, localURL)
          }
        }

        for _ in 0..<6 { enqueueNext() }
        while let (taskID, localURL) = await group.next() {
          guard !Task.isCancelled else {
            group.cancelAll()
            return
          }
          if let localURL {
            self?.receiveFavicon(localURL, for: taskID, generation: generation)
          }
          enqueueNext()
        }
      }
    }
  }

  private func receiveFavicon(_ url: URL, for taskID: TaskID, generation: UUID) {
    guard generation == configurationGeneration, rows.contains(where: { $0.taskID == taskID }) else { return }
    faviconImageURLs[taskID] = url
  }

  nonisolated static func storageCode(for error: Error, context: StorageFailureContext) -> StorageErrorCode {
    if let failure = error as? RepositoryFailure { return StorageErrorMapper.map(failure, context: context).code }
    return StorageErrorMapper.mapUnknown(context: context).code
  }

  nonisolated private static func pageResult(_ history: HistoryApplicationService, cursor: HistoryPageCursor?, filter: HistoryListFilter) -> PageResult {
    do { return .success(try history.historyPage(limit: 50, after: cursor, filter: filter)) }
    catch { return .failure(storageCode(for: error, context: .open)) }
  }

  nonisolated private static func detailResult(_ history: HistoryApplicationService, taskID: TaskID) -> DetailResult {
    do { return .success(try history.detail(taskID: taskID)) }
    catch { return .failure(storageCode(for: error, context: .open)) }
  }
}
