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
  let bilibiliSession = SiteSessionController.bilibili
  /// Ceiling for 保存到本地, in whole MB.
  ///
  /// 以前用整数 GB，那个粒度下 200 MB 这样的值根本表达不出来——区间收到
  /// 200 MB – 2 GB 之后，MB 才是能覆盖整个区间的单位。
  @Published var downloadLimitMegabytes: Int = LocalMediaStore.defaultDownloadLimitBytes / (1024 * 1024) {
    didSet {
      guard downloadLimitMegabytes != oldValue else { return }
      store.downloadLimitBytes = downloadLimitMegabytes * 1024 * 1024
      state = .saved
    }
  }

  static let minimumLimitMegabytes = LocalMediaStore.minimumDownloadLimitBytes / (1024 * 1024)
  static let maximumLimitMegabytes = LocalMediaStore.maximumDownloadLimitBytes / (1024 * 1024)
  /// 200 MB 一档：整个区间 19 步走完，既不用长按半天，也不会一步跨太多。
  static let limitStepMegabytes = 200

  /// 显示用：到 GB 量级就用 GB，免得出现「1800 MB」这种要心算的数字。
  ///
  /// 小数一律**向下**取，不四舍五入：2000 MB 是 1.95 GB，round 会把它显示成
  /// 「2 GB」，跟真正的顶档 2048 MB 撞成同一个字样，看起来像连按两下没反应。
  /// 宁可显示得保守一点，也不能让两个不同的档位长得一样。
  static func formattedLimit(megabytes: Int) -> String {
    guard megabytes >= 1024 else { return "\(megabytes) MB" }
    let gigabytes = Double(megabytes) / 1024
    let truncated = (gigabytes * 10).rounded(.down) / 10
    return truncated == truncated.rounded()
      ? "\(Int(truncated)) GB"
      : String(format: "%.1f GB", truncated)
  }

  private let store: UserDefaultsMediaStoragePreferenceStore

  init(store: UserDefaultsMediaStoragePreferenceStore) {
    self.store = store
    load()
  }

  func load() {
    // Assigning through the published property would re-enter didSet and write
    // the value straight back, so read it into place without that round trip.
    // 读回来的字节数已经被 `clampedDownloadLimit` 收进新区间，所以旧安装里存的
    // 16 GB 会自动落到 2 GB，不需要单独的迁移。
    let storedMegabytes = store.downloadLimitBytes / (1024 * 1024)
    if storedMegabytes != downloadLimitMegabytes {
      _downloadLimitMegabytes = Published(initialValue: storedMegabytes)
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
