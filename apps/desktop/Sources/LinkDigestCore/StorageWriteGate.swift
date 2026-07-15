import Foundation

public enum StorageWriteGateFailure: Error, Sendable, Equatable {
  case unavailable(StorageErrorCode)
  case captureWriteFailed(StorageErrorCode)

  public var code: StorageErrorCode {
    switch self {
    case let .unavailable(code), let .captureWriteFailed(code):
      code
    }
  }

  public var didDegrade: Bool {
    if case .captureWriteFailed = self { return true }
    return false
  }
}

public actor StorageWriteGate {
  public typealias AvailabilitySink = @Sendable (StorageAvailability) async -> Void

  private struct CaptureWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var state: StorageAvailability
  private let availabilitySink: AvailabilitySink
  private var capturePermitHeld = false
  private var captureWaiters: [CaptureWaiter] = []
  private var queuedAttemptObservers: [CheckedContinuation<Void, Never>] = []

  public init(
    initialAvailability: StorageAvailability = .bootstrapping,
    availabilitySink: @escaping AvailabilitySink = { _ in }
  ) {
    state = initialAvailability
    self.availabilitySink = availabilitySink
  }

  public func currentAvailability() -> StorageAvailability {
    state
  }

  public func publishCurrentAvailability() async {
    await availabilitySink(state)
  }

  public func markWritableAfterBootstrap() async {
    guard case .bootstrapping = state else { return }
    state = .writable
    await availabilitySink(.writable)
  }

  // The synchronous Repository Capture transaction runs outside the actor but
  // under this gate's exclusive permit. The operation closure cannot await and
  // cannot contain UI/socket/network/Provider callbacks; permit handoff returns
  // to the actor only after that synchronous transaction finishes.
  public nonisolated func performCaptureWrite<Value: Sendable>(
    operation: @Sendable () throws -> Value,
    mapFailure: @Sendable (Error) -> StorageErrorCode
  ) async throws -> Value {
    let attemptID = UUID()
    try await withTaskCancellationHandler {
      try await acquireCapturePermit(attemptID: attemptID)
    } onCancel: {
      Task { await self.cancelQueuedCaptureAttempt(attemptID: attemptID) }
    }

    do {
      let value = try operation()
      await finishSuccessfulCaptureWrite()
      return value
    } catch {
      throw await finishFailedCaptureWrite(error, mapFailure: mapFailure)
    }
  }

  @discardableResult
  public func degrade(_ code: StorageErrorCode) async -> StorageAvailability {
    if case .unavailable = state {
      return state
    }
    let degraded = StorageAvailability.unavailable(code)
    state = degraded
    rejectQueuedCaptureAttempts(code: code)
    await availabilitySink(degraded)
    return degraded
  }

  // Internal test synchronization: returns only after a Capture attempt has
  // been registered in this gate's waiter queue behind a held permit.
  func waitForQueuedCaptureAttempt() async {
    if !captureWaiters.isEmpty { return }
    await withCheckedContinuation { queuedAttemptObservers.append($0) }
  }

  private func acquireCapturePermit(attemptID: UUID) async throws {
    try Task.checkCancellation()
    guard state.isWriteReady else {
      throw StorageWriteGateFailure.unavailable(state.code ?? .unavailable)
    }
    guard capturePermitHeld else {
      capturePermitHeld = true
      return
    }

    try await withCheckedThrowingContinuation { continuation in
      captureWaiters.append(.init(id: attemptID, continuation: continuation))
      let observers = queuedAttemptObservers
      queuedAttemptObservers.removeAll()
      observers.forEach { $0.resume() }
    }
  }

  private func cancelQueuedCaptureAttempt(attemptID: UUID) {
    guard let index = captureWaiters.firstIndex(where: { $0.id == attemptID }) else {
      return
    }
    let waiter = captureWaiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func finishSuccessfulCaptureWrite() {
    handOffCapturePermitIfPossible()
  }

  private func finishFailedCaptureWrite(
    _ error: Error,
    mapFailure: @Sendable (Error) -> StorageErrorCode
  ) -> StorageWriteGateFailure {
    if case let .unavailable(code) = state {
      capturePermitHeld = false
      rejectQueuedCaptureAttempts(code: code)
      return .unavailable(code)
    }

    let code = mapFailure(error)
    state = .unavailable(code)
    capturePermitHeld = false
    rejectQueuedCaptureAttempts(code: code)
    return .captureWriteFailed(code)
  }

  private func handOffCapturePermitIfPossible() {
    guard state.isWriteReady else {
      capturePermitHeld = false
      rejectQueuedCaptureAttempts(code: state.code ?? .unavailable)
      return
    }
    guard !captureWaiters.isEmpty else {
      capturePermitHeld = false
      return
    }
    let next = captureWaiters.removeFirst()
    // The permit remains held and transfers directly to this waiter.
    next.continuation.resume()
  }

  private func rejectQueuedCaptureAttempts(code: StorageErrorCode) {
    let waiters = captureWaiters
    captureWaiters.removeAll()
    waiters.forEach {
      $0.continuation.resume(
        throwing: StorageWriteGateFailure.unavailable(code)
      )
    }
  }
}
