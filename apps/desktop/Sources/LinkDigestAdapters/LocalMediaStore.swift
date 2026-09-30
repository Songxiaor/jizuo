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

  /// `Media/` 目录的总容量上限。**默认 0 = 不限制**。
  ///
  /// 默认关闭是刻意的：开启意味着 App 会在用户没点任何按钮的情况下删他的文件。
  /// 这种事必须是用户自己选的，不能是升级一个版本之后悄悄发生的。
  public static let totalCapacityDisabled = 0
  public static let minimumTotalCapacityBytes = 1024 * 1024 * 1024
  public static let maximumTotalCapacityBytes = 200 * 1024 * 1024 * 1024

  public static func clampedTotalCapacity(_ rawBytes: Int) -> Int {
    guard rawBytes > 0 else { return totalCapacityDisabled }
    return min(max(rawBytes, minimumTotalCapacityBytes), maximumTotalCapacityBytes)
  }

  private let root: URL
  private let fileManager: FileManager
  private let storagePreference: UserDefaultsMediaStoragePreferenceStore?
  private let inventoryLock = NSLock()
  private var inventoryProvider: (@Sendable () throws -> [MediaStorageEntry])?
  private var externalRefresher: (@Sendable (MediaAsset) -> Void)?
  private let externalBookmarks: ExternalMediaReference.Bookmarks

  public init(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default,
    storagePreference: UserDefaultsMediaStoragePreferenceStore? = nil
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    self.fileManager = fileManager
    self.storagePreference = storagePreference
    externalBookmarks = .live
  }

  init(
    applicationSupportRoot: URL,
    externalBookmarks: ExternalMediaReference.Bookmarks
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/Media", isDirectory: true)
    fileManager = .default
    storagePreference = nil
    self.externalBookmarks = externalBookmarks
  }

  public var mediaRoot: URL { root }

  public func ensureRoot() throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  public func absoluteURL(relativePath: String) -> URL {
    root.appendingPathComponent(relativePath, isDirectory: false)
  }

  /// Gallery posters for old video rows: only this store's hashed mp4/mov,
  /// never a user-selected bookmark or a path that escapes `Media/`.
  public func containedInternalMediaURL(relativePath: String) -> URL? {
    let name = (relativePath as NSString).lastPathComponent
    guard name == relativePath,
          name.range(of: #"^[0-9a-f]{64}\.(mp4|mov)$"#, options: .regularExpression) != nil
    else { return nil }
    let url = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
    let rootPath = root.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard url.path.hasPrefix(prefix) else { return nil }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
    return url
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
    // 先按总容量上限腾地方，再做磁盘空间预检——顺序反了的话，明明淘汰之后放得下
    // 的一次下载会先被空间预检挡掉。
    if directoryLease == nil {
      enforceTotalCapacity(incomingByteCount: data.count)
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
    // 本机导入的音视频引用的是原文件，不在 Media/ 也不在自选视频目录里。
    if ExternalMediaReference.isExternal(asset) {
      return try resolveExternalReference(asset)
    }
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

  // MARK: - 目录治理

  /// 目录里的一个文件。孤儿扫描和容量淘汰都用它表达「删哪个、有多大」。
  public struct MediaFile: Sendable, Equatable {
    public let relativePath: String
    public let byteSize: Int64
    public init(relativePath: String, byteSize: Int64) {
      self.relativePath = relativePath
      self.byteSize = byteSize
    }
  }

  public struct OrphanScan: Sendable, Equatable {
    public let files: [MediaFile]
    public var count: Int { files.count }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }
    public init(files: [MediaFile]) { self.files = files }
  }

  /// 列出 `Media/` 下不在 `media_assets` 里的文件。**只列，不删。**
  ///
  /// 清单必须由调用方显式传入，而不是这里去问仓库：孤儿判定是「目录里有、清单里
  /// 没有」，一个取不到清单的实现会把整个目录判成孤儿。宁可要求调用方先拿到清单，
  /// 也不让「拿不到」和「真的一条都没有」长得一样。
  ///
  /// 只认这个 store 自己的命名（64 位 sha + `.mp4`/`.mov`）。没下完的 `.tmp`、
  /// 用户自己拖进来的东西、子目录一律不列——不认识的文件不该由我们来处置。
  public func scanOrphans(knownRelativePaths: Set<String>) throws -> OrphanScan {
    guard fileManager.fileExists(atPath: root.path) else { return .init(files: []) }
    let entries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )
    var orphans: [MediaFile] = []
    for entry in entries {
      let name = entry.lastPathComponent
      guard !knownRelativePaths.contains(name) else { continue }
      // 用同一道边界校验：名字对不上、是软链、是目录、逃出 Media/ 的一律不列。
      guard let url = containedInternalMediaURL(relativePath: name) else { continue }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      orphans.append(.init(relativePath: name, byteSize: Int64(size)))
    }
    return .init(files: orphans.sorted { $0.relativePath < $1.relativePath })
  }

  public struct DeletionReport: Sendable, Equatable {
    public let deleted: [MediaFile]
    public let refused: [String]
    public var deletedBytes: Int64 { deleted.reduce(0) { $0 + $1.byteSize } }
    public init(deleted: [MediaFile], refused: [String]) {
      self.deleted = deleted
      self.refused = refused
    }
  }

  /// **只删传入的这份清单**，一条都不多。
  ///
  /// 每条仍要再过一次 `containedInternalMediaURL`：清单可能是几秒前扫出来的，
  /// 中间目录可能变了；而且这个方法是公开的，不能假设调用方给的是干净的输入。
  /// 校验不过的进 `refused`，不静默跳过——删文件这件事上，「什么都没发生」
  /// 必须能被看见。
  @discardableResult
  public func deleteOrphans(_ files: [MediaFile]) -> DeletionReport {
    deleteContainedFiles(files)
  }

  @discardableResult
  private func deleteContainedFiles(_ files: [MediaFile]) -> DeletionReport {
    var deleted: [MediaFile] = []
    var refused: [String] = []
    for file in files {
      guard let url = containedInternalMediaURL(relativePath: file.relativePath) else {
        refused.append(file.relativePath)
        continue
      }
      do {
        try fileManager.removeItem(at: url)
        deleted.append(file)
      } catch {
        refused.append(file.relativePath)
      }
    }
    return .init(deleted: deleted, refused: refused)
  }

  /// `Media/` 目录当前占用的字节数（只数这个 store 自己的文件）。
  public func totalStoredBytes() throws -> Int64 {
    guard fileManager.fileExists(atPath: root.path) else { return 0 }
    let entries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )
    return entries.reduce(Int64(0)) { total, entry in
      guard let url = containedInternalMediaURL(relativePath: entry.lastPathComponent) else { return total }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      return total + Int64(size)
    }
  }

  /// 总容量上限触发的淘汰计划：按「最久没碰过」优先，删够为止。
  ///
  /// 纯函数，不碰磁盘，好让顺序这件事能被单独测。
  /// - 用户自己选的文件夹里的文件不参与：那是用户的文件，不是我们的缓存。
  /// - 同一个文件可能被多条记录引用（内容寻址），只算一次、也只删一次。
  public static func evictionPlan(
    inventory: [MediaStorageEntry],
    fileSizes: [String: Int64],
    currentBytes: Int64,
    incomingBytes: Int64,
    limitBytes: Int64
  ) -> [MediaFile] {
    guard limitBytes > 0 else { return [] }
    var budget = currentBytes + incomingBytes - limitBytes
    guard budget > 0 else { return [] }
    var seen = Set<String>()
    var plan: [MediaFile] = []
    for entry in inventory.sorted(by: {
      $0.lastUsedMilliseconds == $1.lastUsedMilliseconds
        ? $0.mediaID < $1.mediaID
        : $0.lastUsedMilliseconds < $1.lastUsedMilliseconds
    }) {
      guard budget > 0 else { break }
      guard !entry.usesUserSelectedFile else { continue }
      guard seen.insert(entry.relativePath).inserted else { continue }
      guard let size = fileSizes[entry.relativePath] else { continue }
      plan.append(.init(relativePath: entry.relativePath, byteSize: size))
      budget -= size
    }
    return plan
  }

  /// 淘汰前要知道「库里认哪些文件、各自多久没碰过」，而这个 store 不认识仓库。
  /// 组装期把清单的来源接进来；没接就等于治理功能未启用，绝不瞎删。
  public func setInventoryProvider(_ provider: (@Sendable () throws -> [MediaStorageEntry])?) {
    inventoryLock.lock()
    defer { inventoryLock.unlock() }
    inventoryProvider = provider
  }

  private func currentInventory() -> [MediaStorageEntry]? {
    inventoryLock.lock()
    let provider = inventoryProvider
    inventoryLock.unlock()
    guard let provider else { return nil }
    return try? provider()
  }

  public struct EvictionOutcome: Sendable, Equatable {
    public let evicted: [MediaFile]
    public let stillOverLimit: Bool
    public init(evicted: [MediaFile], stillOverLimit: Bool) {
      self.evicted = evicted
      self.stillOverLimit = stillOverLimit
    }
  }

  /// 新下载写盘前，按总容量上限腾地方。
  ///
  /// 上限默认关闭；关闭时这里直接返回，一个文件都不动。
  ///
  /// 腾不出足够空间也**不**让下载失败：上限是日常清理，不是写入闸门——单个文件
  /// 的大小已经由「单个视频上限」和磁盘预检各挡了一道。因为一项清理策略而让
  /// 「保存到本地」报错，用户只会觉得功能坏了。
  ///
  /// 被淘汰的只删文件，DB 行留着：那条记录还在历史里，界面照旧走「暂不可播 /
  /// 重新获取」那条路，用户随时能再下一次。
  @discardableResult
  public func enforceTotalCapacity(incomingByteCount: Int) -> EvictionOutcome {
    let limit = Int64(storagePreference?.totalCapacityLimitBytes ?? 0)
    guard limit > 0 else { return .init(evicted: [], stillOverLimit: false) }
    // 用户自己选的文件夹是用户的地盘，容量治理一步都不进去。
    guard storagePreference?.hasCustomDirectory != true else {
      return .init(evicted: [], stillOverLimit: false)
    }
    guard let inventory = currentInventory() else {
      return .init(evicted: [], stillOverLimit: false)
    }
    let sizes = fileSizesInRoot()
    let currentBytes = sizes.values.reduce(0, +)
    let plan = Self.evictionPlan(
      inventory: inventory,
      fileSizes: sizes,
      currentBytes: currentBytes,
      incomingBytes: Int64(incomingByteCount),
      limitBytes: limit
    )
    guard !plan.isEmpty else {
      return .init(evicted: [], stillOverLimit: currentBytes + Int64(incomingByteCount) > limit)
    }
    let report = deleteContainedFiles(plan)
    let remaining = currentBytes - report.deletedBytes + Int64(incomingByteCount)
    return .init(evicted: report.deleted, stillOverLimit: remaining > limit)
  }

  private func fileSizesInRoot() -> [String: Int64] {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ) else { return [:] }
    var sizes: [String: Int64] = [:]
    for entry in entries {
      let name = entry.lastPathComponent
      guard let url = containedInternalMediaURL(relativePath: name) else { continue }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      sizes[name] = Int64(size)
    }
    return sizes
  }

  /// 转写后清理的计划：纯函数，便于单测。
  ///
  /// - 只删 App 自己目录里的文件；用户自选文件夹里的永远不动。
  /// - 内容寻址：同一个文件可能被多条记录引用，**每一条**都已转写且都到期才删，
  ///   免得一条已转写的记录把另一条还没转写的视频一起带走。
  /// - 只算磁盘上确实还在的文件。
  public static func transcribedCleanupPlan(
    inventory: [MediaStorageEntry],
    fileSizes: [String: Int64],
    policy: TranscribedVideoCleanupPolicy,
    now: Date
  ) -> [MediaFile] {
    guard let cutoff = policy.cutoffMilliseconds(now: now) else { return [] }
    var eligible: [String: Bool] = [:]
    var order: [String] = []
    for entry in inventory {
      // 「转写完成后清理」只删转写晚于保存的视频；转写之后才下载回来的，留给用户用。
      let transcribed = policy == .afterTranscription ? entry.transcribedAfterSaving : entry.isTranscribed
      let ok = !entry.usesUserSelectedFile && transcribed && entry.createdAtMilliseconds <= cutoff
      if eligible[entry.relativePath] == nil { order.append(entry.relativePath) }
      eligible[entry.relativePath] = (eligible[entry.relativePath] ?? true) && ok
    }
    return order.compactMap { path in
      guard eligible[path] == true, let size = fileSizes[path] else { return nil }
      return MediaFile(relativePath: path, byteSize: size)
    }
  }

  /// 按当前清理规则算出要删哪些文件（不删）。清单读不到时返回 nil：
  /// 「查不到」和「没有可删的」必须分开，前者绝不能当成后者去删。
  public func transcribedCleanupCandidates(now: Date = Date()) -> [MediaFile]? {
    let policy = storagePreference?.transcribedVideoCleanup ?? .keep
    return transcribedCleanupCandidates(policy: policy, now: now)
  }

  public func transcribedCleanupCandidates(policy: TranscribedVideoCleanupPolicy, now: Date = Date()) -> [MediaFile]? {
    guard policy != .keep else { return [] }
    guard let inventory = currentInventory() else { return nil }
    return Self.transcribedCleanupPlan(inventory: inventory, fileSizes: fileSizesInRoot(), policy: policy, now: now)
  }

  /// 删掉清理计划里的文件：只删文件，记录、文字、评论都留着。
  public func deleteTranscribedVideos(_ files: [MediaFile]) -> DeletionReport {
    deleteContainedFiles(files)
  }

  public func deleteFileIfUnreferenced(asset: MediaAsset, stillReferenced: Bool) {
    // User-selected files are user-owned. Deleting History only removes the DB
    // relationship; legacy internal media keeps its previous cleanup behavior.
    guard asset.fileBookmark == nil else { return }
    deleteFileIfUnreferenced(relativePath: asset.relativePath, stillReferenced: stillReferenced)
  }

  // MARK: - 引用原文件（本机导入，2026-09-29）

  /// 给拖进来的原文件建一条「只引用、不复制」的媒体记录。
  ///
  /// 存法沿用 `media_assets` 现有两列，不改表：
  /// - `relative_path`：`{sha256}.mp4`（原文件是 .mov 时为 `.mov`）。只是满足既有校验的占位名，
  ///   `Media/` 里**没有**这个文件；
  /// - `file_bookmark`：`ExternalMediaReference` 前缀 + 原文件的普通书签。书签认的是文件本身，
  ///   同一块盘里移动、改名之后照样找得到。
  /// 因为 `file_bookmark` 非空，它天然享有「用户自己的文件」那套保护：删条目、容量淘汰、
  /// 转写后清理都不会动它。
  public func externalReferenceAsset(
    fileURL: URL,
    taskID: TaskID,
    snapshotID: ContentSnapshotID?,
    contentSHA256: String,
    byteSize: Int64,
    durationSeconds: Double?,
    platform: String,
    createdAtMilliseconds: Int64
  ) throws -> MediaAsset {
    let bookmark: Data
    do { bookmark = try externalBookmarks.create(fileURL) }
    catch { throw ExternalMediaReferenceError.unreadable }
    return MediaAsset(
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: ExternalMediaReference.placeholderRelativePath(
        contentSHA256: contentSHA256, fileExtension: fileURL.pathExtension
      ),
      fileBookmark: ExternalMediaReference.encode(bookmark: bookmark),
      contentSHA256: contentSHA256,
      byteSize: byteSize,
      durationSeconds: durationSeconds,
      platform: platform,
      createdAtMilliseconds: createdAtMilliseconds
    )
  }

  /// 找原文件。书签「过期」（文件被移动或改名）时仍用它找到的新位置，并交给
  /// `externalReferenceRefresher` 把新书签写回库里，下次直接命中。
  /// 找不到时抛 `originalMissing`，带上最后知道的位置，阅读页据此说明并提供「重新定位…」。
  public func resolveExternalReference(_ asset: MediaAsset) throws -> SecurityScopedURLLease {
    guard let bookmark = ExternalMediaReference.bookmark(from: asset.fileBookmark) else {
      throw ExternalMediaReferenceError.originalMissing(lastKnownPath: nil)
    }
    let missing = ExternalMediaReferenceError.originalMissing(
      lastKnownPath: ExternalMediaReference.lastKnownPath(bookmark: bookmark)
    )
    let resolved: (url: URL, isStale: Bool)
    do { resolved = try externalBookmarks.resolve(bookmark) }
    catch { throw missing }
    let values = try? resolved.url.resourceValues(forKeys: [.isRegularFileKey])
    guard resolved.url.isFileURL, values?.isRegularFile == true else { throw missing }
    if resolved.isStale, let fresh = try? externalBookmarks.create(resolved.url) {
      externalReferenceRefresher()?(asset.replacingFileBookmark(ExternalMediaReference.encode(bookmark: fresh)))
    }
    return SecurityScopedURLLease(url: resolved.url)
  }

  /// 「重新定位…」：用户选了一个新位置。只接受和当初导入**同一份内容**的文件（按 SHA-256 核对），
  /// 条目的身份就是这份内容；换成别的文件等于悄悄把条目换了个芯。
  /// 要把整个文件读一遍，调用方放到后台线程。
  public func relocatedExternalReference(_ asset: MediaAsset, to fileURL: URL) throws -> MediaAsset {
    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard fileURL.isFileURL, values?.isRegularFile == true else { throw ExternalMediaReferenceError.unreadable }
    guard Int64(values?.fileSize ?? -1) == asset.byteSize,
          (try? LocalFileImportReader.contentSHA256(of: fileURL)) == asset.contentSHA256
    else { throw ExternalMediaReferenceError.contentMismatch }
    let bookmark: Data
    do { bookmark = try externalBookmarks.create(fileURL) }
    catch { throw ExternalMediaReferenceError.unreadable }
    return asset.replacingFileBookmark(ExternalMediaReference.encode(bookmark: bookmark))
  }

  /// 书签过期后要把新书签写回库里，但这个 store 不认识仓库：由组装方（本机导入）接进来。
  public func setExternalReferenceRefresher(_ refresher: (@Sendable (MediaAsset) -> Void)?) {
    inventoryLock.lock()
    defer { inventoryLock.unlock() }
    externalRefresher = refresher
  }

  private func externalReferenceRefresher() -> (@Sendable (MediaAsset) -> Void)? {
    inventoryLock.lock()
    defer { inventoryLock.unlock() }
    return externalRefresher
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

public enum ExternalMediaReferenceError: Error, Sendable, Equatable {
  /// 书签解析不出来或指向的东西不是文件：被删、被挪到别的盘、所在的移动硬盘没接上。
  case originalMissing(lastKnownPath: String?)
  /// 「重新定位」选的文件和当初导入的不是同一份内容。
  case contentMismatch
  /// 选的文件读不出来，或者给它建不了书签。
  case unreadable

  public var userMessage: String {
    switch self {
    case .originalMissing:
      return "找不到原文件：它可能被删除、移到了别的磁盘，或者所在的移动硬盘没有连接。"
    case .contentMismatch:
      return "选的文件和当初导入的不是同一份内容（可能被剪辑、转码过，或者选错了文件）。想收新版本的话，直接把它拖进汲作导入成新条目。"
    case .unreadable:
      return "这个文件读不出来，可能已损坏或没有读取权限。"
    }
  }
}

/// `media_assets.file_bookmark` 里「引用原文件」的写法：固定前缀 + 普通书签。
///
/// 前缀把它和「设置 → 视频存储」自选目录里那种书签分开：那种书签指向汲作自己存的
/// `{sha}.mp4`，丢了该去设置里重选目录；这种指向用户的原文件，丢了该「重新定位」。
public enum ExternalMediaReference {
  static let magic = Data("linkdigest-original-file:v1\n".utf8)

  public static func encode(bookmark: Data) -> Data { magic + bookmark }

  /// 不是这种写法（旧条目、自选目录）时返回 nil。
  public static func bookmark(from stored: Data?) -> Data? {
    guard let stored, stored.count > magic.count, stored.starts(with: magic) else { return nil }
    return Data(stored.dropFirst(magic.count))
  }

  public static func isExternal(_ asset: MediaAsset) -> Bool { bookmark(from: asset.fileBookmark) != nil }

  /// 书签里记着的最后位置。文件不在了也读得出来，用来告诉用户「原来在哪」。
  public static func lastKnownPath(of asset: MediaAsset) -> String? {
    bookmark(from: asset.fileBookmark).flatMap(lastKnownPath(bookmark:))
  }

  static func lastKnownPath(bookmark: Data) -> String? {
    URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
  }

  /// `relative_path` 的占位名：满足既有校验（64 位 sha + .mp4/.mov），Media/ 里没有这个文件。
  public static func placeholderRelativePath(contentSHA256: String, fileExtension: String) -> String {
    "\(contentSHA256.lowercased()).\(fileExtension.lowercased() == "mov" ? "mov" : "mp4")"
  }

  /// 建书签与解析书签。可替换只为测试；线上始终是 `live`。
  struct Bookmarks: Sendable {
    let create: @Sendable (URL) throws -> Data
    let resolve: @Sendable (Data) throws -> (url: URL, isStale: Bool)

    /// 普通书签，不带 security scope：App 不跑沙盒，带 scope 的书签绑签名，每次重新打包
    /// 签名后就解析不出来（和知识库目录、自选视频目录同一个坑，2026-09-25）。
    /// 解析时不弹窗、不自动挂载网络盘——详情页打开时不能卡在「正在连接服务器」上；
    /// 移动硬盘没接上就是「找不到原文件」，接上之后重新打开这条即可。
    static let live = Bookmarks(
      create: { url in
        try url.bookmarkData(options: [], includingResourceValuesForKeys: [.fileSizeKey], relativeTo: nil)
      },
      resolve: { data in
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withoutUI, .withoutMounting],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        return (url, stale)
      }
    )
  }
}

extension MediaAsset {
  /// 换一个书签，其余原样。转写状态写成 `.none` 只是为了过 `attachMedia` 的入口校验：
  /// 同一 (task, sha) 已有记录时走的是 UPDATE，那条路径不碰转写状态。
  public func replacingFileBookmark(_ bookmark: Data) -> MediaAsset {
    MediaAsset(
      id: id,
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: relativePath,
      fileBookmark: bookmark,
      contentSHA256: contentSHA256,
      byteSize: byteSize,
      durationSeconds: durationSeconds,
      platform: platform,
      author: author,
      transcriptionStatus: .none,
      createdAtMilliseconds: createdAtMilliseconds
    )
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
    AppLog.info(.media, "media_download_started", [
      "host": AppLog.host(url),
      "platform": media.platform,
    ])
    do {
      return try await downloadAndStoreResultUnlocked(
        url: url,
        media: media,
        taskID: taskID,
        snapshotID: snapshotID,
        pageURL: pageURL
      )
    } catch {
      AppLog.error(
        .media,
        "media_download_failed",
        code: Self.mediaLogCode(error),
        ["host": AppLog.host(url), "platform": media.platform]
      )
      throw error
    }
  }

  private func downloadAndStoreResultUnlocked(
    url: URL,
    media: CaptureMedia,
    taskID: TaskID,
    snapshotID: ContentSnapshotID?,
    pageURL: String?
  ) async throws -> DownloadResult {
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
    AppLog.info(.media, "media_download_succeeded", [
      "host": AppLog.host(url),
      "platform": media.platform,
      "bytes": String(body.count),
    ])
    return .init(asset: asset, storedFile: stored)
  }

  private static func mediaLogCode(_ error: Error) -> String {
    guard let error = error as? MediaDownloadError else { return "MEDIA_DOWNLOAD_FAILED" }
    switch error {
    case .invalidURL: return "MEDIA_INVALID_URL"
    case .unsafeURL: return "MEDIA_UNSAFE_URL"
    case .responseStatus: return "MEDIA_RESPONSE_STATUS"
    case .unsupportedContainer: return "MEDIA_UNSUPPORTED_CONTAINER"
    case .responseTooLarge: return "MEDIA_TOO_LARGE"
    case .insufficientDiskSpace: return "MEDIA_DISK_FULL"
    case .emptyBody: return "MEDIA_EMPTY_BODY"
    case .timedOut: return "MEDIA_TIMED_OUT"
    case .network: return "MEDIA_NETWORK"
    case .cancelled: return "MEDIA_CANCELLED"
    case .storageLocationUnavailable: return "MEDIA_STORAGE_UNAVAILABLE"
    case .unsafeDestination: return "MEDIA_UNSAFE_DESTINATION"
    }
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
