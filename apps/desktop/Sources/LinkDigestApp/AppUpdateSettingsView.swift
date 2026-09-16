import AppKit
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

  /// 兜底提示。会临时顶掉「反馈问题」那一行的说明文字，所以得是状态。
  @State private var feedbackNote: String?

  /// 优先交给系统邮件应用；系统把 `mailto:` 交给了浏览器（或压根没有邮件应用）时
  /// 改走网页版写信；两个都不行就把地址复制到剪贴板并说明。
  /// 三种结果都要有反馈——这一行按钮的价值全在「点了真能发出信」。
  private func writeFeedback() {
    let address = FeedbackMail.address(releaseConfiguration: nil)
    switch FeedbackMail.composeTarget(
      address: address,
      environment: DiagnosticsReport.liveEnvironment()
    ) {
    case let .mailClient(url), let .webMail(url):
      NSWorkspace.shared.open(url)
    case .none:
      copyFeedbackAddress()
    }
  }

  private func copyFeedbackAddress() {
    let address = FeedbackMail.address(releaseConfiguration: nil)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(address, forType: .string)
    feedbackNote = "已把 \(address) 复制到剪贴板，可以粘到任意邮箱里。"
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
        // 「检查更新」和版本号同一行：它是这页唯一的动作，原来裸露在卡片外的左下角。
        SettingsRow(
          title: "当前版本",
          caption: model.buildLine
        ) {
          HStack(spacing: DesignTokens.Space.md) {
            Text(model.versionLine)
              .themedFont(.body, monospacedDigit: true)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("app-update-version")
            Button("检查更新") { model.checkForUpdates() }
              .buttonStyle(.appNormal)
              .disabled(!model.canCheckForUpdates)
              .accessibilityIdentifier("app-update-check")
          }
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

        SettingsRow(
          title: "导出诊断信息",
          caption: "不含正文、网址和密钥。含最近两小时运行日志和抓取成败计数。"
        ) {
          Button("导出…") {
            let counts = CaptureOutcomeStore.shared?.snapshot() ?? CaptureOutcomeCounts()
            _ = DiagnosticsExportAction.exportWithSavePanel(counts: counts)
          }
          .buttonStyle(.appNormal)
          .accessibilityLabel("导出诊断信息")
          .accessibilityIdentifier("app-update-export-diagnostics")
        }

        SettingsRow(
          title: "反馈问题",
          // 兜底提示会临时顶掉这句说明（见 writeFeedback），所以它得是 @State。
          caption: feedbackNote ?? "打开邮件把版本信息发给支持邮箱。不会附带你保存的内容。"
        ) {
          HStack(spacing: DesignTokens.Space.md) {
            Button("写邮件…") { writeFeedback() }
              .buttonStyle(.appNormal)
              .accessibilityLabel("反馈问题")
              .accessibilityIdentifier("app-update-feedback")
            // 系统里没有任何能处理 mailto 的邮件应用时，至少要保证地址拿得到。
            Button("复制地址") { copyFeedbackAddress() }
              .buttonStyle(.appNormal)
              .accessibilityLabel("复制支持邮箱地址")
              .accessibilityIdentifier("app-update-feedback-copy")
          }
        }
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
