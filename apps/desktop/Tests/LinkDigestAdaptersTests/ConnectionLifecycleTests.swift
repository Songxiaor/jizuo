import XCTest
@testable import LinkDigestAdapters

final class ConnectionLifecycleTests: XCTestCase {
  func testCancelTimeoutAndOversizeShareOneUnderlyingCancel() {
    let recorder = CancelRecorder()
    let lifecycle = ConnectionLifecycle(cancel: { recorder.cancel() })
    lifecycle.cancelOnce(); lifecycle.cancelOnce(); lifecycle.cancelOnce()
    XCTAssertEqual(recorder.count, 1)
  }
  func testFinishRejectsLateCallbacksWithoutSecondCompletion() {
    let lifecycle = ConnectionLifecycle(cancel: {})
    XCTAssertTrue(lifecycle.finishOnce())
    XCTAssertFalse(lifecycle.finishOnce())
    XCTAssertFalse(lifecycle.finishOnce())
  }
}
private final class CancelRecorder: @unchecked Sendable {
  private let lock = NSLock(); private var value = 0
  func cancel() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
