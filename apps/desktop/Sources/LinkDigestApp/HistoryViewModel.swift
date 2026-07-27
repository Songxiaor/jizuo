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
      // 必须收集每个任务名下的**全部**媒体资产。
      //
      // `mediaAsset(taskID:)` 是 `ORDER BY created_at_ms DESC LIMIT 1`，只给最新
      // 一条。而 media_assets 的唯一键是 (task_id, content_sha256)，同一任务可以
      // 有多行：重抓后字节不同、B 站合流成功与失败产出不同 sha。只删最新那条，
      // 其余文件的 DB 行随 CASCADE 消失、磁盘文件却留了下来，成为再也没人能发现
      // 的孤儿——没有任何清扫器会扫它们。
      let media = taskIDs.flatMap { taskID in
        (try? history.mediaAssets(taskID: taskID)) ?? []
      }
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
  /// 远程流场景保留 descriptor：AVAssetExportSession 拒绝对远程流式 asset
  /// 导出分片（实测 -11838 / -12109 瞬时失败，与网络无关），所以上传前必须
  /// 先经 TranscriptionTempStore 把音轨落到本地临时文件。本机视频场景为 nil。
  let descriptor: MediaDescriptor?
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
  @Published private(set) var transcriptionState: TranscriptionUIState = .idle {
    // 任何终态都必须带走阶段文案，不能让「正在下载音频轨…」陪着失败提示常驻。
    didSet {
      if !transcriptionState.isActive {
        onlineTranscriptionPhase = nil
        onlineTranscriptionPreview = nil
      }
    }
  }
  @Published private(set) var transcriptionText = ""
  @Published private(set) var transcriptionTaskID: TaskID?
  @Published private(set) var transcriptionUsesOnlineService = false
  /// 在线转写进行到哪一步。「正在在线转写…」曾覆盖从建任务记录到最后一片
  /// 上传的全过程——挂在数据库、挂在下载、挂在导出、挂在上传，界面上
  /// 一模一样。这里按真实阶段更新，卡住时直接读出卡在哪个字。
  @Published private(set) var onlineTranscriptionPhase: String?
  /// 流式通道下已确定的文稿前缀，边转写边显示。终态时清空，成品由
  /// `transcriptionText` 接管，避免同一段文字在界面上出现两份。
  @Published private(set) var onlineTranscriptionPreview: String?
  /// 上一次在线转写的分段耗时，终态后保留（阶段文案会被清掉，这条不能跟着走）。
  /// 「慢」必须先拆开看：下载音轨慢、本机切片导出慢、等 ASR 返回慢，
  /// 三段的修法完全不同（带宽 / 编码 preset / 分片粒度与并发），
  /// 凭感觉挑一处改是今天已经栽过的坑。
  @Published private(set) var onlineTranscriptionTimings: String?
  /// 上传段起点：`progress(0, total)` 恰好发生在全部分片导出完成、
  /// 第一片上传之前，是切片段与上传段之间唯一可靠的分界。
  private var onlineUploadStartInstant: ContinuousClock.Instant?
  private var onlineChunkTotal: Int?
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
  @Published private(set) var mindMapRecord: TaskMindMapRecord?
  @Published private(set) var mindMapState: TranscriptTidyUIState = .idle
  @Published private(set) var mindMapTaskID: TaskID?
  @Published var isMindMapConfirmationPresented = false
  /// 台账（整理/脑图）部分的 token 合计；Run 部分由 detail 投影自带。
  @Published private(set) var ledgerTokenTotals: TaskTokenTotals?
  /// 学习批注：用户的摘录与笔记，与机器产物分离。
  @Published private(set) var taskExcerpts: [TaskExcerpt] = []
  @Published var taskNoteDraft = ""
  private var noteSaveTask: Task<Void, Never>?
  /// 待落库的笔记。存在这里而不是只活在 Task 闭包里，切换条目时才能先冲刷再覆盖草稿。
  private var pendingNote: (taskID: TaskID, body: String, timestamp: Int64)?
  /// 笔记/摘录落库失败的提示。这条路径原来全是 `try?`，失败完全无声，
  /// 而界面上写着「笔记自动保存」。
  @Published var annotationFailureMessage: String?
  private var loadedNoteTaskID: TaskID?
  @Published private(set) var remoteMediaFavoriteState: RemoteMediaFavoriteState = .idle
  @Published private(set) var capturedMediaAutoSaveStates: [TaskID: RemoteMediaFavoriteState] = [:]
  @Published private(set) var capturedMediaAutoSaveFailureMessage = ""
  @Published var isCapturedMediaAutoSaveFailurePresented = false

  private let worker = HistoryRepositoryWorker()
  private let imageCache: GitHubREADMEImageCache?
  private let imageResources: (any SafeResourceFetching)?
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
  private let mindMapExtractor: (any MindMapExtracting)?
  private let transcriptionTempStore: TranscriptionTempStore?
  /// 转写专用音轨解析（platform, pageURL) -> 音轨地址。整段 progressive 没有
  /// 独立音轨时用它单独问一次 playurl，避免为了声音下载整段视频。
  private let transcriptionAudioTrackURL: (@Sendable (String?, String) async -> String?)?
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
  private var imageBackfillTask: Task<Void, Never>?
  private var imageBackfillAttemptedSnapshotIDs: Set<ContentSnapshotID> = []
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
    imageResources: (any SafeResourceFetching)? = nil,
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
    mindMapExtractor: (any MindMapExtracting)? = nil,
    transcriptionTempStore: TranscriptionTempStore? = nil,
    transcriptionAudioTrackURL: (@Sendable (String?, String) async -> String?)? = nil,
    livePlaybackTranscribe: (@Sendable (String, AsyncStream<Void>) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>)? = nil,
    startupTranscriptionCleanupFailure: String? = nil,
    onDiscardedTranscriptionAttempt: @escaping @Sendable () -> Void = {},
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.imageCache = imageCache
    self.imageResources = imageResources
    self.mediaStore = mediaStore
    self.mediaDownloader = mediaDownloader
    self.mediaDownloadOperation = mediaDownloadOperation
    self.faviconCache = faviconCache
    self.faviconResources = faviconResources
    self.videoTranscriber = videoTranscriber
    self.imageTextRecognizer = imageTextRecognizer
    self.onlineAudioTranscriber = onlineAudioTranscriber
    self.transcriptTidier = transcriptTidier
    self.mindMapExtractor = mindMapExtractor
    self.transcriptionTempStore = transcriptionTempStore
    self.transcriptionAudioTrackURL = transcriptionAudioTrackURL
    self.livePlaybackTranscribe = livePlaybackTranscribe
    transcriptionCleanupFailure = startupTranscriptionCleanupFailure
    self.onDiscardedTranscriptionAttempt = onDiscardedTranscriptionAttempt
    self.nowMilliseconds = nowMilliseconds
  }

  deinit { pageTask?.cancel(); detailTask?.cancel(); imageBackfillTask?.cancel(); deleteTask?.cancel(); exportTask?.cancel(); faviconTask?.cancel(); tagsTask?.cancel(); navigationCountsTask?.cancel(); tagMutationTask?.cancel(); searchTask?.cancel(); transcriptionTask?.cancel(); imageTextRecognitionTask?.cancel(); transcriptTidyTask?.cancel() }

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
    pageTask?.cancel(); detailTask?.cancel(); imageBackfillTask?.cancel(); deleteTask?.cancel(); faviconTask?.cancel(); tagsTask?.cancel(); navigationCountsTask?.cancel(); tagMutationTask?.cancel(); searchTask?.cancel(); transcriptionTask?.cancel(); imageTextRecognitionTask?.cancel(); invalidateExportPreparation()
    imageBackfillAttemptedSnapshotIDs = []
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
    // 取轨必须与本机转写同一条规则：B 站 DASH 拆轨时 ephemeralPlaybackURL 是
    // **纯画面轨**，直接拿去提取音频得到零分片，最后被吞成「连接中断」——
    // 用户看到的是网络错误，实际根本没到网络那一步。companionAudioURL 才有声音。
    guard let detail, detail.task.id == taskID,
          let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
          canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: model),
          let rawURL = TranscriptionTempStore.preferredTranscriptionSourceURL(descriptor),
          let mediaURL = URL(string: rawURL) else {
      transcriptionState = .failed(OnlineAudioTranscriptionError.modelNotConfigured.userMessage)
      return
    }
    pendingOnlineTranscriptionContext = .init(
      taskID: taskID,
      detail: detail,
      mediaURL: mediaURL,
      platform: descriptor.platform,
      model: model,
      descriptor: descriptor
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
      model: model,
      descriptor: nil
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
    // 部分分片失败必须说出来。长稿切片整理时中间几片撞 429 或超时，那几片会以
    // **原文**回填——不说的话用户看到的是「整理完成 + N tokens」，而实际可能有
    // 大半内容根本没整理过，且这条整理稿已经顶替了阅读区的「原文」。
    let partial = outcome.isPartial
      ? "；\(outcome.chunkCount) 段中有 \(outcome.failedChunkCount) 段未能整理，已保留原文，可重试"
      : ""
    guard let total = outcome.totalTokens else {
      return partial.isEmpty ? nil : String(partial.dropFirst())
    }
    if let prompt = outcome.promptTokens, let completion = outcome.completionTokens {
      return "\(total) tokens（输入 \(prompt) / 输出 \(completion)）\(partial)"
    }
    return "\(total) tokens\(partial)"
  }

  /// 全文 token 总和 = Runs（总结/翻译）+ 台账（整理/脑图）的累计花费。
  var taskTokenGrandTotals: TaskTokenTotals? {
    guard let detail else { return nil }
    var prompt = 0, completion = 0, total = 0
    for run in detail.runs {
      prompt += Int(run.run.usageCost.inputTokens ?? 0)
      completion += Int(run.run.usageCost.outputTokens ?? 0)
      total += Int(run.run.usageCost.totalTokens ?? 0)
    }
    if let ledger = ledgerTokenTotals {
      prompt += ledger.promptTokens
      completion += ledger.completionTokens
      total += ledger.totalTokens
    }
    guard prompt > 0 || completion > 0 || total > 0 else { return nil }
    return TaskTokenTotals(promptTokens: prompt, completionTokens: completion, totalTokens: total)
  }

  /// 非 Run 操作（整理/脑图）成功后记一笔台账并刷新合计。
  private func recordTokenUsage(
    taskID: TaskID, operation: String,
    promptTokens: Int?, completionTokens: Int?, totalTokens: Int?
  ) async {
    guard let store = history?.tokenUsageStore,
          promptTokens != nil || completionTokens != nil || totalTokens != nil else { return }
    let usage = TaskTokenUsage(
      taskID: taskID, operation: operation,
      promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens,
      createdAtMilliseconds: nowMilliseconds()
    )
    let totals = await Task.detached(priority: .utility) { () -> TaskTokenTotals? in
      try? store.appendTokenUsage(usage)
      return try? store.ledgerTokenTotals(taskID: taskID)
    }.value
    guard selectedTaskID == taskID, let totals else { return }
    ledgerTokenTotals = totals
  }

  // MARK: - 学习批注（摘录 + 笔记）

  func addExcerpt(_ text: String, taskID: TaskID) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isReadOnly,
          let store = history?.annotationStore, selectedTaskID == taskID else { return }
    let excerpt = TaskExcerpt(
      taskID: taskID,
      excerpt: String(trimmed.prefix(4_000)),
      createdAtMilliseconds: nowMilliseconds()
    )
    // 先落库再上屏：摘录是用户思考的载体，不允许只存在于内存。
    Task.detached(priority: .userInitiated) { [weak self] in
      let saved = (try? store.addExcerpt(excerpt)) != nil
      await MainActor.run {
        guard let self else { return }
        guard saved else {
          // 静默失败等于「选中文字、点了添加、什么都没发生」，用户会以为自己没点中。
          self.annotationFailureMessage = "摘录没能保存到本机，请检查存储后重试。"
          return
        }
        guard self.selectedTaskID == taskID else { return }
        self.taskExcerpts.append(excerpt)
      }
    }
  }

  func deleteExcerpt(_ excerpt: TaskExcerpt) {
    guard !isReadOnly, let store = history?.annotationStore else { return }
    // 先落库再从界面移除。
    //
    // 原来是反的：先 removeAll 再 `try?` 删库。删库失败时界面上它已经消失，
    // 下次 reload 又从库里读回来——「删掉的摘录刷新后复活」，而且中间没有任何
    // 提示，用户只会觉得这个功能时灵时不灵。
    Task.detached(priority: .utility) { [weak self] in
      let deleted = (try? store.deleteExcerpt(id: excerpt.id, taskID: excerpt.taskID)) != nil
      await MainActor.run {
        guard let self else { return }
        guard deleted else {
          self.annotationFailureMessage = "摘录没能从本机删除，请检查存储后重试。"
          return
        }
        self.taskExcerpts.removeAll { $0.id == excerpt.id }
      }
    }
  }

  /// 笔记随输防抖保存：停顿 800ms 落库；空内容即删除记录。
  ///
  /// 待落库内容记成显式状态而不是只活在 Task 闭包里，这样切换条目、关窗、退出前
  /// 都能先冲刷。原实现有两处会静默丢数据：切到别的条目时 `receiveDetail` 给
  /// `taskNoteDraft` 赋新值会触发 onChange，进而 `cancel()` 掐掉上一条尚未落库的
  /// 写入；即使没被 cancel，`selectedTaskID == taskID` 那个守卫也已不成立。
  /// 用户看到的是「输入后 800ms 内切走，最后那段编辑消失」，而界面上写着「自动保存」。
  ///
  /// 守卫去掉是对的：写入目标是**某个具体 taskID**，与此刻选中谁无关。
  func scheduleNoteSave(taskID: TaskID) {
    guard !isReadOnly, history?.annotationStore != nil else { return }
    pendingNote = (taskID: taskID, body: taskNoteDraft, timestamp: nowMilliseconds())
    noteSaveTask?.cancel()
    noteSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      await self?.flushPendingNote()
    }
  }

  /// 取走待落库的笔记并停掉防抖计时器。同步，不让出执行权。
  @discardableResult
  private func takePendingNote() -> (taskID: TaskID, body: String, timestamp: Int64)? {
    defer {
      pendingNote = nil
      noteSaveTask?.cancel()
      noteSaveTask = nil
    }
    return pendingNote
  }

  /// 落库，不等待。调用方已经把内容从 pendingNote 里取走，不会再被后续编辑覆盖。
  private func persistNoteDetached(_ pending: (taskID: TaskID, body: String, timestamp: Int64)) {
    guard let store = history?.annotationStore else { return }
    Task.detached(priority: .utility) { [weak self] in
      let saved = Self.saveNote(store: store, pending: pending)
      if !saved { await MainActor.run { self?.reportNoteSaveFailure() } }
    }
  }

  /// 把待落库的笔记立刻写下去。切换条目、关闭详情、退出前必须调用。
  /// 幂等：没有待写内容时什么都不做。
  func flushPendingNote() async {
    guard let pending = takePendingNote(), let store = history?.annotationStore else { return }
    let saved = await Task.detached(priority: .utility) {
      Self.saveNote(store: store, pending: pending)
    }.value
    if !saved { reportNoteSaveFailure() }
  }

  nonisolated private static func saveNote(
    store: any AnnotationStoring,
    pending: (taskID: TaskID, body: String, timestamp: Int64)
  ) -> Bool {
    do {
      try store.saveNote(
        taskID: pending.taskID, body: pending.body, updatedAtMilliseconds: pending.timestamp)
      return true
    } catch {
      return false
    }
  }

  /// 界面上写着「笔记自动保存」，那就不能让写失败无声无息。
  /// 存储降级、磁盘满、DB 损坏都发生在 isReadOnly 守卫之后，用户会毫无察觉地
  /// 丢掉整段笔记。
  private func reportNoteSaveFailure() {
    annotationFailureMessage = "笔记没能保存到本机，请检查存储后重试。内容仍在输入框里，可复制备份。"
  }

  // MARK: - 自动处理管线

  /// 每个任务只自动处理一次；重启 App 后不追溯旧内容。
  private var autoPipelineHandledTaskIDs: Set<TaskID> = []
  private var autoPipelineTask: Task<Void, Never>?

  /// 新内容到达后按顺序执行勾选步骤：本机转写 → 整理 → 总结 → 脑图。
  /// 勾选即持久授权：整理/脑图跳过逐次确认；总结沿用数据去向 consent
  /// 存储（首次目的地仍确认一次）。用户切走当前条目时静默停止后续步骤。
  func startAutoPipeline(
    taskID: TaskID,
    transcribe: Bool,
    tidy: Bool,
    summarize: Bool,
    mindMap: Bool,
    tidyModel: String?,
    summarizeAction: @escaping @MainActor () async -> Void
  ) {
    guard transcribe || tidy || summarize || mindMap else { return }
    guard !autoPipelineHandledTaskIDs.contains(taskID) else { return }
    autoPipelineHandledTaskIDs.insert(taskID)
    autoPipelineTask?.cancel()
    autoPipelineTask = Task { [weak self] in
      guard let self else { return }
      // 详情就绪（含媒体解析）。
      guard await self.waitFor(timeoutSeconds: 15, condition: {
        self.selectedTaskID == taskID && self.detailState == .loaded && self.detail?.task.id == taskID
      }) else { return }

      // 1. 本机转写：只处理已落地的本机视频；模型未就绪不弹下载弹窗，跳过。
      let hasTranscript = self.detail.map { Self.latestTranscriptText(in: $0) != nil } ?? false
      if transcribe, !hasTranscript {
        // 自动保存的视频可能还在下载，短暂等待落地；纯文本条目等不到即跳过。
        _ = await self.waitFor(timeoutSeconds: 30, condition: {
          self.selectedTaskID != taskID || self.localMediaFileURL != nil
        })
        guard self.selectedTaskID == taskID else { return }
        if self.localMediaFileURL != nil, self.canTranscribeVideo {
          self.requestTranscription()
          _ = await self.waitFor(timeoutSeconds: 1_800, condition: {
            self.selectedTaskID != taskID || {
              switch self.transcriptionState(for: taskID) {
              case .completed, .failed, .cancelled, .awaitingModelDownload: true
              default: false
              }
            }()
          })
          // 需要下载模型时不自动下载：收起弹窗，转写留给用户手动。
          if self.transcriptionState(for: taskID) == .awaitingModelDownload {
            self.cancelModelDownloadConfirmation()
          }
        }
      }
      guard self.selectedTaskID == taskID else { return }

      // 2. 整理：勾选即授权，跳过确认弹窗。
      let tidySourceReady = self.transcriptionState(for: taskID) == .completed
        || self.detail.map { Self.latestTranscriptText(in: $0) != nil } == true
      if tidy, tidySourceReady {
        self.startTranscriptTidyAuto(taskID: taskID, model: tidyModel)
        _ = await self.waitFor(timeoutSeconds: 600, condition: {
          self.selectedTaskID != taskID || !self.transcriptTidyState(for: taskID).isActive
        })
      }
      guard self.selectedTaskID == taskID else { return }

      // 3. 总结：已有完成的总结 Run 则跳过。
      let hasSummary = self.detail?.runs.contains {
        $0.run.kind == .summarize && $0.run.status == .completed
      } == true
      if summarize, !hasSummary {
        await summarizeAction()
        // 总结产物要进入 detail 投影，脑图才能优先吃到总结。
        self.loadDetailForSelection()
        _ = await self.waitFor(timeoutSeconds: 15, condition: {
          self.selectedTaskID != taskID || self.detailState == .loaded
        })
      }
      guard self.selectedTaskID == taskID else { return }

      // 4. 脑图：已有脑图则跳过；分支标题会自动写入标签。
      if mindMap, self.mindMapRecord == nil {
        self.startMindMapGenerationAuto(taskID: taskID)
      }
    }
  }

  /// 与手动路径同一状态机，只是不弹确认（设置勾选即持久授权）。
  func startTranscriptTidyAuto(taskID: TaskID, model: String?) {
    requestTranscriptTidy(taskID: taskID, model: model)
    if isTranscriptTidyConfirmationPresented {
      isTranscriptTidyConfirmationPresented = false
      confirmTranscriptTidy()
    }
  }

  func startMindMapGenerationAuto(taskID: TaskID) {
    requestMindMapGeneration(taskID: taskID)
    if isMindMapConfirmationPresented {
      isMindMapConfirmationPresented = false
      confirmMindMapGeneration()
    }
  }

  private func waitFor(
    timeoutSeconds: Double,
    condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeoutSeconds)
    while !condition() {
      if Task.isCancelled || clock.now >= deadline { return condition() }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return true
  }

  // MARK: - 脑图

  /// LLM 抽大纲的输入上限；超过时截前段——脑图是压缩，尾部损失可接受。
  private static let mindMapInputCharacterLimit = 20_000

  func mindMapState(for taskID: TaskID) -> TranscriptTidyUIState {
    mindMapTaskID == taskID ? mindMapState : .idle
  }

  var mindMapTokenSummary: String? {
    guard let record = mindMapRecord, let total = record.totalTokens else { return nil }
    if let prompt = record.promptTokens, let completion = record.completionTokens {
      return "\(total) tokens（输入 \(prompt) / 输出 \(completion)）"
    }
    return "\(total) tokens"
  }

  /// 渲染始终从大纲现算，主题切换与编辑都不花 token。
  func mindMapSVG() -> String? {
    guard let record = mindMapRecord else { return nil }
    return MindMapSVGRenderer.render(
      outline: record.outline,
      theme: MindMapTheme.named(record.themeID)
    )
  }

  /// 优先总结产物（脑图本质是压缩，喂总结质量最好也省 token）；
  /// 没有总结时用最新正文 snapshot（整理稿保存后就是最新正文）。
  private func mindMapSourceText() -> String? {
    guard let detail else { return nil }
    let summary = detail.runs
      .filter { $0.run.kind == .summarize && $0.run.status == .completed }
      .compactMap { $0.artifact?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
    let source = summary ?? detail.snapshots.last?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let source, !source.isEmpty else { return nil }
    return String(source.prefix(Self.mindMapInputCharacterLimit))
  }

  func canGenerateMindMap(taskID: TaskID) -> Bool {
    guard let detail, history?.mindMapStore != nil, mindMapExtractor != nil, !isReadOnly,
          detail.task.id == taskID,
          !mindMapState(for: taskID).isActive else { return false }
    return mindMapSourceText() != nil
  }

  func requestMindMapGeneration(taskID: TaskID) {
    guard canGenerateMindMap(taskID: taskID) else { return }
    isMindMapConfirmationPresented = true
  }

  func cancelMindMapConfirmation() { isMindMapConfirmationPresented = false }

  func confirmMindMapGeneration() {
    isMindMapConfirmationPresented = false
    guard let history, let mindMapExtractor, let store = history.mindMapStore,
          let detail, let taskID = selectedTaskID, detail.task.id == taskID,
          let text = mindMapSourceText() else {
      mindMapState = .failed(MindMapOutlineError.emptyInput.userMessage)
      return
    }
    mindMapTaskID = taskID
    mindMapState = .running
    let existingThemeID = mindMapRecord?.themeID ?? MindMapTheme.minimalLight.id
    let createdAt = mindMapRecord?.createdAtMilliseconds ?? nowMilliseconds()
    Task { [weak self] in
      guard let self else { return }
      do {
        let outcome = try await mindMapExtractor.extractOutline(text: text, model: nil)
        try Task.checkCancellation()
        // 这里**不能**用 `selectedTaskID == taskID` 提前 return。
        //
        // 生成要几十秒，期间用户很可能切走。原来在保存之前就 return：token 已经
        // 花掉、大纲被丢弃、mindMapState 永远停在 .running、mindMapTaskID 仍指向
        // 这一条。回来后 receiveDetail 的 `if mindMapTaskID != taskID` 不成立，
        // 状态不会重置；canGenerateMindMap 因 .isActive 为 false，而 mindMapRecord
        // 为 nil，于是脑图区两个分支都不满足——**整块 UI 消失**，本次进程内再也
        // 无法为这条生成脑图。
        //
        // 正确做法与旁边的整理路径一致：结果照存（它属于 taskID，与此刻选中谁无关），
        // 只在更新 UI 前判断是否仍停留在这一条。
        let record = TaskMindMapRecord(
          taskID: taskID,
          outline: outcome.outline,
          themeID: existingThemeID,
          userEdited: false,
          provider: "configured_provider",
          model: nil,
          promptTokens: outcome.promptTokens,
          completionTokens: outcome.completionTokens,
          totalTokens: outcome.totalTokens,
          createdAtMilliseconds: createdAt,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        try await Task.detached(priority: .userInitiated) { try store.saveMindMap(record) }.value
        // 已落库。即使用户切走了，也必须把 .running 收掉——否则回到这条时状态
        // 仍是「生成中」，而 UI 会因此既不显示结果也不显示入口。
        if self.mindMapTaskID == taskID { self.mindMapState = .completed }
        // 记账与打标签都属于「这条记录的事实」，与此刻选中谁无关，必须排在选中态
        // 守卫**之前**。原来排在后面：切走条目时 token 照花、脑图照存，台账却少记
        // 这一笔——而「全文 token 总和」只累加 runs 和台账，不读 mindMapRecord 上的
        // token 列，于是那笔开销永久消失。标签同理，会漏掉本该加上的主题标签。
        await self.recordTokenUsage(
          taskID: taskID, operation: "mind_map",
          promptTokens: outcome.promptTokens, completionTokens: outcome.completionTokens,
          totalTokens: outcome.totalTokens
        )
        // 只写模型给出的跨文章主题标签；分支标题是章节结构，永不进标签系统。
        let topicTags = outcome.outline.tags ?? []
        let tagged = await Task.detached(priority: .utility) { () -> Bool in
          guard !topicTags.isEmpty else { return false }
          return (try? history.addTags(topicTags, to: taskID)) != nil
        }.value
        guard self.selectedTaskID == taskID else { return }
        self.mindMapRecord = record
        guard self.selectedTaskID == taskID else { return }
        if tagged {
          self.loadDetailForSelection()
          self.reloadAvailableTags()
          self.reloadNavigationCounts()
        }
      } catch {
        // 失败同样不能提前 return：切走后状态若停在 .running，回来时脑图区会
        // 整块消失（既没有结果可显示，入口又因 .isActive 被禁用）。
        guard self.mindMapTaskID == taskID else { return }
        if let failure = error as? TranscriptTidyError {
          self.mindMapState = .failed(failure.userMessage)
        } else if let failure = error as? MindMapOutlineError {
          self.mindMapState = .failed(failure.userMessage)
        } else {
          self.mindMapState = .failed(MindMapOutlineError.invalidJSON.userMessage)
        }
      }
    }
  }

  /// 用户改错别字后的保存：纯本地，不再经过模型。
  func updateMindMapOutline(taskID: TaskID, outline: MindMapOutline) {
    guard let store = history?.mindMapStore, let existing = mindMapRecord,
          existing.taskID == taskID, !isReadOnly else { return }
    let clamped = outline.clamped()
    guard !clamped.title.isEmpty, !clamped.branches.isEmpty else { return }
    let record = TaskMindMapRecord(
      taskID: taskID,
      outline: clamped,
      themeID: existing.themeID,
      userEdited: true,
      provider: existing.provider,
      model: existing.model,
      promptTokens: existing.promptTokens,
      completionTokens: existing.completionTokens,
      totalTokens: existing.totalTokens,
      createdAtMilliseconds: existing.createdAtMilliseconds,
      updatedAtMilliseconds: nowMilliseconds()
    )
    mindMapRecord = record
    persistMindMap(record, store: store, failureMessage: "脑图修改没能保存到本机，请检查存储后重试。重新打开这条记录会回到上一次保存的版本。")
  }

  func updateMindMapTheme(taskID: TaskID, themeID: String) {
    guard let store = history?.mindMapStore, let existing = mindMapRecord,
          existing.taskID == taskID, existing.themeID != themeID else { return }
    let record = TaskMindMapRecord(
      taskID: taskID,
      outline: existing.outline,
      themeID: MindMapTheme.named(themeID).id,
      userEdited: existing.userEdited,
      provider: existing.provider,
      model: existing.model,
      promptTokens: existing.promptTokens,
      completionTokens: existing.completionTokens,
      totalTokens: existing.totalTokens,
      createdAtMilliseconds: existing.createdAtMilliseconds,
      updatedAtMilliseconds: nowMilliseconds()
    )
    mindMapRecord = record
    persistMindMap(record, store: store, failureMessage: "脑图配色没能保存到本机，请检查存储后重试。重新打开这条记录会回到上一次保存的版本。")
  }

  /// 脑图的本地保存：先上屏、后落库，所以**必须**有失败出口。
  ///
  /// 原来两处都是 `Task.detached { try? store.saveMindMap(record) }`——改完大纲或换完
  /// 配色，界面立刻变了，写库失败却完全无声。下次打开这条记录编辑就没了，中间没有任何
  /// 提示，表现和「删掉的摘录刷新后复活」是同一类：先上屏后落库而落库没有出口。
  ///
  /// 这里不改成「先落库再上屏」：脑图编辑是连续操作（改一个字就存一次），同步等写库会
  /// 让编辑器卡顿。异步保存 + 明确的失败提示是这条路径更合适的取舍。
  private func persistMindMap(
    _ record: TaskMindMapRecord,
    store: any MindMapStoring,
    failureMessage: String
  ) {
    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        try store.saveMindMap(record)
      } catch {
        await MainActor.run { self?.annotationFailureMessage = failureMessage }
      }
    }
  }

  /// 脑图 + 原文合并导出的自包含 HTML（SVG 内联，无外部依赖）。
  func mindMapCombinedExportHTML() -> String? {
    guard let svg = mindMapSVG(), let detail else { return nil }
    let title = detail.snapshots.last?.title ?? mindMapRecord?.outline.title ?? "LinkDigest"
    let body = detail.snapshots.last?.bodyText ?? ""
    let paragraphs = body
      .components(separatedBy: "\n\n")
      .map { "<p>\(Self.htmlEscaped($0))</p>" }
      .joined(separator: "\n")
    return """
    <!DOCTYPE html>
    <html lang="zh"><head><meta charset="utf-8"><title>\(Self.htmlEscaped(title))</title>
    <style>
    body { max-width: 860px; margin: 40px auto; padding: 0 24px; font-family: 'PingFang SC', -apple-system, sans-serif; line-height: 1.8; color: #222; }
    .map { margin: 24px 0 40px; } .map svg { max-width: 100%; height: auto; }
    p { margin: 0 0 1em; }
    </style></head><body>
    <h1>\(Self.htmlEscaped(title))</h1>
    <div class="map">\(svg)</div>
    \(paragraphs)
    </body></html>
    """
  }

  private static func htmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
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
          await self.recordTokenUsage(
            taskID: context.taskID, operation: "transcript_tidy",
            promptTokens: outcome.promptTokens, completionTokens: outcome.completionTokens,
            totalTokens: outcome.totalTokens
          )
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
    onlineTranscriptionPhase = "正在创建转写任务记录…"
    onlineTranscriptionTimings = nil
    onlineTranscriptionPreview = nil
    onlineUploadStartInstant = nil
    onlineChunkTotal = nil
    // 单调时钟：耗时测量不能用注入的 nowMilliseconds（测试里是可控假时钟，
    // 且系统时间可能回拨）。
    let clock = ContinuousClock()
    let startedAt = clock.now
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
      guard self.transcriptionRequestID == requestID else {
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: context.taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        return
      }
      guard case .applied = running else {
        // 曾在这里静默 return：数据库拒绝置 running（stale/冲突）时 UI 没有
        // 任何终态，永远停在「正在在线转写…」。任何退出都必须给出可见状态。
        _ = await worker.updateTaskTranscriptionStatus(
          history, taskID: context.taskID, attempt: attempt, status: .cancelled,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        self.onlineTranscriptionPhase = nil
        self.transcriptionState = .failed("转写任务状态冲突（可能有未结束的旧任务），请再试一次。")
        return
      }
      self.transcriptionState = .transcribing
      // 远程流必须先落地：AVAssetExportSession 对远程流式 asset 一律
      // -11838 瞬时失败（实测），分片导出只能吃本地文件。TranscriptionTempStore
      // 会按拆轨规则只下音频轨（B 站 13 分钟约 7.6MB），attempt 结束即清理。
      var tempAttemptID: String?
      defer {
        if let tempAttemptID, let store = self.transcriptionTempStore {
          try? store.cleanup(attemptID: tempAttemptID)
        }
      }
      var downloadFinishedAt: ContinuousClock.Instant?
      var downloadedBytes: Int?
      let audioSourceURL: URL
      if mediaURL.isFileURL {
        audioSourceURL = mediaURL
      } else if let descriptor = context.descriptor, let store = self.transcriptionTempStore {
        do {
          // 整段 progressive 的 descriptor 没有 companionAudioURL，直接下它等于
          // 为了声音拉整段视频（实测 61.6MB）。这里补一次只取音轨的 playurl。
          var overrideAudioURL: String?
          if descriptor.companionAudioURL == nil, let resolve = self.transcriptionAudioTrackURL {
            self.onlineTranscriptionPhase = "正在获取音频轨地址…"
            overrideAudioURL = await resolve(descriptor.platform, descriptor.pageURL)
          }
          self.onlineTranscriptionPhase = "正在下载音频轨到本机…"
          let temp = try await store.prepare(
            descriptor: descriptor,
            overrideAudioURL: overrideAudioURL
          )
          tempAttemptID = temp.attemptID
          audioSourceURL = temp.fileURL
          downloadFinishedAt = clock.now
          downloadedBytes = (try? FileManager.default
            .attributesOfItem(atPath: temp.fileURL.path)[.size] as? Int) ?? nil
          self.onlineTranscriptionPhase = "音轨已就绪，正在分片上传转写…"
        } catch {
          guard self.transcriptionRequestID == requestID else { return }
          _ = await worker.updateTaskTranscriptionStatus(
            history, taskID: context.taskID, attempt: attempt, status: .failed,
            updatedAtMilliseconds: self.nowMilliseconds()
          )
          let ns = error as NSError
          self.transcriptionState = .failed(
            OnlineAudioTranscriptionError
              .audioExtractionFailed(detail: "下载音轨失败 \(ns.domain) \(ns.code)")
              .userMessage
          )
          return
        }
      } else {
        audioSourceURL = mediaURL
      }
      do {
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
          // 时刻要在闭包同步段取，跨过 MainActor hop 再取会把调度延迟算进来。
          let mark = clock.now
          Task { @MainActor in
            guard let self, self.transcriptionRequestID == requestID else { return }
            if done == 0, self.onlineUploadStartInstant == nil {
              self.onlineUploadStartInstant = mark
              self.onlineChunkTotal = total
            }
            self.onlineTranscriptionPhase = done == 0
              ? "正在转写 \(total) 个音频分片…"
              : "已完成 \(done)/\(total) 片…"
          }
        }
        let onPartial: @Sendable (String) -> Void = { [weak self] prefix in
          Task { @MainActor in
            guard let self, self.transcriptionRequestID == requestID else { return }
            self.onlineTranscriptionPreview = prefix
          }
        }
        let text: String
        if let streaming = onlineAudioTranscriber as? any StreamingOnlineAudioTranscribing {
          // 流式通道下，等待感由「第一句话多久出现」决定，而不是总耗时。
          text = try await streaming.transcribe(
            remoteMediaURL: audioSourceURL,
            model: context.model,
            language: "zh",
            progress: onProgress,
            partialTranscript: onPartial
          )
        } else {
          text = try await onlineAudioTranscriber.transcribe(
            remoteMediaURL: audioSourceURL,
            model: context.model,
            language: "zh",
            progress: onProgress
          )
        }
        let finishedAt = clock.now
        try Task.checkCancellation()
        guard self.transcriptionRequestID == requestID else { return }
        self.recordOnlineTranscriptionTimings(
          startedAt: startedAt,
          downloadFinishedAt: downloadFinishedAt,
          finishedAt: finishedAt,
          downloadedBytes: downloadedBytes,
          succeeded: true
        )
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
        let failedAt = clock.now
        let cancelled = error is CancellationError || (error as? OnlineAudioTranscriptionError) == .cancelled
        _ = await worker.updateTaskTranscriptionStatus(
          history,
          taskID: context.taskID,
          attempt: attempt,
          status: cancelled ? .cancelled : .failed,
          updatedAtMilliseconds: self.nowMilliseconds()
        )
        guard self.transcriptionRequestID == requestID else { return }
        // 失败也要留下分段耗时：卡住时最需要知道的就是走到哪一段才断的。
        self.recordOnlineTranscriptionTimings(
          startedAt: startedAt,
          downloadFinishedAt: downloadFinishedAt,
          finishedAt: failedAt,
          downloadedBytes: downloadedBytes,
          succeeded: false
        )
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

  /// 顺利跑完时不显示分段耗时的阈值。
  ///
  /// 常驻显示是当初为了定位「三四十秒」加的，现在正常是 5s 上下，天天挂着
  /// 只是噪音；但整段撤掉又会让日后的退化悄无声息。折中成「快就闭嘴，
  /// 慢就自己冒出来」——刚好在需要它的时候在。
  private static let onlineTranscriptionTimingsVisibleAbove: Double = 10
  /// 把在线转写拆成「下载音轨 / 本机切片 / 上传等 ASR」三段写成一行诊断。
  /// 分界点：`downloadFinishedAt` 是临时文件落盘，`onlineUploadStartInstant`
  /// 是首次 `progress(0, total)`（全部分片导出完成、第一片上传之前）。
  /// 任何一段缺失就省掉那一段，绝不用估算值冒充实测。
  private func recordOnlineTranscriptionTimings(
    startedAt: ContinuousClock.Instant,
    downloadFinishedAt: ContinuousClock.Instant?,
    finishedAt: ContinuousClock.Instant,
    downloadedBytes: Int?,
    succeeded: Bool
  ) {
    let total = Self.seconds(startedAt.duration(to: finishedAt))
    // 失败一律显示：卡住时最需要知道的就是走到哪一段才断的。
    guard !succeeded || total > Self.onlineTranscriptionTimingsVisibleAbove else {
      onlineTranscriptionTimings = nil
      return
    }
    var parts: [String] = []
    let chunkStart = downloadFinishedAt ?? startedAt
    if let downloadFinishedAt {
      var label = String(format: "下载 %.1fs", Self.seconds(startedAt.duration(to: downloadFinishedAt)))
      if let downloadedBytes {
        label += String(format: "/%.1fMB", Double(downloadedBytes) / 1_048_576)
      }
      parts.append(label)
    }
    if let uploadStart = onlineUploadStartInstant {
      parts.append(String(format: "切片 %.1fs", Self.seconds(chunkStart.duration(to: uploadStart))))
      var label = String(format: "转写 %.1fs", Self.seconds(uploadStart.duration(to: finishedAt)))
      if let total = onlineChunkTotal { label += " · \(total) 片" }
      parts.append(label)
    } else {
      // 没走到上传就断了：切片段和上传段无法区分，合并报出来而不是硬拆。
      parts.append(String(format: "本机准备 %.1fs（未开始上传）", Self.seconds(chunkStart.duration(to: finishedAt))))
    }
    parts.append(String(format: "合计 %.1fs", total))
    onlineTranscriptionTimings = parts.joined(separator: " · ")
  }

  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  /// 取走待处理的在线转写上下文，取走即清空。
  ///
  /// 这个上下文原来只在**成功**路径被置 nil，取消模型下载、下载失败都不清。
  /// 于是：对 A 发起在线转写 → 提示下载模型 → 取消（临时文件已删，但 context 还在）
  /// → 换到 B 点转写 → 确认下载 → 优先取到 A 那份陈旧 context，去转写一个已被删除
  /// 的临时文件，并把状态写到 **A 的 taskID** 上，而界面显示的是 B。
  /// 「取走即消费」让它不可能活过一次使用。
  private func takePendingRemoteTranscriptionContext() -> RemoteTranscriptionContext? {
    defer { pendingRemoteTranscriptionContext = nil }
    return pendingRemoteTranscriptionContext
  }

  /// This is the only UI path allowed to call model installation.
  func confirmModelDownloadAndTranscribe() {
    isTranscriptionModelConfirmationPresented = false
    if let context = takePendingRemoteTranscriptionContext() {
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
    if let context = takePendingRemoteTranscriptionContext(), let history {
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
    // 用 defer 而不是把清理写在函数末尾。
    //
    // `AppleSpeechVideoTranscriber` 的契约明写「caller owns workspaceURL and removes
    // it on every terminal outcome」，但原来清理只在最后一行，本函数有六处提前
    // return 会绕过它。最容易触发的是 requestID 变了（用户发起第二次转写，或
    // configure() 换了 requestID）——此时目录里已经躺着抽取出来的音频，之后无人
    // 删除，累积到重启。defer 由语言保证每条退出路径都走到。
    defer { try? FileManager.default.removeItem(at: context.workspaceURL) }
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

  func clearTagSelection() {
    guard !selectedTagNormalizedNames.isEmpty else { return }
    selectedTagNormalizedNames = []
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
    // 正文取最新快照（含转写与整理稿），frontmatter 取最新的**来源**快照。
    //
    // 原来正文也排除转写稿，理由写的是「优先原文 snapshot」。但视频条目的「原文」
    // 就是几十字的 caption——抓一条视频、转写、整理，然后导出 Markdown/纯文本/
    // PDF/Word 或「拷贝全文」，拿到的全是那几十字，几千字转写稿一个字都不在。
    // 而阅读区显示的是 snapshots.last（转写稿）、总结喂给模型的也是 snapshots.last，
    // 「编辑转写」的说明更是明写「保存后总结、翻译与导出都使用校对后的文本」。
    // 四条导出路径与 UI 承诺、阅读区、总结输入全都对不上，只有 .json 完整导出
    // 能拿到转写内容。
    //
    // 作者/发布时间这类 frontmatter 仍应来自来源快照——转写稿没有这些字段，
    // 这正是阅读区 latestSourceSnapshot 已有的区分。
    let transcriptionKind = CapturedDocument.Origin.localTranscription.rawValue
    guard let snapshot = detail.snapshots.last else { return nil }
    let sourceSnapshot = detail.snapshots.last(where: { $0.sourceKind != transcriptionKind })
      ?? snapshot
    let note = MarkdownNoteFrontmatter.parse(snapshot.bodyText)
    let sourceNote = MarkdownNoteFrontmatter.parse(sourceSnapshot.bodyText)
    let body = note.body.isEmpty ? snapshot.bodyText : note.body
    func nonEmpty(_ value: String?) -> String? {
      guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
      return trimmed
    }
    // 标题与作者/发布时间取来源快照：转写稿的标题常是空的或「转写」这类占位，
    // 作者/发布时间它根本没有。
    let title = nonEmpty(sourceSnapshot.title)
      ?? nonEmpty(snapshot.title)
      ?? CapturedDocumentTitle.display(nil, for: detail.task.canonicalURL)

    var lines: [String] = ["---", "title: \(yamlQuoted(title))", "source: \(yamlQuoted(detail.task.canonicalURL))"]
    if let author = nonEmpty(sourceNote.author) { lines.append("author: \(yamlQuoted(author))") }
    if let published = nonEmpty(sourceNote.published) { lines.append("published: \(yamlQuoted(published))") }
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
      if let snapshot = value.snapshots.last {
        let snapshotID = snapshot.id
        localImageURLs = imageCache?.localImageURLs(taskID: taskID, snapshotID: snapshotID) ?? []
        backfillRemoteImagesIfNeeded(
          snapshot: snapshot,
          taskID: taskID,
          generation: generation
        )
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
      mindMapRecord = (try? history?.mindMapStore?.loadMindMap(taskID: taskID)) ?? nil
      if mindMapTaskID != taskID { mindMapState = .idle; mindMapTaskID = nil }
      ledgerTokenTotals = (try? history?.tokenUsageStore?.ledgerTokenTotals(taskID: taskID)) ?? nil
      taskExcerpts = (try? history?.annotationStore?.listExcerpts(taskID: taskID)) ?? []
      if loadedNoteTaskID != taskID {
        // 覆盖草稿之前先把上一条待落库的笔记冲刷掉。这里必须在同一个同步段里把
        // pendingNote 取走：赋值 taskNoteDraft 会触发编辑器的 onChange →
        // scheduleNoteSave(新条目)，那一步会覆盖 pendingNote。await 让出去再冲刷
        // 就晚了，上一条的最后一段编辑会被静默丢掉。
        let carriedOver = takePendingNote()
        loadedNoteTaskID = taskID
        taskNoteDraft = (try? history?.annotationStore?.loadNote(taskID: taskID) ?? nil) ?? ""
        if let carriedOver { persistNoteDetached(carriedOver) }
      }
      detailState = .loaded
    case let .failure(code):
      detail = nil
      localImageURLs = []
      localMediaFileURL = nil
      localMediaLease = nil
      localMediaResolutionFailure = nil
      mindMapRecord = nil
      ledgerTokenTotals = nil
      detailErrorCode = code
      detailState = .failed
    }
  }

  /// A capture can persist before a transient CDN/network failure leaves its
  /// image cache empty. Opening that history item retries the already-stored
  /// remote markdown references once per App session, then refreshes only the
  /// local image list. History text and database rows remain unchanged.
  private func backfillRemoteImagesIfNeeded(
    snapshot: ContentSnapshot,
    taskID: TaskID,
    generation: UUID
  ) {
    guard localImageURLs.isEmpty,
          let imageCache,
          let imageResources,
          !MarkdownRemoteImageReferences.absoluteHTTPSURLs(in: snapshot.bodyText).isEmpty,
          imageBackfillAttemptedSnapshotIDs.insert(snapshot.id).inserted
    else { return }

    imageBackfillTask?.cancel()
    let captureID = "history-backfill-\(UUID().uuidString.lowercased())"
    imageBackfillTask = Task { [weak self] in
      await imageCache.stageRemoteMarkdownImages(
        markdown: snapshot.bodyText,
        captureID: captureID,
        resources: imageResources
      )
      guard !Task.isCancelled else {
        imageCache.discardStaged(captureID: captureID)
        return
      }
      imageCache.promote(
        captureID: captureID,
        taskID: taskID,
        snapshotID: snapshot.id
      )
      guard let self,
            self.configurationGeneration == generation,
            self.selectedTaskID == taskID,
            self.detail?.snapshots.last?.id == snapshot.id
      else { return }
      self.localImageURLs = imageCache.localImageURLs(
        taskID: taskID,
        snapshotID: snapshot.id
      )
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
