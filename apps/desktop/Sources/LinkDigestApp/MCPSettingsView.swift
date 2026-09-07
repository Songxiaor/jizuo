import SwiftUI

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

      SettingsCardGroup(header: "1. 启用") {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          Toggle("开启本地 MCP", isOn: $model.enabled)
            .accessibilityIdentifier("mcp-enabled")
          Text(enableStatusLine)
            .themedFont(.callout)
            .foregroundStyle(model.enabled ? theme.primaryText : theme.secondaryText)
            .accessibilityIdentifier("mcp-status")
            .fixedSize(horizontal: false, vertical: true)
          Text("开启后，同一 Mac 用户下的本地程序可以通过此接口访问资料。只把连接配置交给你信任的 Agent；返回的正文可能被发送给它使用的模型。关闭后会拒绝新调用，已提交的保存和转写任务仍由汲作处理。")
            .themedFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(header: "2. 权限") {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
          VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Toggle("允许抓取与整理", isOn: $model.allowsChanges)
              .accessibilityIdentifier("mcp-allow-changes")
            Text("添加博主、发现与保存作品、下载视频、标签和收藏。")
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Toggle("允许转写与总结", isOn: $model.allowsProcessing)
              .accessibilityIdentifier("mcp-allow-processing")
            Text("本地视频转写使用汲作的识别服务；总结使用你配置的模型，可能产生费用。模型下载和数据发送授权仍在 App 中处理。")
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(
        header: "3. 复制连接说明",
        footer: "适用于支持本地 stdio MCP 的 Agent 客户端。仅支持远程 URL 的云端 Agent 不能直接连接本机；安装位置改变后，请重新复制配置。"
      ) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          Text("1. 开启上方 MCP，并按任务选择权限。\n2. 点击「复制连接说明」，粘贴给本机 Agent。\n3. 让 Agent 配置并重新连接，调用 jizuo_status 确认成功。")
            .themedFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
          copyInstructionsButton
          if !copyNotice.isEmpty {
            Text(copyNotice)
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !model.helperAvailable {
            Text("当前 App 缺少 MCP 连接程序，请使用包含 MCP 的完整安装包。")
              .themedFont(.caption)
              .foregroundStyle(theme.warning)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(header: "4. 连接结果") {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          statusRow(title: "启用状态", value: model.enabled ? "已开启" : "未开启")
          statusRow(title: "服务状态", value: model.status)
          statusRow(title: "近期调用", value: model.lastCall)
            .accessibilityIdentifier("mcp-last-call")
          Text("「启用」是开关；「服务」是本机接口是否在跑；「近期调用」记录最近工具名与时间，不代表 Agent 当前仍在线；不记录正文或凭据。")
            .themedFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      DisclosureGroup("高级：JSON 配置与服务重启", isExpanded: $showsAdvanced) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          Text("复制原始 JSON，或在服务异常时手动重启。不会改变上方权限或默认启用状态。")
            .themedFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Space.sm) {
              advancedButtons
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
              advancedButtons
            }
          }
        }
        .padding(.top, DesignTokens.Space.sm)
      }
      .themedFont(.callout)

      Text("当前支持：资料搜索与读取、链接保存、抖音、小红书、X 和 B 站博主作品发现与保存、本地视频转写、总结、标签、收藏和打开记录。博主发现一次处理一位；多位由 Agent 依次提交。")
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var enableStatusLine: String {
    if !model.enabled { return "未开启 · 本地接口未对外提供" }
    if !model.helperAvailable { return "已开启 · 但缺少连接程序" }
    return model.status
  }

  private var copyInstructionsButton: some View {
    Button("复制连接说明") { copy(model.agentInstructions) }
      .buttonStyle(.borderedProminent)
      .disabled(!model.enabled || !model.helperAvailable)
      .accessibilityIdentifier("mcp-copy-instructions")
  }

  @ViewBuilder private var advancedButtons: some View {
    Button("复制 JSON 配置") { copy(model.connectionJSON) }
      .disabled(!model.helperAvailable)
    Button("重试服务") { model.restart() }
      .disabled(!model.enabled)
  }

  private func statusRow(title: String, value: String) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
        Text(title)
          .themedFont(.callout, weight: .medium)
          .foregroundStyle(theme.secondaryText)
          .frame(minWidth: 72, alignment: .leading)
        Text(value)
          .themedFont(.callout)
          .foregroundStyle(theme.primaryText)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text(title)
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(theme.secondaryText)
        Text(value)
          .themedFont(.callout)
          .foregroundStyle(theme.primaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    copyNotice = NSPasteboard.general.setString(value, forType: .string)
      ? "已复制，可粘贴给你的 Agent。"
      : "复制失败，请重试。"
  }
}
