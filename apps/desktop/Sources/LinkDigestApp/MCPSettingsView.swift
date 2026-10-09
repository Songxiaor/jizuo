import LinkDigestCore
import SwiftUI

/// AI 助手接入页：三张卡——开关与权限、连接助手、状态。
///
/// 原来是「1. 启用 / 2. 权限 / 3. 复制连接说明 / 4. 连接结果」四个编号小标题裸露在
/// 卡片外，开关用的是方形勾选框（其它页全是拨杆），「已开启 · 仅限本机当前用户」
/// 在勾选框下、启用状态、服务状态三处各印一遍。现在开关统一拨杆，状态只在
/// 「状态」卡出现一次，说明收进 ⓘ。
struct MCPSettingsView: View {
  @Environment(\.appTheme) private var theme
  @ObservedObject var model: MCPController
  @State private var copyNotice = ""
  @State private var showsAdvanced = false

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "AI 助手",
        symbol: "link",  // 和侧栏「AI 助手」同一个图标
        caption: "让 Claude Code 等助手读写你的内容",
        fill: theme.accent
      )

      SettingsRowGroup {
        SettingsRow(
          title: "允许连接",
          caption: model.enabled ? "本机助手可以读写你的内容" : "关着的时候，任何助手都连不上。",
          details: "开启后，这台 Mac 上用同一个账户运行的助手可以读写你在汲作里保存的内容。只把连接配置交给你信任的助手；它读到的正文可能会被发送给它自己用的模型。关掉之后新的调用会被拒绝，已经提交的保存和转写仍由汲作做完。"
        ) {
          Toggle("", isOn: $model.enabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("允许连接")
            .accessibilityIdentifier("mcp-enabled")
        }
        SettingsRow(
          title: "收集整理",
          caption: "存作品、下视频、加标签和收藏"
        ) {
          Toggle("", isOn: $model.allowsChanges)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("收集整理")
            .accessibilityIdentifier("mcp-allow-changes")
        }
        SettingsRow(
          title: "转写总结",
          caption: "总结用你的模型，可能花钱",
          details: "要不要下载模型、要不要把内容发出去，仍然由汲作自己问你。"
        ) {
          Toggle("", isOn: $model.allowsProcessing)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("转写总结")
            .accessibilityIdentifier("mcp-allow-processing")
        }
      }

      SettingsCard(
        title: "连接助手",
        summary: "复制说明发给助手，照着连",
        details: "适用于能连本机助手服务的客户端。只能填远程网址的云端助手连不上这台 Mac；汲作换了安装位置之后，请重新复制一次连接说明。\n当前支持：内容搜索与读取、链接保存、抖音、小红书、X 和 B 站博主作品发现与保存、本机视频转写、总结、标签、收藏和打开记录。博主发现一次处理一位；多位由助手依次提交。",
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            if !copyNotice.isEmpty {
              Text(copyNotice)
                .themedFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.helperAvailable {
              SettingsInlineNotice(
                message: "这一版\(ProductDisplay.name)里没带连接程序，助手暂时连不上。你保存的内容不受影响。请换成完整版安装包重新安装。",
                tone: .warning
              )
            }
            DisclosureGroup("高级选项", isExpanded: $showsAdvanced) {
              VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Text("复制原始配置，或重启服务")
                  .themedFont(.subheadline)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Space.sm) {
                  advancedButtons
                }
              }
              .padding(.top, DesignTokens.Space.sm)
            }
            .themedFont(.subheadline)
          }
        },
        titleAccessory: {
          copyInstructionsButton
        }
      )

      SettingsRowGroup {
        SettingsRow(
          title: "服务状态",
          details: "服务是否在运行"
        ) {
          Text(enableStatusLine)
            .themedFont(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("mcp-status")
        }
        SettingsRow(
          title: "最近使用",
          details: "只记功能和时间，不记内容"
        ) {
          Text(model.lastCall)
            .themedFont(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("mcp-last-call")
        }
      }
    }
  }

  private var enableStatusLine: String {
    if !model.enabled { return "未开启" }
    if !model.helperAvailable { return "已开启 · 但这一版没带连接程序" }
    return model.status
  }

  private var copyInstructionsButton: some View {
    Button("复制说明") { copy(model.agentInstructions) }
      .buttonStyle(.appProminent(theme.accent))
      .disabled(!model.enabled || !model.helperAvailable)
      .accessibilityIdentifier("mcp-copy-instructions")
  }

  @ViewBuilder private var advancedButtons: some View {
    Button("复制配置") { copy(model.connectionJSON) }
      .buttonStyle(.appQuiet)
      .disabled(!model.helperAvailable)
    Button("重启服务") { model.restart() }
      .buttonStyle(.appQuiet)
      .disabled(!model.enabled)
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    copyNotice = NSPasteboard.general.setString(value, forType: .string)
      ? "已复制，可以粘贴给你的助手了。"
      : "没能复制到剪贴板，你的设置没有变化。请再点一次。"
  }
}
