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
        // 页头只说这页干什么。签名、CloudKit 容器这些技术原因在卡片的 ⓘ 里。
        caption: "把「我的笔记」和链接卡同步到 iPhone。API Key 不同步。",
        fill: SettingsCategoryChip.fill(for: "companionSync", theme: appTheme)
      )

      SettingsCard(
        title: "与 iPhone 同步",
        summary: "本机历史里的「我的笔记」和链接会投影成笔记卡，经 iCloud 私有库与手机互相同步。",
        details: """
        流程：导出本机条目 → CloudKit 拉推合并 → 写回本机历史。
        软删除会在两端传播；稿件与作品不同步。
        需要系统已登录 Apple ID，并在签名产物里打开 iCloud(CloudKit) 容器 iCloud.com.syc.linkdigest。当前日用包是 ad-hoc 签名，没有 iCloud 能力，启动时不会连 CloudKit，避免闪退。
        免费 Personal Team 可能无法开通自定义 CloudKit 容器；若同步报权限错误，需要付费 Apple Developer Program。
        当前状态：\(model.statusSummary)
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          // 状态独占一行：能同步时是一句安静的灰字，不能同步或失败时是一条提示条。
          // 原来一整行红字挤在禁用按钮右边，既读不完整也分不清是错误还是说明。
          // 没法同步（日用包没有 iCloud 能力）时先判这一条：这时协调器的 phase 也是
          // failed，但那不是「同步失败」，是「这一版没有这个功能」，不该用红色报错。
          // 用户要知道的只有「现在不能用」；签名、容器这些原因在 ⓘ 里。
          if !model.canSync && !model.isRunning {
            SettingsInlineNotice(message: "这一版还不能同步到 iPhone；原因见标题旁的 ⓘ。", tone: .warning)
              .accessibilityIdentifier("companion-sync-status")
          } else if model.status.phase == .failed {
            SettingsInlineNotice(message: model.statusSummary, tone: .danger)
              .accessibilityIdentifier("companion-sync-status")
          } else {
            Text(model.statusSummary)
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("companion-sync-status")
          }
        },
        titleAccessory: {
          Button {
            Task { await model.synchronize() }
          } label: {
            Text(model.isRunning ? "同步中…" : "立即同步")
          }
          .buttonStyle(.appProminent(appTheme.accent))
          .disabled(!model.canSync)
          .accessibilityIdentifier("companion-sync-now")
        }
      )
    }
  }
}
