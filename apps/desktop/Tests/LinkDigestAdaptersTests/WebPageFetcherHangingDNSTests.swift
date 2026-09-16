import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// DNS 挂住时，抓取必须在超时窗口内失败，并且随时响应"停止"。
///
/// 原来的同步 `getaddrinfo` 做不到这两条：它占住 Swift 并发的协作线程池，用户
/// 点停止也只能干等解析自己放弃——界面上看不出任何原因，只是一直转圈。
final class WebPageFetcherHangingDNSTests: XCTestCase {
  /// 「解析开始了吗」以前用 `DispatchSemaphore.wait` 问，那会按住测试主体所在的
  /// 协作线程；池子里被按住一条就可能让别的任务排不进来，测试无输出地挂死。
  /// 换成续体后等待方只是挂起，不占线程；`release` 仍是信号量，但它阻塞的是
  /// `HostResolution.offloaded` 派发出去的普通全局队列线程，本就可以被丢弃。
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
      return ["127.0.0.1"]
    }

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

    func finish() { release.signal() }
  }

  func testFetchFailsWithinTheResolutionTimeoutWhenDNSNeverAnswers() async {
    let resolver = HangingResolver()
    defer { resolver.finish() }
    let fetcher = PeerBoundNetworkWebPageFetcher(
      resolver: { try resolver.resolve($0) },
      allowLoopbackForTesting: true,
      limits: .init(redirects: 1, responseBytes: 1_024, timeout: 30),
      portForTesting: 1,
      resolverTimeoutSecondsForTesting: 0.3
    )

    let started = Date()
    do {
      _ = try await fetcher.fetch(url: URL(string: "http://hanging-dns.test/page")!)
      XCTFail("hanging DNS must not produce a page")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, .timedOut)
    }
    // 连接超时是 30 秒，解析超时是 0.3 秒：抓取必须按后者失败。
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testFetchCancellationIsHonouredWhileDNSIsStillPending() async {
    let resolver = HangingResolver()
    defer { resolver.finish() }
    let fetcher = PeerBoundNetworkWebPageFetcher(
      resolver: { try resolver.resolve($0) },
      allowLoopbackForTesting: true,
      limits: .init(redirects: 1, responseBytes: 1_024, timeout: 30),
      portForTesting: 1,
      resolverTimeoutSecondsForTesting: 30
    )

    let url = URL(string: "http://hanging-dns.test/page")!
    let task = Task { try await fetcher.fetch(url: url) }
    await resolver.waitForEntry()
    let started = Date()
    task.cancel()
    do {
      // 取消不生效时裸 `task.value` 会永久挂起。竞速兜底让它 5 秒后失败收场。
      _ = try await raceWithFetchTimeout(seconds: 5) { try await task.value }
      XCTFail("cancelled fetch unexpectedly succeeded")
    } catch is HangingDNSTestTimeout {
      XCTFail("取消后 fetch 5 秒内没有返回")
    } catch {
      XCTAssertEqual(error as? ManualLinkError, .cancelled)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "取消不能等解析自己超时")
  }
}

struct HangingDNSTestTimeout: Error {}

/// 竞速兜底：`body` 与计时器抢先，超时抛 `HangingDNSTestTimeout`。
func raceWithFetchTimeout<Value: Sendable>(
  seconds: TimeInterval,
  _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw HangingDNSTestTimeout()
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw HangingDNSTestTimeout() }
    return value
  }
}
