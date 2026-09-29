import LinkDigestCore
import SwiftUI

/// 设置 → 按意思搜（2026-09-29）。
struct SemanticSearchSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  let service: SemanticSearchService

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "按意思搜",
        symbol: "text.magnifyingglass",
        caption: "搜索时，除了包含这几个字的内容，再列出讲的是相近事情的内容。比如搜「AI 产品怎么收费」，也能找到写着「订阅制」「定价策略」的收藏。",
        fill: SettingsCategoryChip.fill(for: "semanticSearch", theme: appTheme)
      )

      SettingsCard(
        title: "在这台电脑上理解内容",
        summary: "用一个开源的中文语义模型（BAAI bge-small-zh，MIT 协议）在本机计算，不花钱，内容不会发给任何服务商。",
        details: """
        打开后会下载模型文件，约 91MB，只下载一次；下载完会核对校验值。
        然后给全部内容建一次索引，一千多条大约半分钟。之后新存的内容在你搜索时自动补上。
        索引是单独的一个文件，不改你的资料；关掉后搜索回到只按关键词。
        Agent 通过 MCP 搜索时也会用上。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            if let notice = statusNotice {
              SettingsInlineNotice(message: notice.text, tone: notice.tone)
                .accessibilityIdentifier("semantic-search-status")
            }
            SettingsActionRow(showsProgress: isWorking) {
              if case .failed = service.state {
                Button("重试") { service.retry() }
                  .buttonStyle(.appNormal)
                  .accessibilityIdentifier("semantic-search-retry")
              }
              if service.isEnabled {
                Button("关闭") { service.disable() }
                  .buttonStyle(.appQuiet)
                  .accessibilityIdentifier("semantic-search-disable")
              } else {
                Button("打开（下载约 91MB）") { service.enable() }
                  .buttonStyle(.appProminent(appTheme.accent))
                  .accessibilityIdentifier("semantic-search-enable")
              }
            }
          }
        }
      )
    }
  }

  private var isWorking: Bool {
    switch service.state {
    case .downloading, .loading, .indexing: true
    default: false
    }
  }

  private var statusNotice: (text: String, tone: SettingsInlineNotice.Tone)? {
    switch service.state {
    case .off: nil
    case let .downloading(fraction): ("正在下载模型… \(Int((fraction * 100).rounded()))%", .info)
    case .loading: ("正在载入模型…", .info)
    case let .indexing(done, total): ("正在建索引… \(done) / \(total) 条", .info)
    case let .ready(count): ("已就绪，\(count) 条内容可以按意思搜。", .info)
    case let .failed(message): (message, .danger)
    }
  }
}
