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
  /// 惰性：`SiteSessionController.bilibili` 会创建一个 WKWebsiteDataStore 分区，
  /// 只在进设置页时才需要；原来随 App 启动在主线程建。
  lazy var bilibiliSession = SiteSessionController.bilibili
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

  // MARK: - 目录治理

  /// 孤儿扫描的状态机。
  ///
  /// 「扫描」和「删除」是**两步**，中间必须停在一个用户看得见数字的状态上。
  /// 一个按钮直接把文件删掉的设计在这里不能用：这些是用户已经保存到本机的视频，
  /// 删了就没了。
  enum OrphanState: Equatable {
    /// 没接上仓库清单。此时判不了孤儿——「查不到」和「真的一条都没有」长得一样，
    /// 而按后者行事会把整个目录当孤儿删掉。
    case unavailable
    case idle
    case scanning
    case scanned(count: Int, bytes: Int64)
    case deleted(count: Int, bytes: Int64)
    case failed(String)
  }

  @Published private(set) var orphanState: OrphanState = .unavailable
  private var scannedOrphans: [LocalMediaStore.MediaFile] = []

  /// 总容量上限开关。关闭（默认）时不限制，也不会有任何文件被自动删除。
  @Published var totalCapacityEnabled = false {
    didSet {
      guard totalCapacityEnabled != oldValue else { return }
      store.totalCapacityLimitBytes = totalCapacityEnabled
        ? totalCapacityGigabytes * 1024 * 1024 * 1024
        : LocalMediaStore.totalCapacityDisabled
      state = .saved
    }
  }

  @Published var totalCapacityGigabytes = MediaStorageSettingsViewModel.defaultCapacityGigabytes {
    didSet {
      guard totalCapacityGigabytes != oldValue else { return }
      guard totalCapacityEnabled else { return }
      store.totalCapacityLimitBytes = totalCapacityGigabytes * 1024 * 1024 * 1024
      state = .saved
    }
  }

  static let minimumCapacityGigabytes = LocalMediaStore.minimumTotalCapacityBytes / (1024 * 1024 * 1024)
  static let maximumCapacityGigabytes = LocalMediaStore.maximumTotalCapacityBytes / (1024 * 1024 * 1024)
  static let defaultCapacityGigabytes = 20
  static let capacityStepGigabytes = 5

  static func formattedBytes(_ bytes: Int64) -> String {
    let units: [(Double, String)] = [(1024 * 1024 * 1024, "GB"), (1024 * 1024, "MB"), (1024, "KB")]
    for (scale, name) in units where Double(bytes) >= scale {
      return String(format: "%.1f %@", Double(bytes) / scale, name)
    }
    return "\(bytes) B"
  }

  func scanOrphans() {
    guard let mediaStore, let inventory else {
      orphanState = .unavailable
      return
    }
    orphanState = .scanning
    Task { [mediaStore, inventory] in
      let result = await Task.detached { () -> Result<LocalMediaStore.OrphanScan, Error> in
        do {
          let known = Set(try inventory().map(\.relativePath))
          return .success(try mediaStore.scanOrphans(knownRelativePaths: known))
        } catch {
          return .failure(error)
        }
      }.value
      switch result {
      case let .success(scan):
        scannedOrphans = scan.files
        orphanState = .scanned(count: scan.count, bytes: scan.totalBytes)
      case .failure:
        scannedOrphans = []
        orphanState = .failed("这次没能扫完视频文件夹。没有任何文件被改动。请稍后再点一次「扫描一下」。")
      }
    }
  }

  /// 只删刚才扫出来、并且已经在界面上给用户看过数字的那份清单。
  func deleteScannedOrphans() {
    guard let mediaStore, case .scanned = orphanState, !scannedOrphans.isEmpty else { return }
    let files = scannedOrphans
    Task { [mediaStore] in
      let report = await Task.detached { mediaStore.deleteOrphans(files) }.value
      scannedOrphans = []
      orphanState = .deleted(count: report.deleted.count, bytes: report.deletedBytes)
      if !report.refused.isEmpty {
        state = .failed("有 \(report.refused.count) 个文件没能删掉。它们原样留在文件夹里，没有损坏。重新扫描一次就能再试。")
      }
    }
  }

  private let store: UserDefaultsMediaStoragePreferenceStore
  private let mediaStore: LocalMediaStore?
  private let inventory: (@Sendable () throws -> [MediaStorageEntry])?

  /// `mediaStore` / `inventory` 默认为空：设置页在组装期还没接上仓库时也要能打开，
  /// 只是治理那一栏显示「暂不可用」，而不是崩掉或者在没有清单的情况下乱删。
  init(
    store: UserDefaultsMediaStoragePreferenceStore,
    mediaStore: LocalMediaStore? = nil,
    inventory: (@Sendable () throws -> [MediaStorageEntry])? = nil
  ) {
    self.store = store
    self.mediaStore = mediaStore
    self.inventory = inventory
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
    let storedCapacity = store.totalCapacityLimitBytes
    let capacityIsOn = storedCapacity > 0
    if capacityIsOn != totalCapacityEnabled {
      _totalCapacityEnabled = Published(initialValue: capacityIsOn)
    }
    if capacityIsOn {
      let gigabytes = max(Self.minimumCapacityGigabytes, storedCapacity / (1024 * 1024 * 1024))
      if gigabytes != totalCapacityGigabytes {
        _totalCapacityGigabytes = Published(initialValue: gigabytes)
      }
    }
    if mediaStore != nil, inventory != nil {
      if orphanState == .unavailable { orphanState = .idle }
    } else {
      orphanState = .unavailable
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
      state = .failed("读不到你之前选的视频文件夹了。里面的视频没有被动过。请点「选择文件夹」重新指一次。")
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
      state = .failed("没能记住这个文件夹。保存位置还是原来那个，视频没有丢。请重新选一次，或换一个文件夹。")
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
