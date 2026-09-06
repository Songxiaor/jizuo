import LinkDigestShared
import SwiftUI

struct CompanionNoteSyncSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @Bindable var model: CompanionNoteSyncCoordinator

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "手机同步",
        symbol: "iphone.and.arrow.forward",
        caption: "通过 iCloud CloudKit 与 iPhone Companion 同步笔记和链接卡。当前日用包是 ad-hoc 签名，没有 iCloud 能力，启动时不会连 CloudKit，避免闪退。API Key 不同步。",
        fill: SettingsCategoryChip.fill(for: "companionSync", theme: appTheme)
      )

      SettingsCard(
        title: "与 iPhone 同步",
        summary: "本机历史里的「我的笔记」和链接会投影成笔记卡，经 iCloud 私有库与手机互相同步。",
        details: """
        流程：导出本机条目 → CloudKit 拉推合并 → 写回本机历史。
        软删除会在两端传播；稿件与作品不同步。
        需要系统已登录 Apple ID，并在签名产物里打开 iCloud(CloudKit) 容器 iCloud.com.syc.linkdigest。
        免费 Personal Team 可能无法开通自定义 CloudKit 容器；若同步报权限错误，需要付费 Apple Developer Program。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Button {
              Task { await model.synchronize() }
            } label: {
              Text(model.isRunning ? "同步中…" : "立即同步")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(appTheme.accent)
            .disabled(!model.canSync)
            .accessibilityIdentifier("companion-sync-now")

            Spacer(minLength: 0)

            Text(model.statusSummary)
              .font(.caption)
              .foregroundStyle(model.status.phase == .failed ? appTheme.danger : .secondary)
              .lineLimit(3)
              .accessibilityIdentifier("companion-sync-status")
          }
        }
      }
    }
  }
}
