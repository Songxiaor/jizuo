import CryptoKit
import Foundation
import LinkDigestCore

/// Local video/media files for Loop V captures.
///
/// Layout: `Application Support/LinkDigest/Media/{sha256}.mp4` (or `.mov`).
/// Signed remote URLs are downloaded once into this store and never re-fetched
/// later from a saved URL. Task deletion removes the DB row (CASCADE) and then
/// unlinks the file when no other task still references the same content hash.
public final class LocalMediaStore: @unchecked Sendable {
  /// User-configurable ceiling for "保存到本地".
  ///
  /// 区间取 200 MB – 2 GB。之前是 1–128 GB、默认 16 GB，两头都不合用：最低 1 GB
  /// 对「只想留个几百兆的短视频」来说起点太高，而 128 GB 实际上等于没有上限——
  /// 单个视频不该有这个量级，一旦某个响应声称自己有几十 GB，这道闸门就形同虚设。
  ///
  /// 上界必须是有限值：整个传输层建立在有限的 `byteLimit` 之上，无上限会拿掉
  /// 「畸形或恶意响应把磁盘写满」的唯一刹车。
  public static let defaultDownloadLimitBytes = 1024 * 1024 * 1024
  public static let minimumDownloadLimitBytes = 200 * 1024 * 1024
  public static let maximumDownloadLimitBytes = 2 * 1024 * 1024 * 1024
  /// 传输层的响应上限，必须跟得上用户能配置的最大值。
  ///
  /// 原来它等于**默认值**而不是最大值，于是配置高于默认值时，传输层会先一步把
  /// 下载卡掉，用户调大的那部分根本不生效。绑到上界就不会再有这种错位。
  public static let maxBytes = maximumDownloadLimitBytes
  /// Keep at least this much free space after the write (safety margin).
  public static let minimumFreeBytesAfterWrite: Int64 = 50 * 1024 * 1024
  /// Never let a configured ceiling commit more than the volume can spare.
  public static let reservedFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

  public static func clampedDownloadLimit(_ rawBytes: Int) -> Int {
    min(max(rawBytes, minimumDownloadLimitBytes), maximumDownloadLimitBytes)
  }

  private let root: URL
  private let fileManager: FileManager
  private let storagePreference: UserDefaultsMediaStoragePreferenceStore?

  public init(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default,
    storagePreference: UserDefaultsMediaStoragePreferenceStore? = nil
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    self.fileManager = fileManager
    self.storagePreference = storagePreference
  }

  public var mediaRoot: URL { root }

  public func ensureRoot() throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  public func absoluteURL(relativePath: String) -> URL {
    root.appendingPathComponent(relativePath, isDirectory: false)
  }

  /// Validates Content-Type + magic bytes for mp4/mov containers.
  public static func validatedContainer(body: Data, contentType: String?) throws -> String {
    guard !body.isEmpty else { throw MediaDownloadError.emptyBody }
    let type = contentType?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    // `audio/mp4`：B 站 DASH 的独立音轨（`.m4s`）也是 ISO base media 容器，
    // 内容就是这条视频的声音，转写要的正是它。
    let isMP4Type = type == nil
      || type == "video/mp4"
      || type == "application/mp4"
      || type == "audio/mp4"
      || type == "video/quicktime"
      || type == "application/octet-stream"
    guard isMP4Type else { throw MediaDownloadError.unsupportedContainer }
    if isISOBaseMedia(body) {
      // Prefer .mov when the server explicitly said quicktime; otherwise .mp4.
      if type == "video/quicktime" { return "mov" }
      return "mp4"
    }
    throw MediaDownloadError.unsupportedContainer
  }

  public static func contentSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func assertDiskSpace(forByteCount byteCount: Int) throws {
    try assertDiskSpace(forByteCount: byteCount, at: root)
  }

  /// The configured ceiling, further reduced by what the volume can spare.
  /// Callers use this as the transport `byteLimit`, so an over-large download is
  /// stopped mid-stream rather than after the disk is already full.
  public func effectiveDownloadLimitBytes() -> Int {
    let configured = storagePreference?.downloadLimitBytes ?? Self.defaultDownloadLimitBytes
    let values = try? root.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    )
    let available = [
      values?.volumeAvailableCapacityForImportantUsage,
      values?.volumeAvailableCapacity.map(Int64.init),
    ].compactMap { $0 }.max()
    guard let available else { return configured }
    let spareBytes = available - Self.reservedFreeBytes
    guard spareBytes > 0 else { return 0 }
    return min(configured, Int(clamping: spareBytes))
  }

  private func assertDiskSpace(forByteCount byteCount: Int, at directory: URL) throws {
    let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let available = [
      values.volumeAvailableCapacityForImportantUsage,
      values.volumeAvailableCapacity.map(Int64.init),
    ].compactMap { $0 }.max() ?? Int64.max
    let needed = Int64(byteCount) + Self.minimumFreeBytesAfterWrite
    guard available >= needed else { throw MediaDownloadError.insufficientDiskSpace }
  }

  /// Writes validated bytes under the content hash name. Idempotent for the same hash.
  public func store(data: Data, preferredExtension: String) throws -> (relativePath: String, sha256: String) {
    let stored = try storeDetailed(data: data, preferredExtension: preferredExtension)
    return (stored.relativePath, stored.sha256)
  }

  public struct StoredFile: Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let fileBookmark: Data?
    public let fileURL: URL
    public let didCreateFile: Bool
  }

  public func storeDetailed(data: Data, preferredExtension: String) throws -> StoredFile {
    let directoryLease: SecurityScopedURLLease?
    do { directoryLease = try storagePreference?.directoryLease() }
    catch { throw MediaDownloadError.storageLocationUnavailable }
    let directory = directoryLease?.url ?? root
    if directoryLease == nil {
      try ensureRoot()
    } else {
      let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else {
        throw MediaDownloadError.storageLocationUnavailable
      }
    }
    try assertDiskSpace(forByteCount: data.count, at: directory)
    let sha = Self.contentSHA256(data)
    let ext = preferredExtension.hasPrefix(".") ? String(preferredExtension.dropFirst()) : preferredExtension
    let relative = "\(sha).\(ext)"
    let destination = directory.appendingPathComponent(relative, isDirectory: false)
    var didCreateFile = false
    if fileManager.fileExists(atPath: destination.path) {
      try validateExistingDestination(destination, expectedSHA256: sha)
    } else {
      let temporary = directory.appendingPathComponent(".linkdigest-\(UUID().uuidString).tmp", isDirectory: false)
      do {
        try data.write(to: temporary, options: [.withoutOverwriting])
        if fileManager.fileExists(atPath: destination.path) {
          try validateExistingDestination(destination, expectedSHA256: sha)
          try? fileManager.removeItem(at: temporary)
        } else {
          try fileManager.moveItem(at: temporary, to: destination)
          didCreateFile = true
        }
      } catch {
        try? fileManager.removeItem(at: temporary)
        throw error
      }
    }
    let bookmark: Data?
    if directoryLease != nil {
      do { bookmark = try storagePreference?.bookmarkForFile(destination) }
      catch {
        if didCreateFile { try? fileManager.removeItem(at: destination) }
        throw MediaDownloadError.storageLocationUnavailable
      }
    } else {
      bookmark = nil
    }
    return .init(
      relativePath: relative,
      sha256: sha,
      fileBookmark: bookmark,
      fileURL: destination,
      didCreateFile: didCreateFile
    )
  }

  public func resolve(_ asset: MediaAsset) throws -> SecurityScopedURLLease {
    if let bookmark = asset.fileBookmark {
      guard let storagePreference else { throw MediaStoragePreferenceError.missingResource }
      return try storagePreference.fileLease(bookmark: bookmark)
    }
    let url = absoluteURL(relativePath: asset.relativePath)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw MediaStoragePreferenceError.missingResource
    }
    return SecurityScopedURLLease(url: url)
  }

  public func rollbackCreatedFile(_ stored: StoredFile) {
    guard stored.didCreateFile else { return }
    guard (try? validateExistingDestination(stored.fileURL, expectedSHA256: stored.sha256)) != nil else {
      return
    }
    try? fileManager.removeItem(at: stored.fileURL)
  }

  private func validateExistingDestination(_ url: URL, expectedSHA256: String) throws {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true,
          values?.isDirectory != true,
          values?.isSymbolicLink != true,
          let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          Self.contentSHA256(bytes) == expectedSHA256
    else { throw MediaDownloadError.unsafeDestination }
  }

  public func deleteFileIfUnreferenced(relativePath: String, stillReferenced: Bool) {
    guard !stillReferenced else { return }
    let url = absoluteURL(relativePath: relativePath)
    try? fileManager.removeItem(at: url)
  }

  public func deleteFileIfUnreferenced(asset: MediaAsset, stillReferenced: Bool) {
    // User-selected files are user-owned. Deleting History only removes the DB
    // relationship; legacy internal media keeps its previous cleanup behavior.
    guard asset.fileBookmark == nil else { return }
    deleteFileIfUnreferenced(relativePath: asset.relativePath, stillReferenced: stillReferenced)
  }

  /// ISO BMFF / QuickTime: `ftyp` box within the first 12 bytes (size + 'ftyp').
  private static func isISOBaseMedia(_ data: Data) -> Bool {
    guard data.count >= 12 else { return false }
    // Standard: bytes 4..8 == "ftyp"
    if data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 { return true }
    // Some producers place a free/wide box first; scan the first 64 bytes for 'ftyp'.
    let limit = min(data.count - 4, 64)
    if limit >= 4 {
      for index in 0...limit {
        if data[index] == 0x66, data[index + 1] == 0x74, data[index + 2] == 0x79, data[index + 3] == 0x70 {
          return true
        }
      }
    }
    return false
  }
}

/// Downloads a single signed media URL through the same PeerBound / proxy resource
/// path as other adapters. Never retains the remote URL after success.
public final class VideoMediaDownloader: @unchecked Sendable {
  private let resources: any SafeResourceFetching
  private let store: LocalMediaStore
  private let nowMilliseconds: @Sendable () -> Int64

  /// CDNs (notably Douyin) reject the default `LinkDigest/0.1` client with 403.
  /// Present the same public browser identity as the audio-download path; still
  /// never attach cookies or credentials.
  private static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  public init(
    resources: any SafeResourceFetching,
    store: LocalMediaStore,
    nowMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.resources = resources
    self.store = store
    self.nowMilliseconds = nowMilliseconds
  }

  public func downloadAndStore(
    media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID?,
    pageURL: String? = nil
  ) async throws -> MediaAsset {
    try await downloadAndStoreResult(
      media: media,
      taskID: taskID,
      snapshotID: snapshotID,
      pageURL: pageURL
    ).asset
  }

  public struct DownloadResult: Sendable, Equatable {
    public let asset: MediaAsset
    public let storedFile: LocalMediaStore.StoredFile
  }

  public func downloadAndStoreResult(
    media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID?,
    pageURL: String? = nil
  ) async throws -> DownloadResult {
    guard let url = URL(string: media.videoURL), url.scheme?.lowercased() == "https" else {
      throw MediaDownloadError.invalidURL
    }
    // Douyin CDN rejects bare clients without a same-site Referer (403).
    // Use the public page URL when present; never attach cookies or credentials.
    var headers: [String: String] = [
      "Accept": "video/mp4,video/quicktime,audio/mp4,application/octet-stream,*/*",
      "User-Agent": Self.browserUserAgent,
    ]
    if media.platform == "douyin" {
      let referer = pageURL.flatMap { URL(string: $0) }.map { url -> String in
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? "https://www.douyin.com/"
      } ?? "https://www.douyin.com/"
      headers["Referer"] = referer
      headers["Origin"] = "https://www.douyin.com"
    }
    // 实测 `*.bilivideo.com` 无 Referer 一律 403，带站点根 Referer 即 206。
    // 只发站点根，不把带查询串的观看页地址泄给 CDN；同样不带 cookie。
    if media.platform == "bilibili" {
      headers["Referer"] = "https://www.bilibili.com/"
    }
    // The effective ceiling is the smaller of what the user allowed and what the
    // volume can actually spare, so a large download fails fast with a clear
    // reason instead of filling the disk and failing at write time.
    let effectiveLimit = store.effectiveDownloadLimitBytes()
    let response: SafeResourceResponse
    do {
      response = try await resources.fetchResource(
        .init(
          url: url,
          headers: headers,
          byteLimit: effectiveLimit
        )
      )
    } catch let error as ManualLinkError {
      throw mapManual(error)
    } catch is CancellationError {
      throw MediaDownloadError.cancelled
    } catch {
      throw MediaDownloadError.network
    }
    guard (200...299).contains(response.statusCode) else { throw MediaDownloadError.responseStatus }
    guard response.body.count > 0 else { throw MediaDownloadError.emptyBody }
    guard response.body.count <= effectiveLimit else { throw MediaDownloadError.responseTooLarge }
    var body = response.body
    var fileExtension = try LocalMediaStore.validatedContainer(body: body, contentType: response.contentType)

    // 画面与声音分成两条流的来源（B 站 DASH）：刚下到的只是画面，再取一次音轨，
    // 在本机合成一个带声音的 mp4 再落库。合成失败就保留画面那条——有画面无声
    // 也好过整条抓取失败，转写还能另走音轨。
    if let companion = media.companionAudioURL,
       let companionURL = URL(string: companion),
       companionURL.scheme?.lowercased() == "https" {
      do {
        let audio = try await resources.fetchResource(
          .init(url: companionURL, headers: headers, byteLimit: effectiveLimit)
        )
        guard (200...299).contains(audio.statusCode), !audio.body.isEmpty else {
          throw MediaDownloadError.responseStatus
        }
        _ = try LocalMediaStore.validatedContainer(body: audio.body, contentType: audio.contentType)
        body = try await Self.muxedContainer(video: body, audio: audio.body)
        fileExtension = "mp4"
      } catch is CancellationError {
        throw MediaDownloadError.cancelled
      } catch {
        // 保留画面那条继续走原路径。
      }
    }

    let stored = try store.storeDetailed(data: body, preferredExtension: fileExtension)
    let asset = MediaAsset(
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: stored.relativePath,
      fileBookmark: stored.fileBookmark,
      contentSHA256: stored.sha256,
      byteSize: Int64(body.count),
      durationSeconds: media.durationSeconds,
      platform: media.platform,
      author: media.author,
      transcriptionStatus: .none,
      createdAtMilliseconds: nowMilliseconds()
    )
    return .init(asset: asset, storedFile: stored)
  }

  /// 合成需要文件而不是内存里的字节，所以先落到临时目录，合成完读回来，
  /// 无论成败都清掉临时文件——这三个中间件都不进媒体库。
  private static func muxedContainer(video: Data, audio: Data) async throws -> Data {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-mux-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let videoURL = workspace.appendingPathComponent("video.mp4", isDirectory: false)
    let audioURL = workspace.appendingPathComponent("audio.mp4", isDirectory: false)
    let outputURL = workspace.appendingPathComponent("muxed.mp4", isDirectory: false)
    try video.write(to: videoURL, options: .atomic)
    try audio.write(to: audioURL, options: .atomic)
    try await SeparateTrackMuxer.mux(
      videoFileURL: videoURL,
      audioFileURL: audioURL,
      destinationURL: outputURL
    )
    return try Data(contentsOf: outputURL, options: .mappedIfSafe)
  }

  private func mapManual(_ error: ManualLinkError) -> MediaDownloadError {
    switch error {
    case .unsafeURL: .unsafeURL
    case .responseStatus: .responseStatus
    case .responseTooLarge: .responseTooLarge
    case .timedOut: .timedOut
    case .cancelled: .cancelled
    case .invalidURL: .invalidURL
    default: .network
    }
  }
}
