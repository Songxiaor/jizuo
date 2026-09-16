import SwiftUI
import AppKit
import LinkDigestCore

struct BrowserSupportSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: BrowserSupportViewModel
  var appModel: AppViewModel

  /// 找不到扩展文件夹时报出来的东西。带上找过的路径——这种问题多半是 App 被单独
  /// 挪走、扩展目录留在原处，路径列表直接指出该去哪儿找。
  private struct ExtensionFolderMiss: Identifiable {
    let id = UUID()
    let searched: [URL]
    let detail: String?
  }

  @State private var revealFailure: ExtensionFolderMiss?
  /// 已经连上浏览器之后，安装三步默认收起；点「重新安装扩展」再展开。
  @State private var showsInstallSteps = false
  /// 等待确认「断开」的浏览器。断开之后这个浏览器再点同步就送不进来了，
  /// 而且它长得和「重新检查」一样低调，误点的代价不小——先问一句。
  @State private var pendingDisconnect: BrowserSupportBrowser?

  /// 有没有一个浏览器的通道已经通了。通了之后安装步骤就是噪音。
  private var hasConnectedBrowser: Bool {
    detectedBrowsers.contains { isChannelHealthy(model.status(for: $0).state) }
  }

  /// 列哪些浏览器：档案表里提供的、且本机真的装着的。
  ///
  /// 不列没装的：安装器拒绝创建浏览器目录，没装的浏览器即使列出来也连不上，只会多出
  /// 永远灰着的噪音。当前提供面只有 Chrome，所以正常情况下这里就一行。
  private var detectedBrowsers: [BrowserSupportBrowser] {
    model.statuses.filter { $0.state != .unavailable }.map(\.browser)
  }

  /// 空态里列的浏览器名同样来自档案表。
  ///
  /// 写死一句「没有检测到 Google Chrome」看着没问题，但档案表里加了浏览器之后
  /// 它不会跟着变——用户装了新支持的浏览器，页面还在让他去装 Chrome。
  private var supportedBrowserNames: String {
    BrowserSupportBrowser.allKnown.map(\.displayName).joined(separator: "、")
  }

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "浏览器支持",
        symbol: "puzzlepiece.extension",
        caption: "在浏览器里装一次扩展，之后打开的页面就能一键同步到本机。",
        fill: SettingsCategoryChip.fill(for: "browserSupport", theme: appTheme)
      )

      // 「装一次扩展就自动同步」本是一件事，原来拆成 App 接收 / 浏览器配置 /
      // 安装步骤三张卡，还把真正要动手的步骤压在最底下。合成一张卡、按真实动线
      // 从上往下读：先做什么 → 各浏览器状态 → 接收状态收成一行。
      SettingsCard(
        title: "连接浏览器",
        summary: "扩展只在你点同步时连接，不常驻。",
        details: "加载扩展后，首次同步成功会在下方显示送达时间。安装位置改变后需要重新连接一次，浏览器里的扩展不用重装。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 16) {
          // ① 动手步骤放最前——这才是要做的事，不是先看两屏状态。
          // 已经连上之后收起：三步说明对连好的人是噪音，只留一个「重新安装」入口。
          if !hasConnectedBrowser || showsInstallSteps {
            VStack(alignment: .leading, spacing: 6) {
              installStep(1, "打开浏览器的扩展管理页")
              installStep(2, "开启「开发者模式」")
              installStep(3, "选择「加载已解压的扩展程序」，再选下面打开的文件夹")
            }
            Button("打开扩展文件夹", action: revealExtensionFiles)
              .buttonStyle(.appProminent(appTheme.accent))
              .accessibilityIdentifier("reveal-test-browser-extension")
          } else {
            HStack(spacing: DesignTokens.Space.md) {
              Button("重新安装扩展…") { showsInstallSteps = true }
                .buttonStyle(.appNormal)
                .accessibilityIdentifier("browser-support-reinstall")
              Text("扩展已装好。换了浏览器、或扩展文件夹挪过位置时再点。")
                .themedFont(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Divider()

          // ② 每个浏览器压成一行：状态点 + 名字 + 一个词，只有需要动作的才带按钮。
          HStack(spacing: 8) {
            Text("已检测到的浏览器").themedFont(.subheadline, weight: .medium)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("重新检查") { Task { await model.load() } }
              .buttonStyle(.appQuiet)
              .disabled(model.isLoading || model.activeBrowser != nil)
          }
          // Grid 而不是 VStack：浏览器名长度不同，用 HStack 排状态词的起点就会参差
          // 不齐。列对齐是「每一行看起来是同一种东西」的前提，多于一行时才看得出来。
          //
          // 一个都没检测到是可能的（没装 Chrome 的机器）。空 Grid 会让上面那行标题
          // 孤零零地悬着，看不出是「还没扫」还是「扫完了没有」。
          if detectedBrowsers.isEmpty && !model.isLoading {
            Text("没有检测到\(supportedBrowserNames)。装好之后点「重新检查」。")
              .themedFont(.subheadline)
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
      if let errorText = model.errorText {
        Text(errorText).foregroundStyle(appTheme.danger)
          .accessibilityIdentifier("browser-support-error")
          .padding(.vertical, DesignTokens.Space.md)
          .padding(.horizontal, DesignTokens.Space.lg)
          .modifier(SettingsThemedCardChrome())
      }
    }
    .alert(item: $revealFailure) { miss in
      Alert(
        title: Text("没能打开扩展文件夹"),
        message: Text(
          [miss.detail, "汲作在这些位置找过，都没找到扩展。你的设置和内容没有受影响；请重新下载安装包，或手动去下面任一位置找找：\n" + miss.searched.map(\.path).joined(separator: "\n")]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        ),
        dismissButton: .default(Text("好"))
      )
    }
    // 断开只动汲作自己写进浏览器的那个连接文件，浏览器里的扩展和你保存的内容都不动，
    // 但断开之后扩展就送不进来了，得重新连一次——所以先说清楚再动手。
    .confirmationDialog(
      "断开 \(pendingDisconnect?.displayName ?? "") 的连接？",
      isPresented: Binding(
        get: { pendingDisconnect != nil },
        set: { if !$0 { pendingDisconnect = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("断开", role: .destructive) {
        if let browser = pendingDisconnect {
          pendingDisconnect = nil
          Task { await model.uninstall(browser) }
        }
      }
      .accessibilityIdentifier("browser-support-disconnect-confirm")
      Button("取消", role: .cancel) { pendingDisconnect = nil }
    } message: {
      Text("断开后，这个浏览器再点同步就送不进汲作了。你已经保存的内容一条都不会少，浏览器里的扩展也不会被删。想用的时候点「连接」就能接回来。")
    }
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
          title: Text("把 \(confirmation.browser.displayName) 连到这个汲作？"),
          message: Text("这个浏览器里已经有一份连接配置。\(ProductDisplay.name) 会先备份它，再把浏览器切到当前这个汲作。不会删浏览器数据，也不会删已经装好的扩展。"),
          primaryButton: .default(Text("连接")) { Task { await model.confirmReplacement(confirmation) } },
          secondaryButton: .cancel(Text("取消")) { model.cancelPendingReplacement() }
        )
      case let .result(result):
        switch result.kind {
        case .installed, .repaired:
          Alert(
            title: Text(result.kind == .installed ? "已连接这个浏览器" : "已重新连接这个浏览器"),
            message: Text("下一步：1. 点“打开扩展文件夹”；2. 在浏览器的扩展管理页开启开发者模式；3. 选择“加载已解压的扩展程序”，再选 Finder 里刚刚选中的“汲作浏览器扩展”。"),
            primaryButton: .default(Text("打开 \(result.browser.displayName)")) { openBrowser(result.browser) },
            secondaryButton: .default(Text("打开扩展文件夹")) { revealExtensionFiles() }
          )
        case .uninstalled:
          Alert(title: Text("已断开连接"), message: Text("\(ProductDisplay.name) 只删掉了自己写进这个浏览器的连接文件。浏览器里的扩展还在，你保存的内容也一条没少。想用的时候点「连接」就能接回来。"), dismissButton: .default(Text("好")))
        case .restored:
          Alert(title: Text("已还原成接管前的样子"), message: Text("这个浏览器的连接文件已经还原成汲作接管之前的那一份。"), dismissButton: .default(Text("好")))
        }
      // 这不是报错，是还差一步——所以标题问的是「允许吗」，不是「失败了」。文案只说要做
      // 什么、以及为什么必须由你来点：文件夹已经定位好，用户不需要知道 TCC 是什么。
      case let .accessRequest(request):
        Alert(
          title: Text("允许 \(ProductDisplay.name) 访问 \(request.browser.displayName) 的文件夹"),
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
        .themedFont(.subheadline)
        .foregroundStyle(appModel.browserReceiverState == .ready ? Color.secondary : receiverColor)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("browser-receiver-status")
  }

  /// 这一行只说**接收服务在不在跑**，不报「有没有收到过内容」。
  ///
  /// 原来它写「App 接收就绪 · 还没收到过同步」，而上面每个浏览器那行同时写着
  /// 「最近同步 14:03」——两句话直接打架。打架的原因是两边读的根本不是一个东西：
  /// `lastBrowserCaptureAt` 只记**这次打开汲作之后**收到的内容，退出就归零；
  /// 浏览器那行读的是落在磁盘上的送达记录，跨次运行都在。
  ///
  /// 所以把职责切开：送达事实只由浏览器那一行报（它是准的），这一行只回答
  /// 「现在能不能收」。本次运行内确实收到过时补一句，并明说范围是「这次打开之后」。
  private var receiverLineText: String {
    if appModel.browserReceiverState == .ready, let date = appModel.lastBrowserCaptureAt {
      return "接收服务已就绪 · 这次打开汲作后，最近一次收到内容是 \(date.formatted(date: .omitted, time: .standard))"
    }
    return switch appModel.browserReceiverState {
    case .starting: "正在启动接收服务…"
    case .ready: "接收服务已就绪，随时可以接收浏览器发来的内容"
    case .unavailable: "接收服务正在恢复；如果一直这样，请完全退出汲作再重新打开"
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
        .foregroundStyle(display.needsAction ? appTheme.warning : Color.secondary)
        .frame(width: 18)
      Text(browser.displayName)
        .gridColumnAlignment(.leading)
      Text(display.text)
        .themedFont(.subheadline)
        .foregroundStyle(display.needsAction ? appTheme.warning : Color.secondary)
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

    // 通道断了、而且断的原因是这个 App 自己挪了位置，就把原因说出来。
    //
    // 「需连接」本身没有指向性:用户上周还好好的，今天扩展报 NATIVE_HOST_NOT_FOUND，
    // 而设置页只说需连接——他没法从这三个字推出「因为 App 改名了」。
    // manifest 存的是绝对路径，改名、移动、换个文件夹装都会让它指空，
    // 而这几种的处理办法是同一个:重新连接一次。
    if let stale = status.stalePath {
      GridRow {
        // 第一列留空，让说明和上面那行的浏览器名对齐。
        Color.clear.frame(width: 18, height: 0)
        Text("原来指向的程序已不在原位（\(ProductDisplay.name) 改过名或被移动过）。点「重新连接」即可，浏览器里的扩展不用重装。")
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .gridCellColumns(3)
          .help(stale)
          .accessibilityIdentifier("browser-support-stale-path-\(browser.id)")
      }
    }

    // 说不清的状态必须带着「为什么」和「现在能做什么」一起出现，否则那一行只是
    // 一个用户无从下手的名词。
    if let advice = unresolvedStateAdvice(status.state) {
      GridRow {
        Color.clear.frame(width: 18, height: 0)
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          Text(advice.text)
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(advice.actionTitle, action: advice.action)
            .buttonStyle(.appNormal)
            .accessibilityIdentifier("browser-support-advice-action-\(browser.id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridCellColumns(3)
        .accessibilityIdentifier("browser-support-advice-\(browser.id)")
      }
    }
  }

  @ViewBuilder private func browserAction(
    _ browser: BrowserSupportBrowser, state: BrowserSupportInstallState
  ) -> some View {
    if model.canInstall(browser) || (model.canRepair(browser) && needsConnectionAction(state)) {
      Button("连接") { Task { await model.requestInstall(browser) } }
        .buttonStyle(.appNormal)
    } else if model.canUninstall(browser) {
      Button("断开") { pendingDisconnect = browser }
        .buttonStyle(.appDestructive(appTheme.danger))
        .accessibilityIdentifier("browser-support-disconnect-\(browser.id)")
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
    case .ready: appTheme.success
    case .unavailable: appTheme.danger
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
      // 没收到过不等于没装——可能只是还没用过，所以不报警。
      return ("circle", "还没收到过内容", false)
    }
    return ("checkmark.circle", "最近一次收到内容 \(Self.deliveryFormat(lastDelivery))", false)
  }

  /// 当天只显示时间，跨天补上日期——「最近一次收到内容 14:03」在第二天会读成刚刚收到过。
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
    // 这两条以前是「安装记录无效」「缺少安装工件」——说的是内部状态，用户既看不懂
    // 也不知道该干什么。改成人话，并由 `unresolvedStateAdvice` 在下一行补上原因和
    // 一个真能点的按钮。
    case .invalidReceipt: "连接文件不是汲作装的"
    case .unavailableArtifact: "这一版没带连接文件"
    }
  }

  /// 「连接文件不是汲作装的」「这一版没带连接文件」这两种状态没有对应的常规按钮
  /// （既不满足 `canInstall` 也不满足 `canRepair`），光显示一个名词等于死路一条。
  /// 这里给它们各配一句原因和一个真能点的下一步。
  private func unresolvedStateAdvice(
    _ state: BrowserSupportInstallState
  ) -> (text: String, actionTitle: String, action: () -> Void)? {
    switch state {
    case .invalidReceipt:
      return (
        "这个浏览器里已经有一个同名的连接文件，但不是汲作写的，所以汲作没有覆盖它——你的内容和浏览器数据都没被动过。请在浏览器里删掉旧的汲作扩展，再按下面三步重装一次。",
        "重新安装扩展",
        { showsInstallSteps = true }
      )
    case .unavailableArtifact:
      return (
        "这一版汲作里没带浏览器连接文件，所以连不上。你已经保存的内容不受影响。换成完整版安装包重新装一次就好。",
        "去检查更新",
        { SettingsNavigationRequest.request("updates") }
      )
    default:
      return nil
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
      panel.message = "选中「\(request.directory.lastPathComponent)」这个文件夹，允许 \(ProductDisplay.name) 写入 \(request.browser.displayName) 的连接配置"
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
        .themedFont(.caption2, weight: .bold, monospacedDigit: true)
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.secondary.opacity(0.15)))
      Text(text)
        .themedFont(.subheadline)
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
    candidates.append(neighborhood.appendingPathComponent("汲作浏览器扩展", isDirectory: true))
    candidates.append(neighborhood.appendingPathComponent("LinkDigest-extension", isDirectory: true))
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
    let delivery = BrowserExtensionFolderDelivery()
    var candidates: [URL] = []
    if let bundled = delivery.bundledSource() {
      candidates.append(bundled)
      do {
        let delivered = try delivery.deliver(
          source: bundled,
          destinationParent: delivery.defaultDestinationParent()
        )
        NSWorkspace.shared.activateFileViewerSelecting([delivered])
        return
      } catch {
        revealFailure = ExtensionFolderMiss(
          searched: candidates,
          detail: "扩展就在 App 里，但这次没能把它导出到硬盘上：\(error.localizedDescription)\n浏览器和你保存的内容都没有受影响。磁盘空间够的话再点一次「打开扩展文件夹」。"
        )
        return
      }
    }
    candidates.append(contentsOf: extensionFolderCandidates())
    let found = candidates.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
    }
    guard let found else {
      revealFailure = ExtensionFolderMiss(searched: candidates, detail: nil)
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([found])
  }
}
