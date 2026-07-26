import Foundation
import LinkDigestCore

enum BrowserSupportAction: String, Identifiable {
  case install
  case repair

  var id: String { rawValue }
  var title: String { self == .install ? "安装浏览器支持" : "修复浏览器支持" }
}

enum BrowserSupportResultKind: String { case installed, repaired, uninstalled, restored }

struct BrowserSupportResult: Identifiable {
  let browser: BrowserSupportBrowser
  let kind: BrowserSupportResultKind
  var id: String { "\(browser.rawValue)-\(kind.rawValue)" }
}

struct BrowserSupportConfirmation: Identifiable {
  let action: BrowserSupportAction
  let browser: BrowserSupportBrowser
  let fingerprint: String
  var id: String { "\(action.rawValue)-\(browser.rawValue)" }
}

enum BrowserSupportPresentation: Identifiable {
  case confirmation(BrowserSupportConfirmation)
  case result(BrowserSupportResult)

  var id: String {
    switch self {
    case let .confirmation(value): "confirmation-\(value.id)"
    case let .result(value): "result-\(value.id)"
    }
  }
}

@MainActor
final class BrowserSupportViewModel: ObservableObject {
  @Published private(set) var statuses: [BrowserSupportStatus] = []
  @Published private(set) var isLoading = false
  @Published private(set) var activeBrowser: BrowserSupportBrowser?
  @Published var presentation: BrowserSupportPresentation?
  @Published private(set) var errorText: String?

  private let installer: (any BrowserSupportInstalling)?

  init(installer: (any BrowserSupportInstalling)?) {
    self.installer = installer
  }

  var isAvailable: Bool { installer != nil }

  var pendingConfirmation: BrowserSupportConfirmation? {
    guard case let .confirmation(value) = presentation else { return nil }
    return value
  }

  var result: BrowserSupportResult? {
    guard case let .result(value) = presentation else { return nil }
    return value
  }

  func status(for browser: BrowserSupportBrowser) -> BrowserSupportStatus {
    statuses.first(where: { $0.browser == browser })
      ?? .init(browser: browser, state: installer == nil ? .unavailableArtifact : .unavailable, hasRecoverableBackup: false)
  }

  func canInstall(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && status(for: browser).state == .notInstalled
  }

  func canRepair(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable
      && [.currentAppUnverified, .drifted, .unknownManifest, .installedAppUpdated].contains(status(for: browser).state)
  }

  func canUninstall(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && [.installed, .installedAppUpdated].contains(status(for: browser).state)
  }

  func canRestore(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && [.installed, .installedAppUpdated].contains(status(for: browser).state) && status(for: browser).hasRecoverableBackup
  }

  func load() async {
    guard !isLoading, activeBrowser == nil else { return }
    guard let installer else {
      statuses = BrowserSupportBrowser.allCases.map { .init(browser: $0, state: .unavailableArtifact, hasRecoverableBackup: false) }
      return
    }
    isLoading = true
    statuses = await installer.inspect()
    isLoading = false
  }

  /// This entry guard deliberately mirrors the buttons.  Direct calls cannot
  /// skip confirmation or enqueue a second filesystem transaction.
  func requestInstall(_ browser: BrowserSupportBrowser) async {
    guard canInstall(browser) || canRepair(browser) else { return }
    let state = status(for: browser).state
    let action: BrowserSupportAction = state == .notInstalled ? .install : .repair
    if [.currentAppUnverified, .drifted, .unknownManifest].contains(state) {
      guard let fingerprint = status(for: browser).replacementFingerprint else { return }
      presentation = .confirmation(.init(action: action, browser: browser, fingerprint: fingerprint))
      return
    }
    await execute(action, browser: browser)
  }

  func confirmReplacement(_ confirmation: BrowserSupportConfirmation) async {
    guard activeBrowser == nil,
          confirmation.action == .repair,
          !confirmation.fingerprint.isEmpty
    else { return }
    presentation = nil
    guard let installer else { return }
    activeBrowser = confirmation.browser
    errorText = nil
    do {
      try await installer.confirmReplacement(confirmation.browser, expectedFingerprint: confirmation.fingerprint)
      presentation = .result(.init(browser: confirmation.browser, kind: .repaired))
    } catch {
      errorText = visibleError(for: error)
    }
    statuses = await installer.inspect()
    activeBrowser = nil
  }

  func cancelPendingReplacement() { presentation = nil }

  func uninstall(_ browser: BrowserSupportBrowser) async {
    guard canUninstall(browser), let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.uninstall(browser)
      presentation = .result(.init(browser: browser, kind: .uninstalled))
    } catch {
      errorText = visibleError(for: error)
    }
    statuses = await installer.inspect()
    activeBrowser = nil
  }

  func restore(_ browser: BrowserSupportBrowser) async {
    guard canRestore(browser), let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.restoreLatestBackup(browser)
      presentation = .result(.init(browser: browser, kind: .restored))
    } catch {
      errorText = visibleError(for: error)
    }
    statuses = await installer.inspect()
    activeBrowser = nil
  }

  private func execute(_ action: BrowserSupportAction, browser: BrowserSupportBrowser) async {
    guard activeBrowser == nil, let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.install(browser)
      presentation = .result(.init(browser: browser, kind: action == .install ? .installed : .repaired))
    } catch {
      errorText = visibleError(for: error)
    }
    statuses = await installer.inspect()
    activeBrowser = nil
  }

  private func visibleError(for error: Error) -> String {
    switch error as? BrowserSupportInstallerError {
    case .browserNotDetected:
      "未检测到该浏览器的 NativeMessagingHosts 目录。"
    case .frozenArtifactUnavailable:
      "当前 App 包缺少已验证的浏览器支持工件。"
    case .confirmationRequired:
      "检测到同名 manifest；请先确认备份并接管。"
    case .confirmationStale:
      "同名 manifest 已变化，未覆盖；请重新确认最新状态。"
    case .uninstallRefused:
      "manifest 与 LinkDigest 收据不一致，已停止卸载以保护现有文件。"
    case .restoreRefused:
      "当前文件无法确认属于 LinkDigest，不能覆盖恢复。"
    case .unsafeFilesystemState:
      "检测到不安全的文件系统状态，未写入任何浏览器目录。"
    case .transactionFailed, .none:
      "浏览器支持操作未完成；现有文件已保持或恢复。"
    }
  }
}
