import CryptoKit
import Foundation
import LinkDigestCore

/// A small, host-keyed cache for history-list favicons.
///
/// The cache only receives resources through `SafeResourceFetching`, so every
/// request still passes the same URL admission, peer/TLS and redirect checks
/// as page capture. It is deliberately best-effort: a failed favicon can never
/// fail a captured document, a run, or history loading.
public final class WebsiteFaviconCache: @unchecked Sendable {
  public static let perHostByteLimit = 64 * 1024
  public static let maximumCachedHosts = 128
  public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
  /// A host which does not serve a safe, supported favicon should not hold up
  /// every history reload. Keep that negative result local for one day, then
  /// permit a retry in case the site has fixed its icon.
  public static let negativeCacheTTL: TimeInterval = 24 * 60 * 60

  private let root: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private let lock = NSLock()

  public init(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/WebsiteFavicons", isDirectory: true)
    self.fileManager = fileManager
    self.now = now
  }

  /// Returns a cached local file, if present. No remote URL is ever returned
  /// to SwiftUI.
  public func localImageURL(for sourceURL: URL) -> URL? {
    guard let key = Self.cacheKey(for: sourceURL) else { return nil }
    let file = root.appendingPathComponent(key, isDirectory: false)
    lock.lock()
    defer { lock.unlock() }
    guard fileManager.fileExists(atPath: file.path) else { return nil }
    try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
    return file
  }

  /// Fetches at most one 64 KiB favicon for a previously captured host.
  /// Redirects stay on that normalized host; the transport separately validates
  /// every redirect URL and actual network peer.
  public func localImageURL(
    fetchingIfNeededFor sourceURL: URL,
    resources: any SafeResourceFetching
  ) async -> URL? {
    if let cached = localImageURL(for: sourceURL) { return cached }
    guard let key = Self.cacheKey(for: sourceURL),
          let sourceHost = PublicWebURLPolicy.normalizedHost(sourceURL.host ?? "")
    else { return nil }
    if hasFreshNegativeCache(for: key) { return nil }

    // 本站拿不到就退到注册域。
    //
    // 实测 support.claude.com 的 /favicon.ico 返回 200 但**零字节**，而
    // claude.com/favicon.ico 有 15086 字节的正常图标。这不是个例：帮助中心、
    // 文档站、博客常挂在 support./help./docs./blog. 这类子域上，图标只在主域有。
    // 只剥一层标签，且要求剩余部分仍是可注册域，避免把 foo.co.uk 削成 co.uk。
    var response: SafeResourceResponse?
    for host in Self.faviconHostChain(from: sourceHost) {
      guard let faviconURL = Self.faviconURL(host: host) else { continue }
      let sameHost: @Sendable (URL) -> Bool = { candidate in
        guard candidate.user == nil, candidate.password == nil,
              let scheme = candidate.scheme?.lowercased(), ["http", "https"].contains(scheme),
              (scheme == "http" && (candidate.port == nil || candidate.port == 80)) ||
                (scheme == "https" && (candidate.port == nil || candidate.port == 443)),
              let candidateHost = PublicWebURLPolicy.normalizedHost(candidate.host ?? "")
        else { return false }
        return candidateHost == host
      }
      guard let candidate = try? await resources.fetchResource(.init(
        url: faviconURL,
        headers: ["Accept": "image/x-icon,image/vnd.microsoft.icon,image/png,image/*;q=0.8"],
        byteLimit: Self.perHostByteLimit,
        allowsRedirectTarget: sameHost
      )),
        (200...299).contains(candidate.statusCode),
        candidate.body.count <= Self.perHostByteLimit,
        sameHost(candidate.url),
        Self.isSupportedImage(candidate)
      else { continue }
      response = candidate
      break
    }

    // 猜路径全失败时，回到页面自己声明的地址。
    //
    // 声明的图标常挂在 CDN 上（和页面不同域），所以这一条不能沿用 same-host 守卫。
    // 安全性由别处兜住：URL 仍走 PublicWebURLPolicy、有字节上限、且必须通过
    // magic bytes 校验才会落盘——放宽的只是「必须同域」这一条。
    if response == nil {
      response = await fetchDeclaredIcon(pageURL: sourceURL, resources: resources)
    }

    guard let response else {
      recordNegativeCache(for: key)
      return nil
    }

    // 无论图标取自本站还是主域，都按**原始 host** 落键，
    // 这样 `localImageURL(for:)` 的同步查询能直接命中。
    return lock.withLock {
      guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
      let destination = root.appendingPathComponent(key, isDirectory: false)
      guard (try? response.body.write(to: destination, options: .atomic)) != nil else {
        recordNegativeCacheLocked(for: key)
        return nil
      }
      try? fileManager.removeItem(at: negativeCacheURL(for: key))
      try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
      pruneLocked()
      return destination
    }
  }

  /// The source scheme and host are retained; userinfo, query and fragment are
  /// discarded. PublicWebURLPolicy will still re-admit this URL at transport
  /// time, including for records created by older app versions.
  /// 抓一次页面 HTML，按它声明的图标地址逐个尝试。
  ///
  /// 只在猜路径全失败后才走这里：多一次 HTML 请求，不该让大多数正常站点也付这个钱。
  private func fetchDeclaredIcon(
    pageURL: URL,
    resources: any SafeResourceFetching
  ) async -> SafeResourceResponse? {
    guard let page = try? await resources.fetchResource(.init(
      url: pageURL,
      headers: ["Accept": "text/html,application/xhtml+xml"],
      byteLimit: Self.htmlByteLimit,
      allowsRedirectTarget: { _ in true }
    )),
      (200...299).contains(page.statusCode),
      let html = String(data: Data(page.body), encoding: .utf8)
        ?? String(data: Data(page.body), encoding: .isoLatin1)
    else { return nil }

    let candidates = Self.declaredIconURLs(inHTML: html, baseURL: page.url)
    for candidate in candidates.prefix(Self.maximumDeclaredIconAttempts) {
      guard let response = try? await resources.fetchResource(.init(
        url: candidate,
        headers: ["Accept": "image/png,image/x-icon,image/svg+xml,image/*;q=0.8"],
        byteLimit: Self.perHostByteLimit,
        allowsRedirectTarget: { _ in true }
      )),
        (200...299).contains(response.statusCode),
        response.body.count <= Self.perHostByteLimit,
        Self.isSupportedImage(response)
      else { continue }
      return response
    }
    return nil
  }

  /// 只读 head 够用的量；整页可能几 MB，为了一个图标不值得。
  private static let htmlByteLimit = 256 * 1024
  /// 一页里声明四五个尺寸很常见，试太多等于为一个图标打一串请求。
  private static let maximumDeclaredIconAttempts = 3

  /// 从页面 HTML 里读出它自己声明的图标地址。
  ///
  /// 猜 `/favicon.ico` 在真实站点上有两种常见坏法，实测都撞到了：
  /// - `support.claude.com` 返回 200 但**零字节**；
  /// - `www.residentialvps.com` 返回 200 但 content-type 是 `text/html`——
  ///   SPA 把所有未知路径都回首页，退到注册域也是同一份 HTML。
  ///
  /// 站点自己在 `<link rel="icon">` 里声明的地址才是权威来源。按 sizes 里的
  /// 像素数降序取，拿不到尺寸的排在后面——16×16 也能用，但有大的优先。
  static func declaredIconURLs(inHTML html: String, baseURL: URL) -> [URL] {
    let pattern = #"<link\b[^>]*\brel\s*=\s*["']([^"']*)["'][^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    // 只扫 head 附近：正文里的 <link> 不是图标声明，扫全文既慢又容易误命中。
    let scope = String(html.prefix(200_000))
    var found: [(url: URL, weight: Int)] = []
    for match in regex.matches(in: scope, range: NSRange(scope.startIndex..., in: scope)) {
      guard let tagRange = Range(match.range, in: scope),
            let relRange = Range(match.range(at: 1), in: scope)
      else { continue }
      let rel = scope[relRange].lowercased()
      guard rel.split(separator: " ").contains(where: {
        $0 == "icon" || $0 == "shortcut" || $0 == "apple-touch-icon"
          || $0 == "apple-touch-icon-precomposed"
      }) else { continue }
      let tag = String(scope[tagRange])
      guard let href = attribute("href", in: tag), !href.isEmpty,
            let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
            let scheme = resolved.scheme?.lowercased(), ["http", "https"].contains(scheme),
            resolved.user == nil, resolved.password == nil
      else { continue }
      let side = attribute("sizes", in: tag)
        .flatMap { $0.lowercased().split(separator: "x").first.flatMap { Int($0) } } ?? 0
      found.append((resolved, side))
    }
    // 去重保序：同一个地址被 icon 和 apple-touch-icon 同时声明很常见。
    var seen = Set<String>()
    return found
      .sorted { $0.weight > $1.weight }
      .compactMap { seen.insert($0.url.absoluteString).inserted ? $0.url : nil }
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
      options: [.caseInsensitive]
    ), let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
      let range = Range(match.range(at: 1), in: tag)
    else { return nil }
    return String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 依次尝试的 host：本站，然后（若存在）注册域。
  ///
  /// 只剥一层标签。剥更多会滑向公共后缀（`a.b.co.uk` → `co.uk`），那是一个
  /// 别人的域，抓它的图标既不对也不该。判据是「剩余部分至少两段，且不是已知的
  /// 多段有效顶级域」——不引公共后缀表的前提下，这条足够保守。
  static func faviconHostChain(from host: String) -> [String] {
    var chain = [host]
    if let parent = registrableParent(of: host) { chain.append(parent) }
    return chain
  }

  /// 常见的多段有效顶级域。命中就说明再剥一层会越过注册边界。
  private static let multiLabelSuffixes: Set<String> = [
    "co.uk", "org.uk", "ac.uk", "gov.uk",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "com.au", "net.au", "org.au",
    "co.jp", "or.jp", "ne.jp", "ac.jp",
    "com.hk", "com.tw", "com.sg", "com.br", "com.mx",
    "co.kr", "co.in", "co.nz", "co.za",
  ]

  private static func registrableParent(of host: String) -> String? {
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count >= 3 else { return nil }
    let parent = labels.dropFirst().joined(separator: ".")
    // 剥完只剩「有效顶级域」本身，说明原 host 已经是注册域，不能再退。
    guard parent.split(separator: ".").count >= 2,
          !multiLabelSuffixes.contains(parent)
    else { return nil }
    return parent
  }

  static func faviconURL(host: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/favicon.ico"
    return components.url
  }

  public static func faviconURL(for sourceURL: URL) -> URL? {
    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          components.user == nil, components.password == nil,
          let host = PublicWebURLPolicy.normalizedHost(components.host ?? ""), !host.isEmpty,
          (scheme == "http" && (components.port == nil || components.port == 80)) ||
            (scheme == "https" && (components.port == nil || components.port == 443))
    else { return nil }
    var favicon = components
    favicon.scheme = scheme
    favicon.host = host
    favicon.user = nil
    favicon.password = nil
    favicon.path = "/favicon.ico"
    favicon.query = nil
    favicon.fragment = nil
    return favicon.url
  }

  private static func cacheKey(for sourceURL: URL) -> String? {
    guard let host = PublicWebURLPolicy.normalizedHost(sourceURL.host ?? ""), !host.isEmpty else { return nil }
    return SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSupportedImage(_ response: SafeResourceResponse) -> Bool {
    guard let type = response.contentType?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else { return false }
    switch type {
    case "image/png":
      return response.body.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    case "image/jpeg":
      return response.body.starts(with: [0xff, 0xd8, 0xff])
    case "image/gif":
      return response.body.starts(with: Array("GIF87a".utf8)) || response.body.starts(with: Array("GIF89a".utf8))
    case "image/webp":
      return response.body.count >= 12
        && response.body.starts(with: Array("RIFF".utf8))
        && Data(response.body[8..<12]) == Data("WEBP".utf8)
    case "image/x-icon", "image/vnd.microsoft.icon":
      return response.body.starts(with: [0x00, 0x00, 0x01, 0x00])
    default:
      return false
    }
  }

  private func negativeCacheURL(for key: String) -> URL {
    root.appendingPathComponent("\(key).miss", isDirectory: false)
  }

  private func hasFreshNegativeCache(for key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let marker = negativeCacheURL(for: key)
    guard fileManager.fileExists(atPath: marker.path) else { return false }
    let date = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    guard date.addingTimeInterval(Self.negativeCacheTTL) > now() else {
      try? fileManager.removeItem(at: marker)
      return false
    }
    return true
  }

  private func recordNegativeCache(for key: String) {
    lock.lock()
    defer { lock.unlock() }
    recordNegativeCacheLocked(for: key)
  }

  private func recordNegativeCacheLocked(for key: String) {
    guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return }
    let marker = negativeCacheURL(for: key)
    guard fileManager.createFile(atPath: marker.path, contents: Data()) else { return }
    try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: marker.path)
    pruneLocked()
  }

  /// Cleanup is cache-only: on each successful write, discard entries unused
  /// for 30 days and then evict oldest files until 128 hosts remain. Task
  /// deletion does not remove a shared host favicon, so another history item
  /// can continue to reuse it.
  private func prune() {
    lock.lock()
    defer { lock.unlock() }
    pruneLocked()
  }

  private func pruneLocked() {
    guard let files = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let deadline = now().addingTimeInterval(-Self.retentionInterval)
    var retained: [String: (urls: [URL], latestDate: Date)] = [:]
    for file in files {
      let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      if date < deadline { try? fileManager.removeItem(at: file) }
      else {
        let name = file.lastPathComponent
        let key = name.hasSuffix(".miss") ? String(name.dropLast(5)) : name
        var entry = retained[key] ?? ([], .distantPast)
        entry.urls.append(file)
        entry.latestDate = max(entry.latestDate, date)
        retained[key] = entry
      }
    }
    for (_, entry) in retained.sorted(by: { $0.value.latestDate < $1.value.latestDate }).dropLast(Self.maximumCachedHosts) {
      for file in entry.urls { try? fileManager.removeItem(at: file) }
    }
  }
}
