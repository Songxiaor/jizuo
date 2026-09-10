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
    case service, generation, appearance, mediaStorage, knowledgeVault, companionSync, siteLogin, browserSupport, mcp, updates, labs
    var id: String { rawValue }
    var title: String {
      switch self {
      case .service: "模型与识别"
      case .generation: "生成偏好"
      case .appearance: "外观"
      case .mediaStorage: "视频存储"
      case .knowledgeVault: "知识库同步"
      case .companionSync: "手机同步"
      case .siteLogin: "站点登录"
      case .browserSupport: "浏览器支持"
      case .updates: "版本与更新"
      case .mcp: "MCP 连接"
      case .labs: "实验室"
      }
    }
    var symbol: String {
      switch self {
      case .service: "sparkles.rectangle.stack"
      case .generation: "text.badge.checkmark"
      case .appearance: "paintpalette"
      case .mediaStorage: "externaldrive"
      case .knowledgeVault: "folder.badge.gearshape"
      case .companionSync: "iphone.and.arrow.forward"
      case .siteLogin: "person.crop.circle.badge.checkmark"
      case .browserSupport: "puzzlepiece.extension"
      case .updates: "arrow.triangle.2.circlepath"
      case .mcp: "point.3.connected.trianglepath.dotted"
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
      allCases.filter { $0 != .labs || ExperimentalFeatures.isOfferedToUsers }
    }
  }

  /// 侧栏分组：把分类按「做什么」归成五组，而不是让人从头到尾扫一条平列表。
  ///
  /// 分组本身不控制可见性——那仍然只由 `SettingsTab.visibleCases` 一处判据决定；
  /// 这里只负责「同一批分类摆在哪个标题下面」。
  private enum SettingsTabGroup: CaseIterable, Hashable {
    case aiAndProcessing
    case readingAndAppearance
    case connection
    case dataAndStorage
    case aboutAndUpdates

    var title: String {
      switch self {
      case .aiAndProcessing: "AI与处理"
      case .readingAndAppearance: "阅读与外观"
      case .connection: "连接"
      case .dataAndStorage: "数据与存储"
      case .aboutAndUpdates: "关于与更新"
      }
    }

    var tabs: [SettingsTab] {
      switch self {
      case .aiAndProcessing: [.service, .generation]
      case .readingAndAppearance: [.appearance, .labs]
      case .connection: [.mcp, .browserSupport, .siteLogin]
      case .dataAndStorage: [.mediaStorage, .knowledgeVault, .companionSync]
      case .aboutAndUpdates: [.updates]
      }
    }

    /// 按当前可见性过滤后的分类。目前只有「实验室」会被过滤掉，
    /// 但判据统一走 `SettingsTab.visibleCases`，不在这里另写一份。
    var visibleTabs: [SettingsTab] {
      let visible = SettingsTab.visibleCases
      return tabs.filter { visible.contains($0) }
    }
  }

  private static let outputLanguagePresets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Español", "Français", "Deutsch"]
  private static let customOutputLanguageTag = "__custom__"

  @ObservedObject var model: ProviderSettingsViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject var knowledgeVault: KnowledgeVaultSettingsViewModel
  let updater: SPUUpdater
  @Bindable var companionSync: CompanionNoteSyncCoordinator
  @State private var apiKeyInput = ""
  @State private var selectedTab: SettingsTab = .service
  @State private var isCustomOutputLanguage = false
  @State private var translationModelSearchQuery = ""
  @State private var pendingDeletionID: String?
  /// 待确认「整组删除」的服务商（组名 + 该组全部模型 ID）。
  @State private var pendingGroupDeletion: LibraryProviderGroup?
  /// 「清除授权记录」按下之后的一行反馈。成功和失败都要说，因为清除本身没有可见效果。
  @State private var consentRevokeNotice: String?
  /// 当前展开的服务商。同时只展开一家：模型清单落在网格下面，同时摊开两家就分不清
  /// 哪一段属于谁。默认全部收起——归拢的意义就是先只看「有哪几家」。
  @State private var expandedLibraryProvider: String?
  @State private var activeAssignmentPicker: AssignmentPicker?
  /// 「功能与模型」里哪几行的 ⓘ 展开着。按标题记，不给六行各开一个 Bool。
  @State private var expandedAssignmentDetails: Set<String> = []
  /// 编辑模型时是否展开服务商网格。默认折叠成一行，点「更换」才展开。
  @State private var isChoosingPreset = false
  /// 自绘侧栏选中高亮的滑动锚点。见 `paperSidebarRow`。
  @Namespace private var sidebarSelectionNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(ExperimentalFeatures.workbenchKey) private var isWorkbenchEnabled = false
  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  @AppStorage(TopicSchedule.storageKey) private var topicScheduleRaw = ""
  @AppStorage(ExperimentalFeatures.hitLabKey) private var isHitLabEnabled = false

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
    .pickerStyle(.menu)
    .labelsHidden()
    .settingsControlWidth()
    .accessibilityIdentifier(identifier)
  }

  /// 界面字体预览：故意用界面里**最小**的两个字号。
  ///
  /// 界面字体的成败在 10pt 上——计数、时间戳都是这个尺寸，笔画细的字体在这里
  /// 发虚。用正文字号预览界面字体，等于避开了唯一该看的地方。
  @ViewBuilder private var uiFontPreview: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("预览（界面里最小的两个字号）")
        .themedFont(.subheadline)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        // 预览句直接用主窗口侧栏的真实文案：原来写的「未总结 / 哔哩哔哩 / 待分类」
        // 和侧栏实际显示的「待总结 / B站 / 其他」对不上，预览预览的是一套不存在的界面。
        Text("待总结 149     B站 5     其他 9")
          .themedFont(.subheadline)
        Text("2026-08-17 19:24 · 已保存到本机 · 19.6 MB")
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
          List(selection: $selectedTab) {
            ForEach(SettingsTabGroup.allCases, id: \.self) { group in
              let tabs = group.visibleTabs
              if !tabs.isEmpty {
                Section(group.title) {
                  ForEach(tabs) { tab in
                    Label {
                      Text(tab.title)
                    } icon: {
                      SettingsSidebarChip(symbol: tab.symbol, fill: sidebarChipFill(tab))
                    }
                    // 只防换行，不防截断：撑宽是下面 `.frame(minWidth:)` 的职责，
                    // 行内视图的 ideal 宽度传不出 List。
                    .lineLimit(1)
                    .tag(tab)
                    .padding(.vertical, DesignTokens.Space.xs)
                  }
                }
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
      // 中文导航（「模型与识别」「浏览器支持」）需要完整显示；不压到 200。
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
        switch selectedTab {
        case .mcp: MCPSettingsView(model: MCPController.shared)
        case .service: serviceTab
        case .generation: generationTab
        case .appearance: appearanceTab
        case .labs: labsTab
        case .mediaStorage:
          MediaStorageSettingsView(model: mediaStorage)
        case .knowledgeVault:
          KnowledgeVaultSettingsView(model: knowledgeVault)
        case .companionSync:
          CompanionNoteSyncSettingsView(model: companionSync)
        case .siteLogin:
          SiteLoginSettingsView(mediaStorage: mediaStorage, browserSupport: browserSupport,
                                openBrowserSupport: { selectedTab = .browserSupport })
        case .browserSupport:
          BrowserSupportSettingsView(model: browserSupport, appModel: appModel)
        case .updates:
          AppUpdateSettingsView(updater: updater)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // 窗口标题恒为「设置」，不跟着 selectedTab 变。原来这里写
      // `selectedTab.title`，和页内页头（`SettingsPageHeader` 的大标题）说的是
      // 同一件事，两处同时写着「视频存储」「站点登录」是重复；当前分类已经由
      // 侧栏选中态 + 页头共同表达，窗口标题不需要再报一遍。
      .navigationTitle("设置")
    }
    // 复用主界面那套工具栏主题 modifier，避免两处各写一份判据再各自漂移。
    .modifier(HistoryWindowToolbarThemeModifier(theme: settingsTheme))
    .frame(
      minWidth: 780,
      idealWidth: 900,
      maxWidth: .infinity,
      minHeight: 560,
      idealHeight: 700,
      maxHeight: .infinity
    )
    .foregroundStyle(settingsTheme.primaryText)
    .tint(settingsTheme.accent)
    .accentColor(settingsTheme.accent)
    .onAppear {
      AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw)
      if let raw = SettingsNavigationRequest.consume(), let tab = SettingsTab(rawValue: raw) {
        selectedTab = tab
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notification)) { note in
      guard let raw = note.object as? String, let tab = SettingsTab(rawValue: raw) else { return }
      selectedTab = tab
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
      pageHeader(for: .service, caption: "配置总结、翻译、转写、校对和图片识别各自要用的模型。")

      // 这张卡只剩「标签 + 控件」六行：说明全部收进各行的 ⓘ，卡片脚注也删掉——
      // 原来每行下面一段灰字、卡底再一句脚注，六个控件配了五段说明，控件密度极低，
      // 而且脚注和下一张卡的脚注讲的是同一句话。
      settingCard(
        title: "功能与模型",
        summary: "翻译和校对默认跟随总结模型；本地转写和图片识别默认本机离线。",
        details: "本地转写默认 Apple 听写、不出网。在线备用转写只用于超过 200MB、无法本机导入的视频。校对会根据标题和配文还原听写错词并补标点，看不懂的句子原样保留。图片识别固定用本机 Vision。",
        controlWidth: .full
      ) {
        capabilityAssignmentRows
      }

      // 「添加模型…」放标题行右端：它是这张卡唯一的主动作，原来孤零零缩在
      // 列表左下角，和列表内容抢同一列，看起来像列表的一项。
      settingCard(
        title: UISettingsPresentation.modelServicesCardTitle,
        summary: UISettingsPresentation.modelServicesSummary,
        details: UISettingsPresentation.modelServicesDetails,
        controlWidth: .full,
        titleAccessory: {
          Button("添加模型…") { model.beginAddModel() }
            .buttonStyle(.appProminent(settingsTheme.accent))
            .disabled(model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels)
            .accessibilityIdentifier("add-library-model")
        }
      ) {
        VStack(alignment: .leading, spacing: 0) {
          if model.libraryEntryDisplays.isEmpty {
            Text("还没有添加模型。添加后即可在上方为每个功能选择模型。")
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
    }
    .controlSize(.regular)
    .onChange(of: apiKeyInput) { oldValue, newValue in
      if oldValue != newValue { model.apiKeyDraftDidChange() }
    }
    .onChange(of: model.isEditorVisible) { _, visible in
      // 每次打开编辑器都从「已选服务商折叠成一行」开始；添加流程本来就没有
      // 已选项，会直接展开网格（见 `showsPresetGrid`）。
      if visible { isChoosingPreset = false }
    }
    // 编辑表单改成 Sheet：原来它长在列表底下，只有一行小灰字「编辑模型：服务商」
    // 提示这是编辑区，和「模型服务」列表之间没有任何分隔，用户分不清哪些字段
    // 属于列表、哪些属于正在编辑的那个模型。
    .sheet(isPresented: isEditorSheetPresented) {
      editorSheet
    }
    .confirmationDialog(
      "删除这个模型配置？",
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
      Text("对应的 API Key 会一并从本机钥匙串移除；正在使用它的功能会回到未配置或本机状态。")
    }
    .confirmationDialog(
      "删除「\(pendingGroupDeletion?.id ?? "")」下的全部 \(pendingGroupDeletion?.entries.count ?? 0) 个模型？",
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
      Text("这家服务商的 API Key 会一并从本机钥匙串移除；正在用这些模型的功能会回到未配置或本机状态。")
    }
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
  @ViewBuilder private var capabilityAssignmentRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      assignmentRow(title: UISettingsPresentation.summaryAssignmentTitle) {
        if model.libraryEntryDisplays.isEmpty {
          Text("先在下方添加模型")
            .themedFont(.body)
            .foregroundStyle(.secondary)
            .settingsControlWidth()
        } else {
          assignmentPickerButton(
            kind: .summary,
            selectedEntry: model.summaryEntryDisplays.first(where: { $0.id == model.summaryAssignmentID })
          )
        }
      }

      assignmentRow(
        title: UISettingsPresentation.translationAssignmentTitle,
        details: UISettingsPresentation.translationFollowsSummaryHint
      ) {
        preferenceModelAssignmentControl(
          title: UISettingsPresentation.translationAssignmentTitle,
          emptyOptionTitle: "跟随总结模型",
          options: model.summaryEntryDisplays,
          text: $model.translationModelName,
          identifier: "translation-model-name",
          customPlaceholder: "模型名称"
        )
      }

      assignmentRow(title: UISettingsPresentation.localTranscriptionTitle) {
        assignmentPickerButton(
          kind: .transcription,
          selectedEntry: model.transcriptionEntryDisplays.first(where: { $0.id == model.transcriptionAssignmentID })
        )
      }

      assignmentRow(
        title: UISettingsPresentation.onlineTranscriptionTitle,
        details: "给超过 200MB、无法本机导入的视频用。"
      ) {
        preferenceModelAssignmentControl(
          title: UISettingsPresentation.onlineTranscriptionTitle,
          emptyOptionTitle: "不使用：只用 Apple 本机转写",
          options: model.transcriptionEntryDisplays,
          text: $model.transcriptionModelName,
          identifier: "transcription-model-name",
          customPlaceholder: "例如 whisper-large-v3-turbo"
        )
      }

      assignmentRow(
        title: UISettingsPresentation.tidyAssignmentTitle,
        details: "根据标题和配文还原听写错词并补标点；看不懂的句子原样保留。"
      ) {
        preferenceModelAssignmentControl(
          title: UISettingsPresentation.tidyAssignmentTitle,
          emptyOptionTitle: "跟随总结模型",
          options: model.summaryEntryDisplays,
          text: $model.tidyModelName,
          identifier: "tidy-model-name",
          customPlaceholder: "模型名称"
        )
      }

      assignmentRow(title: UISettingsPresentation.imageRecognitionTitle) {
        Text("Apple Vision · 本机离线")
          .themedFont(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .settingsControlWidth()
          .accessibilityIdentifier("image-text-assignment-picker")
      }
    }
  }

  /// 「功能与模型」里的一行：标签 + 可展开的 ⓘ 在左，控件靠右。
  ///
  /// 不复用 `SettingsRow`：它自带左右 16pt 内距，而这里已经在卡片内，再套一层
  /// 会让六行比卡片标题往里缩一截。
  @ViewBuilder
  private func assignmentRow<Control: View>(
    title: String,
    details: String? = nil,
    @ViewBuilder control: () -> Control
  ) -> some View {
    let isExpanded = expandedAssignmentDetails.contains(title)
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
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
  }

  @ViewBuilder
  private func preferenceModelAssignmentControl(
    title: String,
    emptyOptionTitle: String,
    options: [ProviderSettingsViewModel.LibraryEntryDisplay],
    text: Binding<String>,
    identifier: String,
    customPlaceholder: String
  ) -> some View {
    VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
      modelChoicePicker(
        label: title,
        emptyOptionTitle: emptyOptionTitle,
        options: options,
        text: text,
        identifier: identifier
      )
      modelChoiceCustomField(
        placeholder: customPlaceholder,
        options: options,
        text: text,
        identifier: identifier
      )
    }
  }

  /// 总结 / 本地转写的选择按钮：和其它行的下拉同一宽度、同一描边，点开是分组 popover。
  ///
  /// 不用系统 `Picker`：选项要按服务商分组、每项带模型 ID 副标题，menu Picker 画不出来。
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
    return kind == .transcription ? "Apple 听写" : "未指派"
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
      Text(kind == .transcription ? "选择本地/在线转写模型" : "选择总结模型")
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
              title: "Apple 听写",
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
                  isSelected: selectedAssignmentID(for: kind) == entry.id
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
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("library-provider-group")
      // 整组删除收进组头的更多菜单：一家服务商十来个模型，一条条删太折腾。
      Menu {
        Button("删除这家的全部模型（\(group.entries.count) 个）", role: .destructive) {
          pendingGroupDeletion = group
        }
        .accessibilityIdentifier("delete-library-provider")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help("更多")
      .accessibilityLabel("这家服务商的更多操作")
      .accessibilityIdentifier("library-provider-more")
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
      .help("编辑这个模型配置")
      .accessibilityLabel("编辑这个模型配置")
      .accessibilityIdentifier("edit-library-model")
      // 删除收进更多菜单，确认对话框仍走既有 pendingDeletionID 流程。
      Menu {
        Button("删除这个模型配置", role: .destructive) {
          pendingDeletionID = entry.id
        }
        .accessibilityIdentifier("delete-library-model")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help("更多")
      .accessibilityLabel("更多操作")
      .accessibilityIdentifier("library-model-more")
    }
    .padding(.leading, DesignTokens.Space.xl)
    .frame(height: 40)
    .contentShape(Rectangle())
  }

  private func assignmentBadge(_ text: String) -> some View {
    Text(text)
      .themedFont(.caption2, weight: .semibold)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.15), in: Capsule())
      .foregroundStyle(Color.accentColor)
  }

  // MARK: - 模型编辑器

  private var isEditorSheetPresented: Binding<Bool> {
    Binding(
      get: { model.isEditorVisible },
      set: { if !$0 { model.closeEditor() } }
    )
  }

  private var editorTitle: String {
    if model.editingProfileID == nil { return "添加模型" }
    let name = model.libraryEntryDisplays.first(where: { $0.id == model.editingProfileID })?.displayName
    return name.map { "编辑模型 · \($0)" } ?? "编辑模型"
  }

  /// 添加流程没有已选服务商，直接展开网格；编辑流程默认折叠成一行，点「更换」才展开。
  private var showsPresetGrid: Bool {
    model.editingProfileID == nil || isChoosingPreset
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
        Button("测试连接") { Task { await model.testConnection() } }
          .buttonStyle(.appQuiet)
          .disabled(!model.canTestConnection || !apiKeyInput.isEmpty)
          .help(testConnectionBlocked ? unsavedChangesText : "发送极短提示验证当前已保存配置")
          .accessibilityIdentifier("test-provider-connection")
        if !model.isAddingModelBatch {
          Button("仅保存") {
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
          Link("套餐与 API 接入说明", destination: URL(string: "https://commandcode.ai/docs/provider")!)
          Link("获取 API Key", destination: URL(string: "https://commandcode.ai/docs/studio#api-keys")!)
        }
        .themedFont(.subheadline)
        .accessibilityIdentifier("command-code-setup-links")
      }
    }
  }

  /// Base URL、API Key、模型收成一张卡，一行一个字段，标签同宽对齐。
  @ViewBuilder private var editorConnectionCard: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("连接与模型").settingsSectionHeaderStyle()
      VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
          GridRow(alignment: .firstTextBaseline) {
            Text("Base URL")
              .frame(width: 86, alignment: .leading)
            TextField("", text: $model.baseURL, prompt: Text("https://api.example.com/v1"))
              .labelsHidden()
              .accessibilityLabel("Base URL")
              .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
              .accessibilityIdentifier("provider-base-url")
          }

          GridRow(alignment: .firstTextBaseline) {
            Text("API Key")
              .frame(width: 86, alignment: .leading)
            if model.shouldShowAPIKeyInput {
              SecureField("", text: $apiKeyInput, prompt: Text("输入密钥"))
                .labelsHidden()
                .accessibilityLabel("API Key")
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
                Button(model.selectedPreset == .commandCode ? "读取模型列表" : "验证并读取模型列表") {
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
                  Button("手动填写模型名", action: model.enableManualModelEntry)
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
                    ForEach(model.filteredModels, id: \.self) { name in
                      let alreadyAdded = model.isModelAlreadyInLibrary(name)
                      Button {
                        model.toggleCatalogModel(name)
                      } label: {
                        HStack(spacing: 10) {
                          Image(systemName: alreadyAdded ? "checkmark.circle" : (model.selectedCatalogModels.contains(name) ? "checkmark.square.fill" : "square"))
                            .foregroundStyle(model.selectedCatalogModels.contains(name) ? Color.accentColor : .secondary)
                          Text(name)
                            .foregroundStyle(alreadyAdded ? .secondary : .primary)
                            .lineLimit(1)
                          Spacer()
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
                      if name != model.filteredModels.last {
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
                  .foregroundStyle(model.selectedCatalogModelCount == 0 ? .secondary : Color.accentColor)
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
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())

      Text("测试只发送“Reply with OK.”的极短提示；不会创建历史记录或保存回复内容。")
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
        ForEach(model.filteredModels, id: \.self) { Text($0).tag($0) }
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
      TextField("", text: selection, prompt: Text("手动填写模型名"))
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
      ForEach(SettingsTabGroup.allCases, id: \.self) { group in
        let tabs = group.visibleTabs
        if !tabs.isEmpty {
          Section {
            ForEach(tabs) { tab in
              paperSidebarRow(tab)
            }
          } header: {
            // 和主窗侧栏同一个坑：这是 `List` 的分区标题，收不到窗口根部注入的
            // 环境字体，必须显式给。
            Text(group.title)
              .themedFont(.caption, weight: .semibold)
              .foregroundStyle(.secondary)
          }
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
      withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
        selectedTab = tab
      }
    } label: {
      Label {
        Text(tab.title)
          .themedFont(.body)
      } icon: {
        SettingsSidebarChip(
          symbol: tab.symbol,
          fill: isSelected ? settingsTheme.accent : settingsTheme.secondaryText
        )
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityLabel(tab.title)
    .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
    .buttonStyle(.plain)
    // 与主界面侧栏共用同一档间距和浅色选中态，两个窗口切换时不会像两套组件。
    .padding(.vertical, DesignTokens.Space.xs)
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
        caption: "这一页的功能都还在成型，可能在后续版本里变化或调整。",
        captionIdentifier: "labs-scope-note"
      )

      // 「工作台」「爆款实验室」「每天自动出选题」都只是一个开关＋一段说明，
      // 三张几乎等大的整卡挤在一起反而看不出主次。收进一张行式卡片；
      // 「我的表达方式」有三组分段控件和一段长文本，仍然独占一张卡。
      SettingsRowGroup {
        SettingsRow(
          title: "工作台",
          caption: "把素材和灵感加工成作品的地方。打开后侧边栏会出现「工作台」。",
          details: "目前只能手动建创作、加素材、推进阶段——还没有接 AI。数据结构在后续版本会调整，关掉不会删数据，你建过的东西下次打开还在。"
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
          details: "它不是预测模型，是校准循环。盲预测的价值不在于准——准不准很大程度上看平台推荐和运气；而「我以为会爆的那些为什么没爆」是能学的，前提是预测在看到结果之前就已经落定，之后不能改。关掉之后模块从界面消失，但已经记下的预测不会删。"
        ) {
          Toggle("爆款实验室", isOn: $isHitLabEnabled)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityIdentifier("hit-lab-enabled")
        }

        SettingsRow(
          title: "每天自动出选题",
          caption: "App 开着的时候，到点跑一次，从素材库里出几条不同角度的选题。",
          details: "错过那一分钟也没关系：判据是「今天的触发点已经过了、今天还没跑过」，所以十点才开电脑照样会跑。自动跑会花掉订阅额度，所以默认关着。"
        ) {
          VStack(alignment: .trailing, spacing: DesignTokens.Space.sm) {
            Toggle("每天自动出选题", isOn: scheduleBinding(\.isEnabled))
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
        title: "我的表达方式",
        summary: "起草时 AI 照着这些写。改一次，后面所有产出跟着变。",
        details: "参考段落比前面几个选项有用得多——「短句为主」只是描述，而一段真实的文字直接展示了你怎么断句、怎么起头、怎么收尾。",
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
            Text("从不使用的词").themedFont(.subheadline).foregroundStyle(.secondary)
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
      pageHeader(for: .appearance, caption: "选择界面主题，分别指定界面字体与阅读字体。切换即时生效，无需保存。")

      settingCard(
        title: "主题",
        summary: "选择界面明暗与阅读纸色；切换即时生效。",
        details: "浅色和深色是同一套配色的白天和夜晚：同一组带绿的中性色、同一个墨绿强调色。「跟随系统」在两者之间自动切换。界面字体默认跟随系统（英文数字 SF Pro、中文 PingFang），下面两项可以各自覆盖。",
        controlWidth: .full
      ) {
        ThemeSwatchPicker(selection: $appearanceThemeRaw)
      }

      // 界面字体和阅读字体分成两张卡、两个偏好，故意不合并：两者的取舍方向相反。
      // 界面最小 10pt，要的是「立得住」；正文最小 13pt，要的是「读着舒服」。
      // 同一个字体很少两边都最优，绑在一起等于强迫用户二选一。
      settingCard(
        title: "界面字体",
        summary: "侧栏、列表、按钮与设置页；不影响文章阅读区。",
        details: "推荐一档只列能自己画完整简体中文、且至少有两个字重的家族。日文与韩文字体（Klee、Hiragino Mincho、YuMincho 等）缺简化字，拿它们排中文会逐字回退到别的字体，一句话里两种字形混排——它们仍在「其它」里，但不推荐。",
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
        summary: "只调整文章阅读区；界面控件与代码块保持原字体。",
        details: "列表只收录自带中文字形的字体家族。像 New York、Georgia 这类只有拉丁字形的字体，中文要逐字回退且不做标点挤压，每个「，」「。」后面都会裂开一道缝，所以不列出来。推荐一档还额外要求能画完整的简体中文——日文字体只缺一部分简化字，症状更隐蔽：整段里零星几个字掉到别的字体上。",
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
                Text("无衬线").tag(ReadingFontSelection.defaultStoredValue)
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
    guard let identity = model.dataDestinationCard else {
      return ("保存有效模型服务配置后，这里会显示发送目的地。", "arrow.up.doc")
    }
    if identity.isLocalEndpoint {
      return ("内容将发送到本地端点 · \(identity.model)", "desktopcomputer")
    }
    return ("内容将发送至 \(identity.host) · \(identity.model)", "arrow.up.doc")
  }

  private var generationTab: some View {
    SettingsPlainPage {
      pageHeader(for: .generation, caption: "控制总结、翻译输出，以及新内容进来后自动跑哪些步骤。改完即时生效，无需保存。")

      // 常用默认在前：大多数人打开这页只改语言。
      // 并发、长提示词收进「高级」卡；发送授权并进管线卡底部，不再独占一张卡。
      //
      // 这一页原来有一条底部固定的「保存生成偏好」条，而外观页写着「切换即时生效」，
      // 模型页又是每个模型各自保存——三页三种保存模型。现在统一即时生效，状态只
      // 在保存失败时以一行提示条露出来。
      SettingsRowGroup {
          SettingsRow(
            title: "输出语言",
            details: "总结、翻译等生成结果统一用这个语言输出。生成时会把这条语言指令追加到提示词；模型分配仍在「模型与识别」。"
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

      // 这条链在代码里严格串行且有依赖，所以画成有序链条而不是四个平级开关。
      VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        Text(UISettingsPresentation.newCaptureAutoProcessTitle).themedFont(.headline)
        Text(UISettingsPresentation.newCaptureAutoProcessCaption)
          .themedFont(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 0) {
          pipelineStep(
            index: 1,
            title: UISettingsPresentation.pipelineStepTitle(index: 1),
            trailingNote: "只发送标题",
            isOn: $model.autoLocalizeTitleNewCaptures,
            identifier: "auto-pipeline-localize-title"
          )
          pipelineStep(
            index: 2,
            title: UISettingsPresentation.pipelineStepTitle(index: 2),
            trailingNote: "不出网",
            isOn: $model.autoTranscribeNewCaptures,
            identifier: "auto-pipeline-transcribe"
          )
          pipelineStep(
            index: 3,
            title: UISettingsPresentation.pipelineStepTitle(index: 3),
            trailingNote: "只发送文字",
            requirementUnmet: model.autoTranscribeNewCaptures
              ? nil
              : "仅影响自动进来的新内容：② 未开启就没有转写稿可整理",
            isOn: $model.autoTidyTranscription,
            identifier: "auto-tidy-transcription"
          )
          pipelineStep(
            index: 4,
            title: UISettingsPresentation.pipelineStepTitle(index: 4),
            trailingNote: "读原文，不读译文",
            isOn: $model.autoSummarizeNewCaptures,
            identifier: "auto-pipeline-summarize"
          )
          pipelineStep(
            index: 5,
            title: UISettingsPresentation.pipelineStepTitle(index: 5),
            trailingNote: "优先用总结产物",
            isLast: true,
            // 脑图未开启时不展示前置条件警告，避免关掉时仍被无关提示打扰。
            requirementUnmet: model.autoSummarizeNewCaptures
              ? nil
              : (model.autoMindMapNewCaptures
                ? "④ 未开启：将直接读原文生成，质量通常不如先总结"
                : nil),
            isOn: $model.autoMindMapNewCaptures,
            identifier: "auto-pipeline-mindmap"
          )
        }
        .padding(.top, DesignTokens.Space.xxs)

        // 数据去向紧贴造成出网的开关；必须留在 DisclosureGroup 外面。
        SettingsCrossReference(
          message: dataDestinationLine.message,
          systemImage: dataDestinationLine.symbol
        )
        .accessibilityIdentifier("data-destination-card")

        DisclosureGroup("了解更多") {
          VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text("开启即视为持久授权，自动执行时不再逐次弹出发送确认；首次使用某个模型服务时仍会按数据去向流程确认一次。本机转写不出网；中文标题/校对/总结/脑图只发送文字。手动转写完成后请点「模型校对」。")
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let identity = model.dataDestinationCard {
              LabeledContent("Base URL", value: identity.normalizedBaseURL)
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
            Text("已记住的发送授权").themedFont(.body)
            Text(consentRevokeNotice ?? "首次把内容发往某个服务商、或首次使用在线转写、校对、脑图时会各告知一次，之后不再重复询问。")
              .themedFont(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: DesignTokens.Space.md)
          Button("清除授权记录") {
            Task {
              let cleared = await appModel.revokeRememberedConsents()
              consentRevokeNotice = cleared ? "已清除。下一次发送会重新询问。" : "清除失败：无法写入本机记录。"
            }
          }
          .buttonStyle(.appQuiet)
          .accessibilityIdentifier("revoke-remembered-consents")
        }
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())

      // 高级项收成一张可折叠的卡，不再裸露在两张卡之间。
      VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        DisclosureGroup("高级：翻译并发与总结提示词") {
          VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            HStack(alignment: .center, spacing: DesignTokens.Space.md) {
              VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text("翻译并发")
                  .themedFont(.body)
                Text("长文翻译会切成多段同时发送，段数越多越快。只对超过约 8000 字的正文生效；免费或有速率限制的服务商调高后可能被限流。")
                  .themedFont(.subheadline)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: DesignTokens.Space.md)
              Picker("翻译并发", selection: $model.translationConcurrency) {
                ForEach(
                  Array(ModelPreferences.translationConcurrencyRange),
                  id: \.self
                ) { value in
                  Text(value == 1 ? "不并发" : "\(value) 段").tag(value)
                }
              }
              .labelsHidden()
              .frame(width: 120)
              .accessibilityIdentifier("translation-concurrency")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
              Text("总结提示词")
                .themedFont(.body)
              Text("无论用内置还是自定义提示词，\(ProductDisplay.name) 都会追加输出语言指令。提示词保存在本机；生成时会随正文发送给所选模型。")
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
                Button("重置为默认提示词", action: model.resetSummaryPrompt)
                  .buttonStyle(.appQuiet)
                  .disabled(model.preferencesState == .saving)
                  .accessibilityIdentifier("reset-summary-prompt")
              }
            }
          }
          .padding(.top, DesignTokens.Space.md)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .themedFont(.headline)
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())

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
          if selected != Self.customModelTag {
            text.wrappedValue = selected
          } else if !isCustomModelName(text.wrappedValue, in: options) {
            text.wrappedValue = " "
          }
        }
      ),
      identifier: identifier
    )
    .accessibilityLabel(label)
  }

  /// 只在选了「自定义…」时出现。带边框——否则光标落在一片空白里，找不到该点哪。
  @ViewBuilder
  private func modelChoiceCustomField(
    placeholder: String,
    options: [ProviderSettingsViewModel.LibraryEntryDisplay],
    text: Binding<String>,
    identifier: String
  ) -> some View {
    if isCustomModelName(text.wrappedValue, in: options) {
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 260)
        .accessibilityIdentifier("\(identifier)-custom")
    }
  }

  /// 下拉的三组：空值语义项、已添加的模型（带服务商副标题）、自定义。
  /// 自定义项的标题就是当前手填的名字，标签上直接能看到，不是一个「自定义…」占位。
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
    let customTitle = current.trimmingCharacters(in: .whitespaces)
    sections.append([
      .init(
        value: Self.customModelTag,
        title: isCustom && !customTitle.isEmpty ? customTitle : "自定义…",
        subtitle: isCustom ? "自定义" : nil
      ),
    ])
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

  /// 自动处理管线的一步。
  ///
  /// 这条链在代码里是**严格串行且有依赖**的：整理要吃转写产物，脑图要吃总结产物。
  /// 原来 UI 是四个平级、无序、互不相关的开关，顺序只在 footer 用一句话交代——
  /// 于是「只勾整理、不勾转写」这种基本不会生效的组合，界面完全不拦也不提示。
  ///
  /// - Parameter requirementUnmet: 上游没开时的原因。只在标题下用提示说明，
  ///   **不禁用、也不把开关画淡**：淡了会看起来像坏掉或点不了，其实还能开。
  ///   重新抓取一条早先转写过的条目时，整理确实能独立生效，硬禁用会砍掉这个可用组合。
  @ViewBuilder
  private func pipelineStep(
    index: Int,
    title: String,
    trailingNote: String,
    isLast: Bool = false,
    requirementUnmet: String? = nil,
    isOn: Binding<Bool>,
    identifier: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 0) {
        Text("\(index)")
          .themedFont(.caption2, weight: .bold, monospacedDigit: true)
          .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
          .frame(width: 18, height: 18)
          .background(
            Circle().fill(
              (isOn.wrappedValue ? Color.accentColor : Color.secondary).opacity(0.15)
            )
          )
        // 连线让「这是一条链」成为结构而不是文案。
        if !isLast {
          Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
        }
      }
      .frame(minHeight: isLast ? 18 : 44)

      VStack(alignment: .leading, spacing: 3) {
        // 手排页里默认 Toggle 是勾选框；管线各步的开关统一拨杆靠右。
        HStack {
          Text(title)
          Spacer(minLength: 12)
          Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
        if let requirementUnmet {
          Label(requirementUnmet, systemImage: "arrow.turn.left.up")
            .themedFont(.caption2)
            .foregroundStyle(appTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(trailingNote)
            .themedFont(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.bottom, isLast ? 0 : 8)
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
                ? Color.accentColor.opacity(0.12)
                : (isHovering ? theme.primaryText.opacity(0.035) : theme.card)
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : theme.hairline, lineWidth: 1)
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
        TextField("手动填写模型名", text: selection)
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
        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
    }
    .contentShape(Rectangle())
  }
}
