import Foundation

protocol ConnectionCancelling: AnyObject { func cancel() }

/// Lock-protected lifetime gate shared by cancellation, timeout, framing error
/// and late callbacks. `finish` is true exactly once.
final class ConnectionLifecycle: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelAction: @Sendable () -> Void
  private var cancelled = false
  private var finished = false
  init(cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }
  func cancelOnce() { if lock.withLock({ if cancelled { return false }; cancelled = true; return true }) { cancelAction() } }
  func finishOnce() -> Bool { lock.withLock { if finished { return false }; finished = true; return true } }
}
