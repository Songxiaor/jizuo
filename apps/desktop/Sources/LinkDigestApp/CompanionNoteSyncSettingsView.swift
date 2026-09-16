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
        // 页头只说这页干什么。签名、iCloud 容器这些技术原因在卡片的 ⓘ 里。
        caption: "把「我的笔记」和链接卡同步到 iPhone。密钥不会同步过去。",
        fill: SettingsCategoryChip.fill(for: "companionSync", theme: appTheme)
      )

      SettingsCard(
        title: "与 iPhone 同步",
        summary: "本机历史里的「我的笔记」和链接会投影成笔记卡，经 iCloud 私有库与手机互相同步。",
        details: """
        同步走你自己的 iCloud 私人空间：本机先导出，和 iCloud 上的合并，再写回本机。两边都只有你自己看得到。
        在一边删掉的，另一边也会跟着删；稿件和成品不参与同步。
        需要这台 Mac 已经登录 Apple ID。当前这一版汲作没有开通 iCloud 能力，所以启动时不会去连，也不会因此闪退——这就是下面按钮点不动的原因。
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
