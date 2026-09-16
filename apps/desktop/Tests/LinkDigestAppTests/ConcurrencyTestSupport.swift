import Foundation
import XCTest

/// 并发测试的两件公共设施：**不占协作线程池的阻塞**，和**带超时的 `task.value`**。
///
/// 为什么需要它们：
///
/// 1) Swift 并发的协作线程池不保证在某条线程被阻塞时再开一条。仓储写事务是同步的
///    （`StorageWriteGate.performCaptureWrite(operation:)` 的 operation 不能 await），
///    测试要卡住一次写事务就只能在那个闭包里阻塞。如果这个闭包跑在协作线程上，
///    而测试主体接下来还要 `await`，两边就会互相等：测试永久挂起，没有任何输出，
///    只能靠 CI 的整体超时把整轮杀掉。`BlockingWorkExecutor` 把这类任务挪到普通
///    并发队列上，阻塞的是可以随时新增的 dispatch 线程，协作线程池一条都不占。
///
/// 2) 裸 `await task.value` 一旦对面不返回就是永久挂起。`awaitValue` 用一场竞速
///    把它变成「5 秒内没结果就 XCTFail」——同样是失败，但能看见是哪条、卡在哪。
enum ConcurrencyTestSupport {
  static let defaultTimeout: TimeInterval = 5
}

struct TestTimeoutError: Error, CustomStringConvertible {
  let label: String
  var description: String { "timed out waiting for \(label)" }
}

/// 把任务调度到普通并发队列上，这样任务里的同步阻塞不会占用协作线程池。
final class BlockingWorkExecutor: TaskExecutor, @unchecked Sendable {
  private let queue: DispatchQueue

  init(label: String = "linkdigest.tests.blocking-work") {
    queue = DispatchQueue(label: label, attributes: .concurrent)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let unowned = UnownedJob(job)
    queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

/// `await task.value` 的超时兜底。超时时 XCTFail 并抛错，绝不静默挂起。
func awaitValue<Success: Sendable>(
  _ task: Task<Success, Error>,
  timeout: TimeInterval = ConcurrencyTestSupport.defaultTimeout,
  label: String = "task.value",
  file: StaticString = #filePath,
  line: UInt = #line
) async throws -> Success {
  try await withTimeout(timeout, label: label, file: file, line: line) { try await task.value }
}

func awaitValue<Success: Sendable>(
  _ task: Task<Success, Never>,
  timeout: TimeInterval = ConcurrencyTestSupport.defaultTimeout,
  label: String = "task.value",
  file: StaticString = #filePath,
  line: UInt = #line
) async throws -> Success {
  try await withTimeout(timeout, label: label, file: file, line: line) { await task.value }
}

/// 通用竞速：`body` 与一个计时器抢先，谁先完成算谁的。
func withTimeout<Value: Sendable>(
  _ seconds: TimeInterval = ConcurrencyTestSupport.defaultTimeout,
  label: String = "operation",
  file: StaticString = #filePath,
  line: UInt = #line,
  _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw TestTimeoutError(label: label)
    }
    do {
      guard let value = try await group.next() else {
        throw TestTimeoutError(label: label)
      }
      group.cancelAll()
      return value
    } catch let error as TestTimeoutError {
      group.cancelAll()
      XCTFail("\(error.description)（\(seconds) 秒）", file: file, line: line)
      throw error
    } catch {
      group.cancelAll()
      throw error
    }
  }
}

/// 不阻塞任何线程地等一个 `DispatchSemaphore` 被 signal。
///
/// 直接 `semaphore.wait()` 会把当前协作线程按住，正是上面说的那种死锁。这里改成
/// 零超时轮询 + `Task.sleep`：调用方在等待期间是挂起的，线程照常还给池子。
func awaitSignal(
  _ semaphore: DispatchSemaphore,
  timeout: TimeInterval = ConcurrencyTestSupport.defaultTimeout,
  label: String = "semaphore",
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if pollSignal(semaphore) { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  XCTFail("等待 \(label) 超时（\(timeout) 秒）", file: file, line: line)
  throw TestTimeoutError(label: label)
}

/// 零超时探测必须放在同步函数里：`DispatchSemaphore.wait` 在 async 上下文中
/// 是被禁用的 API（Swift 6 里直接报错），哪怕超时是 0。
private func pollSignal(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now()) == .success
}
