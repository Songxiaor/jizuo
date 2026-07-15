import Foundation
import LinkDigestCore
import LinkDigestTransport

struct CurrentCapture: Sendable, Equatable {
  let envelope: CaptureEnvelopeV1
  let taskID: TaskID
  let snapshotID: ContentSnapshotID
}

struct CaptureReceiver: Sendable {
  typealias CaptureSink = @Sendable (CurrentCapture) async -> Void
  private let history: HistoryApplicationService?
  private let storageWriteGate: StorageWriteGate
  private let nowMilliseconds: @Sendable () -> Int64
  private let captureSink: CaptureSink

  init(
    history: HistoryApplicationService?,
    storageWriteGate: StorageWriteGate,
    nowMilliseconds: @escaping @Sendable () -> Int64,
    captureSink: @escaping CaptureSink
  ) {
    self.history = history
    self.storageWriteGate = storageWriteGate
    self.nowMilliseconds = nowMilliseconds
    self.captureSink = captureSink
  }

  func process(_ data: Data) async -> NativeResponse {
    let envelope: CaptureEnvelopeV1
    do {
      envelope = try CaptureValidator.decode(data)
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

    guard let history else {
      let availability = await storageWriteGate.currentAvailability()
      return .error(storageError(
        requestID: envelope.requestId,
        code: availability.code ?? .unavailable
      ))
    }

    let accepted: AcceptCaptureResult
    do {
      accepted = try await storageWriteGate.performCaptureWrite(
        operation: {
          try history.acceptCapture(
            envelope,
            receivedAtMilliseconds: nowMilliseconds()
          )
        },
        mapFailure: { error in
          guard let failure = error as? RepositoryFailure else {
            return .writeFailed
          }
          return StorageErrorMapper.map(failure, context: .write).code
        }
      )
    } catch let failure as StorageWriteGateFailure {
      if failure.didDegrade {
        // The gate state was changed before its actor was released. UI
        // publication is deliberately outside the synchronous write section.
        await storageWriteGate.publishCurrentAvailability()
      }
      return .error(storageError(
        requestID: envelope.requestId,
        code: failure.code
      ))
    } catch {
      let degraded = await storageWriteGate.degrade(.writeFailed)
      await storageWriteGate.publishCurrentAvailability()
      return .error(storageError(
        requestID: envelope.requestId,
        code: degraded.code ?? .writeFailed
      ))
    }

    await captureSink(.init(
      envelope: envelope,
      taskID: accepted.taskID,
      snapshotID: accepted.snapshotID
    ))
    return .taskAccepted(
      version: 1,
      requestId: envelope.requestId,
      characterCount: envelope.capture.characterCount
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
