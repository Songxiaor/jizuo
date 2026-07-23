import Foundation

/// Durable media row for a captured task. Files live under
/// `Application Support/LinkDigest/Media/` and are named by content SHA-256.
public struct MediaAsset: Codable, Sendable, Equatable {
  public let id: String
  public let taskID: TaskID
  public let snapshotID: ContentSnapshotID?
  public let relativePath: String
  /// Security-scoped bookmark for a user-selected file. NULL means the legacy
  /// Application Support media root. It is repository-only and never exported.
  public let fileBookmark: Data?
  public let contentSHA256: String
  public let byteSize: Int64
  public let durationSeconds: Double?
  public let platform: String
  public let author: String?
  public let transcriptionStatus: TranscriptionStatus
  public let createdAtMilliseconds: Int64

  public init(
    id: String = UUID().uuidString.lowercased(),
    taskID: TaskID,
    snapshotID: ContentSnapshotID? = nil,
    relativePath: String,
    fileBookmark: Data? = nil,
    contentSHA256: String,
    byteSize: Int64,
    durationSeconds: Double? = nil,
    platform: String,
    author: String? = nil,
    transcriptionStatus: TranscriptionStatus = .none,
    createdAtMilliseconds: Int64
  ) {
    self.id = id
    self.taskID = taskID
    self.snapshotID = snapshotID
    self.relativePath = relativePath
    self.fileBookmark = fileBookmark
    self.contentSHA256 = contentSHA256
    self.byteSize = byteSize
    self.durationSeconds = durationSeconds
    self.platform = platform
    self.author = author
    self.transcriptionStatus = transcriptionStatus
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

public enum TranscriptionStatus: String, Codable, Sendable, Equatable, CaseIterable {
  case none
  case pending
  case running
  case completed
  case failed
}

/// Durable ownership for one transcription request. SQLite allocates the
/// strictly increasing generation; wall-clock time is deliberately not part of
/// ordering or ownership.
public struct TranscriptionAttemptToken: Codable, Sendable, Equatable, Hashable {
  public let id: String
  public let mediaID: String
  public let generation: Int64

  public init(
    id: String = UUID().uuidString.lowercased(),
    mediaID: String,
    generation: Int64
  ) {
    self.id = id
    self.mediaID = mediaID
    self.generation = generation
  }
}

/// Non-terminal mutations allowed after SQLite has assigned an owner.
/// `pending` belongs exclusively to `beginMediaTranscription`; `completed`
/// belongs exclusively to the atomic completion transaction.
public enum TranscriptionStatusMutation: String, Sendable, Equatable, CaseIterable {
  case running
  case none
  case failed
}

public enum TranscriptionStatusUpdateResult: Sendable, Equatable {
  case applied
  case stale
}

public enum CompleteMediaTranscriptionResult: Sendable, Equatable {
  case accepted(AcceptCaptureResult)
  case replay(AcceptCaptureResult)
  case stale
}

/// Minimal, non-sensitive completion facts. Source and engine are bounded
/// factual identifiers rather than a closed Apple-only enum; provider/model
/// remain nullable so the schema does not need rewriting for another local or
/// remote engine. SpeechAnalyzer exposes a locale asset, not a marketing model.
public struct TranscriptionCompletionEvidence: Codable, Sendable, Equatable {
  public let id: String
  public let source: String
  public let engine: String
  public let provider: String?
  public let model: String?
  public let localeIdentifier: String?
  public let language: String?
  public let completedAtMilliseconds: Int64

  public init(
    id: String = UUID().uuidString.lowercased(),
    source: String,
    engine: String,
    provider: String? = nil,
    model: String? = nil,
    localeIdentifier: String? = nil,
    language: String? = nil,
    completedAtMilliseconds: Int64
  ) {
    self.id = id
    self.source = source
    self.engine = engine
    self.provider = provider
    self.model = model
    self.localeIdentifier = localeIdentifier
    self.language = language
    self.completedAtMilliseconds = completedAtMilliseconds
  }

  public static func appleSpeechAnalyzer(
    localeIdentifier: String,
    language: String,
    completedAtMilliseconds: Int64
  ) -> Self {
    .init(
      source: "on_device",
      engine: "apple_speech_analyzer",
      provider: "apple",
      model: nil,
      localeIdentifier: localeIdentifier,
      language: language,
      completedAtMilliseconds: completedAtMilliseconds
    )
  }

  public static func onlineSpeechToText(
    provider: String,
    model: String,
    language: String?,
    completedAtMilliseconds: Int64
  ) -> Self {
    .init(
      source: "cloud",
      engine: "openai_compatible_audio_transcriptions",
      provider: provider,
      model: model,
      localeIdentifier: nil,
      language: language,
      completedAtMilliseconds: completedAtMilliseconds
    )
  }

  /// Text-in/text-out tidy pass over an existing transcript. Distinct from
  /// speech-to-text so evidence never claims audio left the machine.
  public static func onlineTextTidy(
    provider: String,
    model: String,
    completedAtMilliseconds: Int64
  ) -> Self {
    .init(
      source: "cloud",
      engine: "openai_compatible_chat_completions",
      provider: provider,
      model: model,
      localeIdentifier: nil,
      language: nil,
      completedAtMilliseconds: completedAtMilliseconds
    )
  }
}

public struct AttachMediaCommand: Sendable, Equatable {
  public let asset: MediaAsset
  public init(asset: MediaAsset) { self.asset = asset }
}

public enum MediaDownloadError: Error, Sendable, Equatable {
  case invalidURL
  case unsafeURL
  case responseStatus
  case unsupportedContainer
  case responseTooLarge
  case insufficientDiskSpace
  case emptyBody
  case timedOut
  case network
  case cancelled
  case storageLocationUnavailable
  case unsafeDestination

  public var userMessage: String {
    switch self {
    case .invalidURL: "视频地址无效。"
    case .unsafeURL: "为保护本机网络，LinkDigest 不能下载这个视频地址。"
    case .responseStatus: "视频暂时无法下载，请稍后重试。"
    case .unsupportedContainer: "只支持 mp4 / mov 视频容器。"
    case .responseTooLarge: "视频超过 200MB 上限，暂不导入。"
    case .insufficientDiskSpace: "本机磁盘空间不足，无法保存视频。"
    case .emptyBody: "视频内容为空。"
    case .timedOut: "下载视频超时，请稍后重试。"
    case .network: "无法下载视频，请检查网络后重试。"
    case .cancelled: "已取消视频下载。"
    case .storageLocationUnavailable: "视频保存位置不可用，请在设置中重新选择文件夹。"
    case .unsafeDestination: "目标文件不是安全的普通文件，已停止保存。"
    }
  }
}
