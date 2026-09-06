import Foundation
import LinkDigestCore
import LinkDigestTransport

struct CurrentCapture: Sendable, Equatable {
  let document: CapturedDocument
  let wireEnvelope: CaptureEnvelopeV1?
  let wireEnvelopeV2: CaptureEnvelopeV2?
  let mediaDescriptor: MediaDescriptor?
  let taskID: TaskID
  let snapshotID: ContentSnapshotID
  /// App 内部发起的抓取没有 wire envelope；批量主页导入仍需要把用户明确选择的
  /// “只保存”意图带到自动处理与媒体保存边界。
  private let appRequestedAction: CaptureRequestedAction?
  /// 仅供 App 内批量主页导入使用。wire envelope 的 `.save` 保持既有媒体语义，
  /// 避免把扩展的“保存”误当成“禁止自动媒体保存”。
  let suppressesAutomaticEnrichment: Bool

  var allowsAutomaticEnrichment: Bool { !suppressesAutomaticEnrichment }

  var requestedAction: CaptureRequestedAction? {
    wireEnvelope?.requestedAction ?? wireEnvelopeV2?.requestedAction ?? appRequestedAction
  }

  var browserDeclaredFaviconURL: URL? {
    let raw = wireEnvelope?.source.faviconURL ?? wireEnvelopeV2?.source.faviconURL
    return raw.flatMap(URL.init(string:))
  }

  init(envelope: CaptureEnvelopeV1, taskID: TaskID, snapshotID: ContentSnapshotID) {
    document = .init(wire: envelope)
    wireEnvelope = envelope
    wireEnvelopeV2 = nil
    mediaDescriptor = envelope.media.map {
      MediaDescriptor(
        kind: .directFile,
        pageURL: envelope.source.url,
        canonicalURL: envelope.source.url,
        platform: $0.platform,
        ephemeralPlaybackURL: $0.videoURL,
        posterURL: $0.coverURL,
        durationSeconds: $0.durationSeconds,
        author: $0.author,
        transcriptionCapability: .supported,
        selectionReason: .singleCandidate,
        playbackState: .unknown
      )
    }
    self.taskID = taskID
    self.snapshotID = snapshotID
    appRequestedAction = nil
    suppressesAutomaticEnrichment = false
  }

  init(envelope: CaptureEnvelopeV2, taskID: TaskID, snapshotID: ContentSnapshotID) {
    document = .init(wire: envelope)
    wireEnvelope = nil
    wireEnvelopeV2 = envelope
    mediaDescriptor = envelope.media
    self.taskID = taskID
    self.snapshotID = snapshotID
    appRequestedAction = nil
    suppressesAutomaticEnrichment = false
  }

  init(
    document: CapturedDocument,
    taskID: TaskID,
    snapshotID: ContentSnapshotID,
    requestedAction: CaptureRequestedAction? = nil,
    suppressesAutomaticEnrichment: Bool = false
  ) {
    self.document = document
    wireEnvelope = nil
    wireEnvelopeV2 = nil
    mediaDescriptor = document.media.map {
      MediaDescriptor(
        kind: .directFile,
        pageURL: document.url,
        canonicalURL: document.url,
        platform: $0.platform,
        ephemeralPlaybackURL: $0.videoURL,
        posterURL: $0.coverURL,
        durationSeconds: $0.durationSeconds,
        author: $0.author,
        transcriptionCapability: .supported,
        selectionReason: .singleCandidate,
        playbackState: .unknown
      )
    }
    self.taskID = taskID
    self.snapshotID = snapshotID
    appRequestedAction = requestedAction
    self.suppressesAutomaticEnrichment = suppressesAutomaticEnrichment
  }

  /// Browser media stays session-only until the user taps “保存到本地”. Manual
  /// source adapters keep their established explicit local-ingest callback.
  var shouldAutomaticallyPersistLegacyMedia: Bool {
    allowsAutomaticEnrichment && document.media != nil && document.origin != .browserCapture
  }

}

struct CaptureReceiver: Sendable {
  typealias CaptureSink = @Sendable (CurrentCapture) async -> Void
  /// 受理结果只回「入队多少、跳过多少」——逐条抓取在 App 的队列里慢慢做，
  /// 不能占住扩展的 native-message 预算（与图片下载同一个 fail-open 模式）。
  struct BookmarksOutcome: Sendable, Equatable {
    let queued: Int
    let skipped: Int
  }
  typealias BookmarksSink = @Sendable (XBookmarksSyncRequest) async -> BookmarksOutcome

  private let history: HistoryApplicationService?
  private let storageWriteGate: StorageWriteGate
  private let nowMilliseconds: @Sendable () -> Int64
  private let captureSink: CaptureSink
  private let bookmarksSink: BookmarksSink?

  init(
    history: HistoryApplicationService?,
    storageWriteGate: StorageWriteGate,
    nowMilliseconds: @escaping @Sendable () -> Int64,
    captureSink: @escaping CaptureSink,
    bookmarksSink: BookmarksSink? = nil
  ) {
    self.history = history
    self.storageWriteGate = storageWriteGate
    self.nowMilliseconds = nowMilliseconds
    self.captureSink = captureSink
    self.bookmarksSink = bookmarksSink
  }

  func process(_ data: Data) async -> NativeResponse {
    // 收藏夹同步走独立消息：它带的只是一串推文 id，不是一次页面捕获，
    // 因此不经过 capture envelope 的 schema（那套契约保持冻结）。
    do {
      if let lookup = try XBookmarksLookupRequest.decode(data) {
        // 勾选前查重：只读历史，不入队。按推文 id 认，不拿 /i/status 整串去比。
        // history 缺失或查询失败时回空列表（扩展可降级到游标粗标）。
        let found = (try? history?.existingXTweetIDs(in: Set(lookup.tweetIDs))) ?? []
        return .bookmarksLookup(
          version: 1,
          requestId: lookup.requestId,
          existingIDs: lookup.tweetIDs.filter { found.contains($0) }
        )
      }
      if let request = try XBookmarksSyncRequest.decode(data) {
        guard let bookmarksSink else {
          return .error(appError(
            requestID: request.requestId,
            category: "protocol",
            code: CaptureValidationError.CAPTURE_SCHEMA_INVALID.rawValue,
            retryable: false,
            action: "upgrade_app"
          ))
        }
        let outcome = await bookmarksSink(request)
        return .bookmarksAccepted(
          version: 1,
          requestId: request.requestId,
          queuedCount: outcome.queued,
          skippedCount: outcome.skipped
        )
      }
    } catch let issue as CaptureValidationError {
      return .error(appError(
        requestID: "app-receiver",
        category: "protocol",
        code: issue.rawValue,
        retryable: false,
        action: "retry"
      ))
    } catch {
      return .error(appError(
        requestID: "app-receiver",
        category: "protocol",
        code: CaptureValidationError.CAPTURE_SCHEMA_INVALID.rawValue,
        retryable: false,
        action: "retry"
      ))
    }

    let wire: CaptureWireEnvelope
    do {
      wire = try CaptureWireEnvelope.decode(data)
    } catch let issue as CaptureValidationError {
      return .error(appError(
        requestID: "app-receiver",
        category: "protocol",
        code: issue.rawValue,
        retryable: false,
        action: "retry"
      ))
    } catch {
      return .error(appError(
        requestID: "app-receiver",
        category: "protocol",
        code: CaptureValidationError.CAPTURE_SCHEMA_INVALID.rawValue,
        retryable: false,
        action: "retry"
      ))
    }

    let requestID = wire.requestId
    do {
      let ingestor = CaptureIngestService(
        history: history,
        storageWriteGate: storageWriteGate,
        nowMilliseconds: nowMilliseconds,
        captureSink: captureSink
      )
      switch wire {
      case let .v1(envelope):
        _ = try await ingestor.ingest(envelope: envelope)
      case let .v2(envelope):
        _ = try await ingestor.ingest(envelope: envelope)
      }
    } catch let failure as StorageWriteGateFailure {
      return .error(storageError(
        requestID: requestID,
        code: failure.code
      ))
    } catch {
      return .error(storageError(
        requestID: requestID,
        code: .writeFailed
      ))
    }
    return .taskAccepted(
      version: 1,
      requestId: requestID,
      characterCount: wire.characterCount
    )
  }

  func handleClient(_ client: FileHandle) async {
    defer { try? client.close() }
    let response: NativeResponse
    do {
      let data = try ChromiumFramer.readFrame(from: client, timeout: 10)
      response = await process(data)
    } catch {
      response = .error(appError(
        requestID: "app-receiver",
        category: "protocol",
        code: CaptureValidationError.CAPTURE_SCHEMA_INVALID.rawValue,
        retryable: false,
        action: "retry"
      ))
    }
    try? ChromiumFramer.writeFrame(try JSONEncoder().encode(response), to: client)
  }

  private func storageError(requestID: String, code: StorageErrorCode) -> AppError {
    let presentation = StorageErrorMapper.presentation(for: code)
    return appError(
      requestID: requestID,
      category: "storage",
      code: presentation.code.rawValue,
      retryable: presentation.retryable,
      action: presentation.action
    )
  }

  private func appError(
    requestID: String,
    category: String,
    code: String,
    retryable: Bool,
    action: String
  ) -> AppError {
    AppError(
      version: 1,
      requestId: requestID,
      createdAt: ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: Double(nowMilliseconds()) / 1_000)
      ),
      category: category,
      code: code,
      retryable: retryable,
      action: action,
      safeDetail: nil
    )
  }
}
