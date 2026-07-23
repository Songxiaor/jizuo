import Foundation

public enum MediaStoragePreferenceError: Error, Sendable, Equatable {
  case invalidDirectory
  case bookmarkCreationFailed
  case staleBookmark
  case missingResource
  case unsafeDestination

  public var userMessage: String {
    switch self {
    case .invalidDirectory: "请选择一个可用的文件夹。"
    case .bookmarkCreationFailed: "无法保存这个文件夹的访问权限，请重新选择。"
    case .staleBookmark: "已保存的视频位置权限已失效，请在设置中重新选择文件夹。"
    case .missingResource: "已保存的视频或文件夹不存在，请检查磁盘后重新选择。"
    case .unsafeDestination: "目标位置不是安全的普通文件，已停止保存。"
    }
  }
}

public final class SecurityScopedURLLease: @unchecked Sendable {
  public let url: URL
  private let didStartAccessing: Bool

  init(url: URL) {
    self.url = url
    didStartAccessing = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if didStartAccessing { url.stopAccessingSecurityScopedResource() }
  }
}

/// Local-only preference for a user-selected media directory. Bookmark bytes
/// remain in UserDefaults and are never logged, exported, or sent over IPC.
public final class UserDefaultsMediaStoragePreferenceStore: @unchecked Sendable {
  public typealias BookmarkCreator = @Sendable (URL) throws -> Data
  public typealias BookmarkResolver = @Sendable (Data) throws -> (url: URL, isStale: Bool)

  private let defaults: UserDefaults
  private let key: String
  private let createBookmark: BookmarkCreator
  private let resolveBookmark: BookmarkResolver

  public convenience init(
    suiteName: String? = nil,
    key: String = "media-storage.directory-bookmark"
  ) {
    let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.init(defaults: defaults, key: key)
  }

  init(
    defaults: UserDefaults,
    key: String = "media-storage.directory-bookmark",
    createBookmark: @escaping BookmarkCreator = UserDefaultsMediaStoragePreferenceStore.liveCreateBookmark,
    resolveBookmark: @escaping BookmarkResolver = UserDefaultsMediaStoragePreferenceStore.liveResolveBookmark
  ) {
    self.defaults = defaults
    self.key = key
    self.createBookmark = createBookmark
    self.resolveBookmark = resolveBookmark
  }

  public var hasCustomDirectory: Bool { defaults.data(forKey: key) != nil }

  public func saveDirectory(_ url: URL) throws {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard url.isFileURL,
          values?.isDirectory == true,
          values?.isSymbolicLink != true
    else { throw MediaStoragePreferenceError.invalidDirectory }
    do {
      defaults.set(try createBookmark(url), forKey: key)
    } catch let error as MediaStoragePreferenceError {
      throw error
    } catch {
      throw MediaStoragePreferenceError.bookmarkCreationFailed
    }
  }

  public func clearDirectory() { defaults.removeObject(forKey: key) }

  /// Ceiling for "保存到本地", in bytes. Unset means the built-in default; any
  /// stored value is clamped on read so a hand-edited defaults entry cannot
  /// push the transport bound outside the supported range.
  private var downloadLimitKey: String { key + ".download-limit-bytes" }

  public var downloadLimitBytes: Int {
    get {
      let stored = defaults.integer(forKey: downloadLimitKey)
      guard stored > 0 else { return LocalMediaStore.defaultDownloadLimitBytes }
      return LocalMediaStore.clampedDownloadLimit(stored)
    }
    set { defaults.set(LocalMediaStore.clampedDownloadLimit(newValue), forKey: downloadLimitKey) }
  }

  public func resetDownloadLimit() { defaults.removeObject(forKey: downloadLimitKey) }

  private var autoSaveCapturedVideoKey: String { key + ".auto-save-captured-video" }

  /// New installs keep captured videos by default. `object(forKey:)` is the
  /// important distinction here: `bool(forKey:)` alone cannot tell an unset
  /// key from an existing user's explicit `false` choice.
  public var autoSaveCapturedVideo: Bool {
    get {
      defaults.object(forKey: autoSaveCapturedVideoKey) == nil
        ? true
        : defaults.bool(forKey: autoSaveCapturedVideoKey)
    }
    set { defaults.set(newValue, forKey: autoSaveCapturedVideoKey) }
  }

  public func resolvedDirectoryURL() throws -> URL? {
    guard let bookmark = defaults.data(forKey: key) else { return nil }
    return try resolvedLease(bookmark, requiresDirectory: true).url
  }

  public func directoryLease() throws -> SecurityScopedURLLease? {
    guard let bookmark = defaults.data(forKey: key) else { return nil }
    return try resolvedLease(bookmark, requiresDirectory: true)
  }

  public func fileLease(bookmark: Data) throws -> SecurityScopedURLLease {
    try resolvedLease(bookmark, requiresDirectory: false)
  }

  public func bookmarkForFile(_ url: URL) throws -> Data {
    do { return try createBookmark(url) }
    catch { throw MediaStoragePreferenceError.bookmarkCreationFailed }
  }

  private func resolvedLease(_ bookmark: Data, requiresDirectory: Bool) throws -> SecurityScopedURLLease {
    let resolved: (url: URL, isStale: Bool)
    do { resolved = try resolveBookmark(bookmark) }
    catch { throw MediaStoragePreferenceError.missingResource }
    guard !resolved.isStale else { throw MediaStoragePreferenceError.staleBookmark }
    let lease = SecurityScopedURLLease(url: resolved.url)
    let values = try? resolved.url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard resolved.url.isFileURL,
          values?.isSymbolicLink != true,
          requiresDirectory ? values?.isDirectory == true : values?.isRegularFile == true
    else { throw MediaStoragePreferenceError.missingResource }
    return lease
  }

  private static func liveCreateBookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: [.isDirectoryKey, .isRegularFileKey],
      relativeTo: nil
    )
  }

  private static func liveResolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return (url, stale)
  }
}
