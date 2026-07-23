import CryptoKit
import Foundation
import LinkDigestCore

public final class GitHubRepositorySourceAdapter: SourceAdapting, @unchecked Sendable {
  public static let readmeAccept = "application/vnd.github.raw+json"
  private let resources: any SafeResourceFetching
  private let imageCache: GitHubREADMEImageCache?
  private let now: @Sendable () -> Date

  public init(
    resources: any SafeResourceFetching,
    imageCache: GitHubREADMEImageCache? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.resources = resources
    self.imageCache = imageCache
    self.now = now
  }

  public func takesOwnership(of url: URL) -> Bool { GitHubRepository(url: url) != nil }

  public func capture(url: URL) async throws -> CapturedDocument {
    guard let repository = GitHubRepository(url: url) else { throw ManualLinkError.invalidURL }
    let apiURL = repository.readmeAPIURL
    let response = try await resources.fetchResource(.init(
      url: apiURL,
      headers: ["Accept": Self.readmeAccept],
      byteLimit: URLSessionWebPageFetcher.Limits().responseBytes
    ))
    switch response.statusCode {
    case 200...299: break
    case 404: throw ManualLinkError.githubRepositoryUnavailable
    case 403, 429: throw ManualLinkError.githubRateLimited
    default: throw ManualLinkError.responseStatus
    }
    guard let markdown = String(data: response.body, encoding: .utf8),
          !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ManualLinkError.emptyContent }
    guard markdown.unicodeScalars.count <= CaptureValidator.maxTextScalars else { throw ManualLinkError.responseTooLarge }

    let timestamp = ISO8601DateFormatter().string(from: now())
    let document = CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: repository.canonicalURL.absoluteString,
      title: repository.displayName,
      platform: "github",
      method: "github_readme_api",
      text: markdown,
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "GitHub 公开仓库 README"
    )
    // Image failures are intentionally isolated from the README capture. The
    // document remains usable for summary and translation without local media.
    await imageCache?.stage(markdown: markdown, repository: repository, captureID: document.requestID, resources: resources)
    return document
  }
}

public struct GitHubRepository: Sendable, Equatable {
  public let owner: String
  public let name: String
  public let canonicalURL: URL

  public init?(url: URL) {
    guard url.scheme?.lowercased() == "https",
          PublicWebURLPolicy.normalizedHost(url.host ?? "") == "github.com",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443
    else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2,
          Self.validPathPart(parts[0]), Self.validPathPart(parts[1])
    else { return nil }
    owner = String(parts[0]); name = String(parts[1])
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.path = "/\(owner)/\(name)"
    components.query = nil
    components.fragment = nil
    guard let canonical = components.url else { return nil }
    canonicalURL = canonical
  }

  public var displayName: String { "\(owner)/\(name)" }
  public var readmeAPIURL: URL {
    URL(string: "https://api.github.com/repos/\(owner)/\(name)/readme")!
  }
  public var rawBaseURL: URL {
    URL(string: "https://raw.githubusercontent.com/\(owner)/\(name)/HEAD/")!
  }

  private static func validPathPart(_ value: Substring) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
  }
}

public final class GitHubREADMEImageCache: @unchecked Sendable {
  public static let perImageByteLimit = 5 * 1024 * 1024
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  /// GitHub READMEs often embed many badge SVGs/PNGs; cap count there only.
  public static let githubREADMEImageCountCap = 20
  /// Safety valve for one capture's total downloaded image bytes (not a count cap).
  /// Content-driven: if the article has 100 images under this budget, we keep all 100.
  public static let articleTotalByteBudget = 200 * 1024 * 1024
  public static let weChatPerImageByteLimit = 10 * 1024 * 1024
  public static let weChatTotalByteBudget = 60 * 1024 * 1024
  public static let weChatImageCountCap = 60

  private struct Manifest: Codable { let entries: [Entry] }
  private struct Entry: Codable { let filename: String }
  private let root: URL
  private let fileManager: FileManager

  public init(applicationSupportRoot: URL, fileManager: FileManager = .default) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/GitHubREADMEImages", isDirectory: true)
    self.fileManager = fileManager
  }

  public func stage(markdown: String, repository: GitHubRepository, captureID: String, resources: any SafeResourceFetching) async {
    await stageURLs(
      GitHubREADMEImageReferences.urls(in: markdown, repository: repository),
      captureID: captureID,
      resources: resources,
      allowsRedirectTarget: GitHubREADMEImageReferences.isAllowedImageURL,
      maxCount: Self.githubREADMEImageCountCap,
      totalByteBudget: nil
    )
  }

  /// Downloads every absolute HTTPS image referenced by the capture body.
  /// Count follows content; only per-image size and a total byte budget apply.
  public func stageRemoteMarkdownImages(
    markdown: String,
    captureID: String,
    resources: any SafeResourceFetching
  ) async {
    await stageURLs(
      MarkdownRemoteImageReferences.absoluteHTTPSURLs(in: markdown),
      captureID: captureID,
      resources: resources,
      allowsRedirectTarget: MarkdownRemoteImageReferences.isAllowedImageURL,
      maxCount: nil,
      totalByteBudget: Self.articleTotalByteBudget
    )
  }

  /// WeChat uses a deliberately narrower CDN admission policy than generic
  /// markdown. Failed decorative media is fail-open: the article still saves.
  public func stageWeChatImages(
    bodyImageURLs: [String],
    coverImageURL: String?,
    articleURL: URL,
    captureID: String,
    resources: any SafeResourceFetching,
    perImageByteLimit: Int = GitHubREADMEImageCache.weChatPerImageByteLimit,
    totalByteBudget: Int = GitHubREADMEImageCache.weChatTotalByteBudget
  ) async {
    var seen = Set<String>()
    var urls: [URL] = []
    for raw in bodyImageURLs + (coverImageURL.map { [$0] } ?? []) {
      guard let url = URL(string: raw),
            WeChatImageReferences.isAllowedImageURL(url),
            seen.insert(url.absoluteString).inserted
      else { continue }
      urls.append(url)
    }
    await stageURLs(
      urls,
      captureID: captureID,
      resources: resources,
      allowsRedirectTarget: WeChatImageReferences.isAllowedImageURL,
      // Body images are ordered first; a cover is only kept if it remains
      // within the same 60-file task cache budget.
      maxCount: Self.weChatImageCountCap,
      totalByteBudget: totalByteBudget,
      perImageByteLimit: perImageByteLimit,
      headers: ["User-Agent": Self.browserUserAgent, "Referer": articleURL.absoluteString],
      stopsWhenTotalBudgetExceeded: true
    )
  }

  private func stageURLs(
    _ urls: [URL],
    captureID: String,
    resources: any SafeResourceFetching,
    allowsRedirectTarget: @escaping @Sendable (URL) -> Bool,
    maxCount: Int?,
    totalByteBudget: Int?,
    perImageByteLimit: Int = GitHubREADMEImageCache.perImageByteLimit,
    headers: [String: String]? = nil,
    stopsWhenTotalBudgetExceeded: Bool = false
  ) async {
    let directory = stagingDirectory(captureID)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    var entries: [Entry] = []
    var seen = Set<String>()
    var totalBytes = 0
    if let data = try? Data(contentsOf: manifestURL),
       let existing = try? JSONDecoder().decode(Manifest.self, from: data) {
      entries = existing.entries
      seen = Set(existing.entries.map(\.filename))
      for entry in existing.entries {
        let path = directory.appendingPathComponent(entry.filename, isDirectory: false)
        if let attrs = try? fileManager.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? NSNumber {
          totalBytes += size.intValue
        }
      }
    } else {
      try? remove(directory)
      guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
    }

    for url in urls {
      if let maxCount, entries.count >= maxCount { break }
      if let totalByteBudget, totalBytes >= totalByteBudget { break }
      let filename = Self.filename(for: url)
      if seen.contains(filename) { continue }
      guard allowsRedirectTarget(url),
            let response = try? await resources.fetchResource(
              .init(
                url: url,
                headers: headers ?? Self.remoteImageHeaders(for: url),
                byteLimit: perImageByteLimit,
                allowsRedirectTarget: allowsRedirectTarget
              )
            ),
            (200...299).contains(response.statusCode),
            response.body.count <= perImageByteLimit,
            allowsRedirectTarget(response.url),
            Self.isImage(response)
      else { continue }
      if let totalByteBudget, totalBytes + response.body.count > totalByteBudget {
        if stopsWhenTotalBudgetExceeded { break }
        continue
      }
      let destination = directory.appendingPathComponent(filename, isDirectory: false)
      guard (try? response.body.write(to: destination, options: .atomic)) != nil else { continue }
      entries.append(.init(filename: filename))
      seen.insert(filename)
      totalBytes += response.body.count
    }
    guard !entries.isEmpty,
          let data = try? JSONEncoder().encode(Manifest(entries: entries))
    else {
      if entries.isEmpty { try? remove(directory) }
      return
    }
    try? data.write(to: manifestURL, options: .atomic)
  }

  public func promote(captureID: String, taskID: TaskID, snapshotID: ContentSnapshotID) {
    let source = stagingDirectory(captureID)
    guard fileManager.fileExists(atPath: source.path) else { return }
    let destination = snapshotDirectory(taskID: taskID, snapshotID: snapshotID)
    try? remove(destination)
    do {
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.moveItem(at: source, to: destination)
    } catch { try? remove(source) }
  }

  public func discardStaged(captureID: String) { try? remove(stagingDirectory(captureID)) }
  public func delete(taskID: TaskID) { try? remove(root.appendingPathComponent(taskID.rawValue, isDirectory: true)) }

  public func localImageURLs(taskID: TaskID, snapshotID: ContentSnapshotID) -> [URL] {
    let directory = snapshotDirectory(taskID: taskID, snapshotID: snapshotID)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
    return manifest.entries.compactMap { entry in
      guard entry.filename.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
      let url = directory.appendingPathComponent(entry.filename, isDirectory: false)
      return fileManager.fileExists(atPath: url.path) ? url : nil
    }
  }

  private func stagingDirectory(_ captureID: String) -> URL {
    root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(captureID, isDirectory: true)
  }
  private func snapshotDirectory(taskID: TaskID, snapshotID: ContentSnapshotID) -> URL {
    root.appendingPathComponent(taskID.rawValue, isDirectory: true).appendingPathComponent(snapshotID.rawValue, isDirectory: true)
  }
  private func remove(_ url: URL) throws { if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) } }
  private static func filename(for url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
  private static func remoteImageHeaders(for url: URL) -> [String: String] {
    var headers = ["User-Agent": browserUserAgent]
    guard let host = url.host?.lowercased() else { return headers }
    if matches(host, domain: "qpic.cn")
      || matches(host, domain: "qlogo.cn")
      || matches(host, domain: "qq.com") {
      headers["Referer"] = "https://mp.weixin.qq.com/"
    } else if matches(host, domain: "douyinvod.com")
      || matches(host, domain: "douyincdn.com")
      || matches(host, domain: "douyin.com") {
      headers["Referer"] = "https://www.douyin.com/"
    }
    return headers
  }
  private static func matches(_ host: String, domain: String) -> Bool {
    host == domain || host.hasSuffix(".\(domain)")
  }
  private static func isImage(_ response: SafeResourceResponse) -> Bool {
    guard let type = response.contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
    switch type {
    case "image/png": return response.body.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    case "image/jpeg": return response.body.starts(with: [0xff, 0xd8, 0xff])
    case "image/gif": return response.body.starts(with: Array("GIF87a".utf8)) || response.body.starts(with: Array("GIF89a".utf8))
    case "image/webp":
      return response.body.count >= 12
        && response.body.starts(with: Array("RIFF".utf8))
        && Data(response.body[8..<12]) == Data("WEBP".utf8)
    default: return false
    }
  }
}

/// Exact CDN admission for WeChat article images and redirect hops.
public enum WeChatImageReferences {
  public static func isAllowedImageURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443,
          let host = PublicWebURLPolicy.normalizedHost(url.host ?? "")
    else { return false }
    return host == "mmbiz.qpic.cn" || host.hasSuffix(".mmbiz.qpic.cn") || host == "mmecoa.qpic.cn"
  }
}

public enum GitHubREADMEImageReferences {
  public static func urls(in markdown: String, repository: GitHubRepository) -> [URL] {
    let markdownMatches = matches("!\\[[^\\]]*\\]\\(([^\\s)]+)(?:\\s+[^)]*)?\\)", in: markdown)
    let htmlMatches = matches("<img\\b[^>]*\\bsrc\\s*=\\s*[\\\"']([^\\\"']+)[\\\"'][^>]*>", in: markdown)
    var seen = Set<String>(), result: [URL] = []
    for raw in markdownMatches + htmlMatches {
      guard let url = resolve(raw, repository: repository), seen.insert(url.absoluteString).inserted else { continue }
      result.append(url)
    }
    return result
  }

  private static func resolve(_ raw: String, repository: GitHubRepository) -> URL? {
    guard !raw.hasPrefix("data:"), !raw.hasPrefix("file:"), !raw.hasPrefix("//") else { return nil }
    if let url = URL(string: raw), url.scheme != nil {
      return isAllowedImageURL(url) ? url : nil
    }
    let path = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
    guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
    return URL(string: path, relativeTo: repository.rawBaseURL)?.absoluteURL
  }

  public static func isAllowedImageURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
          let host = PublicWebURLPolicy.normalizedHost(url.host ?? "")
    else { return false }
    return host == "github.com" || host == "raw.githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
  }

  private static func matches(_ pattern: String, in value: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: value) else { return nil }
      return String(value[capture])
    }
  }
}

/// Absolute `https` image URLs embedded in capture markdown (browser / manual pages).
public enum MarkdownRemoteImageReferences {
  public static func absoluteHTTPSURLs(in markdown: String) -> [URL] {
    let markdownMatches = GitHubREADMEImageReferences.matchesPublic(
      "!\\[[^\\]]*\\]\\(([^\\s)]+)(?:\\s+[^)]*)?\\)",
      in: markdown
    )
    let htmlMatches = GitHubREADMEImageReferences.matchesPublic(
      "<img\\b[^>]*\\bsrc\\s*=\\s*[\\\"']([^\\\"']+)[\\\"'][^>]*>",
      in: markdown
    )
    var seen = Set<String>(), result: [URL] = []
    for raw in markdownMatches + htmlMatches {
      guard let url = URL(string: raw), isAllowedImageURL(url), seen.insert(url.absoluteString).inserted else { continue }
      result.append(url)
    }
    return result
  }

  public static func isAllowedImageURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          url.port == nil || url.port == 443,
          let host = PublicWebURLPolicy.normalizedHost(url.host ?? ""),
          !host.isEmpty
    else { return false }
    // Local-first capture may reference CDN hosts (X, WeChat, etc.). Reject obvious private forms.
    if host == "localhost" || host.hasSuffix(".local") { return false }
    if host.contains(":") { return false } // bare IPv6 form
    let labels = host.split(separator: ".")
    if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
      // Crude IPv4 private/reserved skip
      if let a = UInt8(labels[0]), a == 10 || a == 127 || a == 0 { return false }
      if let a = UInt8(labels[0]), let b = UInt8(labels[1]), a == 192, b == 168 { return false }
      if let a = UInt8(labels[0]), let b = UInt8(labels[1]), a == 172, (16...31).contains(b) { return false }
    }
    return true
  }
}

extension GitHubREADMEImageReferences {
  /// Shared regex capture helper for adapters outside this enum.
  fileprivate static func matchesPublic(_ pattern: String, in value: String) -> [String] {
    matches(pattern, in: value)
  }
}
