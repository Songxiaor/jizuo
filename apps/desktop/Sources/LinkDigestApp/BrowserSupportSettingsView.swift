import SwiftUI
import AppKit
import LinkDigestCore

struct BrowserSupportSettingsView: View {
  @ObservedObject var model: BrowserSupportViewModel

  var body: some View {
    Form {
      Section {
        ForEach(BrowserSupportBrowser.allCases) { browser in
          browserRow(browser)
        }
      } header: {
        Text("浏览器支持")
      } footer: {
        Text("LinkDigest 只管理自己的 Native Messaging manifest 与收据；不会扫描或修改其它扩展配置。日用 App Host 与测试版 Host 路径不同，因此测试时可能显示内容漂移；点“修复”会先备份，再临时切换到测试版 Host，之后可用“恢复备份”回到原状态。")
      }
      Section {
        Button("在 Finder 中显示测试扩展", action: revealExtensionFiles)
          .accessibilityIdentifier("reveal-test-browser-extension")
      } footer: {
        Text("Debug 交付包优先打开 App 相邻的 extension；源码运行时回退到本次 WXT 构建目录。")
      }
      if let errorText = model.errorText {
        Section {
          Text(errorText).foregroundStyle(.red)
            .accessibilityIdentifier("browser-support-error")
        }
      }
    }
    .formStyle(.grouped)
    .task { await model.load() }
    .alert(item: $model.presentation) { presentation in
      switch presentation {
      case let .confirmation(confirmation):
        Alert(
          title: Text("修复需要先备份当前 manifest"),
          message: Text("点击“备份并继续”后，LinkDigest 会先在同一浏览器目录创建时间戳备份，再安全接管并写入经过哈希校验的模板。修复成功后仍可恢复该备份。"),
          primaryButton: .destructive(Text("备份并继续")) { Task { await model.confirmReplacement(confirmation) } },
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

  @ViewBuilder private func browserRow(_ browser: BrowserSupportBrowser) -> some View {
    let status = model.status(for: browser)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(browser.displayName).font(.headline)
        Spacer()
        Text(statusText(status.state)).foregroundStyle(statusColor(status.state))
          .accessibilityIdentifier("browser-support-status-\(browser.rawValue)")
      }
      HStack(spacing: 10) {
        Button("安装") { Task { await model.requestInstall(browser) } }
          .disabled(!model.canInstall(browser))
          .accessibilityIdentifier("browser-support-install-\(browser.rawValue)")
        Button("修复") { Task { await model.requestInstall(browser) } }
          .disabled(!model.canRepair(browser))
          .accessibilityIdentifier("browser-support-repair-\(browser.rawValue)")
        Button("卸载") { Task { await model.uninstall(browser) } }
          .disabled(!model.canUninstall(browser))
          .accessibilityIdentifier("browser-support-uninstall-\(browser.rawValue)")
        if status.hasRecoverableBackup {
          Button("恢复备份") { Task { await model.restore(browser) } }
            .disabled(!model.canRestore(browser))
            .accessibilityIdentifier("browser-support-restore-\(browser.rawValue)")
        }
        if model.activeBrowser == browser { ProgressView().controlSize(.small) }
      }
    }
    .padding(.vertical, 5)
  }

  private func statusText(_ state: BrowserSupportInstallState) -> String {
    switch state {
    case .unavailable: "未检测到浏览器"
    case .notInstalled: "未安装"
    case .installed: "已安装且一致"
    case .installedAppUpdated: "已安装（App 已更新）"
    case .drifted: "日用 Host 与测试版 Host 不同（可备份切换）"
    case .unknownManifest: "检测到未知同名 manifest"
    case .invalidReceipt: "LinkDigest 收据无效，未写入"
    case .unavailableArtifact: "安装工件不可用"
    }
  }

  private func statusColor(_ state: BrowserSupportInstallState) -> Color {
    switch state {
    case .installed, .installedAppUpdated: .green
    case .notInstalled, .unavailable: .secondary
    case .drifted, .unknownManifest, .invalidReceipt, .unavailableArtifact: .orange
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
