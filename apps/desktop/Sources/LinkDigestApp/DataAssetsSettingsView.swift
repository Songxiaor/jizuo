import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DataAssetsSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: DataAssetsViewModel
  @State private var pendingRestoreURL: URL?
  @State private var isRestoreConfirmationPresented = false
  @State private var isExitForRestorePresented = false
  @State private var isDiagnosticConfirmationPresented = false

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "数据",
        symbol: "externaldrive.badge.timemachine",
        caption: "导出、备份和恢复都只在本机进行，不会上传资料。",
        fill: SettingsCategoryChip.fill(for: "data", theme: appTheme)
      )

      SettingsCard(
        title: "批量导出",
        summary: "把全部历史逐条导出为 Markdown，每条一个文件。",
        details: "文件名沿用单条导出的标题命名；同名条目会自动加序号，不会互相覆盖。导出在后台逐条进行，几百条历史也不会挡住设置窗口。",
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Button("导出全部历史", action: chooseBatchExportDirectory)
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .tint(appTheme.accent)
              .disabled(!model.canBatchExport || model.isBusy)
              .accessibilityIdentifier("data-export-all-markdown")
            batchProgress
          }
          status(model.batchState, identifier: "data-export-status")
        }
      }

      SettingsCard(
        title: "整库备份与恢复",
        summary: "备份包含一致的 SQLite 快照和汲作内部保存的视频，打包成一个带时间戳的文件。",
        details: "API Key 仍只在钥匙串，不进入备份。恢复会替换当前资料库，所以必须先明确确认；汲作会自动另存当前库，再把已校验的备份安排到下次启动时恢复。用户自己选在外部文件夹里的视频不复制进备份。",
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            Button("备份整个资料库", action: chooseBackupDirectory)
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .tint(appTheme.accent)
              .disabled(model.isBusy)
              .accessibilityIdentifier("data-backup-library")
            Button("从备份恢复…", action: chooseRestoreArchive)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(Color.secondary)
              .disabled(model.isBusy)
              .accessibilityIdentifier("data-restore-library")
          }
          status(model.backupState, identifier: "data-backup-status")
          status(model.restoreState, identifier: "data-restore-status")
        }
      }

      SettingsCard(
        title: "诊断信息",
        summary: "导出 App 版本/build、macOS 版本、基础运行环境和近期属于汲作的崩溃报告。",
        details: "不读取 API Key、Cookie、Token、历史正文、摘要或完整 URL 列表；不会连接网络，也不会自动发送。崩溃报告在写入前会再遮掉主目录、完整 URL 和常见密钥形态。",
        summaryPlacement: .aboveControl,
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Text("导出内容仅限版本、系统、基础运行信息和近期崩溃报告，不含历史内容或密钥。")
            .font(.caption)
            .appSecondaryText()
            .accessibilityIdentifier("diagnostics-scope-notice")
          Button("导出诊断信息") {
            isDiagnosticConfirmationPresented = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(model.isBusy)
          .accessibilityIdentifier("data-export-diagnostics")
          status(model.diagnosticState, identifier: "data-diagnostics-status")
        }
      }
    }
    .alert("恢复整个资料库？", isPresented: $isRestoreConfirmationPresented) {
      Button("取消", role: .cancel) { pendingRestoreURL = nil }
      Button("先自动备份，再恢复", role: .destructive) {
        guard let url = pendingRestoreURL else { return }
        Task { await model.scheduleRestore(from: url) }
      }
    } message: {
      Text("恢复会在下次启动时替换当前历史库和内部媒体。汲作会先校验所选备份，并自动完整备份当前资料库；任何一步失败都不会覆盖当前数据。")
    }
    .alert("退出并完成恢复", isPresented: $isExitForRestorePresented) {
      Button("稍后退出", role: .cancel) {}
      Button("退出汲作") { NSApp.terminate(nil) }
    } message: {
      if let result = model.scheduledRestore {
        Text("当前资料库已自动备份到：\(result.automaticBackupURL.path)\n\n现在退出，重新打开汲作后会在数据库加载前完成恢复。")
      }
    }
    .alert("导出诊断信息？", isPresented: $isDiagnosticConfirmationPresented) {
      Button("取消", role: .cancel) {}
      Button("继续并选择位置", action: chooseDiagnosticDirectory)
    } message: {
      Text("将导出版本/build、macOS 与基础运行信息、近期崩溃报告；不包含密钥、Cookie、Token、历史正文、摘要或完整 URL 列表，也不会自动上传。")
    }
    .alert("资料库恢复结果", isPresented: startupNoticeBinding) {
      Button("好") { model.dismissStartupRestoreNotice() }
    } message: {
      Text(model.startupRestoreNotice ?? "")
    }
    .onChange(of: model.scheduledRestore) { _, value in
      if value != nil { isExitForRestorePresented = true }
    }
  }

  @ViewBuilder
  private var batchProgress: some View {
    if case .running = model.batchState, let progress = model.batchProgress {
      if progress.total > 0 {
        ProgressView(value: Double(progress.completed), total: Double(progress.total))
          .frame(maxWidth: 180)
        Text("\(progress.completed)/\(progress.total)")
          .font(.caption)
          .monospacedDigit()
          .appSecondaryText()
      } else {
        ProgressView().controlSize(.small)
        Text("正在读取历史…").font(.caption).appSecondaryText()
      }
    }
  }

  @ViewBuilder
  private func status(_ state: DataAssetOperationState, identifier: String) -> some View {
    switch state {
    case .idle, .running:
      EmptyView()
    case let .finished(message):
      Text(message)
        .font(.caption)
        .appSecondaryText()
        .textSelection(.enabled)
        .accessibilityIdentifier(identifier)
    case let .failed(message):
      Text(message)
        .font(.caption)
        .foregroundStyle(appTheme.danger)
        .textSelection(.enabled)
        .accessibilityIdentifier(identifier)
    }
  }

  private var startupNoticeBinding: Binding<Bool> {
    Binding(
      get: { model.startupRestoreNotice != nil },
      set: { if !$0 { model.dismissStartupRestoreNotice() } }
    )
  }

  private func chooseBatchExportDirectory() {
    guard let directory = chooseDirectory(message: "选择存放全部 Markdown 的文件夹") else { return }
    Task { await model.exportAllMarkdown(to: directory) }
  }

  private func chooseBackupDirectory() {
    guard let directory = chooseDirectory(message: "选择存放整库备份的文件夹") else { return }
    Task { await model.createBackup(in: directory) }
  }

  private func chooseDiagnosticDirectory() {
    guard let directory = chooseDirectory(message: "选择存放诊断 zip 的文件夹") else { return }
    Task { await model.exportDiagnostics(in: directory) }
  }

  private func chooseRestoreArchive() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "linkdigestbackup") ?? .data]
    panel.prompt = "选择"
    panel.message = "选择由汲作创建的整库备份文件"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    pendingRestoreURL = url
    isRestoreConfirmationPresented = true
  }

  private func chooseDirectory(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
  }
}
