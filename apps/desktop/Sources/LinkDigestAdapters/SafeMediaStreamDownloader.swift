import Foundation
import LinkDigestCore

/// 播放链路上「边下边落盘」的媒体分片下载。
///
/// 这里的 URL 来自抓取回来的页面内容，和用户手动粘贴的链接一样不可信，所以在
/// 发请求之前先过 `PublicWebURLPolicy`——和 `ProxyAwareWebPageFetcher` /
/// `PeerBoundNetworkWebPageFetcher` / `URLSessionWebPageFetcher` 用的是同一个类型、
/// 同一套判定：私有网段、回环、链路本地、文档/测试网段一律拒绝；TUN/透明代理
/// 解析出的 fake-IP 仍按代理路由放行，不误伤那类网络。
///
/// 为什么不直接调 `SafeResourceFetching.fetchResource`（`VideoMediaDownloader`
/// 走的是那条）：那条路径把整条响应读进 `Data` 再交出来。双轨合成的单条分片
/// 上限 180MB，两条并行就是一次可预期的内存尖峰，而这里要的正是流式落盘。
/// 所以门禁复用，传输仍走 URLSession 的 `download(for:)`——直接写临时文件，
/// 不整段进内存。重定向不交给 URLSession 自己跟：每一跳都回到同一道门禁。
public struct SafeMediaStreamDownloader: Sendable {
  public enum Failure: Error, Equatable {
    /// 地址没过公网门禁（私有网段 / 回环 / 链路本地 / 非法 scheme 或端口）。
    case unsafeURL
    /// 对端回了非 2xx。
    case responseStatus
  }

  private let policy: PublicWebURLPolicy

  /// 默认解析器带一层短 TTL 缓存：一次播放里视频轨和音轨通常同域名，
  /// 门禁和后续 HEAD 探测因此共用同一份 DNS 答案。
  public init(
    policy: PublicWebURLPolicy = .init(
      asyncResolver: HostResolutionCache(base: SystemHostResolver.asyncResolver()).resolver
    )
  ) {
    self.policy = policy
  }

  /// 重定向的纯判定：https 不允许降级成 http。其它跳转仍交给 `admit` / 门禁。
  public static func allowsRedirect(from original: URL?, to target: URL) -> Bool {
    !(original?.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http")
  }

  /// 门禁本身。允许 `.direct` 与 `.systemProxyForFakeIP` 两种路由判定，
  /// 其余一律拒绝。调用方据此给出可解释的失败，而不是让请求先发出去。
  public func admit(_ url: URL) async throws {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      throw Failure.unsafeURL
    }
    do {
      _ = try await policy.routingDecision(for: url)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Failure.unsafeURL
    }
  }

  /// 流式下载到 `destination`。字节由 URLSession 直接写临时文件，只在最后搬一次。
  public func download(
    from url: URL,
    to destination: URL,
    headers: [String: String]?,
    timeout: TimeInterval = 60
  ) async throws {
    try await admit(url)
    let guardDelegate = RedirectGuard(policy: policy)
    let session = URLSession(
      configuration: .default,
      delegate: guardDelegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }
    let (tempURL, response) = try await session.download(for: request(url: url, headers: headers, timeout: timeout))
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw Failure.responseStatus
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: tempURL, to: destination)
  }

  /// HEAD 体积预检。`nil` 表示对端没给可用长度；地址不安全时抛错，不静默放行。
  public func contentLength(
    of url: URL,
    headers: [String: String]?,
    timeout: TimeInterval
  ) async throws -> Int64? {
    try await admit(url)
    var probe = request(url: url, headers: headers, timeout: max(0.05, timeout))
    probe.httpMethod = "HEAD"
    let guardDelegate = RedirectGuard(policy: policy)
    let session = URLSession(configuration: .default, delegate: guardDelegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    guard let (_, response) = try? await session.data(for: probe),
          let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode)
    else { return nil }
    let length = http.expectedContentLength
    return length > 0 ? length : nil
  }

  private func request(url: URL, headers: [String: String]?, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    if let headers {
      for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    return request
  }
}

/// URLSession 默认自己跟重定向，跟到哪儿不经过门禁。这里把每一跳都送回
/// `PublicWebURLPolicy`：判定不通过就断在这一跳，https 也不允许降级成 http。
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let policy: PublicWebURLPolicy

  init(policy: PublicWebURLPolicy) {
    self.policy = policy
  }

  func urlSession(
    _: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let target = request.url,
          SafeMediaStreamDownloader.allowsRedirect(from: task.originalRequest?.url, to: target)
    else {
      completionHandler(nil)
      return
    }
    let policy = policy
    Task {
      do {
        _ = try await policy.routingDecision(for: target)
        completionHandler(request)
      } catch {
        completionHandler(nil)
      }
    }
  }
}
