import Foundation

/// 域名解析的异步形态。
///
/// 抓取链路上的解析原本是同步 `getaddrinfo`，直接在 async 函数里调用：它会占住
/// Swift 并发的协作线程池（线程数只有核数那么多），并且完全不理会 `Task` 取消——
/// 用户点"停止"之后仍要等解析自己超时。这里把解析统一成异步、可取消、带超时的
/// 形态，SSRF 门禁拿到的仍旧是同一份地址答案，判定逻辑一个字没改。
public typealias AsyncHostResolver = @Sendable (String) async throws -> [String]

public enum HostResolution {
  /// 解析超时。系统解析器自己的超时可以长达几十秒，抓取链路等不起。
  public static let defaultTimeoutSeconds: TimeInterval = 8

  /// 把一个阻塞式解析函数搬到普通派发队列上执行，并加上超时与取消响应。
  ///
  /// `getaddrinfo` 没有可移植的中断方式，所以超时/取消时这里的做法是**放弃**
  /// 那次解析（后台线程自己跑完，结果丢弃），而不是继续等它。放弃的是一条普通
  /// 全局队列线程，不是协作线程池的线程，不会拖住其它并发任务。
  public static func offloaded(
    _ resolve: @escaping @Sendable (String) throws -> [String],
    timeoutSeconds: TimeInterval = defaultTimeoutSeconds
  ) -> AsyncHostResolver {
    { host in
      try Task.checkCancellation()
      let gate = ResolutionGate()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
          gate.attach(continuation)
          let queue = DispatchQueue.global(qos: .userInitiated)
          queue.asyncAfter(deadline: .now() + timeoutSeconds) {
            gate.resume(.failure(ManualLinkError.timedOut))
          }
          queue.async {
            do { gate.resume(.success(try resolve(host))) }
            catch { gate.resume(.failure(error)) }
          }
        }
      } onCancel: {
        gate.resume(.failure(ManualLinkError.cancelled))
      }
    }
  }
}

/// 只恢复一次的续体闸门：解析完成、超时、取消三路谁先到谁算数。
///
/// `onCancel` 可能在续体挂上之前就触发，所以早到的结果先存起来，等续体挂上
/// 立刻兑现——否则那次解析会永远挂住。
private final class ResolutionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<[String], Error>?
  private var pending: Result<[String], Error>?
  private var finished = false

  func attach(_ continuation: CheckedContinuation<[String], Error>) {
    lock.lock()
    if let pending {
      finished = true
      self.pending = nil
      lock.unlock()
      continuation.resume(with: pending)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resume(_ result: Result<[String], Error>) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    if let continuation {
      finished = true
      self.continuation = nil
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    if pending == nil { pending = result }
    lock.unlock()
  }
}

/// 一次抓取内对同一个域名只解析一次。
///
/// 抓取链路上同一个 host 原本要查三到四次：路由判定一次、传输层绑定对端再一次，
/// 重定向每跳还要重来。缓存让这些调用共用同一份答案：判定用的地址和真正连上去
/// 的对端因此必然是同一份，DNS rebinding 的窗口反而更小。TTL 只覆盖一次抓取的
/// 量级，过期后照常重新解析，SSRF 判定对每一份答案都照跑不误。
public final class HostResolutionCache: @unchecked Sendable {
  private struct Entry {
    let addresses: [String]
    let expiresAt: Date
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private let ttl: TimeInterval
  private let limit: Int
  private let base: AsyncHostResolver

  public init(ttl: TimeInterval = 20, limit: Int = 128, base: @escaping AsyncHostResolver) {
    self.ttl = ttl
    self.limit = limit
    self.base = base
  }

  /// 可以直接当 `AsyncHostResolver` 传给 `PublicWebURLPolicy` 和各传输层。
  public var resolver: AsyncHostResolver {
    { [self] host in try await addresses(for: host) }
  }

  private func addresses(for host: String) async throws -> [String] {
    let cached = lock.withLock { () -> [String]? in
      guard let entry = entries[host], entry.expiresAt > Date() else { return nil }
      return entry.addresses
    }
    if let cached { return cached }

    let resolved = try await base(host)
    // 空答案等于解析失败，缓存它只会把失败固化住。
    guard !resolved.isEmpty else { return resolved }

    lock.withLock {
      if entries.count >= limit {
        let deadline = Date()
        entries = entries.filter { $0.value.expiresAt > deadline }
        if entries.count >= limit { entries.removeAll() }
      }
      entries[host] = Entry(addresses: resolved, expiresAt: Date().addingTimeInterval(ttl))
    }
    return resolved
  }
}
