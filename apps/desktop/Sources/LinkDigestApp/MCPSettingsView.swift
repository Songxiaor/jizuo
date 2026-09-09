import SwiftUI

/// MCP 连接页：三张卡——开关与权限、连接 Agent、状态。
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
        title: "MCP 连接",
        symbol: "point.3.connected.trianglepath.dotted",
        caption: "让你的 Agent 直接使用汲作。连接程序随 App 安装，无需额外安装 Skill 或运行环境。",
        fill: theme.accent
      )

      SettingsRowGroup {
        SettingsRow(
          title: "开启本地 MCP",
          caption: model.enabled ? nil : "未开启时本地接口不对外提供。",
          details: "开启后，同一 Mac 用户下的本地程序可以通过此接口访问资料。只把连接配置交给你信任的 Agent；返回的正文可能被发送给它使用的模型。关闭后会拒绝新调用，已提交的保存和转写任务仍由汲作处理。"
        ) {
          Toggle("", isOn: $model.enabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("开启本地 MCP")
            .accessibilityIdentifier("mcp-enabled")
        }
        SettingsRow(
          title: "允许抓取与整理",
          caption: "添加博主、发现与保存作品、下载视频、标签和收藏。"
        ) {
          Toggle("", isOn: $model.allowsChanges)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("允许抓取与整理")
            .accessibilityIdentifier("mcp-allow-changes")
        }
        SettingsRow(
          title: "允许转写与总结",
          caption: "本地转写用汲作的识别服务；总结用你配置的模型，可能产生费用。",
          details: "模型下载和数据发送授权仍在 App 中处理。"
        ) {
          Toggle("", isOn: $model.allowsProcessing)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("允许转写与总结")
            .accessibilityIdentifier("mcp-allow-processing")
        }
      }

      SettingsCard(
        title: "连接 Agent",
        summary: "复制连接说明粘贴给本机 Agent，让它配置并重新连接，调用 jizuo_status 确认成功。",
        details: "适用于支持本地 stdio MCP 的 Agent 客户端。仅支持远程 URL 的云端 Agent 不能直接连接本机；安装位置改变后，请重新复制配置。\n当前支持：资料搜索与读取、链接保存、抖音、小红书、X 和 B 站博主作品发现与保存、本地视频转写、总结、标签、收藏和打开记录。博主发现一次处理一位；多位由 Agent 依次提交。",
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
              SettingsInlineNotice(message: "当前 App 缺少 MCP 连接程序，请使用包含 MCP 的完整安装包。", tone: .warning)
            }
            DisclosureGroup("高级：JSON 配置与服务重启", isExpanded: $showsAdvanced) {
              VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                Text("复制原始 JSON，或在服务异常时手动重启。不会改变上方权限或默认启用状态。")
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
          details: "本机接口是否在跑；不代表 Agent 当前仍在线。"
        ) {
          Text(enableStatusLine)
            .themedFont(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("mcp-status")
        }
        SettingsRow(
          title: "近期调用",
          details: "记录最近工具名与时间；不记录正文或凭据。"
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
    if !model.helperAvailable { return "已开启 · 但缺少连接程序" }
    return model.status
  }

  private var copyInstructionsButton: some View {
    Button("复制连接说明") { copy(model.agentInstructions) }
      .buttonStyle(.appProminent(theme.accent))
      .disabled(!model.enabled || !model.helperAvailable)
      .accessibilityIdentifier("mcp-copy-instructions")
  }

  @ViewBuilder private var advancedButtons: some View {
    Button("复制 JSON 配置") { copy(model.connectionJSON) }
      .buttonStyle(.appQuiet)
      .disabled(!model.helperAvailable)
    Button("重试服务") { model.restart() }
      .buttonStyle(.appQuiet)
      .disabled(!model.enabled)
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    copyNotice = NSPasteboard.general.setString(value, forType: .string)
      ? "已复制，可粘贴给你的 Agent。"
      : "复制失败，请重试。"
  }
}
