import SwiftUI

struct MCPSettingsView: View {
  @ObservedObject var model: MCPController
  @State private var copyNotice = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("MCP 连接").font(.title2.bold())
        Text("让你的 Agent 直接使用汲作。连接程序随 App 安装，无需额外安装 Skill 或运行环境。")
          .foregroundStyle(.secondary)
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Toggle("开启本地 MCP", isOn: $model.enabled)
              .accessibilityIdentifier("mcp-enabled")
            Text(model.status).font(.callout)
              .accessibilityIdentifier("mcp-status")
            Text("开启后，同一 Mac 用户下的本地程序可以通过此接口访问资料。只把连接配置交给你信任的 Agent；返回的正文可能被发送给它使用的模型。关闭后会拒绝新调用，已提交的保存和转写任务仍由汲作处理。")
              .font(.caption).foregroundStyle(.secondary)
            Toggle("允许抓取与整理", isOn: $model.allowsChanges)
              .accessibilityIdentifier("mcp-allow-changes")
            Text("添加博主、发现与保存作品、下载视频、标签和收藏。")
              .font(.caption).foregroundStyle(.secondary)
            Toggle("允许转写与总结", isOn: $model.allowsProcessing)
              .accessibilityIdentifier("mcp-allow-processing")
            Text("本地视频转写使用汲作的识别服务；总结使用你配置的模型，可能产生费用。模型下载和数据发送授权仍在 App 中处理。")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("交给 Agent 连接") {
          VStack(alignment: .leading, spacing: 12) {
            Text("1. 开启上方 MCP，并按任务选择权限。\n2. 点击“复制连接说明”，粘贴给本机 Agent。\n3. 让 Agent 配置并重新连接，调用 jizuo_status 确认成功。")
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              Button("复制连接说明") { copy(model.agentInstructions) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.enabled || !model.helperAvailable)
                .accessibilityIdentifier("mcp-copy-instructions")
              Button("复制 JSON 配置") { copy(model.connectionJSON) }
                .disabled(!model.helperAvailable)
              Button("重试服务") { model.restart() }.disabled(!model.enabled)
            }
            if !copyNotice.isEmpty { Text(copyNotice).font(.caption) }
            if !model.helperAvailable {
              Text("当前 App 缺少 MCP 连接程序，请使用包含 MCP 的完整安装包。")
                .foregroundStyle(.secondary)
            }
            Text("适用于支持本地 stdio MCP 的 Agent 客户端。仅支持远程 URL 的云端 Agent 不能直接连接本机；安装位置改变后，请重新复制配置。")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("连接记录") {
          VStack(alignment: .leading, spacing: 8) {
            Text(model.lastCall).accessibilityIdentifier("mcp-last-call")
            Text("这里只显示最近工具名称和调用时间，不记录正文或凭据。")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("当前支持：资料搜索与读取、链接保存、抖音博主作品发现与保存、本地视频转写、总结、标签、收藏和打开记录。博主发现一次处理一位；多位由 Agent 依次提交。")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(maxWidth: 820, alignment: .leading)
    }
  }
  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    copyNotice = NSPasteboard.general.setString(value, forType: .string) ? "已复制，可粘贴给你的 Agent。" : "复制失败，请重试。"
  }
}
