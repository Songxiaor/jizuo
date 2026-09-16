import XCTest
@testable import LinkDigestCore

/// 门禁判定的断言辅助。`validate`/`routingDecision` 现在是 async，
/// `XCTAssertNoThrow` / `XCTAssertThrowsError` 接不住。
func assertPolicyAccepts(
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line,
  _ body: () async throws -> Void
) async {
  do { try await body() } catch {
    XCTFail("unexpected rejection: \(error) \(message())", file: file, line: line)
  }
}

func assertPolicyRejects(
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line,
  _ body: () async throws -> Void
) async {
  do {
    try await body()
    XCTFail("expected rejection \(message())", file: file, line: line)
  } catch {}
}

/// 抓取链路上的域名解析必须是「可取消、有超时、同一个 host 只查一次」的。
///
/// 这三条都不会以崩溃或报错的形式暴露：解析挂住时界面只是一直转圈，占住的还是
/// Swift 并发的协作线程池，连别的任务一起拖慢。所以必须有测试盯着。
final class PublicWebURLPolicyAsyncResolutionTests: XCTestCase {
  /// 永不返回的解析器：模拟 DNS 服务器不回包。
  ///
  /// 「已经开始解析了吗」以前用 `DispatchSemaphore.wait` 问，那会按住调用它的
  /// 那条线程——而测试主体跑在协作线程池上，池子里被按住一条就可能让别的任务
  /// 排不进来，整条测试无输出地挂死。现在换成续体：等待方是挂起，不占线程；
  /// 只有 `release` 仍是信号量，而它阻塞的是 `HostResolution.offloaded` 派发
  /// 出去的普通全局队列线程，本来就是设计好可以被丢弃的那条。
  private final class HangingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private let release = DispatchSemaphore(value: 0)

    func resolve(_: String) throws -> [String] {
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        hasEntered = true
        let pending = entryWaiters
        entryWaiters.removeAll()
        return pending
      }
      waiters.forEach { $0.resume() }
      release.wait()
      return ["8.8.8.8"]
    }

    /// 等到解析真的开始。不阻塞任何线程。
    func waitForEntry() async {
      let alreadyEntered: Bool = lock.withLock { hasEntered }
      guard !alreadyEntered else { return }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = lock.withLock {
          if hasEntered { return true }
          entryWaiters.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }

    /// 测试结束必须放行，否则那条后台线程一直挂着。
    func finish() { release.signal() }
  }

  func testHangingResolutionFailsWithinTheTimeoutInsteadOfBlockingForever() async {
    let resolver = HangingResolver()
    defer { resolver.finish() }
    let policy = PublicWebURLPolicy(
      resolver: { try resolver.resolve($0) },
      allowLoopbackForTesting: false,
      resolverTimeoutSeconds: 0.3
    )

    let started = Date()
    do {
      try await policy.validate(URL(string: "https://slow-dns.example/article")!)
      XCTFail("hanging DNS must not be admitted")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, .timedOut)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "解析超时必须在设定的窗口内返回")
  }

  func testHangingResolutionRespondsToTaskCancellation() async {
    let resolver = HangingResolver()
    defer { resolver.finish() }
    // 超时窗口故意设得很长：这里要证明的是取消本身生效，而不是超时兜底。
    let policy = PublicWebURLPolicy(
      resolver: { try resolver.resolve($0) },
      allowLoopbackForTesting: false,
      resolverTimeoutSeconds: 30
    )

    let task = Task { try await policy.validate(URL(string: "https://slow-dns.example/article")!) }
    await resolver.waitForEntry()
    let started = Date()
    task.cancel()
    do {
      // 取消不生效时这里会永久挂起，测试跑不完也报不出来。竞速兜底让它在
      // 5 秒后以失败告终，而不是拖死整轮。
      try await raceWithTimeout(seconds: 5, label: "cancelled policy.validate") {
        try await task.value
      }
      XCTFail("cancelled resolution unexpectedly succeeded")
    } catch is ResolutionTestTimeout {
      XCTFail("取消后 validate 5 秒内没有返回")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, .cancelled)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "取消必须立刻生效，不能等解析自己超时")
  }

  func testResolutionCacheKeepsOneAnswerPerHostWithinOneFetch() async throws {
    let counter = ResolutionCounter()
    let cache = HostResolutionCache(ttl: 20, base: { host in
      counter.record(host)
      return host == "a.example" ? ["8.8.8.8"] : ["1.1.1.1"]
    })
    let policy = PublicWebURLPolicy(asyncResolver: cache.resolver)

    // 一次抓取里，路由判定 + 对端绑定 + 重定向同 host 那几跳共用一份答案。
    for _ in 0..<4 {
      _ = try await policy.admission(for: URL(string: "https://a.example/page")!)
    }
    XCTAssertEqual(counter.counts["a.example"], 1)

    // 重定向到新 host 仍旧要重新解析。
    _ = try await policy.admission(for: URL(string: "https://b.example/page")!)
    XCTAssertEqual(counter.counts["b.example"], 1)
    XCTAssertEqual(counter.total, 2)
  }

  /// 空答案不进缓存：缓存一次失败等于把失败固化 20 秒。
  func testEmptyAnswersAreNotCached() async {
    let counter = ResolutionCounter()
    let cache = HostResolutionCache(base: { host in
      counter.record(host)
      return []
    })
    let policy = PublicWebURLPolicy(asyncResolver: cache.resolver)
    for _ in 0..<2 {
      await assertPolicyRejects { try await policy.validate(URL(string: "https://empty.example/page")!) }
    }
    XCTAssertEqual(counter.total, 2)
  }
}

struct ResolutionTestTimeout: Error {}

/// 竞速兜底：`body` 与一个计时器抢先，超时抛 `ResolutionTestTimeout`。
/// 裸 `await task.value` 一旦对面不返回就是永久挂起，只能靠整轮超时被杀。
func raceWithTimeout<Value: Sendable>(
  seconds: TimeInterval,
  label: String,
  _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw ResolutionTestTimeout()
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw ResolutionTestTimeout() }
    return value
  }
}

private final class ResolutionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Int] = [:]
  func record(_ host: String) { lock.withLock { storage[host, default: 0] += 1 } }
  var counts: [String: Int] { lock.withLock { storage } }
  var total: Int { lock.withLock { storage.values.reduce(0, +) } }
}
