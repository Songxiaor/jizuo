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
    guard let faviconURL = Self.faviconURL(for: sourceURL),
          let key = Self.cacheKey(for: sourceURL),
          let sourceHost = PublicWebURLPolicy.normalizedHost(sourceURL.host ?? "")
    else { return nil }
    if hasFreshNegativeCache(for: key) { return nil }

    let sameHost: @Sendable (URL) -> Bool = { candidate in
      guard candidate.user == nil, candidate.password == nil,
            let scheme = candidate.scheme?.lowercased(), ["http", "https"].contains(scheme),
            (scheme == "http" && (candidate.port == nil || candidate.port == 80)) ||
              (scheme == "https" && (candidate.port == nil || candidate.port == 443)),
            let candidateHost = PublicWebURLPolicy.normalizedHost(candidate.host ?? "")
      else { return false }
      return candidateHost == sourceHost
    }

    guard let response = try? await resources.fetchResource(.init(
      url: faviconURL,
      headers: ["Accept": "image/x-icon,image/vnd.microsoft.icon,image/png,image/*;q=0.8"],
      byteLimit: Self.perHostByteLimit,
      allowsRedirectTarget: sameHost
    )),
      (200...299).contains(response.statusCode),
      response.body.count <= Self.perHostByteLimit,
      sameHost(response.url),
      Self.isSupportedImage(response)
    else {
      recordNegativeCache(for: key)
      return nil
    }

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
