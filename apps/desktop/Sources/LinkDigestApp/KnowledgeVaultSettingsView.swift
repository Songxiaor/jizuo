import AppKit
import LinkDigestAdapters
import LinkDigestCore
import SwiftUI

struct KnowledgeVaultSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: KnowledgeVaultSettingsViewModel
  /// 「清除」不可逆（要重新选一次文件夹并重新授权），先问一句。
  @State private var isClearConfirmationPresented = false

  /// 当前文件夹那一行：丢了就写出丢的是哪个路径，而不只是「找不到了」。
  private var directoryLine: String {
    if model.isDirectoryMissing {
      return "找不到了：" + (model.missingDirectoryPath ?? "原来的文件夹")
    }
    return model.directoryPath ?? "尚未选择"
  }

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "知识库",
        symbol: "books.vertical",
        caption: "导出到 Obsidian 等笔记库文件夹",
        fill: SettingsCategoryChip.fill(for: "knowledgeVault", theme: appTheme)
      )

      SettingsCard(
        title: "文件夹",
        summary: "内容导出到这里",
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
            // 记住过文件夹、但现在找不到了（被移动或删除）时，不能写「尚未选择」——
            // 下面同时在报「文件夹不存在」，两句话互相矛盾（2026-09-24 走查）。
            Text(directoryLine)
              .themedFont(.body)
              .foregroundStyle(model.isDirectoryMissing ? appTheme.danger : .primary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(model.missingDirectoryPath ?? model.directoryPath ?? "尚未选择")
              .accessibilityIdentifier("knowledge-vault-directory")
            Button(model.directoryPath != nil ? "更改" : (model.hasDirectory ? "重新选择" : "选择文件夹"), action: chooseDirectory)
              .buttonStyle(.appNormal)
              .accessibilityIdentifier("knowledge-vault-choose")
            // 危险动作：文字按钮 + 危险色，和「更改文件夹」拉开层级，并二次确认。
            Button("停止同步") { isClearConfirmationPresented = true }
              .buttonStyle(.appDestructive(appTheme.danger))
              .disabled(!model.hasDirectory)
              .accessibilityIdentifier("knowledge-vault-clear")
              .confirmationDialog(
                // 说清后果：是「不再往这里同步」，不是删文件（2026-10-01）。
                "不再同步到这个文件夹？",
                isPresented: $isClearConfirmationPresented
              ) {
                Button("停止同步", role: .destructive) { model.clearDirectory() }
                Button("取消", role: .cancel) {}
              } message: {
                Text("只忘掉这个位置，文件夹里的文件一个不删。")
              }
          }
        }
      }

      // 「立即同步」是这张卡唯一的主动作，放标题行右端；上次同步时间作为
      // 说明的一部分放标题下，不再和按钮挤同一行。
      SettingsCard(
        title: "立即同步",
        summary: model.lastSyncText.map { "只同步新增和改过的内容。上次同步：\($0)" }
          ?? "只同步新增和改过的内容",
        details: """
        每条内容导出成一个 Markdown：开头的属性区记录来源、平台、作者、发布与保存时间和标签，正文包含总结和原文全文，便于全文检索命中。
        正文里带一个「回链」，点它能回到汲作定位到这条内容看全文、视频和转写。
        单篇超长的原文会被截断并标注，因为过大的文件会被下游检索整个跳过。
        你在汲作里写的笔记、稿件和成品不会被同步——那些是你自己写的东西，不是采集来的素材。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
        VStack(alignment: .leading, spacing: 12) {
          if case let .running(done, total) = model.state, total > 0 {
            HStack(spacing: 12) {
              ProgressView(value: Double(done), total: Double(total))
                .frame(maxWidth: 180)
              Text("\(done)/\(total)")
                .themedFont(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Divider()
          }

          // 手排页里默认 Toggle 是勾选框；设置窗口的开关统一用拨杆并靠右，
          // 和视频存储页保持同一形态。
          HStack {
            Text("自动同步")
            Spacer(minLength: 12)
            Toggle("", isOn: $model.isAutoSyncEnabled)
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityLabel("自动同步")
              .accessibilityIdentifier("knowledge-vault-auto-sync")
          }
          Text("存了新内容就在后台同步")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)

          if let failure = model.lastAutoSyncFailureMessage {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
              .themedFont(.subheadline)
              .foregroundStyle(appTheme.danger)
              .accessibilityIdentifier("knowledge-vault-auto-sync-error")
          }

          if model.isDirectoryMissing {
            Label("这个文件夹被移动、改名或删除了，同步已暂停。点「重新选择」指定新位置后自动恢复。", systemImage: "pause.circle")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("knowledge-vault-missing-hint")
          }

          if !model.hasDirectory {
            Text("请先选择知识库文件夹。")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
          }

          if case let .finished(report) = model.state {
            resultView(report)
          }
        }
        },
        titleAccessory: {
          Button(action: { Task { await model.sync() } }) {
            if model.isRunning {
              Text("同步中…")
            } else {
              Text("立即同步")
            }
          }
          .buttonStyle(.appProminent(appTheme.accent))
          .disabled(!model.canSync)
          .accessibilityIdentifier("knowledge-vault-sync")
        }
      )

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
        .themedFont(.callout)
        .monospacedDigit()
        .accessibilityIdentifier("knowledge-vault-summary")

      // 冲突和失败必须列出文件名。只说「冲突 3」，用户没法知道去查哪个文件。
      if !report.conflicts.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("以下文件已存在且不归汲作管，已跳过，未做任何修改：")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
          ForEach(report.conflicts, id: \.filename) { conflict in
            Text("· \(conflict.filename) —— \(conflict.reason)")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .accessibilityIdentifier("knowledge-vault-conflicts")
      }

      if !report.failures.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("以下条目没能写入：")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
          ForEach(report.failures, id: \.filename) { failure in
            Text("· \(failure.filename) —— \(failure.message)")
              .themedFont(.subheadline)
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
    panel.message = "选择\(ProductDisplay.name)写入 Markdown 的文件夹"
    guard panel.runModal() == .OK else { return }
    model.applySelection(panel.url)
  }
}
