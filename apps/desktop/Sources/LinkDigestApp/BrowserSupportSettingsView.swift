import SwiftUI
import AppKit
import LinkDigestCore

struct BrowserSupportSettingsView: View {
  @ObservedObject var model: BrowserSupportViewModel
  @ObservedObject var appModel: AppViewModel

  private struct ConfigurationRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let browser: BrowserSupportBrowser
  }

  private let configurationRows = [
    ConfigurationRow(
      id: "chrome",
      title: "Google Chrome",
      detail: "在 Chrome 中加载扩展后即可同步",
      browser: .chrome
    ),
    ConfigurationRow(
      id: "brave",
      title: "Brave",
      detail: "在 Brave 中加载扩展后即可同步",
      browser: .brave
    ),
    ConfigurationRow(
      id: "edge",
      title: "Microsoft Edge",
      detail: "先连接到此 App，再在 Edge 加载扩展",
      browser: .edge
    ),
  ]

  var body: some View {
    Form {
      Section {
        receiverStatusRow
      } header: {
        Text("App 接收服务")
      } footer: {
        Text("扩展只在你点击同步时连接，不会保持在线。这里表示 App 是否已准备接收；下方配置提醒不等于传送失败。")
      }
      Section {
        ForEach(configurationRows) { row in
          configurationRow(row)
        }
        HStack {
          Button("重新检查") { Task { await model.load() } }
            .disabled(model.isLoading || model.activeBrowser != nil)
          if model.isLoading {
            ProgressView().controlSize(.small)
          }
        }
      } header: {
        Text("浏览器配置")
      } footer: {
        Text("每个浏览器都需要单独加载扩展并同步一次。看到“配置已就绪”后，首次同步成功会在上方记录送达时间。")
      }
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("首次安装扩展")
            .font(.headline)
          Text("1. 打开浏览器的扩展管理页\n2. 开启“开发者模式”\n3. 选择“加载已解压的扩展程序”，再选择下面打开的文件夹")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button("打开扩展文件夹", action: revealExtensionFiles)
          .accessibilityIdentifier("reveal-test-browser-extension")
      } footer: {
        Text("Chrome、Brave 和 Edge 使用同一份 Chromium 扩展。")
      }
      if let errorText = model.errorText {
        Section {
          Text(errorText).foregroundStyle(.red)
            .accessibilityIdentifier("browser-support-error")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .task { await model.load() }
    .alert(item: $model.presentation) { presentation in
      switch presentation {
      case let .confirmation(confirmation):
        Alert(
          title: Text("连接 \(confirmation.browser.displayName) 到此 App？"),
          message: Text("LinkDigest 会保留现有连接配置的备份，再把这个浏览器切换到当前 App。不会删除浏览器数据或已加载的扩展。"),
          primaryButton: .default(Text("连接")) { Task { await model.confirmReplacement(confirmation) } },
          secondaryButton: .cancel(Text("取消")) { model.cancelPendingReplacement() }
        )
      case let .result(result):
        switch result.kind {
        case .installed, .repaired:
          Alert(
            title: Text(result.kind == .installed ? "浏览器支持已安装" : "浏览器支持已修复"),
            message: Text("下一步：1. 打开对应浏览器；2. 在扩展管理页开启开发者模式；3. 选择“加载已解压的扩展程序”，并选择交付包中的 extension 文件夹。"),
            primaryButton: .default(Text("打开 \(result.browser.displayName)")) { openBrowser(result.browser) },
            secondaryButton: .default(Text("在 Finder 中显示测试扩展")) { revealExtensionFiles() }
          )
        case .uninstalled:
          Alert(title: Text("浏览器支持已卸载"), message: Text("LinkDigest 已移除自己拥有且校验一致的 Native Messaging manifest。浏览器扩展文件不会被删除。"), dismissButton: .default(Text("好")))
        case .restored:
          Alert(title: Text("备份已恢复"), message: Text("已恢复本次接管前由收据绑定的备份。"), dismissButton: .default(Text("好")))
        }
      }
    }
  }

  private var receiverStatusRow: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: receiverSymbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(receiverColor)
        .frame(width: 28, height: 28)
        .background(receiverColor.opacity(0.12), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(receiverTitle).font(.headline)
        Text(receiverDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(receiverBadge)
        .font(.caption.weight(.medium))
        .foregroundStyle(receiverColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(receiverColor.opacity(0.10), in: Capsule())
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("browser-receiver-status")
  }

  @ViewBuilder private func configurationRow(_ row: ConfigurationRow) -> some View {
    let status = model.status(for: row.browser)
    HStack(spacing: 12) {
      Image(systemName: "globe")
        .foregroundStyle(.secondary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title).font(.headline)
        Text(row.detail).font(.caption).foregroundStyle(.secondary)
        Label(statusText(status.state), systemImage: statusSymbol(status.state))
          .font(.caption)
          .foregroundStyle(statusColor(status.state))
          .accessibilityIdentifier("browser-support-status-\(row.id)")
      }
      Spacer(minLength: 16)
      HStack(spacing: 8) {
        if model.canInstall(row.browser) {
          Button("连接到此 App") { Task { await model.requestInstall(row.browser) } }
        }
        if model.canRepair(row.browser), needsConnectionAction(status.state) {
          Button("连接到此 App…") { Task { await model.requestInstall(row.browser) } }
        }
        if model.canUninstall(row.browser) {
          Button("断开连接…") { Task { await model.uninstall(row.browser) } }
        }
        if model.activeBrowser == row.browser {
          ProgressView().controlSize(.small)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(.vertical, 5)
  }

  private var receiverTitle: String {
    return switch appModel.browserReceiverState {
    case .starting: "正在启动接收服务…"
    case .ready: "App 已准备接收"
    case .unavailable: "App 接收服务不可用"
    }
  }

  private var receiverDetail: String {
    if let date = appModel.lastBrowserCaptureAt {
      return "最近一次浏览器送达：\(date.formatted(date: .omitted, time: .standard))"
    }
    return switch appModel.browserReceiverState {
    case .starting: "初始化本地接收通道"
    case .ready: "尚未验证浏览器传送；首次同步后会显示送达时间"
    case .unavailable: "请重新启动 App；若仍失败，再检查下方配置"
    }
  }

  private var receiverBadge: String {
    switch appModel.browserReceiverState {
    case .starting: "启动中"
    case .ready: "可接收"
    case .unavailable: "不可用"
    }
  }

  private var receiverSymbol: String {
    switch appModel.browserReceiverState {
    case .starting: "clock"
    case .ready: "checkmark"
    case .unavailable: "exclamationmark"
    }
  }

  private var receiverColor: Color {
    switch appModel.browserReceiverState {
    case .starting: .secondary
    case .ready: .green
    case .unavailable: .red
    }
  }

  private func needsConnectionAction(_ state: BrowserSupportInstallState) -> Bool {
    switch state {
    case .drifted, .unknownManifest: true
    default: false
    }
  }

  private func statusSymbol(_ state: BrowserSupportInstallState) -> String {
    switch state {
    case .installed, .installedAppUpdated, .currentAppUnverified: "checkmark.circle.fill"
    case .notInstalled, .unavailable: "minus.circle"
    case .drifted, .unknownManifest: "exclamationmark.triangle.fill"
    case .invalidReceipt, .unavailableArtifact: "xmark.circle.fill"
    }
  }

  private func statusText(_ state: BrowserSupportInstallState) -> String {
    switch state {
    case .unavailable: "未检测到浏览器"
    case .notInstalled: "尚未连接"
    case .installed, .installedAppUpdated, .currentAppUnverified: "配置已就绪"
    case .drifted: "尚未连接到此 App"
    case .unknownManifest: "需要连接到此 App"
    case .invalidReceipt: "安装记录无效"
    case .unavailableArtifact: "当前 App 缺少安装工件"
    }
  }

  private func statusColor(_ state: BrowserSupportInstallState) -> Color {
    switch state {
    case .installed, .installedAppUpdated, .currentAppUnverified: .green
    case .notInstalled, .unavailable: .secondary
    case .drifted, .unknownManifest: .orange
    case .invalidReceipt, .unavailableArtifact: .red
    }
  }

  private func openBrowser(_ browser: BrowserSupportBrowser) {
    let path: String
    switch browser {
    case .chrome: path = "/Applications/Google Chrome.app"
    case .brave: path = "/Applications/Brave Browser.app"
    case .edge: path = "/Applications/Microsoft Edge.app"
    }
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, _ in }
  }

  private func revealExtensionFiles() {
    let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("extension", isDirectory: true)
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("apps/browser-extension/.output/chrome-mv3", isDirectory: true)
    let target = FileManager.default.fileExists(atPath: adjacent.path) ? adjacent : development
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }
}
