import Foundation
import LinkDigestCore

public enum KnowledgeVaultError: Error, Sendable, Equatable {
  case invalidDirectory
  case bookmarkCreationFailed
  case staleBookmark
  case missingDirectory
  case unsafeDestination

  public var userMessage: String {
    switch self {
    case .invalidDirectory: "请选择一个可用的文件夹。"
    case .bookmarkCreationFailed: "无法保存这个文件夹的访问权限，请重新选择。"
    case .staleBookmark: "已保存的知识库文件夹权限已失效，请在设置中重新选择。"
    case .missingDirectory: "知识库文件夹不存在或已被移动，请重新选择。"
    case .unsafeDestination: "目标位置不是普通文件夹，已停止同步。"
    }
  }
}

/// 知识库目录的本机授权。
///
/// bookmark 字节只留在 UserDefaults，不写日志、不导出、不过 IPC——和视频目录
/// 那份存储同一条规矩。用 security-scoped bookmark 而不是存路径，是为了目录被
/// 改名或搬走之后授权还能跟着走。
public final class UserDefaultsKnowledgeVaultStore: @unchecked Sendable {
  public typealias BookmarkCreator = @Sendable (URL) throws -> Data
  public typealias BookmarkResolver = @Sendable (Data) throws -> (url: URL, isStale: Bool)

  private let defaults: UserDefaults
  private let key: String
  private let createBookmark: BookmarkCreator
  private let resolveBookmark: BookmarkResolver

  public convenience init(
    suiteName: String? = nil,
    key: String = "knowledge-vault.directory-bookmark"
  ) {
    let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.init(defaults: defaults, key: key)
  }

  init(
    defaults: UserDefaults,
    key: String = "knowledge-vault.directory-bookmark",
    createBookmark: @escaping BookmarkCreator = UserDefaultsKnowledgeVaultStore.liveCreateBookmark,
    resolveBookmark: @escaping BookmarkResolver = UserDefaultsKnowledgeVaultStore.liveResolveBookmark
  ) {
    self.defaults = defaults
    self.key = key
    self.createBookmark = createBookmark
    self.resolveBookmark = resolveBookmark
  }

  public var hasDirectory: Bool { defaults.data(forKey: key) != nil }

  /// 上次同步完成的时间，只用于在设置里显示「上次同步：…」。
  private var lastSyncKey: String { key + ".last-sync-ms" }

  public var lastSyncMilliseconds: Int64? {
    get {
      let value = defaults.object(forKey: lastSyncKey) as? Int64
      return value.flatMap { $0 > 0 ? $0 : nil }
    }
    set {
      guard let newValue else { defaults.removeObject(forKey: lastSyncKey); return }
      defaults.set(newValue, forKey: lastSyncKey)
    }
  }

  private var autoSyncKey: String { key + ".auto-sync" }

  /// 抓到新内容后自动同步一次。
  ///
  /// 默认开：手动同步的问题在于，你不会在抓完东西的时候想起来点它——等到
  /// 真正要找素材时才发现没同步，而那正是最需要它的时刻。
  /// 用 `object(forKey:)` 区分「没设置过」和「用户明确关掉了」。
  public var isAutoSyncEnabled: Bool {
    get {
      defaults.object(forKey: autoSyncKey) == nil ? true : defaults.bool(forKey: autoSyncKey)
    }
    set { defaults.set(newValue, forKey: autoSyncKey) }
  }

  public func saveDirectory(_ url: URL) throws {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard url.isFileURL,
          values?.isDirectory == true,
          values?.isSymbolicLink != true
    else { throw KnowledgeVaultError.invalidDirectory }
    do {
      defaults.set(try createBookmark(url), forKey: key)
    } catch {
      throw KnowledgeVaultError.bookmarkCreationFailed
    }
  }

  public func clearDirectory() {
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: lastSyncKey)
  }

  /// 解析出目录并同时开住 security scope。租约活着的时候才能读写这个目录。
  public func directoryLease() throws -> SecurityScopedURLLease? {
    guard let bookmark = defaults.data(forKey: key) else { return nil }
    let resolved: (url: URL, isStale: Bool)
    do { resolved = try resolveBookmark(bookmark) }
    catch { throw KnowledgeVaultError.missingDirectory }
    guard !resolved.isStale else { throw KnowledgeVaultError.staleBookmark }
    let lease = SecurityScopedURLLease(url: resolved.url)
    let values = try? resolved.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard resolved.url.isFileURL,
          values?.isSymbolicLink != true,
          values?.isDirectory == true
    else { throw KnowledgeVaultError.missingDirectory }
    return lease
  }

  /// 只取路径给界面显示用，不开租约。
  public func displayPath() -> String? {
    guard let bookmark = defaults.data(forKey: key) else { return nil }
    return (try? resolveBookmark(bookmark))?.url.path
  }

  private static func liveCreateBookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: [.isDirectoryKey],
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
