import LinkDigestShared
import SwiftUI

struct CompanionNoteSyncSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var model: CompanionNoteSyncCoordinator

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "手机同步",
        symbol: "iphone.and.arrow.forward",
        // 页头只说这页干什么。签名、iCloud 容器这些技术原因在卡片的 ⓘ 里。
        caption: "把笔记和链接同步到 iPhone",
        fill: SettingsCategoryChip.fill(for: "companionSync", theme: appTheme)
      )

      SettingsCard(
        title: "与 iPhone 同步",
        summary: "通过你的 iCloud 同步",
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
          // 三种状态之间淡入淡出；高度不同，减弱动态时不做动画。
          VStack(alignment: .leading, spacing: 0) {
            if !model.canSync && !model.isRunning {
              SettingsInlineNotice(message: "这一版还不能同步到 iPhone；原因见标题旁的 ⓘ。", tone: .warning)
                .transition(.opacity)
                .accessibilityIdentifier("companion-sync-status")
            } else if model.status.phase == .failed {
              SettingsInlineNotice(message: model.statusSummary, tone: .danger)
                .transition(.opacity)
                .accessibilityIdentifier("companion-sync-status")
            } else {
              Text(model.statusSummary)
                .themedFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .transition(.opacity)
                .accessibilityIdentifier("companion-sync-status")
            }
          }
          .animation(reduceMotion ? nil : DesignTokens.Motion.quick, value: statusKind)
        },
        titleAccessory: {
          Button {
            Task { await model.synchronize() }
          } label: {
            Text(model.isRunning ? "同步中…" : "立即同步")
              .contentTransition(.opacity)
          }
          .animation(
            DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
            value: model.isRunning)
          .buttonStyle(.appProminent(appTheme.accent))
          .disabled(!model.canSync)
          .accessibilityIdentifier("companion-sync-now")
        }
      )
    }
  }

  /// 当前显示哪一种状态（不可用 / 失败 / 普通说明）；只有它翻转才触发转场。
  private var statusKind: Int {
    if !model.canSync && !model.isRunning { return 0 }
    if model.status.phase == .failed { return 1 }
    return 2
  }
}
