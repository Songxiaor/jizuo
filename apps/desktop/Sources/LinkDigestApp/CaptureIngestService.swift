import Foundation
import LinkDigestCore

/// Shared application boundary for browser and manual documents. It owns the
/// only legal order: synchronous storage commit first, UI publication second.
/// Socket validation deliberately remains in `CaptureReceiver`.
struct CaptureIngestService: Sendable {
  typealias CaptureSink = CaptureReceiver.CaptureSink
  private let history: HistoryApplicationService?
  private let storageWriteGate: StorageWriteGate
  private let nowMilliseconds: @Sendable () -> Int64
  private let captureSink: CaptureSink
  private let afterCommit: @Sendable (CapturedDocument, AcceptCaptureResult) -> Void
  /// 抓取成败的本地计数。测试里是 nil（见 `CaptureOutcomeStore.shared`）。
  private let outcomeStore: CaptureOutcomeStore?

  init(history: HistoryApplicationService?, storageWriteGate: StorageWriteGate, nowMilliseconds: @escaping @Sendable () -> Int64, captureSink: @escaping CaptureSink, afterCommit: @escaping @Sendable (CapturedDocument, AcceptCaptureResult) -> Void = { _, _ in }, outcomeStore: CaptureOutcomeStore? = .shared) {
    self.history = history
    self.storageWriteGate = storageWriteGate
    self.nowMilliseconds = nowMilliseconds
    self.captureSink = captureSink
    self.afterCommit = afterCommit
    self.outcomeStore = outcomeStore
  }

  func ingest(envelope: CaptureEnvelopeV1) async throws -> CurrentCapture {
    let document = CapturedDocument(wire: envelope)
    let command = try AcceptCaptureCommand(
      envelope: envelope,
      receivedAtMilliseconds: nowMilliseconds()
    )
    return try await commitAndPublish(command: command, document: document) { accepted in
      CurrentCapture(envelope: envelope, taskID: accepted.taskID, snapshotID: accepted.snapshotID)
    }
  }

  func ingest(envelope: CaptureEnvelopeV2) async throws -> CurrentCapture {
    let document = CapturedDocument(wire: envelope)
    let command = try AcceptCaptureCommand(
      envelope: envelope,
      receivedAtMilliseconds: nowMilliseconds()
    )
    return try await commitAndPublish(command: command, document: document) { accepted in
      CurrentCapture(envelope: envelope, taskID: accepted.taskID, snapshotID: accepted.snapshotID)
    }
  }

  /// 浏览器代抓：内容来自扩展，但要按抓取队列的意图（下载、不抢当前阅读、批量导入）
  /// 入库。provenance 必须按 envelope 记成浏览器抓取，不能走本机文档那条。
  func ingest(
    document: CapturedDocument,
    envelope: CaptureWireEnvelope,
    requestedAction: CaptureRequestedAction? = nil,
    suppressesAutomaticEnrichment: Bool = false,
    navigationIntent: CaptureNavigationIntent = .reveal
  ) async throws -> CurrentCapture {
    let command: AcceptCaptureCommand
    switch envelope {
    case let .v1(value):
      command = try AcceptCaptureCommand(envelope: value, receivedAtMilliseconds: nowMilliseconds())
    case let .v2(value):
      command = try AcceptCaptureCommand(envelope: value, receivedAtMilliseconds: nowMilliseconds())
    }
    return try await commitAndPublish(command: command, document: document) { accepted in
      CurrentCapture(
        document: document,
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        requestedAction: requestedAction,
        suppressesAutomaticEnrichment: suppressesAutomaticEnrichment,
        navigationIntent: navigationIntent
      )
    }
  }

  func ingest(
    _ document: CapturedDocument,
    requestedAction: CaptureRequestedAction? = nil,
    suppressesAutomaticEnrichment: Bool = false,
    navigationIntent: CaptureNavigationIntent = .reveal,
    receivedAtMilliseconds: Int64? = nil
  ) async throws -> CurrentCapture {
    // 批量导入的旧档案带原本的创建 / 录制时间进来，列表按那个时间归组，不堆在「今天」。
    let command = try AcceptCaptureCommand(
      document: document,
      receivedAtMilliseconds: receivedAtMilliseconds ?? nowMilliseconds()
    )
    return try await commitAndPublish(command: command, document: document) { accepted in
      CurrentCapture(
        document: document,
        taskID: accepted.taskID,
        snapshotID: accepted.snapshotID,
        requestedAction: requestedAction,
        suppressesAutomaticEnrichment: suppressesAutomaticEnrichment,
        navigationIntent: navigationIntent
      )
    }
  }

  private func commitAndPublish(
    command: AcceptCaptureCommand,
    document: CapturedDocument,
    makeCurrent: @Sendable (AcceptCaptureResult) -> CurrentCapture
  ) async throws -> CurrentCapture {
    AppLog.info(.capture, "capture_ingest_started", [
      "platform": document.platform,
      "origin": String(describing: document.origin),
      "host": AppLog.host(document.url),
      "chars": String(document.text.unicodeScalars.count),
    ])
    guard let history else {
      let code = (await storageWriteGate.currentAvailability()).code ?? .unavailable
      recordFailure(document: document, code: code.rawValue)
      throw StorageWriteGateFailure.unavailable(code)
    }
    let accepted: AcceptCaptureResult
    do {
      accepted = try await storageWriteGate.performCaptureWrite(
        operation: {
          try history.acceptCapture(command)
        },
        mapFailure: { error in
          guard let failure = error as? RepositoryFailure else { return .writeFailed }
          return StorageErrorMapper.map(failure, context: .write).code
        }
      )
    } catch let failure as StorageWriteGateFailure {
      if failure.didDegrade { await storageWriteGate.publishCurrentAvailability() }
      recordFailure(document: document, code: failure.code.rawValue)
      throw failure
    } catch {
      _ = await storageWriteGate.degrade(.writeFailed)
      await storageWriteGate.publishCurrentAvailability()
      recordFailure(document: document, code: StorageErrorCode.writeFailed.rawValue)
      throw StorageWriteGateFailure.captureWriteFailed(.writeFailed)
    }
    afterCommit(document, accepted)
    let current = makeCurrent(accepted)
    await captureSink(current)
    AppLog.info(.capture, "capture_ingest_succeeded", [
      "platform": document.platform,
      "replayed": String(accepted.deliveryWasReplayed),
    ])
    outcomeStore?.recordSuccess(platform: document.platform)
    return current
  }

  private func recordFailure(document: CapturedDocument, code: String) {
    AppLog.error(.capture, "capture_ingest_failed", code: code, [
      "platform": document.platform,
      "host": AppLog.host(document.url),
    ])
    outcomeStore?.recordFailure(platform: document.platform, code: code)
  }
}
