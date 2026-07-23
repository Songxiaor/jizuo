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

  init(history: HistoryApplicationService?, storageWriteGate: StorageWriteGate, nowMilliseconds: @escaping @Sendable () -> Int64, captureSink: @escaping CaptureSink, afterCommit: @escaping @Sendable (CapturedDocument, AcceptCaptureResult) -> Void = { _, _ in }) {
    self.history = history
    self.storageWriteGate = storageWriteGate
    self.nowMilliseconds = nowMilliseconds
    self.captureSink = captureSink
    self.afterCommit = afterCommit
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

  func ingest(_ document: CapturedDocument) async throws -> CurrentCapture {
    let command = try AcceptCaptureCommand(
      document: document,
      receivedAtMilliseconds: nowMilliseconds()
    )
    return try await commitAndPublish(command: command, document: document) { accepted in
      CurrentCapture(document: document, taskID: accepted.taskID, snapshotID: accepted.snapshotID)
    }
  }

  private func commitAndPublish(
    command: AcceptCaptureCommand,
    document: CapturedDocument,
    makeCurrent: @Sendable (AcceptCaptureResult) -> CurrentCapture
  ) async throws -> CurrentCapture {
    guard let history else {
      throw StorageWriteGateFailure.unavailable((await storageWriteGate.currentAvailability()).code ?? .unavailable)
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
      throw failure
    } catch {
      _ = await storageWriteGate.degrade(.writeFailed)
      await storageWriteGate.publishCurrentAvailability()
      throw StorageWriteGateFailure.captureWriteFailed(.writeFailed)
    }
    afterCommit(document, accepted)
    let current = makeCurrent(accepted)
    await captureSink(current)
    return current
  }
}
