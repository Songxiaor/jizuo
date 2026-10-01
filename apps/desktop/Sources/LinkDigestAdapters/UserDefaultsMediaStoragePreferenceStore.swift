import Foundation
import LinkDigestCore

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

  /// `Media/` 目录的总容量上限，字节。**0 = 不限制，也是默认值。**
  ///
  /// 开启这项意味着 App 会在用户没点任何按钮的时候删他已经保存的视频，所以默认
  /// 必须是关的：升级一个版本之后文件悄悄变少，是最不该发生的一类"惊喜"。
  private var totalCapacityKey: String { key + ".total-capacity-bytes" }

  public var totalCapacityLimitBytes: Int {
    get { LocalMediaStore.clampedTotalCapacity(defaults.integer(forKey: totalCapacityKey)) }
    set { defaults.set(LocalMediaStore.clampedTotalCapacity(newValue), forKey: totalCapacityKey) }
  }

  public func resetDownloadLimit() { defaults.removeObject(forKey: downloadLimitKey) }

  private var autoSaveCapturedVideoKey: String { key + ".auto-save-captured-video" }

  /// New installs leave auto-save off so captures stream without disk use.
  /// `object(forKey:)` is the important distinction here: `bool(forKey:)` alone
  /// cannot tell an unset key from an existing user's explicit `false` choice.
  /// Unset keys now resolve to `false`. Users who already wrote an explicit
  /// true/false keep that value — there is no migration that rewrites them.
  public var autoSaveCapturedVideo: Bool {
    get {
      defaults.object(forKey: autoSaveCapturedVideoKey) == nil
        ? false
        : defaults.bool(forKey: autoSaveCapturedVideoKey)
    }
    set { defaults.set(newValue, forKey: autoSaveCapturedVideoKey) }
  }

  private var transcribedCleanupModeKey: String { key + ".transcribed-cleanup-mode" }
  private var transcribedCleanupDaysKey: String { key + ".transcribed-cleanup-days" }

  /// 转写后视频清理规则。未设置 = 保留，升级后不会有任何文件被悄悄删掉。
  /// 模式和天数分开存：切回「保留」再切回来时，上次选的天数还在。
  public var transcribedVideoCleanup: TranscribedVideoCleanupPolicy {
    get {
      switch defaults.string(forKey: transcribedCleanupModeKey) {
      case "after-transcription": return .afterTranscription
      case "after-days": return .afterDays(transcribedCleanupDays)
      default: return .keep
      }
    }
    set {
      switch newValue {
      case .keep:
        defaults.removeObject(forKey: transcribedCleanupModeKey)
      case .afterTranscription:
        defaults.set("after-transcription", forKey: transcribedCleanupModeKey)
      case let .afterDays(days):
        defaults.set("after-days", forKey: transcribedCleanupModeKey)
        defaults.set(TranscribedVideoCleanupPolicy.clampedDays(days), forKey: transcribedCleanupDaysKey)
      }
    }
  }

  /// 「保存 N 天后清理」上次选的天数（1–30，默认 30）。
  public var transcribedCleanupDays: Int {
    let stored = defaults.integer(forKey: transcribedCleanupDaysKey)
    return stored > 0 ? TranscribedVideoCleanupPolicy.clampedDays(stored) : TranscribedVideoCleanupPolicy.defaultDays
  }

  private var sessionMediaRestoreModeKey: String { key + ".session-media-restore-mode" }

  /// How history recovers streaming playback after the in-memory descriptor is gone.
  /// Default is manual so relaunch does not immediately hit the network for every video.
  public var sessionMediaRestoreMode: SessionMediaRestoreMode {
    get {
      guard let raw = defaults.string(forKey: sessionMediaRestoreModeKey),
            let mode = SessionMediaRestoreMode(rawValue: raw)
      else { return .default }
      return mode
    }
    set { defaults.set(newValue.rawValue, forKey: sessionMediaRestoreModeKey) }
  }

  private var bilibiliStreamQualityKey: String { key + ".bilibili-stream-quality" }

  /// Ceiling for B 站「重新获取播放」清晰度（公开接口仍可能低于浏览器会话档）。
  public var bilibiliStreamQuality: BilibiliStreamQualityPreference {
    get {
      guard let raw = defaults.string(forKey: bilibiliStreamQualityKey),
            let value = BilibiliStreamQualityPreference(rawValue: raw)
      else { return .default }
      return value
    }
    set { defaults.set(newValue.rawValue, forKey: bilibiliStreamQualityKey) }
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

  /// 和知识库目录同一个坑（2026-09-25）：App 不跑沙盒，security-scoped 书签绑签名，
  /// 本机每次重新打包签名后就解析不出来，被当成「文件夹/文件不见了」。改用普通书签。
  private static func liveCreateBookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(
      options: [],
      includingResourceValuesForKeys: [.isDirectoryKey, .isRegularFileKey],
      relativeTo: nil
    )
  }

  /// 先按普通书签解析；存量 security-scoped 书签再按老方式试一次。
  ///
  /// 两次都不自动挂载（2026-10-01 体检，和 LocalMediaStore.Bookmarks.live 同一条规则）：
  /// 自选文件夹在没接上的移动硬盘或网络盘上时，原来解析会去挂载、在主线程上卡到
  /// 「正在连接服务器」超时；第一次失败后换 security scope 再试，又挂一遍。没接上就
  /// 是「找不到文件夹」，接上之后重新打开即可。
  private static func liveResolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return (url, stale)
    } catch {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return (url, stale)
    }
  }
}
