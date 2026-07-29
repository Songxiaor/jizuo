import SwiftUI
import AppKit
import LinkDigestCore

struct BrowserSupportSettingsView: View {
  @ObservedObject var model: BrowserSupportViewModel
  @ObservedObject var appModel: AppViewModel

  /// 找不到扩展文件夹时报出来的东西。带上找过的路径——这种问题多半是 App 被单独
  /// 挪走、扩展目录留在原处，路径列表直接指出该去哪儿找。
  private struct ExtensionFolderMiss: Identifiable {
    let id = UUID()
    let searched: [URL]
  }

  @State private var revealFailure: ExtensionFolderMiss?

  /// 列哪些浏览器：档案表里提供的、且本机真的装着的。
  ///
  /// 不列没装的：安装器拒绝创建浏览器目录，没装的浏览器即使列出来也连不上，只会多出
  /// 永远灰着的噪音。当前提供面只有 Chrome，所以正常情况下这里就一行。
  private var detectedBrowsers: [BrowserSupportBrowser] {
    model.statuses.filter { $0.state != .unavailable }.map(\.browser)
  }

  var body: some View {
    Form {
      // 「装一次扩展就自动同步」本是一件事，原来拆成 App 接收 / 浏览器配置 /
      // 安装步骤三张卡，还把真正要动手的步骤压在最底下。合成一张卡、按真实动线
      // 从上往下读：先做什么 → 各浏览器状态 → 接收状态收成一行。
      Section {
        SettingsCard(
          title: "连接浏览器",
          summary: "在 Chrome 里装一次扩展，之后自动同步。",
          details: "扩展只在你点击同步时连接，不会保持在线。加载扩展后，首次同步成功会在下方显示送达时间。",
          controlWidth: .full
        ) {
          VStack(alignment: .leading, spacing: 16) {
            // ① 动手步骤放最前——这才是要做的事，不是先看两屏状态。
            VStack(alignment: .leading, spacing: 6) {
              installStep(1, "打开浏览器的扩展管理页")
              installStep(2, "开启「开发者模式」")
              installStep(3, "选择「加载已解压的扩展程序」，再选下面打开的文件夹")
            }
            Button("打开扩展文件夹", action: revealExtensionFiles)
              .accessibilityIdentifier("reveal-test-browser-extension")
              .alert(item: $revealFailure) { miss in
                Alert(
                  title: Text("没找到扩展文件夹"),
                  message: Text("找过这些位置：\n" + miss.searched.map(\.path).joined(separator: "\n")),
                  dismissButton: .default(Text("好"))
                )
              }

            Divider()

            // ② 每个浏览器压成一行：状态点 + 名字 + 一个词，只有需要动作的才带按钮。
            HStack(spacing: 8) {
              Text("已检测到的浏览器").font(.subheadline.weight(.medium))
              Spacer()
              if model.isLoading { ProgressView().controlSize(.small) }
              Button("重新检查") { Task { await model.load() } }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.isLoading || model.activeBrowser != nil)
            }
            // Grid 而不是 VStack：浏览器名长度不同，用 HStack 排状态词的起点就会参差
            // 不齐。列对齐是「每一行看起来是同一种东西」的前提，多于一行时才看得出来。
            //
            // 一个都没检测到是可能的（没装 Chrome 的机器）。空 Grid 会让上面那行标题
            // 孤零零地悬着，看不出是「还没扫」还是「扫完了没有」。
            if detectedBrowsers.isEmpty && !model.isLoading {
              Text("没有检测到 Google Chrome。装好之后点「重新检查」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("browser-support-empty")
            } else {
              Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(detectedBrowsers) { browser in
                  browserStatusRow(browser)
                }
              }
            }

            Divider()

            // ③ App 接收状态收成一行——就绪时安静，不可用/报错才突出。
            receiverStatusLine
          }
        }
      }
      if let errorText = model.errorText {
        Section {
          Text(errorText).foregroundStyle(.red)
            .accessibilityIdentifier("browser-support-error")
        }
      }
    }
    .formStyle(.grouped)
    .settingsDetailContentMargins()
    .task { await model.load() }
    // 送达随时会发生：你在浏览器里点一次同步，这一行就得跟着变。原来只在切进这一页时
    // 读一次，页面开着的时候同步完全看不到，要手动点「重新检查」才出来。
    //
    // 用轮询而不是「收到抓取就刷新」，是因为写记录的是 native host：App 先收到内容、
    // 回完响应，host 才落盘，两者之间没有顺序保证，靠事件触发会读到还没写完的旧值。
    // 轮询只读一个几十字节的 JSON，而且 SwiftUI 会在离开这一页时自动取消。
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        model.refreshDeliveries()
      }
    }
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
      // 这不是报错，是还差一步——所以标题问的是「允许吗」，不是「失败了」。文案只说要做
      // 什么、以及为什么必须由你来点：文件夹已经定位好，用户不需要知道 TCC 是什么。
      case let .accessRequest(request):
        Alert(
          title: Text("允许 LinkDigest 访问 \(request.browser.displayName) 的文件夹"),
          message: Text("macOS 不允许 App 自行打开其它 App 的文件夹，必须由你选一次。点「选择文件夹」，在打开的窗口里直接点右下角的按钮就行——文件夹已经定位好，不用自己找。"),
          primaryButton: .default(Text("选择文件夹")) { chooseAccessDirectory(request) },
          secondaryButton: .cancel(Text("以后再说")) { model.cancelPendingAccessRequest() }
        )
      }
    }
  }

  /// 接收状态收成一行：就绪时安静的灰字，不可用/启动中才用状态色突出。
  private var receiverStatusLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: receiverSymbol)
        .font(.caption)
        .foregroundStyle(receiverColor)
      Text(receiverLineText)
        .font(.caption)
        .foregroundStyle(appModel.browserReceiverState == .ready ? Color.secondary : receiverColor)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("browser-receiver-status")
  }

  private var receiverLineText: String {
    if let date = appModel.lastBrowserCaptureAt {
      return "App 接收就绪 · 最近送达 \(date.formatted(date: .omitted, time: .standard))"
    }
    return switch appModel.browserReceiverState {
    case .starting: "正在启动接收服务…"
    case .ready: "App 接收就绪 · 首次同步后显示送达时间"
    case .unavailable: "App 接收服务不可用，请重启 App"
    }
  }

  /// 每个浏览器一行：状态点 + 名字 + 一句状态，只有需要动作的浏览器才带按钮。
  ///
  /// 多行时必须长得一样。原来状态词紧跟在浏览器名后面，而名字长度不同，状态列的起点就
  /// 参差不齐；再加上一行一种文字颜色（绿 / 灰 / 橙），看上去像几种不同的东西。
  ///
  /// 现在：名字和状态各占一列对齐（`GridRow`），文字一律次要灰，颜色只留给「要你动手」
  /// 那一种——需要动作的行才是橙色图标 + 橙色文字 + 按钮，其余全部安静。
  @ViewBuilder private func browserStatusRow(_ browser: BrowserSupportBrowser) -> some View {
    let status = model.status(for: browser)
    let display = rowStatus(status.state, model.lastDelivery(for: browser))
    GridRow {
      Image(systemName: display.symbol)
        .foregroundStyle(display.needsAction ? Color.orange : Color.secondary)
        .frame(width: 18)
      Text(browser.displayName)
        .gridColumnAlignment(.leading)
      Text(display.text)
        .font(.caption)
        .foregroundStyle(display.needsAction ? Color.orange : Color.secondary)
        .gridColumnAlignment(.leading)
      HStack(spacing: 8) {
        Spacer(minLength: 12)
        browserAction(browser, state: status.state)
        if model.activeBrowser == browser {
          ProgressView().controlSize(.small)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("browser-support-status-\(browser.id)")
  }

  @ViewBuilder private func browserAction(
    _ browser: BrowserSupportBrowser, state: BrowserSupportInstallState
  ) -> some View {
    if model.canInstall(browser) || (model.canRepair(browser) && needsConnectionAction(state)) {
      Button("连接") { Task { await model.requestInstall(browser) } }
        .buttonStyle(.bordered)
        .controlSize(.small)
    } else if model.canUninstall(browser) {
      Button("断开") { Task { await model.uninstall(browser) } }
        .buttonStyle(.borderless)
        .controlSize(.small)
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

  /// 通道通没通、这个浏览器在不在用，是两件独立的事，但一行只能显示一句话，所以按
  /// 「先挡路的先说」合并：通道有问题时先说通道——那时候扩展装了也没用；通道没问题，
  /// 才轮到「到底在不在用」。
  ///
  /// 后半句报的是**既成事实**（最近一次同步是什么时候），不是状态推断。原来那句
  /// 「已配置」只说明 manifest 装好了——那由 App 自己写，浏览器里根本没有这个扩展、
  /// 或者刚被删掉，它都不会变，于是一直显示成配置完成。
  ///
  /// 也不去读浏览器档案判断扩展在不在：macOS 不许 App 读其它 App 的数据目录，正常
  /// 启动的 App 拿到的是 `EPERM`，而且不弹授权框。既成事实不需要任何权限。
  /// - Note: `needsAction` 是这一行唯一的强调开关。三行以前各带一种颜色（绿 / 灰 /
  ///   橙），读起来像三种不同的东西；颜色只该回答一个问题——「这一行要不要我动手」。
  private func rowStatus(
    _ state: BrowserSupportInstallState,
    _ lastDelivery: Date?
  ) -> (symbol: String, text: String, needsAction: Bool) {
    guard isChannelHealthy(state) else {
      // 「未检测到」是「你没装这个浏览器」，没什么可做的，不该跟着一起变橙。
      return (statusSymbol(state), statusText(state), state != .unavailable)
    }
    guard let lastDelivery else {
      // 没同步过不等于没装——可能只是还没用过，所以不报警。
      return ("circle", "未同步过", false)
    }
    return ("checkmark.circle", "最近同步 \(Self.deliveryFormat(lastDelivery))", false)
  }

  /// 当天只显示时间，跨天补上日期——「最近同步 14:03」在第二天会读成刚刚同步过。
  private static func deliveryFormat(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .shortened)
  }

  private func isChannelHealthy(_ state: BrowserSupportInstallState) -> Bool {
    switch state {
    case .installed, .installedAppUpdated, .currentAppUnverified: true
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
    case .unavailable: "未检测到"
    case .notInstalled: "未连接"
    // 「已配置」只表示 Native Messaging 通道就位，不代表扩展已加载在跑，
    // 所以不用「就绪」这种暗示「已经在用了」的词。
    case .installed, .installedAppUpdated, .currentAppUnverified: "已配置"
    case .drifted, .unknownManifest: "需连接"
    case .invalidReceipt: "安装记录无效"
    case .unavailableArtifact: "缺少安装工件"
    }
  }

  /// 打开目录选择面板，让 macOS 把这个目录的访问权交给我们。
  ///
  /// 这是非沙箱 App 拿到「别人的 Application Support 目录」访问权的唯一正当途径：系统
  /// 只认用户在面板里亲自做的选择。所以面板必须**定位到**那个目录，而不是让用户自己
  /// 一层层找——找错一个目录，授权就落在别的地方，而报错看上去和没授权一模一样。
  ///
  /// 先收起 alert 再开面板：两个模态叠在一起时，面板可能根本不出现。
  private func chooseAccessDirectory(_ request: BrowserSupportAccessRequest) {
    model.cancelPendingAccessRequest()
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.directoryURL = request.directory
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      panel.message = "选中「\(request.directory.lastPathComponent)」这个文件夹，允许 LinkDigest 写入 \(request.browser.displayName) 的连接配置"
      panel.prompt = "允许访问"
      let granted = panel.runModal() == .OK ? panel.url : nil
      Task { await model.completeAccessRequest(request, granted: granted) }
    }
  }

  /// 用显示名去 `/Applications` 里找那个 app。
  ///
  /// 原来是写死的三条 `switch`——那正是「只支持三个浏览器」的另一处根源。档案表里的
  /// 显示名就是 app 名（Google Chrome、Vivaldi、Arc…），少数对不上的（Chrome Beta 之类）
  /// 找不到就什么都不做：这只是个「装完顺手打开浏览器」的便利按钮，不该为它再维护
  /// 一张路径表。
  private func openBrowser(_ browser: BrowserSupportBrowser) {
    let url = URL(fileURLWithPath: "/Applications/\(browser.displayName).app")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
  }

  /// 安装步骤的一行。编号做成结构而不是塞在一段文字里，照着做的时候不会串行。
  @ViewBuilder
  private func installStep(_ index: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(index)")
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.secondary.opacity(0.15)))
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// 「打开扩展文件夹」找得到的位置。
  ///
  /// 原来只写死两条：App 旁边的 `extension/`，和相对当前工作目录的开发产物。前者从来
  /// 没有被生成过——部署脚本产出的是带版本号的 `LinkDigest-extension-<版本>`；后者在
  /// 打包运行时必然落空，因为 LaunchServices 启动的进程工作目录是 `/`。两条都不存在时
  /// `activateFileViewerSelecting` 静默什么都不做，按钮看上去就是坏的。
  private func extensionFolderCandidates() -> [URL] {
    let neighborhood = Bundle.main.bundleURL.deletingLastPathComponent()
    var candidates: [URL] = []
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      candidates.append(neighborhood.appendingPathComponent("LinkDigest-extension-\(version)", isDirectory: true))
    }
    candidates.append(neighborhood.appendingPathComponent("extension", isDirectory: true))
    // 版本号对不上时（App 换了版本、扩展目录还是旧的）退而求其次：同目录里任何一份
    // 扩展，新的优先。备份目录同名带前缀，必须排掉——指到备份上等于装了个旧版本。
    let siblings = (try? FileManager.default.contentsOfDirectory(at: neighborhood, includingPropertiesForKeys: nil)) ?? []
    candidates.append(contentsOf: siblings
      .filter { $0.lastPathComponent.hasPrefix("LinkDigest-extension-") }
      .filter { !$0.lastPathComponent.contains(".backup") }
      .sorted { $0.lastPathComponent > $1.lastPathComponent })
    // 开发时从源码目录直接 `swift run`，工作目录才是仓库根，这条仍然有意义。
    candidates.append(
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("apps/browser-extension/.output/chrome-mv3", isDirectory: true))
    return candidates
  }

  /// 只认带 `manifest.json` 的目录：没有它浏览器加载不了，指过去只会让人以为是
  /// 浏览器出了问题。一个都找不到就明说，不再静默失败。
  private func revealExtensionFiles() {
    let candidates = extensionFolderCandidates()
    let found = candidates.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
    }
    guard let found else {
      revealFailure = ExtensionFolderMiss(searched: candidates)
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([found])
  }
}
