import AppKit
import LinkDigestAdapters
import LinkDigestCore
import SwiftUI

struct KnowledgeVaultSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: KnowledgeVaultSettingsViewModel

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "知识库同步",
        symbol: "folder.badge.gearshape",
        caption: "把历史里抓到的内容导出成 Markdown，同步进你自己的知识库文件夹。",
        fill: SettingsCategoryChip.fill(for: "knowledgeVault", theme: appTheme)
      )

      SettingsCard(
        title: "知识库文件夹",
        summary: "汲作把历史里抓到的内容导成 Markdown 放进这个文件夹，供你在别的工具里检索。",
        details: """
        只往这个文件夹里写，不读也不改它以外的任何位置。同名文件如果不是汲作写的，会跳过并在同步结果里报出来，不会被覆盖。
        建议单独给汲作一个子文件夹（例如知识库里的「02_输入/汲作」），这样它和你已有的资料物理隔开，出问题也伤不到旧文件。
        文件夹权限用系统书签保存，重启汲作后仍然有效，不需要重新选。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("当前文件夹").foregroundStyle(.secondary)
            Text(model.directoryPath ?? "尚未选择")
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(model.directoryPath ?? "尚未选择")
              .accessibilityIdentifier("knowledge-vault-directory")
            Button(model.hasDirectory ? "更改文件夹" : "选择文件夹", action: chooseDirectory)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(Color.secondary)
              .accessibilityIdentifier("knowledge-vault-choose")
            Button("清除", action: model.clearDirectory)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(Color.secondary)
              .disabled(!model.hasDirectory)
              .accessibilityIdentifier("knowledge-vault-clear")
          }
        }
      }

      SettingsCard(
        title: "同步到知识库",
        summary: "只处理新增和有变化的条目；没变的文件一个字都不会动。",
        details: """
        每条内容导出成一个 Markdown：开头的属性区记录来源、平台、作者、发布与入库时间和标签，正文包含摘要和原文全文，便于全文检索命中。
        正文里带一个「回链」，点它能回到汲作定位到这条内容看全文、视频和转写。
        单篇超长的原文会被截断并标注，因为过大的文件会被下游检索整个跳过。
        你在汲作里写的笔记、稿件和成品不会被同步——那些是你自己写的东西，不是采集来的素材。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Button(action: { Task { await model.sync() } }) {
              if model.isRunning {
                Text("同步中…")
              } else {
                Text("同步到知识库")
              }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(appTheme.accent)
            .disabled(!model.canSync)
            .accessibilityIdentifier("knowledge-vault-sync")

            if case let .running(done, total) = model.state, total > 0 {
              ProgressView(value: Double(done), total: Double(total))
                .frame(maxWidth: 180)
              Text("\(done)/\(total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let lastSyncText = model.lastSyncText {
              Text("上次同步：\(lastSyncText)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("knowledge-vault-last-sync")
            }
          }

          Divider()

          // 手排页里默认 Toggle 是勾选框；设置窗口的开关统一用拨杆并靠右，
          // 和视频存储页保持同一形态。
          HStack {
            Text("抓到新内容后自动同步")
            Spacer(minLength: 12)
            Toggle("", isOn: $model.isAutoSyncEnabled)
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityLabel("抓到新内容后自动同步")
              .accessibilityIdentifier("knowledge-vault-auto-sync")
          }
          Text("在后台安静进行，不打断你；抓一批内容只会同步一次。")
            .font(.caption)
            .foregroundStyle(.tertiary)

          if !model.hasDirectory {
            Text("请先选择知识库文件夹。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if case let .finished(report) = model.state {
            resultView(report)
          }
        }
      }

      if case let .failed(message) = model.state {
        Text(message)
          .foregroundStyle(appTheme.danger)
          .accessibilityIdentifier("knowledge-vault-error")
          .padding(.vertical, DesignTokens.Space.md)
          .padding(.horizontal, DesignTokens.Space.lg)
          .modifier(SettingsThemedCardChrome())
      }
    }
    .onAppear(perform: model.load)
  }

  @ViewBuilder
  private func resultView(_ report: KnowledgeVaultSyncReport) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(report.summaryLine)
        .font(.callout)
        .monospacedDigit()
        .accessibilityIdentifier("knowledge-vault-summary")

      // 冲突和失败必须列出文件名。只说「冲突 3」，用户没法知道去查哪个文件。
      if !report.conflicts.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("以下文件已存在且不归汲作管，已跳过，未做任何修改：")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(report.conflicts, id: \.filename) { conflict in
            Text("· \(conflict.filename) —— \(conflict.reason)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .accessibilityIdentifier("knowledge-vault-conflicts")
      }

      if !report.failures.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("以下条目没能写入：")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(report.failures, id: \.filename) { failure in
            Text("· \(failure.filename) —— \(failure.message)")
              .font(.caption)
              .foregroundStyle(appTheme.danger)
              .textSelection(.enabled)
          }
        }
        .accessibilityIdentifier("knowledge-vault-failures")
      }
    }
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = "选择 \(ProductDisplay.name) 写入 Markdown 的文件夹"
    guard panel.runModal() == .OK else { return }
    model.applySelection(panel.url)
  }
}
