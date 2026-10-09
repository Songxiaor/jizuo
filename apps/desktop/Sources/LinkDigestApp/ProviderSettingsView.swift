import SwiftUI
import Sparkle
import LinkDigestCore

enum SettingsNavigationRequest {
  static let notification = Notification.Name("LinkDigest.SettingsNavigationRequest")
  static let defaultsKey = "settings.requested-tab"

  static func request(_ tab: String) {
    UserDefaults.standard.set(tab, forKey: defaultsKey)
    NotificationCenter.default.post(name: notification, object: tab)
  }

  static func consume() -> String? {
    let tab = UserDefaults.standard.string(forKey: defaultsKey)
    UserDefaults.standard.removeObject(forKey: defaultsKey)
    return tab
  }
}

struct ProviderSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  private enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    // 原始值不改：别处用 `SettingsNavigationRequest` 按字符串跳到某一页（例如 "service"、"generation"）。
    // 2026-09-28 按工序重组：generation 成了「处理流程」，service 成了「模型服务」，新增各工序页（2026-10-01 评论降为「收集」子页，收集之后五道）。
    case service, generation, appearance, mediaStorage, knowledgeVault, dataBackup, companionSync, siteLogin, browserSupport, mcp, updates, labs
    case semanticSearch
    case capture, record, proof, comments, summary, translation, mindMap
    /// 「AI 处理」：校对、总结、翻译、脑图四道工序并成一页（2026-10-04 设置合并）。
    case processing
    var id: String { rawValue }

    /// 这一项现在显示在哪一页、滚到哪一节。2026-10-04 起 17 页并成 9 页，别处仍可按旧名字
    /// 跳过来（「去配置校对模型」请求的是 proof），落到新页上那一节。
    var destination: (page: SettingsTab, anchor: String?) {
      switch self {
      case .browserSupport, .siteLogin, .comments: (.capture, rawValue)
      case .mediaStorage: (.record, rawValue)
      case .proof, .summary, .translation, .mindMap: (.processing, rawValue)
      case .knowledgeVault, .semanticSearch: (.dataBackup, rawValue)
      default: (self, nil)
      }
    }

    /// 工序页对应的那一道工序；通用设置是 nil。
    var step: SettingsProcessStep? {
      switch self {
      case .capture: .capture
      case .record: .record
      case .proof: .proof
      case .summary: .summary
      case .translation: .translation
      case .mindMap: .mindMap
      default: nil
      }
    }

    /// 挂在某道工序下面的子页（侧栏缩进一格）。
    var parent: SettingsTab? {
      switch self {
      // 2026-10-01 评论不再是一道工序：它是收集时顺带存的内容，挂在「收集」下面。
      case .browserSupport, .siteLogin, .comments: .capture
      case .mediaStorage: .record
      default: nil
      }
    }

    var title: String {
      if let step { return step.title }
      switch self {
      case .service: return "模型服务"
      case .generation: return "处理流程"
      case .processing: return "AI 处理"
      default: break
      }
      return legacyTitle
    }

    private var legacyTitle: String {
      switch self {
      case .service: "模型与识别"
      case .generation: "生成偏好"
      case .capture, .record, .proof, .summary, .translation, .mindMap, .processing: ""
      case .comments: "评论"
      case .appearance: "外观"
      case .mediaStorage: "视频存储"
      case .knowledgeVault: "知识库"
      case .semanticSearch: "按意思搜"
      case .dataBackup: "备份恢复"
      case .companionSync: "手机同步"
      case .siteLogin: "网站登录"
      case .browserSupport: "浏览器"
      case .updates: "关于"
      case .mcp: "AI 助手"
      case .labs: "实验室"
      }
    }
    var symbol: String {
      switch self {
      case .service: "cpu"
      case .generation: "arrow.right.circle"
      case .capture: "square.and.arrow.down"
      case .record: "waveform"
      case .proof, .summary, .translation, .mindMap: "seal"
      case .processing: "sparkles"
      case .comments: "text.bubble"
      // 调色盘比同列图标宽一截、半实心圆又比线条图标重（2026-10-09 自查），用画笔。
      case .appearance: "paintbrush"
      case .mediaStorage: "externaldrive"
      // 2026-09-24 走查：原来是 folder.badge.gearshape / externaldrive.badge.timemachine，
      // 带角标的符号比 18pt 图标框宽，溢出后顶到文字上，和上下几行对不齐。
      case .knowledgeVault: "books.vertical"
      case .semanticSearch: "text.magnifyingglass"
      case .dataBackup: "clock.arrow.circlepath"
      case .companionSync: "iphone.and.arrow.forward"
      case .siteLogin: "person.crop.circle.badge.checkmark"
      case .browserSupport: "puzzlepiece.extension"
      case .updates: "info.circle"
      case .mcp: "link"
      case .labs: "flask"
      }
    }

    /// 这一版实际显示的标签页。
    ///
    /// 「实验室」整页四张卡(工作台、爆款实验室、每天自动出选题、我的表达方式)
    /// 全都属于工作台,所以不提供工作台时这一页会是空的——一个点进去什么
    /// 都没有的标签页,比没有这个标签页更让人费解。
    ///
    /// 两处侧栏都读这里,不各自过滤:漏掉一处的表现是「换个主题实验室又
    /// 冒出来了」,而那种 bug 没人会想到去换主题才发现。
    static var visibleCases: [SettingsTab] {
      allCases.filter { tab in
        switch tab {
        case .labs: ExperimentalFeatures.isOfferedToUsers
        // 手机同步还没做完，这一版不给用户看。判据收在 ExperimentalFeatures 里，
        // 因为「不给看入口」和「启动时不要自动往 iCloud 传」必须是同一个开关——
        // 原来这里是个裸 false，而启动路径上那次同步根本没有跟着它走。
        case .companionSync: ExperimentalFeatures.isCompanionSyncOffered
        default: true
        }
      }
    }
  }

  /// 侧栏顺序：平铺一列，不再分组。
  ///
  /// 2026-09-25 对照 Tolaria 设置页：原来十项分五组，其中两组各只有一项，组标题
  /// 比内容还显眼；十项平铺一眼扫得完。按「AI → 外观 → 连接 → 数据 → 版本」排。
  /// 可见性仍只由 `SettingsTab.visibleCases` 一处判据决定。
  ///
  /// 2026-09-28 按工序重组：总览在最上；「工序」一组，
  /// 浏览器扩展、站点登录挂在「汲」下，视频存储挂在「录」下；其余归「通用」。
  ///
  /// 2026-10-01：评论挪到「收集」下面作子页（工序剩收集之后五道）；手机同步、实验室这类
  /// 少数人才用、还在成型的页收进「高级」，「通用」只留常用的。AI 助手接入是对外卖点，
  /// 留在「通用」。
  ///
  /// 2026-10-04 合并成 9 页（原 17 页，Syc 确认）：子页不再单占侧栏一行——浏览器支持、站点登录、
  /// 评论并进「收集」，视频存储并进「转写」，校对 / 总结 / 翻译 / 脑图并成「AI 处理」，知识库同步、
  /// 按意思搜并进「备份恢复」。原来「收集」页三行都是「去设置」，点了跳到侧栏里本来就有的页。
  private static let sidebarSections: [(title: String?, tabs: [SettingsTab])] = [
    (nil, [.generation]),
    ("工序", [.capture, .record, .processing]),
    ("通用", [.service, .appearance, .dataBackup, .mcp, .updates]),
    ("高级", [.companionSync, .labs]),
  ]

  /// 有可见页的分组。「高级」里两页这一版都可能不给看，整组为空时连组标题一起不画。
  private static var visibleSidebarSections: [(title: String?, tabs: [SettingsTab])] {
    sidebarSections.filter { !visibleTabs(in: $0.tabs).isEmpty }
  }

  private static var sidebarOrder: [SettingsTab] { sidebarSections.flatMap(\.tabs) }

  private static var sidebarTabs: [SettingsTab] {
    let visible = SettingsTab.visibleCases
    return sidebarOrder.filter { visible.contains($0) }
  }

  private static func visibleTabs(in section: [SettingsTab]) -> [SettingsTab] {
    let visible = SettingsTab.visibleCases
    return section.filter { visible.contains($0) }
  }

  private static let outputLanguagePresets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Español", "Français", "Deutsch"]
  private static let customOutputLanguageTag = "__custom__"

  @Bindable var model: ProviderSettingsViewModel
  var appModel: AppViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject var knowledgeVault: KnowledgeVaultSettingsViewModel
  let updater: SPUUpdater
  @Bindable var companionSync: CompanionNoteSyncCoordinator
  /// 「把已有外文标题译成中文」要读历史库；没传时不显示这一项。
  var historyModel: HistoryViewModel? = nil
  @State private var isTitleBackfillConfirmationPresented = false
  @State private var apiKeyInput = ""
  @State private var selectedTab: SettingsTab = .generation
  /// 跳过来时要滚到的那一节（见 `SettingsTab.destination`）；点侧栏换页时清掉。
  @State private var settingsAnchor: String?
  @State private var isCustomOutputLanguage = false
  @State private var translationModelSearchQuery = ""
  @State private var pendingDeletionID: String?
  /// 待确认「整组删除」的服务商（组名 + 该组全部模型 ID）。
  @State private var pendingGroupDeletion: LibraryProviderGroup?
  /// 「清除授权记录」按下之后的一行反馈。成功和失败都要说，因为清除本身没有可见效果。
  @State private var consentRevokeNotice: String?
  /// 「清除授权记录」的二次确认。清完之后每一项都会重新问一遍，是会改变后续行为的重置。
  @State private var isConsentRevokeConfirmationPresented = false
  /// 「重置为默认提示词」的二次确认。用户手写的提示词会被整段覆盖，且没有撤销。
  @State private var isPromptResetConfirmationPresented = false
  /// 当前展开的服务商。同时只展开一家：模型清单落在网格下面，同时摊开两家就分不清
  /// 哪一段属于谁。默认全部收起——归拢的意义就是先只看「有哪几家」。
  @State private var expandedLibraryProvider: String?
  @State private var activeAssignmentPicker: AssignmentPicker?
  /// 「检测可用」包含付费模型时的确认框：编辑窗口里的列表，或模型库。
  @State private var pendingProbeScope: ModelProbeScope?

  enum ModelProbeScope: Identifiable {
    case catalog
    case library
    var id: Self { self }
  }
  /// 「功能与模型」里哪几行的 ⓘ 展开着。按标题记，不给六行各开一个 Bool。
  @State private var expandedAssignmentDetails: Set<String> = []
  /// 编辑模型时是否展开服务商网格。默认折叠成一行，点「更换」才展开。
  @State private var isChoosingPreset = false
  /// 总览上点「自动」却做不了时的那句原因。点别的、或切换成功后清掉。
  @State private var chainAutoNotice: String?
  /// 「推荐服务商 → 填入」后把光标放进密钥框。
  @FocusState private var isAPIKeyFieldFocused: Bool
  /// 从「推荐服务商 → 填入」打开的添加窗口：服务商已经选好，网格折成一行，
  /// 密钥框留在首屏（展开的网格有 600pt 高，会把密钥框挤到下面看不见）。
  @State private var isPresetPrefilled = false
  /// 自绘侧栏选中高亮的滑动锚点。见 `paperSidebarRow`。
  @Namespace private var sidebarSelectionNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(ExperimentalFeatures.workbenchKey) private var isWorkbenchEnabled = false
  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  @AppStorage(TopicSchedule.storageKey) private var topicScheduleRaw = ""
  @AppStorage(ExperimentalFeatures.hitLabKey) private var isHitLabEnabled = false
  /// 切回汲作时要不要看一眼剪贴板里有没有链接。默认开：这是「复制一条链接、切回来
  /// 就能存」的那条最短路径，关掉之后每次都得自己粘。
  ///
  /// 键名写死在这里而不是借 `ExperimentalFeatures`：这不是实验开关，是一条普通偏好，
  /// 读它的地方按同一个键读 `UserDefaults.standard` 即可。
  @AppStorage(Self.clipboardLinkDetectionKey) private var isClipboardLinkDetectionEnabled = true

  /// 评论抓取数量。不走 `@AppStorage`：读它的是浏览器拉起的 Native Host，
  /// 那是另一个进程，只能读 `CapturePreferencesStore` 落的那份文件。
  @State private var commentLimit = CapturePreferencesStore.standard().commentLimit
  @State private var commentLimitSaveFailed = false
  @State private var commentLimitsByPlatform = CapturePreferencesStore.standard().commentLimitsByPlatform
  @State private var autoSaveComments = CapturePreferencesStore.standard().autoSaveComments

  private var commentLimitSelection: Binding<Int> {
    Binding(
      get: { commentLimit },
      set: { value in
        commentLimit = value
        do {
          try CapturePreferencesStore.standard().setCommentLimit(value)
          commentLimitSaveFailed = false
        } catch {
          commentLimitSaveFailed = true
        }
      }
    )
  }

  /// 剪贴板链接检测的偏好键。读取方按同一个键读 `UserDefaults.standard`。
  static let clipboardLinkDetectionKey = "capture.clipboardLinkDetectionEnabled"

  private func scheduleBinding<Value>(
    _ keyPath: WritableKeyPath<TopicSchedule, Value>
  ) -> Binding<Value> {
    Binding(
      get: { TopicSchedule.decoded(from: topicScheduleRaw)[keyPath: keyPath] },
      set: { newValue in
        var schedule = TopicSchedule.decoded(from: topicScheduleRaw)
        schedule[keyPath: keyPath] = newValue
        topicScheduleRaw = schedule.encoded()
      }
    )
  }

  /// 把整份表达方式的某一项做成 Binding。
  ///
  /// 整份编码成一个字符串存,而不是给每个字段各开一个 @AppStorage:
  /// 加字段时不用再动存储,读的地方也只有一个真相源。
  private func voiceBinding<Value>(
    _ keyPath: WritableKeyPath<VoiceSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { VoiceSettings.decoded(from: voiceSettingsRaw)[keyPath: keyPath] },
      set: { newValue in
        var settings = VoiceSettings.decoded(from: voiceSettingsRaw)
        settings[keyPath: keyPath] = newValue
        voiceSettingsRaw = settings.encoded()
      }
    )
  }
  @AppStorage(ReadingFontSelection.storageKey)
  private var readingFontRaw = ReadingFontSelection.defaultStoredValue
  @AppStorage(UIFontSelection.storageKey)
  private var uiFontRaw = UIFontSelection.defaultStoredValue
  @AppStorage(ReadingFontSize.storageKey)
  private var readingFontSizeRaw = Double(ReadingFontSize.default)

  /// 设置窗口是否交还系统原生外观。
  ///
  /// 与主界面同一判据（`HistoryContentView` 的 `theme.isNative`）：只有「系统」
  /// 主题用原生 material，浅色与深色都由令牌接管。原来这里判的是 `== .paper`，
  /// 于是深色主题下设置窗口一半是令牌画布 `#1C1C1E`、一半是系统灰——主界面已经
  /// 全深色了，设置窗口却没跟上，这正是「设置页和主界面不像一家」的主要来源。
  private var isNativeTheme: Bool { settingsTheme.isNative }

  /// 阅读排版判据一律问主题自己，不在这里重写一份。
  ///
  /// 原来这里是 `== .paper` 的本地拷贝，和主界面的
  /// `appearanceTheme.usesEditorialReadingTypography` 是两处同义判据。加暖褐主题
  /// 时只改枚举、漏掉这里的话，同一套字体在主界面是宋体、在设置页的预览里是黑体，
  /// 而这种偏差不报错，只有切到那个主题去比对才会发现。
  private var usesEditorialTypography: Bool {
    (AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass).usesEditorialReadingTypography
  }

  /// 本机装了思源宋体才给「宋体」一键位；返回的就是它在选择器里的存储值。
  private var editorialSerifQuickOption: String? {
    let family = ReadingFontCatalog.editorialSerifFamily
    return family == "Songti SC" ? nil : family
  }

  private var resolvedReadingFont: ResolvedReadingFont {
    ReadingFontSelection(storedValue: readingFontRaw)
      .resolved(
        usesEditorialReadingTypography: usesEditorialTypography,
        bodySize: CGFloat(readingFontSizeRaw)
      )
  }

  /// 带中文标点的预览句。
  ///
  /// 「，」「。」后面会不会裂开大缝，只有真渲染出来才看得见——按字体名判断不出来，
  /// 单字宽度也量不出来（各字体都是 1 em，差别在上下文挤压）。所以预览句必须含
  /// 中文标点和中英混排。
  /// 「推荐 / 其它」两档的字体选择器。
  ///
  /// 分档而不是一长条平铺：74 个自带中文字形的家族里，绝大多数是日文/韩文字体
  /// （缺简化字，排中文会逐字回退）或书法装饰体（读不了正文）。平铺等于把八个
  /// 能用的埋进六十几个不能用的里面。
  ///
  /// 「其它」仍然全列，不替用户做决定——只是不推荐。
  @ViewBuilder private func fontPicker(
    title: String,
    selection: Binding<String>,
    themeLabel: String,
    themeTag: String,
    recommended: [String],
    identifier: String
  ) -> some View {
    // 外壳用设置里通用的灰色下拉样式（系统弹出菜单是蓝箭头，和其它页不统一，
    // 2026-09-29 发布前走查）；菜单本身仍是系统菜单，每一项用自己的字形显示。
    Menu {
      Picker(title, selection: selection) {
        Text(themeLabel).tag(themeTag)
        Divider()
        Section("推荐") {
          // 每一项用它自己的字形显示，选之前就能看出长什么样。
          ForEach(recommended, id: \.self) { family in
            Text(family).font(.custom(family, size: 13)).tag(family)
          }
        }
        Section("其它") {
          ForEach(RecommendedFonts.others(excluding: recommended), id: \.self) { family in
            Text(family).font(.custom(family, size: 13)).tag(family)
          }
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      SettingsMenuLabel(title: selection.wrappedValue == themeTag ? themeLabel : selection.wrappedValue)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(title)
    .accessibilityValue(selection.wrappedValue == themeTag ? themeLabel : selection.wrappedValue)
    .accessibilityIdentifier(identifier)
  }

  /// 界面字体预览：故意用界面里**最小**的两个字号。
  ///
  /// 界面字体的成败在 10pt 上——计数、时间戳都是这个尺寸，笔画细的字体在这里
  /// 发虚。用正文字号预览界面字体，等于避开了唯一该看的地方。
  @ViewBuilder private var uiFontPreview: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("预览")
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        // 预览句用中性的示例文字，不抄侧栏的真实分类和计数：写着「待总结 149」的
        // 预览会被当成状态读——用户以为自己真有 149 条没总结，而那个数字是死的。
        // 预览要验证的是字形在 10pt 上立不立得住，示例词同样能验证。
        Text("示例标题　示例分类 12　其他 9")
          .themedFont(.subheadline)
        Text("8月17日 19:24 · 示例说明文字 · 19.6 MB")
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(DesignTokens.Space.sm)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(Color.secondary.opacity(0.08))
      )
      .accessibilityIdentifier("appearance-ui-font-preview")
    }
  }

  @ViewBuilder private var readingFontPreview: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("预览")
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
      Text("众所周知，搜索是 Agent 最基础的能力之一。模型的知识停在训练截止那天。")
        .font(resolvedReadingFont.body())
        .lineSpacing(MarkdownPresentation.bodyLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.sm)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
            .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityIdentifier("appearance-reading-font-preview")
    }
  }

  var body: some View {
    NavigationSplitView {
      Group {
        // 与主界面同判据：只有「系统」主题交还原生 List，浅色和深色都用自绘侧栏。
        if !isNativeTheme {
          paperSidebar
        } else {
          List(selection: Binding(get: { selectedTab }, set: { settingsAnchor = nil; selectedTab = $0 })) {
            ForEach(Array(Self.visibleSidebarSections.enumerated()), id: \.offset) { _, section in
              Section {
                ForEach(Self.visibleTabs(in: section.tabs)) { tab in
                  Label {
                    Text(tab.title)
                  } icon: {
                    sidebarIcon(tab, selected: selectedTab == tab)
                  }
                  // 只防换行，不防截断：撑宽是下面 `.frame(minWidth:)` 的职责，
                  // 行内视图的 ideal 宽度传不出 List。
                  .lineLimit(1)
                  .tag(tab)
                  .padding(.vertical, DesignTokens.Space.xs)
                  .padding(.leading, tab.parent == nil ? 0 : 18)
                }
              } header: {
                if let title = section.title { Text(title) }
              }
            }
          }
          .listStyle(.sidebar)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        // 窗口标题已经是「设置」，侧栏顶栏只留产品名，避免「设置」叠两次。
        Text(ProductDisplay.name)
          .themedFont(.title3, weight: .semibold)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
      }
      // 实测 `navigationSplitViewColumnWidth` 的 min 在这个窗口压不住:设成 205
      // 之后侧栏仍然只有 148pt(分栏宽度被拖动后持久化了)。所以改成对内容加
      // 硬性 minWidth——那是布局约束,分栏必须让位。
      //
      // 中文导航（「模型与识别」「浏览器」）需要完整显示；不压到 200。
      .frame(minWidth: 220)
      .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 280)
      // 去掉 NavigationSplitView 自动塞进工具栏的侧栏折叠按钮：设置窗口的分类栏是
      // 导航主轴，不该被折叠，那个图标只是噪声。
      //
      // 必须挂在**侧栏这一栏的内容**上，挂在 NavigationSplitView 整体上不生效——
      // 那个按钮属于侧栏列的工具栏，外层拿不到它。
      .toolbar(removing: .sidebarToggle)
    } detail: {
      Group {
        switch selectedTab.destination.page {
        case .mcp: MCPSettingsView(model: MCPController.shared)
        case .service: serviceTab
        case .generation: overviewTab
        case .capture: captureTab
        case .record: recordTab
        case .processing: processingTab
        case .appearance: appearanceTab
        case .labs: labsTab
        case .dataBackup: dataTab
        case .companionSync:
          CompanionNoteSyncSettingsView(model: companionSync)
        case .updates:
          AppUpdateSettingsView(updater: updater)
        // 下面这些已并进别的页（`destination` 不会返回它们），留着只为 switch 完整。
        case .browserSupport, .siteLogin, .comments: captureTab
        case .mediaStorage: recordTab
        case .proof, .summary, .translation, .mindMap: processingTab
        case .knowledgeVault, .semanticSearch: dataTab
        }
      }
      .environment(\.settingsScrollAnchor, settingsAnchor)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // 往上滚时页面文字从「设置」标题后面透出来（2026-10-01 走查）；和主窗口同一层渐隐遮罩。
      .overlay(alignment: .top) {
        if !isNativeTheme { ToolbarScrollFade(background: settingsTheme.canvas) }
      }
      // 窗口标题恒为「设置」，不跟着 selectedTab 变。原来这里写
      // `selectedTab.title`，和页内页头（`SettingsPageHeader` 的大标题）说的是
      // 同一件事，两处同时写着「视频存储」「网站登录」是重复；当前分类已经由
      // 侧栏选中态 + 页头共同表达，窗口标题不需要再报一遍。
      .navigationTitle("设置")
    }
    // 复用主界面那套工具栏主题 modifier，避免两处各写一份判据再各自漂移。
    .modifier(HistoryWindowToolbarThemeModifier(theme: settingsTheme))
    .frame(
      // 默认开得下一整张卡：900×700 时「模型服务」和「自动处理管线」这种高卡
      // 一进来就被窗口下沿切掉，用户以为页面到此为止。960×720 是实测能把最高的
      // 那张卡连同它的操作行一起放进一屏的尺寸。min 不动，窗口照旧能缩。
      minWidth: 780,
      idealWidth: 960,
      maxWidth: .infinity,
      minHeight: 560,
      idealHeight: 720,
      maxHeight: .infinity
    )
    .foregroundStyle(settingsTheme.primaryText)
    .tint(settingsTheme.accent)
    .accentColor(settingsTheme.accent)
    .onAppear {
      AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw)
      if let raw = SettingsNavigationRequest.consume(), let tab = SettingsTab(rawValue: raw),
         SettingsTab.visibleCases.contains(tab) {
        navigate(to: tab)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notification)) { note in
      guard let raw = note.object as? String, let tab = SettingsTab(rawValue: raw),
            SettingsTab.visibleCases.contains(tab) else { return }
      navigate(to: tab)
      UserDefaults.standard.removeObject(forKey: SettingsNavigationRequest.defaultsKey)
    }
    .onChange(of: appearanceThemeRaw) { _, newValue in
      AppearanceTheme.applyApplicationAppearance(newValue)
    }
    .task { await model.load() }
  }

  // MARK: - 模型服务

  private var serviceTab: some View {
    SettingsPlainPage {
      pageHeader(for: .service, caption: "在这里添加服务商，选用哪个去「AI 处理」")

      // 还没配模型时，先告诉新手去哪拿密钥、大概花多少、不配也能用什么（2026-10-01）。
      // 配过之后推荐挪到页底，不再占首屏。
      if model.libraryEntryDisplays.isEmpty, !model.isConfigurationLoading {
        recommendedProvidersSection
      }

      // 图片识别（本机、改不了）2026-10-04 挪到「转写」页：它和转写一样是本机识别，
      // 原来单独一行压在这一页最上面，和「管理服务商」无关。

      // 「添加模型…」放标题行右端：它是这张卡唯一的主动作，原来孤零零缩在
      // 列表左下角，和列表内容抢同一列，看起来像列表的一项。
      settingCard(
        title: UISettingsPresentation.modelServicesCardTitle,
        summary: UISettingsPresentation.modelServicesSummary,
        details: UISettingsPresentation.modelServicesDetails,
        controlWidth: .full,
        titleAccessory: {
          modelProbeButton(scope: .library)
          Button("添加模型…") { model.beginAddModel() }
            .buttonStyle(.appProminent(settingsTheme.accent))
            .disabled(model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels)
            .accessibilityIdentifier("add-library-model")
        }
      ) {
        VStack(alignment: .leading, spacing: 0) {
          if model.libraryEntryDisplays.isEmpty {
            Text("还没有模型，先添加一个")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .padding(.vertical, DesignTokens.Space.sm)
          } else {
            // 服务商是紧凑的分组行，不再是带边框的大卡片：卡里套卡，分组头
            // 和它下面的模型行看起来像两种东西。现在组头和模型行同一个左边距、
            // 同样 40pt 高，只靠字重和 hairline 分层。
            ForEach(libraryProviderGroups) { group in
              libraryProviderCard(group)
              if expandedLibraryProvider == group.id {
                ForEach(group.entries) { entry in
                  libraryRow(entry)
                }
              }
              if group.id != libraryProviderGroups.last?.id {
                Rectangle().fill(settingsTheme.hairline).frame(height: 1)
              }
            }
          }
          // 错误必须留在控件旁边。挪进 footer 就会离「添加模型…」很远，
          // 而它恰恰是解释这个按钮为什么没成功的那句话。
          if let errorText = model.libraryErrorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
              .themedFont(.subheadline)
              .foregroundStyle(appTheme.danger)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, DesignTokens.Space.sm)
              .accessibilityIdentifier("model-library-error")
          }
        }
      }

      if !model.libraryEntryDisplays.isEmpty {
        recommendedProvidersSection
      }
    }
    .controlSize(.regular)
    .onChange(of: apiKeyInput) { oldValue, newValue in
      if oldValue != newValue { model.apiKeyDraftDidChange() }
    }
    .onChange(of: model.isEditorVisible) { _, visible in
      // 每次打开编辑器都从「已选服务商折叠成一行」开始；添加流程本来就没有
      // 已选项，会直接展开网格（见 `showsPresetGrid`）。
      if visible { isChoosingPreset = false } else { isPresetPrefilled = false }
    }
    // 编辑表单改成 Sheet：原来它长在列表底下，只有一行小灰字「编辑模型：服务商」
    // 提示这是编辑区，和「模型服务」列表之间没有任何分隔，用户分不清哪些字段
    // 属于列表、哪些属于正在编辑的那个模型。
    .sheet(isPresented: isEditorSheetPresented) {
      editorSheet
    }
    .confirmationDialog(
      "删除这个模型？",
      isPresented: Binding(
        get: { pendingDeletionID != nil },
        set: { if !$0 { pendingDeletionID = nil } }
      )
    ) {
      Button("删除", role: .destructive) {
        if let id = pendingDeletionID {
          pendingDeletionID = nil
          Task { await model.deleteModel(id) }
        }
      }
      Button("取消", role: .cancel) { pendingDeletionID = nil }
    } message: {
      Text("密钥会一起删掉，没法撤销。用它的功能会改回「未配置」或本机处理。")
    }
    .confirmationDialog(
      "删除「\(pendingGroupDeletion?.id ?? "")」的 \(pendingGroupDeletion?.entries.count ?? 0) 个模型？",
      isPresented: Binding(
        get: { pendingGroupDeletion != nil },
        set: { if !$0 { pendingGroupDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("全部删除", role: .destructive) {
        if let group = pendingGroupDeletion {
          pendingGroupDeletion = nil
          Task { await model.deleteModels(group.entries.map(\.id)) }
        }
      }
      .accessibilityIdentifier("delete-library-provider-confirm")
      Button("取消", role: .cancel) { pendingGroupDeletion = nil }
    } message: {
      Text("密钥会一起删掉，没法撤销。用到的功能会改回「未配置」或本机处理。")
    }
  }

  // MARK: - 推荐服务商（2026-10-01）

  /// 每家一行：图标 + 名字 + 适合谁，右边「去注册拿密钥」「填入」。
  /// 「填入」= 打开添加窗口、选好这家服务商（服务地址自动填上），光标放进密钥框。
  private var recommendedProvidersSection: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text(UISettingsPresentation.recommendedProvidersTitle)
          .themedFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Text(UISettingsPresentation.recommendedProvidersSummary)
          .themedFont(.subheadline)
          .foregroundStyle(settingsTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      SettingsRowGroup {
        ForEach(RecommendedProvider.all) { provider in
          recommendedProviderRow(provider)
        }
      }
      // 费用：只说怎么计、去哪看，不写会过期的数字。
      Text(UISettingsPresentation.recommendedProvidersCostNote)
        .themedFont(.subheadline)
        .foregroundStyle(settingsTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: DesignTokens.Space.md) {
        Text("价格页：").foregroundStyle(settingsTheme.secondaryText)
        ForEach(RecommendedProvider.all) { provider in
          // 带「↗」和强调色：原来是三个黑字，看不出能点（2026-10-01 走查）。
          Link(destination: provider.pricingURL) {
            Label(provider.name, systemImage: "arrow.up.right")
              .labelStyle(TrailingIconLabelStyle())
          }
          .foregroundStyle(settingsTheme.accent)
          .help(provider.pricingURL.absoluteString)
          .accessibilityIdentifier("recommended-provider-pricing-\(provider.id)")
        }
      }
      .themedFont(.subheadline)
      if model.libraryEntryDisplays.isEmpty {
        SettingsInlineNotice(message: UISettingsPresentation.noModelCapabilitiesNote, tone: .info)
          .accessibilityIdentifier("no-model-capabilities-note")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recommended-providers")
  }

  private func recommendedProviderRow(_ provider: RecommendedProvider) -> some View {
    HStack(alignment: .center, spacing: DesignTokens.Space.md) {
      providerIcon(provider.preset)
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.name)
          .themedFont(.body, weight: .semibold)
        Text(provider.audience)
          .themedFont(.subheadline)
          .foregroundStyle(settingsTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: DesignTokens.Space.md)
      Button("去注册") { NSWorkspace.shared.open(provider.keyPageURL) }
        .buttonStyle(.appQuiet)
        .help(provider.keyPageURL.absoluteString)
        .accessibilityIdentifier("recommended-provider-signup-\(provider.id)")
      Button("添加") { fillRecommendedProvider(provider) }
        .buttonStyle(.appNormal)
        .disabled(editorBusy)
        .help("打开添加窗口，填好 \(provider.name) 的服务地址")
        .accessibilityIdentifier("recommended-provider-fill-\(provider.id)")
    }
    .padding(.vertical, DesignTokens.Space.sm)
    .padding(.horizontal, DesignTokens.Space.lg)
  }

  private func fillRecommendedProvider(_ provider: RecommendedProvider) {
    model.beginAddModel()
    model.selectPreset(provider.preset)
    isPresetPrefilled = true
    apiKeyInput = ""
  }

  // MARK: - 功能与模型指派

  private enum AssignmentPicker: String, Identifiable {
    case summary
    case transcription

    var id: String { rawValue }
  }

  // 六行同一种形态：标签在左（带 ⓘ），控件在右、统一 240pt 宽、右对齐成一列。
  //
  // 原来这张卡里三种控件样式并存：总结模型是右对齐纯文字 + 上下小箭头，翻译
  // 模型是通栏灰底下拉，在线备用转写是半宽灰底下拉，图片识别是纯文字——同一列
  // 右边缘四个位置。
  //
  // 标题用「总结模型」而不是「总结与翻译」：翻译另有独立配置，
  // 合并标题会让人以为这里已经管了翻译。
  //
  // 2026-09-28 设置按工序重组：六行拆开，各自放进「摘 / 译 / 录 / 校」页和「模型服务」页。
  @ViewBuilder private var summaryAssignmentRow: some View {
  assignmentRow(
    title: UISettingsPresentation.summaryAssignmentTitle,
    caption: "总结和脑图用它，其他没选时也用它",
    // 这一行是整页的中心，原来却是六行里唯一没有 ⓘ 的：用户看不出「总结模型」
    // 到底管到哪儿，也不知道翻译和校对为什么会跟着它变。
    details: "总结、脑图用它；校对和翻译没单独选时也用它。换模型只影响以后生成的。"
  ) {
    if model.libraryEntryDisplays.isEmpty {
      Text("先在下方添加模型")
        .themedFont(.body)
        .foregroundStyle(.secondary)
        .settingsControlWidth()
    } else {
      let summaryEntry = model.summaryEntryDisplays.first(where: { $0.id == model.summaryAssignmentID })
      VStack(alignment: .trailing, spacing: 4) {
        assignmentPickerButton(kind: .summary, selectedEntry: summaryEntry)
        // 总结模型用不了时，翻译、校对（默认跟着它）也一起失败：就地说清楚，给出口。
        if let summaryEntry,
           let record = model.healthRecord(baseURL: summaryEntry.baseURL, model: summaryEntry.modelName),
           record.status != .available, record.status != .temporarilyUnavailable {
          let badge = model.healthBadge(baseURL: summaryEntry.baseURL, model: summaryEntry.modelName)
          HStack(spacing: 6) {
            Label("\(badge.text)：总结和翻译会失败", systemImage: badge.symbol)
              .themedFont(.caption, weight: .medium)
              .foregroundStyle(badge.color(theme: settingsTheme))
              .help(badge.detail)
            Button("换一个模型") { activeAssignmentPicker = .summary }
              .buttonStyle(.appQuiet)
              .controlSize(.small)
          }
          .accessibilityIdentifier("summary-assignment-health-warning")
        }
      }
    }
  }
  }

  @ViewBuilder private var translationAssignmentRow: some View {
  assignmentRow(
    title: UISettingsPresentation.translationAssignmentTitle,
    caption: UISettingsPresentation.translationFollowsSummaryHint
  ) {
    preferenceModelAssignmentControl(
      title: UISettingsPresentation.translationAssignmentTitle,
      emptyOptionTitle: "跟随默认",
      options: model.summaryEntryDisplays,
      text: $model.translationModelName,
      identifier: "translation-model-name",
      customPlaceholder: "模型名称"
    )
  }
  }

  @ViewBuilder private var localTranscriptionRow: some View {
  // 本地转写固定是 Apple 听写。原来这里也能选在线模型，和下面「在线备用转写」
  // 管的是同一个设置，两行互相覆盖；在线模型只在下面那一行选。
  // 只读行：「本机离线、不需要配置」挪到左边常显说明里，右边只剩一个值，
  // 不再是右侧叠两行灰字（2026-09-25 对照 Tolaria：一行一个控件/值）。
  assignmentRow(
    title: UISettingsPresentation.localTranscriptionTitle,
    caption: "视频转文字，本机离线，不联网、不花钱。"
  ) {
    Text("Mac 自带的语音识别")
      .themedFont(.body)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .accessibilityIdentifier("transcription-assignment-picker")
  }
  }

  @ViewBuilder private var onlineTranscriptionRow: some View {
  assignmentRow(
    title: UISettingsPresentation.onlineTranscriptionTitle,
    caption: "给超过 200MB、无法本机导入的视频用。"
  ) {
    VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
      preferenceModelAssignmentControl(
        title: UISettingsPresentation.onlineTranscriptionTitle,
        emptyOptionTitle: "只用本机",
        options: model.transcriptionEntryDisplays,
        text: Binding(
          get: { model.onlineTranscriptionModelName },
          set: { name in Task { await model.selectOnlineTranscriptionModel(name) } }
        ),
        identifier: "transcription-model-name",
        customPlaceholder: "例如 whisper-large-v3-turbo",
        unavailableHint: "「模型服务」里还没有能转写语音的模型。"
      )
      transcriptionDiscoveryControls
    }
  }
  }

  @ViewBuilder private var tidyAssignmentRow: some View {
  assignmentRow(
    title: UISettingsPresentation.tidyAssignmentTitle,
    caption: "还原转写稿里听错的词，补上标点。",
    details: "根据标题和配文还原听写错词并补标点；看不懂的句子原样保留。"
  ) {
    preferenceModelAssignmentControl(
      title: UISettingsPresentation.tidyAssignmentTitle,
      emptyOptionTitle: "跟随默认",
      options: model.summaryEntryDisplays,
      text: $model.tidyModelName,
      identifier: "tidy-model-name",
      customPlaceholder: "模型名称"
    )
  }
  }

  @ViewBuilder private var imageRecognitionRow: some View {
  // 这一行不可改，所以要一眼看出它不是控件。
  //
  // 前五行的控件都是 240pt 的描边下拉；这一行原来同宽同位地摆一段灰字，
  // 于是看起来像一个点不开的下拉——「为什么别的能选，这个点不动」。
  // 现在明确成只读：灰字、不占控件槽位、右对齐贴边，并说清楚为什么没得选。
  assignmentRow(
    title: UISettingsPresentation.imageRecognitionTitle,
    caption: "识别图里的字，本机完成",
    details: "用 Mac 自带的识别，全在本机完成，图片不外发、不花额度，所以没有可选项。"
  ) {
    Text("Apple Vision")
      .themedFont(.body)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .accessibilityIdentifier("image-text-assignment-picker")
  }
  }

  /// 在已添加的服务商里找语音转写模型，找到就一键添加并使用。
  @ViewBuilder private var transcriptionDiscoveryControls: some View {
    switch model.transcriptionDiscoveryState {
    case .idle:
      // 用有边框的普通按钮：quiet 样式平时没有底也没有边，看上去就是一行说明文字（2026-09-25 走查）。
      Button("查找可用") { Task { await model.discoverTranscriptionModels() } }
        .buttonStyle(.appNormal)
        .controlSize(.small)
        .disabled(model.libraryEntryDisplays.isEmpty)
        .help("从已加的服务商里找转写模型")
        .accessibilityIdentifier("discover-transcription-models")
    case .searching:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在查找…").themedFont(.caption).foregroundStyle(.secondary)
      }
    case let .found(candidates):
      VStack(alignment: .trailing, spacing: 4) {
        Text("找到 \(candidates.count) 个语音转写模型")
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(.secondary)
        ForEach(candidates.prefix(8)) { candidate in
          HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
              Text(candidate.model).themedFont(.caption).lineLimit(1).truncationMode(.middle)
              Text(candidate.providerTitle).themedFont(.caption2).foregroundStyle(.tertiary)
            }
            Button("用这个") { Task { await model.addDiscoveredTranscriptionModel(candidate) } }
              .buttonStyle(.appQuiet)
              .controlSize(.small)
              .accessibilityIdentifier("add-discovered-transcription-model")
          }
        }
      }
      .frame(maxWidth: 300, alignment: .trailing)
    case let .none(searched):
      VStack(alignment: .trailing, spacing: 2) {
        Text("查了已添加的 \(searched) 家服务商，都没有语音转写模型。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
        Text("需要另加一家提供语音转写的服务商，比如阶跃星辰、硅基流动、Groq。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
        Button("重新查找") { Task { await model.discoverTranscriptionModels() } }
          .buttonStyle(.appNormal)
          .controlSize(.small)
      }
      .frame(maxWidth: 300, alignment: .trailing)
    case .failed:
      HStack(spacing: 6) {
        Text("没能读取服务商的模型列表").themedFont(.caption).foregroundStyle(appTheme.warning)
        Button("重试") { Task { await model.discoverTranscriptionModels() } }
          .buttonStyle(.appNormal)
          .controlSize(.small)
      }
    }
  }

  /// 「功能与模型」里的一行：标签 + 常显一句说明在左（长解释收进 ⓘ），控件靠右。
  ///
  /// 不复用 `SettingsRow`：它自带左右 16pt 内距，而这里已经在卡片内，再套一层
  /// 会让六行比卡片标题往里缩一截。
  ///
  /// 2026-09-25 对照 Tolaria：原来六行都只有标题 + ⓘ，一句说明都看不到，
  /// 要挨个点开才知道每行管什么。现在每行常显一句，ⓘ 只留给补充细节。
  @ViewBuilder
  private func assignmentRow<Control: View>(
    title: String,
    caption: String,
    details: String? = nil,
    @ViewBuilder control: () -> Control
  ) -> some View {
    let isExpanded = expandedAssignmentDetails.contains(title)
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          HStack(spacing: DesignTokens.Space.sm) {
            Text(title).themedFont(.body)
            if details != nil {
              Button {
                withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
                  if isExpanded { expandedAssignmentDetails.remove(title) } else { expandedAssignmentDetails.insert(title) }
                }
              } label: {
                Image(systemName: "info.circle")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("查看\(title)说明")
              .accessibilityLabel("\(title)详细说明")
            }
          }
          Text(caption)
            .themedFont(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: DesignTokens.Space.md)
        control()
      }
      if isExpanded, let details {
        Text(details)
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, DesignTokens.Space.sm)
    // 2026-09-28 起这些行都放在 `SettingsRowGroup` 里（工序页），左右边距和 `SettingsRow` 一致。
    .padding(.horizontal, DesignTokens.Space.lg)
  }

  @ViewBuilder
  /// 翻译 / 在线备用转写 / 校对的模型下拉。
  ///
  /// 只能从「模型服务」里已经添加的模型中选，不再有「自定义…」：手填的名字没有对应的
  /// 服务地址和密钥，实际调用时只能套用总结模型那家的配置，名字填错了也看不出来。
  /// 没有可选的模型时整个下拉变灰，并说明要先去添加什么样的模型。
  private func preferenceModelAssignmentControl(
    title: String,
    emptyOptionTitle: String,
    options: [ProviderSettingsViewModel.LibraryEntryDisplay],
    text: Binding<String>,
    identifier: String,
    customPlaceholder _: String,
    unavailableHint: String? = nil
  ) -> some View {
    VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
      modelChoicePicker(
        label: title,
        emptyOptionTitle: emptyOptionTitle,
        options: options,
        text: text,
        identifier: identifier
      )
      .disabled(options.isEmpty && text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
      if options.isEmpty, let unavailableHint {
        Text(unavailableHint)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 260, alignment: .trailing)
          .accessibilityIdentifier("\(identifier)-unavailable")
      } else if isCustomModelName(text.wrappedValue, in: options) {
        // 以前手填过、现在不在模型服务里的名字：照实说明，让用户换成列表里的模型。
        Text("「\(text.wrappedValue.trimmingCharacters(in: .whitespaces))」不在模型服务里，请改选列表中的模型")
          .themedFont(.caption)
          .foregroundStyle(appTheme.warning)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 260, alignment: .trailing)
          .accessibilityIdentifier("\(identifier)-legacy-custom")
      }
    }
  }

  /// 总结 / 本地转写的选择按钮：和其它行的下拉同一宽度、同一描边，点开是分组 popover。
  ///
  /// 不用系统 `Picker`：选项要按服务商分组、每项带模型 ID 副标题，menu Picker 画不出来。
  private func pickerLabel(for name: String) -> String {
    guard let base = model.editorHealthBaseURL, model.healthRecord(baseURL: base, model: name) != nil else { return name }
    return "\(name)　·　\(model.healthBadge(baseURL: base, model: name).text)"
  }

  /// 「检测可用」：免费模型直接测；有付费模型时先问一句，因为每条会扣一点点费用。
  @ViewBuilder
  private func modelProbeButton(scope: ModelProbeScope) -> some View {
    switch model.modelProbeState {
    case let .running(done, total):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("检测中 \(done)/\(total)").themedFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        Button("停止") { model.cancelModelProbe() }.buttonStyle(.appQuiet).controlSize(.small)
      }
    default:
      let plan = scope == .catalog ? model.catalogProbePlan : model.libraryProbePlan
      HStack(spacing: 6) {
        if case let .finished(available, total) = model.modelProbeState, total > 0 {
          Text("\(available)/\(total) 可用").themedFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Button("检测可用") {
          if plan.paidModels.isEmpty {
            startProbe(scope: scope, includesPaid: false)
          } else {
            pendingProbeScope = scope
          }
        }
        .buttonStyle(.appNormal)
        .disabled(plan.total == 0 || model.isSaving || model.isLoadingModels)
        .help("给每个模型发一句话，看能不能用")
        .accessibilityIdentifier(scope == .catalog ? "probe-catalog-models" : "probe-library-models")
      }
      .confirmationDialog(
        probeConfirmationTitle(plan),
        isPresented: Binding(
          get: { pendingProbeScope == scope },
          set: { if !$0, pendingProbeScope == scope { pendingProbeScope = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("全部检测（含 \(plan.paidModels.count) 个付费模型）") { startProbe(scope: scope, includesPaid: true) }
        if !plan.freeModels.isEmpty {
          Button("只检测 \(plan.freeModels.count) 个免费模型") { startProbe(scope: scope, includesPaid: false) }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("每个模型发一句话，付费的只花一点额度。结果显示在模型名旁边。")
      }
    }
  }

  private func probeConfirmationTitle(_ plan: ProviderSettingsViewModel.ModelProbePlan) -> String {
    "检测 \(plan.total) 个模型能不能用？"
  }

  private func startProbe(scope: ModelProbeScope, includesPaid: Bool) {
    pendingProbeScope = nil
    switch scope {
    case .catalog:
      model.probeCatalogModels(includesPaid: includesPaid, submittedAPIKey: apiKeyInput.isEmpty ? nil : apiKeyInput)
    case .library:
      model.probeLibraryModels(includesPaid: includesPaid)
    }
  }

  private func assignmentPickerButton(
    kind: AssignmentPicker,
    selectedEntry: ProviderSettingsViewModel.LibraryEntryDisplay?
  ) -> some View {
    Button {
      activeAssignmentPicker = kind
    } label: {
      SettingsMenuLabel(
        title: assignmentDisplayName(kind: kind, entry: selectedEntry),
        subtitle: assignmentDetail(kind: kind, entry: selectedEntry)
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(kind == .summary ? "summary-assignment-picker" : "transcription-assignment-picker")
    .popover(
      isPresented: Binding(
        get: { activeAssignmentPicker == kind },
        set: { isPresented in
          if !isPresented, activeAssignmentPicker == kind {
            activeAssignmentPicker = nil
          }
        }
      ),
      arrowEdge: .trailing
    ) {
      assignmentPickerPopover(kind)
    }
  }

  private func assignmentDisplayName(
    kind: AssignmentPicker,
    entry: ProviderSettingsViewModel.LibraryEntryDisplay?
  ) -> String {
    if let entry { return entry.displayName }
    return kind == .transcription ? "Mac 自带的语音识别" : "未指派"
  }

  private func assignmentDetail(
    kind: AssignmentPicker,
    entry: ProviderSettingsViewModel.LibraryEntryDisplay?
  ) -> String {
    if let entry { return entry.title }
    return kind == .transcription ? "本机 · 离线" : "请选择模型"
  }

  private func assignmentPickerPopover(_ kind: AssignmentPicker) -> some View {
    let entries = kind == .transcription ? model.transcriptionEntryDisplays : model.summaryEntryDisplays
    return VStack(alignment: .leading, spacing: 0) {
      Text(kind == .transcription ? "选择转写方式" : "选择默认模型")
        .themedFont(.headline)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if kind == .transcription {
            assignmentSectionTitle("本机")
            assignmentOptionRow(
              title: "本机转写（用 Mac 自带的语音识别）",
              detail: "离线处理，不发送音频",
              isSelected: model.transcriptionAssignmentID == nil
            ) {
              activeAssignmentPicker = nil
              Task { await model.assignTranscriptionModel(nil) }
            }
          }

          if !entries.isEmpty {
            assignmentSectionTitle(kind == .transcription ? "在线模型" : UISettingsPresentation.modelServicesCardTitle)
            ForEach(assignmentProviderTitles(in: entries), id: \.self) { providerTitle in
              Text(providerTitle)
                .themedFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 3)

              ForEach(entries.filter { $0.title == providerTitle }) { entry in
                assignmentOptionRow(
                  title: entry.displayName,
                  detail: entry.modelName,
                  isSelected: selectedAssignmentID(for: kind) == entry.id,
                  health: model.healthBadge(baseURL: entry.baseURL, model: entry.modelName)
                ) {
                  activeAssignmentPicker = nil
                  Task {
                    if kind == .summary {
                      await model.assignSummaryModel(entry.id)
                    } else {
                      await model.assignTranscriptionModel(entry.id)
                    }
                  }
                }
              }
            }
          } else if kind == .transcription {
            Text("还没有添加可用于音频转写的在线模型。")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .padding(16)
          }
        }
        .padding(.bottom, 10)
      }
      .frame(maxHeight: 420)
    }
    .frame(width: 360)
    .accessibilityIdentifier(kind == .summary ? "summary-assignment-popover" : "transcription-assignment-popover")
  }

  private func assignmentSectionTitle(_ title: String) -> some View {
    Text(title)
      .themedFont(.caption, weight: .semibold)
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 4)
  }

  private func assignmentOptionRow(
    title: String,
    detail: String,
    isSelected: Bool,
    health: ModelHealthBadge? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .themedFont(.headline)
            .foregroundStyle(.primary)
          Text(detail)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 12)
        if let health {
          ModelHealthBadgeView(badge: health, theme: settingsTheme)
        }
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(isSelected ? 1 : 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func assignmentProviderTitles(
    in entries: [ProviderSettingsViewModel.LibraryEntryDisplay]
  ) -> [String] {
    entries.reduce(into: [String]()) { titles, entry in
      if !titles.contains(entry.title) { titles.append(entry.title) }
    }
  }

  private func selectedAssignmentID(for kind: AssignmentPicker) -> String? {
    kind == .summary ? model.summaryAssignmentID : model.transcriptionAssignmentID
  }

  // MARK: - 模型库列表

  /// 按服务商归拢的模型库。一家一组，展开才列它下面的模型。
  ///
  /// 平铺时，同一家的几个模型各占一行、每行都重复一遍服务商名和图标——三家十个
  /// 模型就是十行几乎一样的东西，要找「阶跃星辰下面配了哪几个」得自己用眼睛扫。
  /// 归拢之后先看到的是「有哪几家」，再决定展开哪一家。
  ///
  /// 顺序按第一次出现的先后，不重排：用户添加的次序本身就是一种记忆。
  private struct LibraryProviderGroup: Identifiable {
    let id: String
    let preset: ProviderPreset
    let entries: [ProviderSettingsViewModel.LibraryEntryDisplay]
  }

  private var libraryProviderGroups: [LibraryProviderGroup] {
    var order: [String] = []
    var buckets: [String: [ProviderSettingsViewModel.LibraryEntryDisplay]] = [:]
    for entry in model.libraryEntryDisplays {
      if buckets[entry.title] == nil {
        order.append(entry.title)
        buckets[entry.title] = []
      }
      buckets[entry.title]?.append(entry)
    }
    return order.compactMap { title in
      guard let entries = buckets[title], let first = entries.first else { return nil }
      return LibraryProviderGroup(id: title, preset: first.preset, entries: entries)
    }
  }

  /// 已添加的服务商组头：一行 40pt，图标 + 名称 + 模型数 + 展开箭头。
  ///
  /// 用途徽标（总结 / 转写）挂在具体模型行上，组头只回答「这是哪一家、有几个模型」。
  private func libraryProviderCard(_ group: LibraryProviderGroup) -> some View {
    let expanded = expandedLibraryProvider == group.id
    return HStack(spacing: DesignTokens.Space.sm) {
      Button {
        withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
          expandedLibraryProvider = expanded ? nil : group.id
        }
      } label: {
        HStack(spacing: DesignTokens.Space.sm) {
          providerIcon(group.preset, fallbackName: group.id)
          Text(group.id)
            .themedFont(.body, weight: .semibold)
            .lineLimit(1)
            .truncationMode(.tail)
          Text("\(group.entries.count) 个模型")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("library-provider-group")
      // 给这家再加模型：沿用已保存的密钥，直接读最新列表，不用重新输密钥。
      if let firstEntry = group.entries.first {
        Button {
          Task { await model.beginAddModelsFromProvider(profileID: firstEntry.id) }
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.appIcon)
        .disabled(model.isSaving || model.isTestingConnection || model.isLoadingModels)
        .help("读取 \(group.id) 的最新模型，选新的添加，沿用已存的密钥")
        .accessibilityLabel("拉取 \(group.id) 的最新模型")
        .accessibilityIdentifier("library-provider-fetch-models")
      }
      // 整组删除收进组头的更多菜单：一家服务商十来个模型，一条条删太折腾。
      // 菜单自带的下拉小箭头隐藏掉：原来它被挤到行尾，看起来像第三个控件。
      Menu {
        if let firstEntry = group.entries.first {
          Button("更新模型…") {
            Task { await model.beginAddModelsFromProvider(profileID: firstEntry.id) }
          }
          .accessibilityIdentifier("library-provider-fetch-models-menu")
        }
        Button("全部删除（\(group.entries.count) 个）", role: .destructive) {
          pendingGroupDeletion = group
        }
        .accessibilityIdentifier("delete-library-provider")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("更多")
      .accessibilityLabel("这家服务商的更多操作")
      .accessibilityIdentifier("library-provider-more")
      // 展开箭头放在行尾，和「更多」并排。它也必须能点：原来只是一张图，
      // 用户点箭头什么都不发生，只有点左边的名称才会展开。
      Button {
        withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
          expandedLibraryProvider = expanded ? nil : group.id
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(expanded ? 0 : -90))
          .frame(width: 28, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(expanded ? "收起" : "展开")
      .accessibilityLabel(expanded ? "收起 \(group.id)" : "展开 \(group.id)")
      .accessibilityIdentifier("library-provider-toggle")
    }
  }

  /// 模型行：和组头同一个左边距，靠 24pt 缩进表示从属。
  private func libraryRow(_ entry: ProviderSettingsViewModel.LibraryEntryDisplay) -> some View {
    HStack(spacing: 10) {
      // 服务商图标已在组头，行内不再重复。
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.displayName).themedFont(.body)
        Text(entry.modelName).themedFont(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      ModelHealthBadgeView(badge: model.healthBadge(baseURL: entry.baseURL, model: entry.modelName), theme: settingsTheme)
      if model.summaryAssignmentID == entry.id {
        assignmentBadge("总结")
      }
      if model.transcriptionAssignmentID == entry.id {
        assignmentBadge("转写")
      }
      Button {
        model.beginEditModel(entry.id)
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.appIcon)
      .help("编辑")
      .accessibilityLabel("编辑")
      .accessibilityIdentifier("edit-library-model")
      // 删除收进更多菜单，确认对话框仍走既有 pendingDeletionID 流程。
      Menu {
        Button("删除", role: .destructive) {
          pendingDeletionID = entry.id
        }
        .accessibilityIdentifier("delete-library-model")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("更多")
      .accessibilityLabel("更多操作")
      .accessibilityIdentifier("library-model-more")
      // 和组头的展开箭头对齐，占同样宽度。
      Color.clear.frame(width: 16)
    }
    .padding(.leading, DesignTokens.Space.xl)
    .frame(height: 40)
    .contentShape(Rectangle())
  }

  private func assignmentBadge(_ text: String) -> some View {
    Text(text)
      .themedFont(.caption2, weight: .semibold)
      .padding(.horizontal, 6).padding(.vertical, 2)
      // 主题色，不是 `Color.accentColor`：后者读的是 App 级强调色（默认系统蓝），
      // 不受窗口根部 `.tint(theme.accent)` 影响——暖褐主题下这枚徽标会是蓝的。
      .background(settingsTheme.accent.opacity(0.15), in: Capsule())
      .foregroundStyle(settingsTheme.accent)
  }

  // MARK: - 模型编辑器

  private var isEditorSheetPresented: Binding<Bool> {
    Binding(
      get: { model.isEditorVisible },
      set: { if !$0 { model.closeEditor() } }
    )
  }

  private var editorTitle: String {
    if model.editingProfileID == nil {
      return model.isReusingProviderKey ? "添加模型 · \(model.selectedPreset == .custom ? "沿用已保存的密钥" : model.selectedPreset.displayName)" : "添加模型"
    }
    let name = model.libraryEntryDisplays.first(where: { $0.id == model.editingProfileID })?.displayName
    return name.map { "编辑模型 · \($0)" } ?? "编辑模型"
  }

  /// 添加流程没有已选服务商，直接展开网格；编辑流程默认折叠成一行，点「更换」才展开。
  private var showsPresetGrid: Bool {
    (model.editingProfileID == nil && !model.isReusingProviderKey && !isPresetPrefilled) || isChoosingPreset
  }

  private var editorBusy: Bool {
    model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels
  }

  private var editorSheet: some View {
    VStack(spacing: 0) {
      HStack(spacing: DesignTokens.Space.md) {
        Text(editorTitle)
          .themedFont(.title3, weight: .semibold)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        Button { model.closeEditor() } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.appIcon)
        .disabled(editorBusy)
        .help("关闭")
        .accessibilityLabel("关闭编辑")
        .accessibilityIdentifier("close-library-editor")
      }
      .padding(.horizontal, DesignTokens.Space.xl)
      .padding(.vertical, DesignTokens.Space.lg)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
          editorProviderSection
          editorConnectionCard
        }
        .padding(.horizontal, DesignTokens.Space.xl)
        .padding(.vertical, DesignTokens.Space.lg)
      }

      Divider()

      // 一个主动作：验证并保存。「仅保存」「测试连接」降为文字按钮。
      SettingsActionRow(
        status: editorStatusText,
        statusColor: editorStatusColor,
        showsProgress: model.isSaving || model.isTestingConnection,
        statusIdentifier: "provider-settings-status"
      ) {
        // 新建时「验证并保存」本身就会测一次；这里只给已保存的配置用。
        // 原来新建时它一直灰着、提示「请先保存再测试」，新用户第一眼就是一个点不了的按钮
        // （2026-10-02 新用户走查）。
        if model.hasConfiguredAPIKey || model.isEditingLibraryEntry {
          Button("测试连接") { Task { await model.testConnection() } }
            .buttonStyle(.appNormal)
            .disabled(!model.canTestConnection || !apiKeyInput.isEmpty)
            .help(testConnectionBlocked ? unsavedChangesText : "发一句话试试能不能连上")
            .accessibilityIdentifier("test-provider-connection")
        }
        if !model.isAddingModelBatch {
          Button("直接保存") {
            let submittedKey = apiKeyInput
            Task {
              await model.save(apiKey: submittedKey)
              apiKeyInput = ""
            }
          }
          .buttonStyle(.appQuiet)
          .disabled(!model.canSaveConfiguration)
          .accessibilityIdentifier("save-provider-settings-only")
        }
        Button(model.isAddingModelBatch ? "保存 \(model.selectedCatalogModelCount) 个模型" : "验证并保存") {
          let submittedKey = apiKeyInput
          Task {
            await model.saveAndVerify(apiKey: submittedKey)
            apiKeyInput = ""
          }
        }
        .buttonStyle(.appProminent(settingsTheme.accent))
        .disabled(!model.canSaveConfiguration)
        .accessibilityIdentifier("save-provider-settings")
      }
      .padding(.horizontal, DesignTokens.Space.xl)
      .padding(.vertical, DesignTokens.Space.md)
    }
    .frame(width: 640)
    .frame(minHeight: 420, idealHeight: 560, maxHeight: 720)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
    .foregroundStyle(settingsTheme.primaryText)
    .tint(settingsTheme.accent)
    .accessibilityIdentifier("model-editor-sheet")
    .modifier(PrefilledAPIKeyFocus(isOn: isPresetPrefilled, focus: $isAPIKeyFieldFocused))
    .task {
      // 从「填入」进来时光标放进密钥框。Sheet 出场时 AppKit 会把第一个输入框（服务地址）
      // 设成第一响应者，所以出场落定后再补一次，否则会被它盖掉。
      guard isPresetPrefilled else { return }
      try? await Task.sleep(for: .milliseconds(800))
      isAPIKeyFieldFocused = true
    }
  }

  /// 状态只留一行：保存状态优先，有连接测试结果时接在后面。
  private var editorStatusText: String {
    if model.connectionTestState != .idle { return connectionStatusText }
    return model.statusText
  }

  private var editorStatusColor: Color {
    if model.connectionTestState != .idle { return connectionStatusColor }
    return statusColor
  }

  @ViewBuilder private var editorProviderSection: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("服务商").settingsSectionHeaderStyle()
      if showsPresetGrid {
        // 12 家服务商排成一列时，每行连着行内距和分隔线要占 54pt，光这一块
        // 就吃掉约 650pt——一屏几乎装不下，选个服务商得先滚半天。
        // 换成多列卡片后约 200pt。
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 168), spacing: 8, alignment: .top)],
          alignment: .leading,
          spacing: 8
        ) {
          ForEach(ProviderPreset.allCases) { preset in
            Button {
              model.selectPreset(preset)
              if model.editingProfileID != nil { isChoosingPreset = false }
            } label: {
              providerCard(preset)
            }
            .buttonStyle(.plain)
            .disabled(editorBusy)
          }
          .accessibilityIdentifier("provider-preset")
        }
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      } else {
        // 已选服务商折叠成一行：图标 + 名称 + 端点，右端「更换」。
        HStack(spacing: DesignTokens.Space.sm) {
          providerIcon(model.selectedPreset, fallbackName: model.selectedPreset.endpointHost)
          Text(model.selectedPreset.displayName)
            .themedFont(.body, weight: .semibold)
          Text(model.selectedPreset.endpointHost)
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: DesignTokens.Space.md)
          Button("更换") { isChoosingPreset = true }
            .buttonStyle(.appQuiet)
            .disabled(editorBusy)
            .accessibilityIdentifier("change-provider-preset")
        }
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      // 套餐说明收成一行 caption；Command Code 另给两个链接。
      Text(model.selectedPreset.documentationHint)
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if model.selectedPreset == .commandCode {
        HStack(spacing: 16) {
          Link("接入说明", destination: URL(string: "https://commandcode.ai/docs/provider")!)
          Link("获取密钥", destination: URL(string: "https://commandcode.ai/docs/studio#api-keys")!)
        }
        .themedFont(.subheadline)
        .accessibilityIdentifier("command-code-setup-links")
      }
    }
  }

  /// Base URL、API Key、模型收成一张卡，一行一个字段，标签同宽对齐。
  @ViewBuilder private var editorConnectionCard: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("连接设置").settingsSectionHeaderStyle()
      VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
          GridRow(alignment: .firstTextBaseline) {
            Text("服务地址")
              .frame(width: 86, alignment: .leading)
            TextField("", text: $model.baseURL, prompt: Text("https://api.example.com/v1"))
              .labelsHidden()
              .accessibilityLabel("服务地址")
              .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
              .accessibilityIdentifier("provider-base-url")
          }

          GridRow(alignment: .firstTextBaseline) {
            Text("密钥")
              .frame(width: 86, alignment: .leading)
            if model.shouldShowAPIKeyInput {
              SecureField("", text: $apiKeyInput, prompt: Text("输入密钥"))
                .labelsHidden()
                .focused($isAPIKeyFieldFocused)
                .accessibilityLabel("密钥")
                .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
                .accessibilityIdentifier("provider-api-key")
            } else {
              HStack(spacing: 10) {
                Text(model.apiKeyStatusText).foregroundStyle(appTheme.success)
                  .accessibilityIdentifier("provider-api-key-configured")
                Spacer(minLength: 0)
                Button("更换", action: model.beginAPIKeyReplacement)
                  .buttonStyle(.appQuiet)
                  .disabled(!model.canBeginAPIKeyReplacement)
                  .accessibilityIdentifier("replace-provider-api-key")
              }
            }
          }

          GridRow(alignment: .firstTextBaseline) {
            Text("模型")
              .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
              HStack(spacing: DesignTokens.Space.sm) {
                if !model.isAddingModelBatch { editorModelControl }
                Button(model.selectedPreset == .commandCode ? "读取列表" : "读取列表") {
                  let submittedKey = apiKeyInput
                  Task {
                    if model.shouldShowAPIKeyInput {
                      await model.loadModels(apiKey: submittedKey)
                    } else {
                      await model.loadModels()
                    }
                  }
                }
                .buttonStyle(.appNormal)
                .disabled(
                  !model.canLoadModelCatalog
                    || (model.shouldShowAPIKeyInput && apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                .accessibilityIdentifier("load-provider-models")
                if model.isLoadingModels { ProgressView().controlSize(.small) }
                if model.shouldOfferManualModelEntry {
                  Button("手动填写", action: model.enableManualModelEntry)
                    .buttonStyle(.appQuiet)
                    .accessibilityIdentifier("enable-manual-provider-model")
                }
                Spacer(minLength: 0)
              }

              if model.isAddingModelBatch {
                TextField("", text: $model.modelSearchQuery, prompt: Text("输入关键词过滤"))
                  .textFieldStyle(.roundedBorder)
                  .frame(maxWidth: 260)
                  .accessibilityLabel("搜索模型")
                  .accessibilityIdentifier("provider-model-search")

                ScrollView {
                  LazyVStack(spacing: 0) {
                    ForEach(model.healthSortedFilteredModels, id: \.self) { name in
                      let alreadyAdded = model.isModelAlreadyInLibrary(name)
                      let health = model.editorHealthBaseURL.map { model.healthBadge(baseURL: $0, model: name) } ?? .unchecked
                      let unusable = model.editorHealthBaseURL.flatMap { model.healthRecord(baseURL: $0, model: name) }?.status.isDefinitelyUnusable == true
                      Button {
                        model.toggleCatalogModel(name)
                      } label: {
                        HStack(spacing: 10) {
                          Image(systemName: alreadyAdded ? "checkmark.circle" : (model.selectedCatalogModels.contains(name) ? "checkmark.square.fill" : "square"))
                            .foregroundStyle(model.selectedCatalogModels.contains(name) ? settingsTheme.accent : .secondary)
                          Text(name)
                            .foregroundStyle(alreadyAdded || unusable ? .secondary : .primary)
                            .lineLimit(1)
                          Spacer()
                          if ProviderSettingsViewModel.isTranscriptionModel(name) {
                            Text("语音转写")
                              .themedFont(.caption2, weight: .medium)
                              .foregroundStyle(settingsTheme.accent)
                              .padding(.horizontal, 6)
                              .padding(.vertical, 2)
                              .background(settingsTheme.badge, in: Capsule())
                          }
                          ModelHealthBadgeView(badge: health, theme: settingsTheme)
                          if alreadyAdded {
                            Text("已添加")
                              .font(.caption)
                              .foregroundStyle(.secondary)
                          }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                      }
                      .buttonStyle(.plain)
                      .disabled(alreadyAdded)
                      .accessibilityIdentifier("provider-model-option")
                      if name != model.healthSortedFilteredModels.last {
                        Divider().padding(.leading, 36)
                      }
                    }
                  }
                }
                .frame(minHeight: 120, maxHeight: 260)
                // 与主界面的滚动容器同一套令牌（HistoryContentView 的转写编辑器）：
                // `.background.opacity(0.55)` 在浅色/深色主题下会露出半透明白框，
                // `.separator` 也是系统色，两者都不随主题走。
                .background(
                  settingsTheme.isNative ? Color(nsColor: .textBackgroundColor) : settingsTheme.listPane,
                  in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                )
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(settingsTheme.hairline, lineWidth: 1))
                Text("已选择 \(model.selectedCatalogModelCount) 个模型")
                  .themedFont(.subheadline)
                  .foregroundStyle(model.selectedCatalogModelCount == 0 ? Color.secondary : settingsTheme.accent)
                  .accessibilityIdentifier("provider-model-selection-count")
              }
            }
          }
        }
        .frame(maxWidth: .infinity)

        Text(model.modelCatalogStatusText)
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("provider-model-catalog-status")

        if model.modelCatalogState == .loaded, !model.availableModels.isEmpty {
          HStack(spacing: DesignTokens.Space.sm) {
            modelProbeButton(scope: .catalog)
            if let base = model.editorHealthBaseURL, !model.modelName.isEmpty, !model.isAddingModelBatch {
              let badge = model.healthBadge(baseURL: base, model: model.modelName)
              ModelHealthBadgeView(badge: badge, theme: settingsTheme)
              Text(badge.detail)
                .themedFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
          }
        }
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())

      Text("只发一句话，不留记录")
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// 编辑表单「模型」行的控件：读到目录就下拉选，没读到就按状态给文本框或占位。
  @ViewBuilder private var editorModelControl: some View {
    let selection = Binding(
      get: { model.modelName },
      set: { model.selectModel($0) }
    )
    if model.modelCatalogState == .loaded, !model.availableModels.isEmpty {
      Picker("模型", selection: selection) {
        if selection.wrappedValue.isEmpty {
          Text("请选择模型").tag("")
        } else if !model.availableModels.contains(selection.wrappedValue) {
          Text("当前：\(selection.wrappedValue)").tag(selection.wrappedValue)
        }
        // 菜单里放不了彩色标记，用文字写在模型名后面；能用的排前面。
        ForEach(model.healthSortedFilteredModels, id: \.self) { name in
          Text(pickerLabel(for: name)).tag(name)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260)
      .accessibilityIdentifier("provider-model-picker")
      TextField("", text: $model.modelSearchQuery, prompt: Text("过滤"))
        .textFieldStyle(.roundedBorder)
        .frame(width: 96)
        .accessibilityLabel("搜索模型")
        .accessibilityIdentifier("provider-model-search")
    } else if model.isManualModelEntryEnabled {
      TextField("", text: selection, prompt: Text("手动填写"))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 260)
        .disabled(model.isSaving || model.isConfigurationLoading)
        .accessibilityIdentifier("provider-model-name")
    } else if model.hasConfiguredAPIKey, !model.modelName.isEmpty {
      Text(model.modelName)
        .themedFont(.body)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("provider-model-name")
    } else {
      Text("读取列表后选择")
        .themedFont(.body)
        .foregroundStyle(.secondary)
    }
  }

  /// 纸质主题的设置侧栏：画布底色 + 主窗口同款橙色选中样式。
  private var paperSidebar: some View {
    List {
      ForEach(Array(Self.visibleSidebarSections.enumerated()), id: \.offset) { _, section in
        if let title = section.title {
          Text(title)
            .themedFont(.caption)
            .tracking(2)
            .foregroundStyle(settingsTheme.secondaryText)
            .padding(.top, DesignTokens.Space.md)
            .padding(.horizontal, DesignTokens.Space.sm)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(Self.visibleTabs(in: section.tabs)) { tab in
          paperSidebarRow(tab)
        }
      }
    }
    // 别改成 `.plain` 想去掉那圈浮动面板阴影——实测无效（面板 inset 仍是 8pt、
    // 高光边和投影像素级不变），而且 plain 会把行的左边距缩掉，图标左缘不再和
    // 主界面的 29.5pt 对齐。浮动面板来自 Settings scene 本身，不是 listStyle。
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.canvas)
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion),
      value: selectedTab
    )
  }

  /// 自绘侧栏的单个分类行。
  ///
  /// 选中高亮用 `matchedGeometryEffect` 在同一命名空间内挂靠：切换分类时，高亮块
  /// 从旧行的位置滑到新行，而不是旧的消失、新的凭空出现。`withAnimation` 包住状态
  /// 变化本身——没有它，`matchedGeometryEffect` 只负责插值，不负责触发过渡。
  @ViewBuilder
  private func paperSidebarRow(_ tab: SettingsTab) -> some View {
    let isSelected = selectedTab == tab
    Button {
      settingsAnchor = nil
      withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
        selectedTab = tab
      }
    } label: {
      Label {
        Text(tab.title)
          .themedFont(.body)
      } icon: {
        sidebarIcon(tab, selected: isSelected)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, tab.parent == nil ? 0 : 18)
      .contentShape(Rectangle())
    }
    .accessibilityLabel(tab.title)
    .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
    .buttonStyle(.plain)
    // 与主界面侧栏共用同一档间距和浅色选中态，两个窗口切换时不会像两套组件。
    .padding(.vertical, DesignTokens.Space.xxs)
    .padding(.horizontal, DesignTokens.Space.sm)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
          .fill(settingsTheme.accent.opacity(0.12))
          .matchedGeometryEffect(id: "settings-sidebar-highlight", in: sidebarSelectionNamespace)
      }
    }
    .foregroundStyle(settingsTheme.primaryText)
    .fontWeight(isSelected ? .semibold : .regular)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  // MARK: - 外观

  /// 设置窗口与主窗口共用同一套主题令牌，保证外观切换全局一致。
  @Environment(\.colorScheme) private var systemColorScheme
  private var settingsTheme: HistoryThemeTokens {
    (AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass).tokens(systemColorScheme: systemColorScheme)
  }

  /// 侧栏图标：每一页同一套线条图标，同大小、同灰色，选中时换靛青。
  ///
  /// 2026-10-09 Syc 定：原来工序页是朱印、其余页是灰方框里一个宋体字（闲章）、改过名的页又退回
  /// 系统图标，一列三种标准。印只留在页面里——「处理流程」的工序链和各工序页页头，
  /// 在那里它表示这道工序自动还是手动；导航只管认路。
  private func sidebarIcon(_ tab: SettingsTab, selected: Bool) -> some View {
    SettingsSidebarChip(symbol: tab.symbol, fill: selected ? settingsTheme.accent : settingsTheme.secondaryText)
  }

  /// 这一道工序新内容进来会不会自动做。
  private func isAuto(_ step: SettingsProcessStep) -> Bool {
    autoBinding(step)?.wrappedValue ?? true
  }

  /// 工序页右上「自动」开关绑的是哪个偏好。收集一直开着，没有开关。
  private func autoBinding(_ step: SettingsProcessStep) -> Binding<Bool>? {
    switch step {
    case .capture: nil
    case .record: $model.autoTranscribeNewCaptures
    case .proof: $model.autoTidyTranscription
    case .summary: $model.autoSummarizeNewCaptures
    case .translation: $model.autoLocalizeTitleNewCaptures
    case .mindMap: $model.autoMindMapNewCaptures
    }
  }

  /// 这道工序现在不能设成自动的原因；nil = 可以。
  ///
  /// 校、摘、译、图都要调用模型：一个能写字的模型都没配时设成自动，新内容进来每一步都会失败，
  /// 而失败发生在后台、用户看不到为什么。录是本机 Apple 听写，不需要模型。
  private func autoBlockReason(_ step: SettingsProcessStep) -> String? {
    switch step {
    case .capture, .record:
      return nil
    case .proof, .summary, .translation, .mindMap:
      guard !model.isConfigurationLoading, model.summaryEntryDisplays.isEmpty else { return nil }
      return "「\(step.title)」要用模型，还没配。先到「模型服务」添加一个。"
    }
  }

  /// 总览上点「自动 / 手动」：和工序页右上的开关写同一份设置（2026-10-01）。
  /// 关掉随时可以；打开时有前提没满足就说原因，不静默不动。
  private func toggleAutoFromChain(_ step: SettingsProcessStep) {
    guard let binding = autoBinding(step) else { return }
    if !binding.wrappedValue, let reason = autoBlockReason(step) {
      chainAutoNotice = reason
      return
    }
    chainAutoNotice = nil
    binding.wrappedValue.toggle()
  }

  private func stepHeader(_ step: SettingsProcessStep, caption: String, autoLabel: String = "自动", compact: Bool = false) -> some View {
    SettingsStepHeader(
      step: step, caption: caption, isAuto: autoBinding(step), autoLabel: autoLabel,
      sealColor: settingsTheme.seal, secondaryText: settingsTheme.secondaryText, hairline: settingsTheme.hairline,
      compact: compact
    )
  }

  /// 侧栏 chip 的底色。两条侧栏分支共用同一份取色逻辑，避免图标换了颜色却漏了一处。
  private func sidebarChipFill(_ tab: SettingsTab) -> Color {
    SettingsCategoryChip.fill(for: tab.rawValue, theme: settingsTheme)
  }

  /// 详情页页头。标题、图标、chip 底色都从 `SettingsTab` 本身取，四个页面不用各自
  /// 重写一份——只有一句话说明是每页各自的。
  private func pageHeader(
    for tab: SettingsTab,
    caption: String,
    captionIdentifier: String? = nil
  ) -> some View {
    SettingsPageHeader(
      title: tab.title,
      symbol: tab.symbol,
      caption: caption,
      fill: sidebarChipFill(tab),
      captionIdentifier: captionIdentifier
    )
  }

  /// 还在成型中的功能。默认全关。
  private var labsTab: some View {
    SettingsPlainPage {
      // 原来那句范围说明是一张独立的 info 卡；页头的一句话就是它，标识跟着文案走。
      pageHeader(
        for: .labs,
        caption: "这一页的功能还在打磨，关掉不会删数据。",
        captionIdentifier: "labs-scope-note"
      )

      // 「工作台」「爆款实验室」「每天自动出选题」都只是一个开关＋一段说明，
      // 三张几乎等大的整卡挤在一起反而看不出主次。收进一张行式卡片；
      // 「我的文风」有三组分段控件和一段长文本，仍然独占一张卡。
      SettingsRowGroup {
        SettingsRow(
          title: "工作台",
          caption: "把素材加工成作品，打开后侧栏出现",
          details: "目前只能手动建创作、加素材、推进阶段，还没接 AI。关掉不删数据。"
        ) {
          Toggle("", isOn: $isWorkbenchEnabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("工作台")
            .accessibilityIdentifier("labs-workbench-toggle")
        }

        SettingsRow(
          title: "爆款实验室",
          caption: "发布前先写下预测，几天后拿真实结果对照。",
          details: "这是校准，不是预测：发布前写下判断，事后对照「以为会爆的为什么没爆」。判断写下后不能改。关掉后模块隐藏，已记的预测不删。"
        ) {
          Toggle("爆款实验室", isOn: $isHitLabEnabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("hit-lab-enabled")
        }

        SettingsRow(
          title: "每日选题",
          caption: "每天定时从素材里出几条选题",
          details: "过了时间点且今天还没出，就会补出一次，晚开电脑也照样出。会花订阅额度，所以默认关着。"
        ) {
          VStack(alignment: .trailing, spacing: DesignTokens.Space.sm) {
            Toggle("每日选题", isOn: scheduleBinding(\.isEnabled))
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityIdentifier("topic-schedule-enabled")
            if TopicSchedule.decoded(from: topicScheduleRaw).isEnabled {
              HStack(spacing: 8) {
                Text("时间").themedFont(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: scheduleBinding(\.hour)) {
                  ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 62)
                Text(":").foregroundStyle(.secondary)
                Picker("", selection: scheduleBinding(\.minute)) {
                  ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 62)
              }
            }
          }
        }
      }

      // 表达方式属于工作台,不属于「输出沉淀」:它是你主动定义的加工参数,
      // 不是从你的修改里反推出来的猜测。学错了你没法直接纠正,而旋钮随时能拧。
      settingCard(
        title: "我的文风",
        summary: "AI 起草时照这个写",
        details: "参考段落最有用：一段真实文字直接示范你怎么断句、起头、收尾。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("语气", selection: voiceBinding(\.tone)) {
            ForEach(VoiceSettings.Tone.allCases, id: \.self) {
              Text($0.displayName).tag($0)
            }
          }
          .pickerStyle(.segmented)
          Picker("句子", selection: voiceBinding(\.sentenceLength)) {
            ForEach(VoiceSettings.SentenceLength.allCases, id: \.self) {
              Text($0.displayName).tag($0)
            }
          }
          .pickerStyle(.segmented)
          Picker("结构", selection: voiceBinding(\.structure)) {
            ForEach(VoiceSettings.Structure.allCases, id: \.self) {
              Text($0.displayName).tag($0)
            }
          }
          .pickerStyle(.segmented)

          VStack(alignment: .leading, spacing: 5) {
            Text("禁用词").themedFont(.subheadline).foregroundStyle(.secondary)
            TextField("赋能、抓手、闭环…", text: voiceBinding(\.forbiddenWords))
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("voice-forbidden-words")
          }

          VStack(alignment: .leading, spacing: 5) {
            Text("参考段落").themedFont(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: voiceBinding(\.sample))
              .themedFont(.callout)
              .frame(minHeight: 88)
              .scrollContentBackground(.hidden)
              .padding(6)
              .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color(nsColor: .textBackgroundColor))
              )
              .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).strokeBorder(settingsTheme.hairline))
              .accessibilityIdentifier("voice-sample")
          }
        }
      }
    }
  }

  private var appearanceTab: some View {
    SettingsPlainPage {
      pageHeader(for: .appearance, caption: "主题和字体，改了即时生效")

      settingCard(
        title: "主题",
        summary: "选择界面明暗与阅读纸色。",
        details: "浅色和深色是同一套配色的白天和夜晚，「跟随系统」自动切换。界面字体默认跟随系统，下面两项可分别改。",
        controlWidth: .full
      ) {
        ThemeSwatchPicker(selection: $appearanceThemeRaw)
      }

      // 界面字体和阅读字体分成两张卡、两个偏好，故意不合并：两者的取舍方向相反。
      // 界面最小 10pt，要的是「立得住」；正文最小 13pt，要的是「读着舒服」。
      // 同一个字体很少两边都最优，绑在一起等于强迫用户二选一。
      settingCard(
        title: "界面字体",
        summary: "侧栏、列表和按钮的字体",
        details: "推荐里只列能完整显示简体中文、至少两种粗细的字体。日文、韩文字体缺简化字，一句话里会混两种字形，放在「其它」里。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          HStack(alignment: .center, spacing: DesignTokens.Space.md) {
            Text("字体")
              .themedFont(.body)
            Spacer(minLength: DesignTokens.Space.md)
            fontPicker(
              title: "界面字体",
              selection: $uiFontRaw,
              themeLabel: "跟随主题",
              themeTag: UIFontSelection.defaultStoredValue,
              recommended: RecommendedFonts.ui(),
              identifier: "appearance-ui-font-picker"
            )
          }
          uiFontPreview
        }
      }

      // 字体选择和字号预览原来是两张卡：选完字体看不到效果，调完字号才在另一张卡
      // 里看见样子，来回要跳两次。字体选择本身自带「阅读字体选择+预览」的性质
      // （不看渲染结果判断不出中文标点会不会裂开），字号又要用同一段预览验证效果，
      // 合成一张卡后调哪个都当场看得见。
      settingCard(
        title: "阅读字体",
        // 这句必须跟着 ReadingFontSelection.resolved 一起改。原来写的是
        // 「浅色使用衬线、其它使用无衬线」——那是 New York 时期的行为，
        // 字体改成中文家族后就成了错的文案。
        summary: "只改正文的字体",
        details: "只列带中文字形的字体。New York、Georgia 这类只有西文字形，中文会逐字换字体、标点后裂缝，所以不列。日文字体缺部分简化字，不进推荐。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          // 无衬线 / 宋体一键切换：宋体是长文最常被选的替代，不该藏在下拉的第二组里。
          // 只在本机装了思源宋体时出现——Songti SC 在 16.5pt 上发虚，不值得给一键位。
          if let serif = editorialSerifQuickOption {
            HStack(alignment: .center, spacing: DesignTokens.Space.md) {
              Text("风格")
                .themedFont(.body)
              Spacer(minLength: DesignTokens.Space.md)
              Picker("阅读风格", selection: Binding(
                get: { readingFontRaw == serif ? serif : ReadingFontSelection.defaultStoredValue },
                set: { readingFontRaw = $0 }
              )) {
                Text("黑体").tag(ReadingFontSelection.defaultStoredValue)
                Text("宋体").tag(serif)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .settingsControlWidth()
              .accessibilityIdentifier("appearance-reading-style")
            }
          }
          HStack(alignment: .center, spacing: DesignTokens.Space.md) {
            Text("字体")
              .themedFont(.body)
            Spacer(minLength: DesignTokens.Space.md)
            fontPicker(
              title: "阅读字体",
              selection: $readingFontRaw,
              themeLabel: "跟随主题",
              themeTag: ReadingFontSelection.defaultStoredValue,
              recommended: RecommendedFonts.reading(),
              identifier: "appearance-reading-font-picker"
            )
          }

          Divider()

          // 字号滑块和字体下拉同一列右对齐；说明收进标签下方一行 caption。
          HStack(alignment: .center, spacing: DesignTokens.Space.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
              Text("正文字号")
                .themedFont(.body)
              Text("标题与引用按同一比例跟着缩放。")
                .themedFont(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Space.md)
            HStack(spacing: DesignTokens.Space.sm) {
              Slider(
                value: $readingFontSizeRaw,
                in: Double(ReadingFontSize.minimum)...Double(ReadingFontSize.maximum),
                step: Double(ReadingFontSize.step)
              )
              .accessibilityIdentifier("appearance-reading-font-size-slider")
              Text(String(format: "%.1f", readingFontSizeRaw))
                .themedFont(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            }
            .settingsControlWidth()
          }

          readingFontPreview
        }
      }
    }
  }

  // MARK: - 生成与数据

  /// 自动处理管线卡底部那一行「内容发去哪」。
  ///
  /// 只给 host 不给完整 URL：日常要回答的是「发给谁、用哪个模型」，
  /// `https://opencode.ai/zen/v1` 里真正有信息量的就是 `opencode.ai`。
  /// 完整 Base URL 在同一张卡的「了解更多」里。
  private var dataDestinationLine: (message: String, symbol: String) {
    guard let destination = model.dataDestinationDisplay else {
      return ("配好模型后，这里显示发往哪儿", "arrow.up.doc")
    }
    if model.isLocalEndpoint {
      return ("将发送到这台 Mac 上运行的 \(destination.provider) · \(destination.model)", "desktopcomputer")
    }
    return ("将发送到 \(destination.provider) · \(destination.model)", "arrow.up.doc")
  }

  // MARK: - 工序总览与各工序页（2026-09-28 设置按工序重组；2026-10-01 收集之后五道）

  private var overviewTab: some View {
    SettingsPlainPage {
      pageHeader(for: .generation, caption: "新内容按顺序处理；实心自动，空心手动")
      SettingsProcessChain(
        isAuto: isAuto,
        sealColor: settingsTheme.seal,
        primaryText: settingsTheme.primaryText,
        secondaryText: settingsTheme.secondaryText,
        onSelect: { step in
          withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
            navigate(to: SettingsTab.allCases.first { $0.step == step } ?? .generation)
          }
        },
        onToggleAuto: toggleAutoFromChain
      )
      .padding(.vertical, DesignTokens.Space.sm)
      if let chainAutoNotice {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
          SettingsInlineNotice(message: chainAutoNotice, tone: .warning)
          Button("添加模型") {
            self.chainAutoNotice = nil
            selectedTab = .service
          }
          .buttonStyle(.appQuiet)
          .accessibilityIdentifier("settings-chain-open-service")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-chain-auto-notice")
      }
      preferencesStatusNotice
    }
  }

  /// 换到某一项：合并后的页和要滚到的那一节（2026-10-04 设置合并）。
  private func navigate(to tab: SettingsTab) {
    let destination = tab.destination
    settingsAnchor = destination.anchor
    selectedTab = destination.page
  }

  /// 收集：剪贴板检测，加上原来三个子页（浏览器支持、站点登录、评论）整段并进来（2026-10-04）。
  /// 原来这三行都只有一个「去设置」按钮，点了跳到侧栏里本来就有的页，等于同一个入口放两处。
  private var captureTab: some View {
    SettingsPlainPage {
      stepHeader(.capture, caption: "从浏览器、链接、文件收进来")
      SettingsRowGroup {
        clipboardDetectionRow
      }
      SettingsEmbeddedSection(anchor: SettingsTab.browserSupport.rawValue) {
        BrowserSupportSettingsView(model: browserSupport, appModel: appModel)
      }
      SettingsEmbeddedSection(anchor: SettingsTab.siteLogin.rawValue) {
        SiteLoginSettingsView(mediaStorage: mediaStorage, browserSupport: browserSupport,
                              openBrowserSupport: { navigate(to: .browserSupport) })
      }
      SettingsEmbeddedSection(anchor: SettingsTab.comments.rawValue) {
        commentsTab
      }
    }
  }

  /// 转写：本机 / 在线转写、图片识别（原在「模型服务」页顶上，改不了的一行），加上视频存储。
  private var recordTab: some View {
    SettingsPlainPage {
      stepHeader(.record, caption: "视频录音转成文字，本机免费")
      SettingsRowGroup {
        localTranscriptionRow
        onlineTranscriptionRow
        imageRecognitionRow
      }
      preferencesStatusNotice
      SettingsEmbeddedSection(anchor: SettingsTab.mediaStorage.rawValue) {
        MediaStorageSettingsView(model: mediaStorage)
      }
    }
  }

  /// AI 处理：校对、总结、翻译、脑图四道工序一页（2026-10-04 设置合并）。四道都调用模型，
  /// 最上面是它们共用的默认模型和输出语言；每一节保留自己的印和「自动」开关。
  private var processingTab: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: SettingsTab.processing.title,
        symbol: SettingsTab.processing.symbol,
        caption: "以下几步都要用 AI 模型",
        fill: sidebarChipFill(.processing)
      )
      SettingsRowGroup {
        summaryAssignmentRow
        outputLanguageRow
      }
      processingSection(.proof) {
        stepHeader(.proof, caption: "改错字、补标点、加小标题", compact: true)
        if model.autoTidyTranscription, !model.autoTranscribeNewCaptures {
          SettingsInlineNotice(message: "「转写 · 录」是手动：新内容不会自动转写，你手动转完会接着校对。", tone: .warning)
        }
        SettingsRowGroup {
          tidyAssignmentRow
        }
      }
      processingSection(.summary) {
        stepHeader(.summary, caption: "给每条写一份总结，读原文、不读译文", compact: true)
        advancedCard(title: "高级：总结要求") { summaryPromptSection }
      }
      processingSection(.translation) {
        stepHeader(.translation, caption: "外文标题自动译成中文", autoLabel: "翻译标题", compact: true)
        SettingsRowGroup {
          translationAssignmentRow
        }
        if let historyModel {
          titleBackfillRow(historyModel)
            .padding(.vertical, DesignTokens.Space.sm)
            .padding(.horizontal, DesignTokens.Space.lg)
            .modifier(SettingsThemedCardChrome())
        }
        advancedCard(title: "高级：分段翻译") { translationConcurrencyRow }
      }
      processingSection(.mindMap) {
        stepHeader(.mindMap, caption: "把内容整理成脑图", compact: true)
        if model.autoMindMapNewCaptures, !model.autoSummarizeNewCaptures {
          SettingsInlineNotice(message: "「总结 · 摘」是手动：脑图会直接读原文，效果通常不如先总结。", tone: .warning)
        }
      }
      preferencesStatusNotice
    }
  }

  /// 「AI 处理」里的一道工序：上面一道细线，`.id` 供从别处跳过来定位。
  private func processingSection<Content: View>(_ tab: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
      Rectangle().fill(settingsTheme.hairline).frame(height: 1)
      content()
    }
    .id(tab.rawValue)
  }

  /// 数据与备份：备份、知识库同步、按意思搜，加上原来在「处理流程」里的发送授权记录。
  private var dataTab: some View {
    SettingsPlainPage {
      pageHeader(for: .dataBackup, caption: "备份、知识库、按意思搜和发送授权")
      SettingsEmbeddedSection(anchor: SettingsTab.dataBackup.rawValue, showsHeader: false) {
        DataBackupSettingsView()
      }
      SettingsEmbeddedSection(anchor: SettingsTab.knowledgeVault.rawValue) {
        KnowledgeVaultSettingsView(model: knowledgeVault)
      }
      if let service = historyModel?.semanticSearch {
        SettingsEmbeddedSection(anchor: SettingsTab.semanticSearch.rawValue) {
          SemanticSearchSettingsView(service: service)
        }
      }
      sendAuthorizationSection
    }
  }

  private var commentsTab: some View {
    SettingsPlainPage {
      pageHeader(for: .comments, caption: "收集时顺带存前几条评论，免费")
      SettingsRowGroup {
        SettingsRow(
          title: "自动保存",
          caption: "不用在扩展里逐条勾选"
        ) {
          Toggle("", isOn: autoSaveCommentsBinding)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("自动保存评论")
            .accessibilityIdentifier("settings-comments-auto-save")
        }
        SettingsRow(
          title: "默认条数",
          caption: commentLimitSaveFailed
            ? "保存失败，请重试；这次仍按之前的条数存。"
            : "下面没有单独设的平台都按这个数。",
          details: "适用于 Reddit、论坛、X、YouTube、B 站、知乎、抖音、小红书。不够数时扩展会往下翻，够了或到底就停，再滚回原位置。"
        ) {
          SettingsMenuPicker(
            sections: [CapturePreferencesStore.commentLimitChoices.map { .init(value: $0, title: "\($0) 条") }],
            selection: commentLimitSelection,
            identifier: "capture-comment-limit"
          )
          .accessibilityLabel("默认评论条数")
        }
      }
      Text("按平台")
        .themedFont(.caption)
        .tracking(2)
        .foregroundStyle(settingsTheme.secondaryText)
        .padding(.top, DesignTokens.Space.sm)
      SettingsRowGroup {
        ForEach(CapturePreferencesStore.commentPlatforms, id: \.key) { platform in
          SettingsRow(title: platform.title) {
            SettingsMenuPicker(
              sections: [
                [.init(value: Self.followDefaultCommentLimit, title: "跟随默认"), .init(value: CapturePreferencesStore.commentsDisabled, title: "不存")],
                CapturePreferencesStore.commentLimitChoices.map { .init(value: $0, title: "\($0) 条") },
              ],
              selection: platformCommentLimitSelection(platform.key),
              identifier: "capture-comment-limit-\(platform.key)"
            )
            .accessibilityLabel("\(platform.title)评论条数")
          }
        }
      }
    }
  }

  private func advancedCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    let body = content()
    return VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      DisclosureGroup(title) {
        body
          .padding(.top, DesignTokens.Space.md)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .themedFont(.headline)
    }
    .padding(.vertical, DesignTokens.Space.md)
    .padding(.horizontal, DesignTokens.Space.lg)
    .modifier(SettingsThemedCardChrome())
  }

  /// 按平台下拉里代表「跟随默认」的哨兵值（真实条数是 0 或 10–100）。
  private static let followDefaultCommentLimit = -1

  private func platformCommentLimitSelection(_ platform: String) -> Binding<Int> {
    Binding(
      get: { commentLimitsByPlatform[platform] ?? Self.followDefaultCommentLimit },
      set: { value in
        let stored: Int? = value == Self.followDefaultCommentLimit ? nil : value
        if let stored { commentLimitsByPlatform[platform] = stored } else { commentLimitsByPlatform.removeValue(forKey: platform) }
        do {
          try CapturePreferencesStore.standard().setCommentLimit(stored, forPlatform: platform)
          commentLimitSaveFailed = false
        } catch {
          commentLimitSaveFailed = true
        }
      }
    )
  }

  private var autoSaveCommentsBinding: Binding<Bool> {
    Binding(
      get: { autoSaveComments },
      set: { value in
        autoSaveComments = value
        do {
          try CapturePreferencesStore.standard().setAutoSaveComments(value)
          commentLimitSaveFailed = false
        } catch {
          commentLimitSaveFailed = true
        }
      }
    )
  }

  // MARK: - 从「生成偏好」拆出来的部件（2026-09-28 设置按工序重组，各页复用）

  private var outputLanguageRow: some View {
    SettingsRow(
      title: "输出语言",
      caption: "总结、翻译等生成结果统一用这个语言。",
      details: "生成时把语言要求加进提示里；用哪个模型在「默认模型」里选。"
    ) {
      VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
        SettingsMenuPicker(
          sections: [
            Self.outputLanguagePresets.map { .init(value: $0, title: $0) },
            [.init(value: Self.customOutputLanguageTag, title: "自定义…")],
          ],
          selection: outputLanguageSelection,
          identifier: "output-language"
        )
        .accessibilityLabel("输出语言")
        if showsCustomOutputLanguageField {
          TextField("例如：Italiano", text: $model.targetLanguage)
            .textFieldStyle(.roundedBorder)
            .settingsControlWidth()
            .accessibilityLabel("自定义语言")
            .accessibilityIdentifier("output-language-custom")
        }
      }
    }

  }

  private var clipboardDetectionRow: some View {
    SettingsRow(
      title: "粘贴提醒",
      caption: "复制链接后切回来，会问要不要存",
      details: "只在切回汲作的那一刻看一眼剪贴板，只认链接，其它内容不读、不留、不外发。关掉后仍可手动粘贴。"
    ) {
      Toggle("", isOn: $isClipboardLinkDetectionEnabled)
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("粘贴提醒")
        .accessibilityIdentifier("capture-clipboard-link-detection")
    }

  }

  /// 数据去向与已记住的发送授权：讲的是「自动处理会把内容发出去」这件事，放在工序总览底部。
  @ViewBuilder private var sendAuthorizationSection: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      // 数据去向紧贴造成出网的开关；必须留在 DisclosureGroup 外面。
      SettingsCrossReference(
        message: dataDestinationLine.message,
        systemImage: dataDestinationLine.symbol
      )
      .accessibilityIdentifier("data-destination-card")

      DisclosureGroup("了解更多") {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
          Text("开了就自动执行，不再每次确认；第一次用某个服务商仍会问一次。本机转写不联网；标题、校对、总结、脑图只发文字；手动转写完也会接着校对。")
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let identity = model.dataDestinationCard {
            LabeledContent("服务地址", value: identity.normalizedBaseURL)
          }
        }
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, DesignTokens.Space.xs)
      }
      .themedFont(.subheadline)

      Rectangle().fill(settingsTheme.hairline).frame(height: 1)
        .padding(.vertical, DesignTokens.Space.xs)

      // 发送授权并进这张卡的底部：它讲的就是「自动处理会把内容发出去」这件事的
      // 另一面。只提供「清除已记住记录」，不虚构逐项撤销。
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          Text("发送授权").themedFont(.body)
          Text(consentRevokeNotice ?? "第一次发给服务商时问过你的记录")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: DesignTokens.Space.md)
        // 清除之后每一项都会重新问一遍，是一次会改变后续行为的重置动作：危险色 +
        // 先问一句。清除本身没有可见效果，所以结果仍然用左边那行反馈。
        Button("清除记录") { isConsentRevokeConfirmationPresented = true }
          .buttonStyle(.appDestructive(appTheme.danger))
          .accessibilityIdentifier("revoke-remembered-consents")
          .confirmationDialog(
            "清除发送授权？",
            isPresented: $isConsentRevokeConfirmationPresented,
            titleVisibility: .visible
          ) {
            Button("清除记录", role: .destructive) {
              Task {
                let cleared = await appModel.revokeRememberedConsents()
                consentRevokeNotice = cleared
                  ? "已清除。下一次发送会重新问你一遍。"
                  : "没清除成功，授权还是原样，请再点一次。"
              }
            }
            .accessibilityIdentifier("revoke-remembered-consents-confirm")
            Button("取消", role: .cancel) {}
          } message: {
            Text("之后每个服务商、每项在线功能都会重新问你一次。内容、模型和密钥不受影响。")
          }
      }
    }
    .padding(.vertical, DesignTokens.Space.md)
    .padding(.horizontal, DesignTokens.Space.lg)
    .modifier(SettingsThemedCardChrome())
  }

  private var translationConcurrencyRow: some View {
    HStack(alignment: .center, spacing: DesignTokens.Space.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text("分段翻译")
          .themedFont(.body)
        Text("长文分几段同时翻，段越多越快")
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: DesignTokens.Space.md)
      Picker("分段翻译", selection: $model.translationConcurrency) {
        ForEach(
          Array(ModelPreferences.translationConcurrencyRange),
          id: \.self
        ) { value in
          Text(value == 1 ? "不分段" : "\(value) 段").tag(value)
        }
      }
      .labelsHidden()
      .frame(width: 120)
      .accessibilityIdentifier("translation-concurrency")
    }

  }

  private var summaryPromptSection: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      Text("总结要求")
        .themedFont(.body)
      Text("不管用默认还是自己写的要求，都会加上输出语言。要求存在本机，生成时随正文发给模型。")
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextEditor(text: $model.summaryPrompt)
        .themedFont(.callout)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 96, maxHeight: 140)
        .padding(DesignTokens.Space.sm)
        .background(settingsTheme.isNative ? Color(nsColor: .textBackgroundColor) : settingsTheme.listPane)
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(settingsTheme.hairline, lineWidth: 1))
        .accessibilityIdentifier("summary-prompt")
      HStack {
        Spacer(minLength: 0)
        // 重置会把用户自己写的提示词整段覆盖掉，而且没有撤销——这一栏里
        // 唯一不可逆的动作，必须先问一句，并且不能和「了解更多」一样低调。
        Button("恢复默认") { isPromptResetConfirmationPresented = true }
          .buttonStyle(.appDestructive(appTheme.danger))
          .disabled(model.preferencesState == .saving)
          .accessibilityIdentifier("reset-summary-prompt")
          .confirmationDialog(
            "总结要求恢复默认？",
            isPresented: $isPromptResetConfirmationPresented,
            titleVisibility: .visible
          ) {
            Button("恢复默认", role: .destructive) { model.resetSummaryPrompt() }
              .accessibilityIdentifier("reset-summary-prompt-confirm")
            Button("取消", role: .cancel) {}
          } message: {
            Text("你写的会被覆盖，没法撤销，需要的话先复制。已生成的总结不变。")
          }
      }
    }
  }

  @ViewBuilder private var preferencesStatusNotice: some View {
    // 即时生效，正常时安静；只有保存失败才需要一行说明。
    if case .failed = model.preferencesState {
      SettingsInlineNotice(message: model.preferencesStatusText, tone: .danger)
        .accessibilityIdentifier("model-preferences-status")
    } else if model.preferencesState == .saving {
      Text(model.preferencesStatusText)
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("model-preferences-status")
    }
  }

  // MARK: - 设置卡片零件

  /// 统一卡片见 `SettingsCard`。这里只是保留原调用形式，避免各页各写一份。
  @ViewBuilder
  private func settingCard(
    title: String,
    summary: String,
    details: String? = nil,
    controlWidth: SettingsControlWidth = .compact,
    @ViewBuilder control: @escaping () -> some View
  ) -> some View {
    SettingsCard(
      title: title,
      summary: summary,
      details: details,
      controlWidth: controlWidth,
      control: control
    )
  }

  /// 主控件画在标题行右端的卡片。见 `SettingsCard.titleAccessory` 的注释。
  private func settingCard(
    title: String,
    summary: String,
    details: String? = nil,
    controlWidth: SettingsControlWidth = .compact,
    @ViewBuilder titleAccessory: @escaping () -> some View,
    @ViewBuilder control: @escaping () -> some View
  ) -> some View {
    SettingsCard(
      title: title,
      summary: summary,
      details: details,
      controlWidth: controlWidth,
      control: control,
      titleAccessory: titleAccessory
    )
  }

  /// 从已添加的模型里选，而不是让人手打模型名。
  ///
  /// 模型名（`whisper-large-v3-turbo` 这种）拼错不会当场报错，只会在真正调用时
  /// 失败，而失败信息来自服务端、未必说得清是名字错了。已经添加过的模型是现成的
  /// 事实来源，让人选比让人背准确得多。
  ///
  /// 保留「自定义…」是因为库里未必有想用的那个模型；但那是例外路径，不该是默认。
  ///
  /// 空值有明确语义（「使用总结模型」「只用本机转写」），所以它是选项之一而不是
  /// 一个需要清空输入框才能达到的状态。
  @ViewBuilder
  private func modelChoicePicker(
    label: String,
    emptyOptionTitle: String,
    options: [ProviderSettingsViewModel.LibraryEntryDisplay],
    text: Binding<String>,
    identifier: String
  ) -> some View {
    SettingsMenuPicker(
      sections: modelChoiceSections(
        emptyOptionTitle: emptyOptionTitle, options: options, current: text.wrappedValue
      ),
      selection: Binding(
        get: { isCustomModelName(text.wrappedValue, in: options) ? Self.customModelTag : text.wrappedValue },
        set: { selected in
          // 选「自定义…」时不清空已有值，否则改一次下拉就丢掉手填的名字；
          // 从预设切到自定义时先放一个空格占位，让输入框出现。
          // 旧的手填名字只作为「当前值」展示，选它等于不变。
          if selected != Self.customModelTag {
            text.wrappedValue = selected
          }
        }
      ),
      identifier: identifier
    )
    .accessibilityLabel(label)
  }

  /// 下拉的分组：空值语义项、已添加的模型（带服务商副标题），以及以前手填、现在不在模型服务里的旧值。
  private func modelChoiceSections(
    emptyOptionTitle: String,
    options: [ProviderSettingsViewModel.LibraryEntryDisplay],
    current: String
  ) -> [[SettingsMenuPicker<String>.Option]] {
    let isCustom = isCustomModelName(current, in: options)
    var sections: [[SettingsMenuPicker<String>.Option]] = [[.init(value: "", title: emptyOptionTitle)]]
    if !options.isEmpty {
      sections.append(options.map { .init(value: $0.modelName, title: $0.modelName, subtitle: $0.title) })
    }
    // 不再提供「自定义…」。以前手填过的名字仍显示成当前值，免得下拉显示成空白。
    let customTitle = current.trimmingCharacters(in: .whitespaces)
    if isCustom, !customTitle.isEmpty {
      sections.append([.init(value: Self.customModelTag, title: customTitle, subtitle: "不在模型服务里")])
    }
    return sections
  }

  private func isCustomModelName(
    _ name: String, in options: [ProviderSettingsViewModel.LibraryEntryDisplay]
  ) -> Bool {
    !name.isEmpty && !options.contains { $0.modelName == name }
  }

  /// 下拉里代表「自定义…」的哨兵值。用一个不可能成为模型名的字符串，
  /// 避免和真实模型名撞车。
  private static let customModelTag = "__linkdigest_custom_model__"

  /// 开关只管以后进来的新内容；开关上线前、或批量抓取时漏掉的旧标题在这里补。
  /// 会调用模型，所以先数、再确认、再执行，全程可停。
  @ViewBuilder
  private func titleBackfillRow(_ history: HistoryViewModel) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text("补译标题")
          Text(titleBackfillCaption(history.titleBackfillState))
            .themedFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        switch history.titleBackfillState {
        case .idle, .failed, .finished:
          Button("检查") {
            history.countTitleBackfillCandidates(outputLanguage: model.outputLanguage)
          }
          .accessibilityIdentifier("title-backfill-count")
        case .counting:
          ProgressView().controlSize(.small)
        case let .ready(count):
          if count > 0 {
            Button("译成中文…") { isTitleBackfillConfirmationPresented = true }
              .accessibilityIdentifier("title-backfill-start")
          } else {
            Button("完成") { history.resetTitleBackfill() }
          }
        case .running:
          Button("停止") { history.cancelTitleBackfill() }
            .accessibilityIdentifier("title-backfill-cancel")
        }
      }
      if case let .running(done, total) = history.titleBackfillState {
        ProgressView(value: Double(done), total: Double(max(total, 1)))
      }
    }
    .padding(.top, DesignTokens.Space.xs)
    .accessibilityIdentifier("title-backfill-row")
    .confirmationDialog(
      titleBackfillConfirmationTitle(history.titleBackfillState),
      isPresented: $isTitleBackfillConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("开始翻译") {
        history.startTitleBackfill(outputLanguage: model.outputLanguage, model: model.activeSummaryModelName)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只把标题发给模型，排队翻，随时能停。原标题保留，会用掉少量额度。")
    }
  }

  private func titleBackfillConfirmationTitle(_ state: HistoryViewModel.TitleBackfillState) -> String {
    if case let .ready(count) = state { return "把 \(count) 条外文标题译成中文？" }
    return "把外文标题译成中文？"
  }

  private func titleBackfillCaption(_ state: HistoryViewModel.TitleBackfillState) -> String {
    switch state {
    case .idle: "开关只影响以后存的内容。点「检查」看看库里还有多少条外文标题。"
    case .counting: "正在检查…"
    case let .ready(count): count > 0 ? "有 \(count) 条外文标题还没译成中文。" : "没有需要翻译的外文标题。"
    case let .running(done, total): "正在翻译 \(done) / \(total)，可以关掉设置窗口，后台继续。"
    case let .finished(localized, total): "已处理 \(total) 条，其中 \(localized) 条译成了中文。"
    case .failed: "没能读取资料库，请稍后再试。"
    }
  }

  // MARK: - 共用构件

  /// 服务商卡片：图标 + 名字 + 一句能力说明，多列排布。
  ///
  /// 名字和说明都限一行并截断：卡片一旦因为某一家名字长就换行，整行卡片的高度
  /// 都会被它拉齐，网格立刻变得参差。说明本来就只有「支持在线音频转写」和
  /// 「OpenAI-compatible」两种，截断不会丢信息。
  private func providerCard(_ preset: ProviderPreset) -> some View {
    let selected = model.selectedPreset == preset
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        providerIcon(preset)
        Text(preset.displayName)
          .themedFont(.subheadline, weight: .semibold)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        // 「能不能在线转写」是这张网格里唯一影响选择的能力差异，其余各家在这一层
        // 没有区别。它只在少数几家成立，所以用徽标标出来，而不是给每张卡都写一行。
        if preset.supportsOnlineTranscription {
          assignmentBadge("转写")
        }
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.tint)
        }
      }
      Text(preset.endpointHost)
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .modifier(SettingsCardChrome(selected: selected, theme: appTheme))
  }

/// 「模型服务」组头与「选择服务商」网格共用同一张卡片外壳，避免两套 chrome 漂移。
  /// 模型服务已改为单列展开；选择服务商编辑器仍用多列网格。
  private struct SettingsCardChrome: ViewModifier {
    let selected: Bool
    let theme: HistoryThemeTokens
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      content
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .fill(
              selected
                ? theme.accent.opacity(0.12)
                : (isHovering ? theme.primaryText.opacity(0.035) : theme.card)
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .animation(
          DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
          value: isHovering
        )
        .onHover { isHovering = $0 }
    }
  }

  /// - Parameter fallbackName: 没有官方图标时,首字母取自这个名字。
  ///   传服务商真名(如 opencode.ai)而不是预设显示名——自定义预设的显示名是
  ///   「自定义」,取首字母会得到一个对用户毫无意义的「自」。
  @ViewBuilder private func providerIcon(
    _ preset: ProviderPreset, fallbackName: String? = nil
  ) -> some View {
    if let icon = ProviderIconCatalog.image(for: preset) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
    } else {
      // 没有官方图标时画一个中性徽标,不再用「哈希色 + 预设显示名首字母」。
      //
      // 那套兜底有两个问题:自定义服务商的预设显示名是「自定义」,于是方块里
      // 印着一个「自」字,对用户没有任何意义;而 hue = hash % 360 出来的颜色
      // 是随机的,和这个应用的米色/橙色调必然不搭——十个模型就是十种杂色。
      //
      // 现在统一成描边的中性方块,里面是服务商真名的首字母(opencode.ai → O)。
      Text(ProviderIconCatalog.fallbackInitial(for: fallbackName ?? preset.displayName))
        .font(.system(size: BadgeTypography.size, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .background(
          Color.secondary.opacity(0.12),
          in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.22))
        )
    }
  }

  /// 操作行：按钮在左，状态说明靠右并允许换行，避免长状态文案把整行撑开。
  @ViewBuilder private func actionRow(
    status: String,
    color: Color,
    showsProgress: Bool,
    statusIdentifier: String,
    @ViewBuilder button: () -> some View
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      button()
      if showsProgress { ProgressView().controlSize(.small) }
      Spacer(minLength: 16)
      Text(status)
        .foregroundStyle(color)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(statusIdentifier)
    }
  }

  @ViewBuilder private func modelSelector(
    title: String,
    selection: Binding<String>,
    forTranslation: Bool
  ) -> some View {
    if model.modelCatalogState == .loaded, !model.availableModels.isEmpty {
      Picker(title, selection: selection) {
        if selection.wrappedValue.isEmpty {
          Text("请选择模型").tag("")
        } else if !model.availableModels.contains(selection.wrappedValue) {
          Text("当前：\(selection.wrappedValue)").tag(selection.wrappedValue)
        }
        ForEach(forTranslation ? filteredTranslationModels : model.filteredModels, id: \.self) { Text($0).tag($0) }
      }
      .accessibilityIdentifier(forTranslation ? "translation-model-picker" : "provider-model-picker")
      LabeledContent("搜索模型") {
        TextField("输入关键词过滤", text: forTranslation ? $translationModelSearchQuery : $model.modelSearchQuery)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
          .accessibilityIdentifier(forTranslation ? "translation-model-search" : "provider-model-search")
      }
    } else if model.isManualModelEntryEnabled || forTranslation {
      LabeledContent(title) {
        TextField("手动填写", text: selection)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
          .disabled(model.isSaving || model.isConfigurationLoading)
          .accessibilityIdentifier(forTranslation ? "translation-model-name" : "provider-model-name")
      }
    } else if model.hasConfiguredAPIKey, !model.modelName.isEmpty {
      LabeledContent(title, value: model.modelName)
    } else {
      LabeledContent(title) {
        Text("读取列表后选择").foregroundStyle(.secondary)
      }
    }
  }

  /// 翻译模型使用独立搜索词，避免与总结模型共享同一个过滤状态。
  private var filteredTranslationModels: [String] {
    let query = translationModelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return query.isEmpty ? model.availableModels : model.availableModels.filter { $0.lowercased().contains(query) }
  }

  // MARK: - 输出语言选择

  private var showsCustomOutputLanguageField: Bool {
    isCustomOutputLanguage || !Self.outputLanguagePresets.contains(model.targetLanguage)
  }

  private var outputLanguageSelection: Binding<String> {
    Binding(
      get: {
        if isCustomOutputLanguage || !Self.outputLanguagePresets.contains(model.targetLanguage) {
          return Self.customOutputLanguageTag
        }
        return model.targetLanguage
      },
      set: { newValue in
        if newValue == Self.customOutputLanguageTag {
          isCustomOutputLanguage = true
        } else {
          isCustomOutputLanguage = false
          model.targetLanguage = newValue
        }
      }
    )
  }

  // MARK: - 状态颜色与文案

  private var preferencesStatusColor: Color {
    if case .failed = model.preferencesState { return appTheme.danger }
    if case .saved = model.preferencesState { return appTheme.success }
    return .secondary
  }
  private var statusColor: Color { if case .failed = model.state { return appTheme.danger }; return .secondary }
  private var connectionStatusColor: Color {
    if case .failure = model.connectionTestState { return appTheme.danger }
    if case .success = model.connectionTestState { return appTheme.success }
    return .secondary
  }
  private let unsavedChangesText = "有未保存更改，请先保存后再测试"
  private var testConnectionBlocked: Bool { !model.canTestConnection || !apiKeyInput.isEmpty }
  private var connectionStatusText: String {
    if model.hasUnsavedIdentityChanges || model.isReplacingAPIKey || !apiKeyInput.isEmpty { return unsavedChangesText }
    return model.connectionTestStatusText
  }
}

/// 主题色卡。
///
/// 主题从 3 套涨到 6 套之后 segmented 就装不下了：中文名加图标挤在一行，
/// 每格窄到只剩两个字。但真正的问题不是宽度——是「浅色」「石楠」「高对比」
/// 这几个名字并排放着，选之前根本不知道差在哪。主题是纯视觉的东西，
/// 让人靠名字猜颜色本身就是错的分工。
///
/// 所以每格直接把该主题的画布色画出来，右下角压一条强调色：
/// 画布色分开浅色系和深色系，强调色（品牌橙 / 橄榄 / 莓红 / 纯黑）分开
/// 同为近白底的浅色、石楠、珊瑚和高对比。
private struct ThemeSwatchPicker: View {
  @Binding var selection: String
  /// 选中框走主题强调色。`Color.accentColor` 是 App 级强调色（默认系统蓝），
  /// 在色卡这种「一堆颜色里挑一个」的地方尤其扎眼。
  @Environment(\.appTheme) private var appTheme

  // adaptive 而不是固定列数：设置窗口可以拖宽，固定 5 列在窄窗口会溢出，
  // 固定 3 列在宽窗口又留一大片空白。
  private let columns = [GridItem(.adaptive(minimum: 74, maximum: 104), spacing: 10, alignment: .leading)]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      ForEach(AppearanceTheme.allCases) { theme in
        // 这里**不要**加 `withAnimation` 的交叉淡入淡出。试过，实测更慢：
        // 不加是 234ms 一次重排，加了变成 344ms 摊在 ~13 帧上（每帧 26ms，
        // 超过 16.7ms 的帧预算），既掉帧总量又更大。一次干脆的重排比一段
        // 卡顿的过渡好。
        Button { selection = theme.rawValue } label: { swatch(theme) }
          .buttonStyle(.plain)
          .help(theme.displayName)
          .accessibilityLabel(theme.displayName)
          .accessibilityAddTraits(selection == theme.rawValue ? [.isSelected] : [])
          .accessibilityIdentifier("appearance-theme-\(theme.rawValue)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("appearance-theme-picker")
  }

  private func swatch(_ theme: AppearanceTheme) -> some View {
    let isSelected = selection == theme.rawValue
    return VStack(spacing: 5) {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(theme.swatchBase)
        .frame(height: 38)
        .overlay(alignment: .bottomTrailing) {
          Capsule()
            .fill(theme.swatchAccent)
            .frame(width: 16, height: 5)
            .padding(6)
        }
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(theme.tokens.hairline)
        }
        .overlay(alignment: .topLeading) {
          // 选中态不只靠外圈描边：描边是颜色差异，色卡本身就是一堆颜色，
          // 靠颜色区分颜色最不可靠。勾是形状，一眼且不依赖辨色能力。
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(theme.swatchAccent, theme.swatchBase)
              .padding(4)
          }
        }
      Text(theme.displayName)
        .themedFont(.caption2)
        .fontWeight(isSelected ? .semibold : .regular)
        .lineLimit(1)
    }
    .padding(3)
    .background {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(isSelected ? appTheme.accent : .clear, lineWidth: 2)
    }
    .contentShape(Rectangle())
  }
}

/// 「推荐服务商 → 填入」打开的添加窗口：默认焦点给密钥框（服务地址已经填好了）。
/// 其它入口不改默认焦点。
private struct PrefilledAPIKeyFocus: ViewModifier {
  let isOn: Bool
  let focus: FocusState<Bool>.Binding

  @ViewBuilder func body(content: Content) -> some View {
    if isOn {
      content.defaultFocus(focus, true)
    } else {
      content
    }
  }
}

/// 文字在前、小图标在后：外链的「名字 ↗」。
private struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 2) {
      configuration.title
      configuration.icon.imageScale(.small)
    }
  }
}
