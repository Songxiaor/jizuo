import AppKit
import Combine
import LinkDigestAdapters
import LinkDigestCore

@MainActor
final class MediaStorageSettingsViewModel: ObservableObject {
  enum State: Equatable { case idle, saved, failed(String) }

  @Published private(set) var directoryPath = "默认（App 本地数据目录）"
  @Published private(set) var usesCustomDirectory = false
  @Published private(set) var state: State = .idle
  @Published var autoSaveCapturedVideo = false {
    didSet {
      guard autoSaveCapturedVideo != oldValue else { return }
      store.autoSaveCapturedVideo = autoSaveCapturedVideo
      state = .saved
    }
  }
  /// History streaming recovery: auto-refresh vs manual “重新获取播放”.
  @Published var sessionMediaRestoreMode: SessionMediaRestoreMode = .default {
    didSet {
      guard sessionMediaRestoreMode != oldValue else { return }
      store.sessionMediaRestoreMode = sessionMediaRestoreMode
      state = .saved
    }
  }
  /// B 站重新获取时的清晰度偏好上限。
  @Published var bilibiliStreamQuality: BilibiliStreamQualityPreference = .default {
    didSet {
      guard bilibiliStreamQuality != oldValue else { return }
      store.bilibiliStreamQuality = bilibiliStreamQuality
      state = .saved
    }
  }
  @Published var isBilibiliLoginPresented = false
  let bilibiliSession = BilibiliSiteSessionController.shared
  /// Ceiling for 保存到本地, in whole GB — the unit the user actually reasons in.
  @Published var downloadLimitGigabytes: Int = 16 {
    didSet {
      guard downloadLimitGigabytes != oldValue else { return }
      store.downloadLimitBytes = downloadLimitGigabytes * 1024 * 1024 * 1024
      state = .saved
    }
  }

  static let minimumLimitGigabytes = LocalMediaStore.minimumDownloadLimitBytes / (1024 * 1024 * 1024)
  static let maximumLimitGigabytes = LocalMediaStore.maximumDownloadLimitBytes / (1024 * 1024 * 1024)

  private let store: UserDefaultsMediaStoragePreferenceStore

  init(store: UserDefaultsMediaStoragePreferenceStore) {
    self.store = store
    load()
  }

  func load() {
    // Assigning through the published property would re-enter didSet and write
    // the value straight back, so read it into place without that round trip.
    let storedGigabytes = store.downloadLimitBytes / (1024 * 1024 * 1024)
    if storedGigabytes != downloadLimitGigabytes {
      _downloadLimitGigabytes = Published(initialValue: storedGigabytes)
    }
    let storedAutoSave = store.autoSaveCapturedVideo
    if storedAutoSave != autoSaveCapturedVideo {
      _autoSaveCapturedVideo = Published(initialValue: storedAutoSave)
    }
    let storedRestore = store.sessionMediaRestoreMode
    if storedRestore != sessionMediaRestoreMode {
      _sessionMediaRestoreMode = Published(initialValue: storedRestore)
    }
    let storedQuality = store.bilibiliStreamQuality
    if storedQuality != bilibiliStreamQuality {
      _bilibiliStreamQuality = Published(initialValue: storedQuality)
    }
    Task { await bilibiliSession.refreshStatus() }
    do {
      if let url = try store.resolvedDirectoryURL() {
        directoryPath = url.path
        usesCustomDirectory = true
      } else {
        directoryPath = "默认（App 本地数据目录）"
        usesCustomDirectory = false
      }
      state = .idle
    } catch let error as MediaStoragePreferenceError {
      usesCustomDirectory = store.hasCustomDirectory
      directoryPath = "已选择的位置当前不可用"
      state = .failed(error.userMessage)
    } catch {
      state = .failed("无法读取视频保存位置，请重新选择。")
    }
  }

  /// A nil URL means the panel was cancelled and must not mutate preference.
  func applySelection(_ url: URL?) {
    guard let url else { return }
    do {
      try store.saveDirectory(url)
      directoryPath = url.path
      usesCustomDirectory = true
      state = .saved
    } catch let error as MediaStoragePreferenceError {
      state = .failed(error.userMessage)
    } catch {
      state = .failed("无法保存这个视频文件夹，请重试。")
    }
  }

  func restoreDefault() {
    store.clearDirectory()
    directoryPath = "默认（App 本地数据目录）"
    usesCustomDirectory = false
    state = .saved
  }

  func presentBilibiliLogin() {
    isBilibiliLoginPresented = true
  }

  func clearBilibiliSession() {
    Task {
      await bilibiliSession.clear()
      state = .saved
    }
  }
}
