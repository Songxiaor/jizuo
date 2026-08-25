import Sparkle
import SwiftUI
import LinkDigestCore

/// 设置里的「版本与更新」。
///
/// 检查更新以前只藏在屏幕顶部「汲作」菜单里，设置页完全没有入口，看起来像功能不存在。
/// 这一页把当前版本、手动检查和「有新版本时提醒我」放在一起。
///
/// 「提醒」只控制要不要主动去看有没有新版本；装不装仍要确认。静默替换由发布配置钉死关闭。
struct AppUpdateSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @StateObject private var model: AppUpdateSettingsModel

  init(updater: SPUUpdater) {
    _model = StateObject(wrappedValue: AppUpdateSettingsModel(updater: updater))
  }

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "版本与更新",
        symbol: "arrow.triangle.2.circlepath",
        caption: "查看当前版本，检查更新。有新版本时只会提醒，不会自己安装。",
        fill: SettingsCategoryChip.fill(for: "updates", theme: appTheme)
      )

      SettingsRowGroup {
        SettingsRow(
          title: "当前版本",
          caption: model.buildLine
        ) {
          Text(model.versionLine)
            .themedFont(.body, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("app-update-version")
        }

        SettingsRow(
          title: "有新版本时提醒我",
          caption: model.reminderCaption,
          details: "按系统节奏在后台检查。发现新版本会弹出说明，是否安装仍由你确认。不会在你不知情时替换汲作。"
        ) {
          Toggle("", isOn: $model.remindsWhenUpdateAvailable)
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!model.canManageReminder)
            .accessibilityLabel("有新版本时提醒我")
            .accessibilityIdentifier("app-update-remind-toggle")
        }
      }

      HStack {
        Button("检查更新") { model.checkForUpdates() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .tint(appTheme.accent)
          .disabled(!model.canCheckForUpdates)
          .accessibilityIdentifier("app-update-check")
        Spacer(minLength: 0)
      }
    }
  }
}

@MainActor
final class AppUpdateSettingsModel: ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published var remindsWhenUpdateAvailable: Bool {
    didSet {
      guard remindsWhenUpdateAvailable != oldValue, let updater else { return }
      updater.automaticallyChecksForUpdates = remindsWhenUpdateAvailable
    }
  }

  let versionLine: String
  let buildLine: String
  let canManageReminder: Bool
  let reminderCaption: String

  private let updater: SPUUpdater?

  init(updater: SPUUpdater, bundle: Bundle = .main) {
    self.updater = updater
    let info = bundle.infoDictionary
    let isConfigured = AppUpdateConfiguration(infoDictionary: info) != nil
    let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    versionLine = "\(ProductDisplay.name) \(shortVersion)"
    buildLine = "内部版本 \(build)"
    canManageReminder = isConfigured
    reminderCaption = isConfigured
      ? "关闭后不会主动检查，仍可点「检查更新」。"
      : "这一份不是发布安装包，不能在线更新。"
    remindsWhenUpdateAvailable = isConfigured && updater.automaticallyChecksForUpdates
    updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }

  func checkForUpdates() {
    guard canCheckForUpdates else { return }
    updater?.checkForUpdates()
  }
}
