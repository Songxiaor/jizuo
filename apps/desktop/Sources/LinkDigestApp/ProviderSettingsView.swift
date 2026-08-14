import SwiftUI
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
    case service, generation, appearance, mediaStorage, knowledgeVault, data, siteLogin, browserSupport, labs
    var id: String { rawValue }
    var title: String {
      switch self {
      case .service: "模型与识别"
      case .generation: "生成偏好"
      case .appearance: "外观"
      case .mediaStorage: "视频存储"
      case .knowledgeVault: "知识库同步"
      case .data: "数据"
      case .siteLogin: "站点登录"
      case .browserSupport: "浏览器支持"
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
      case .data: "externaldrive.badge.timemachine"
      case .siteLogin: "person.crop.circle.badge.checkmark"
      case .browserSupport: "puzzlepiece.extension"
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

  /// 侧栏分组：把 8 个分类按「做什么」归成三组，而不是让人从头到尾扫一条平列表。
  ///
  /// 分组本身不控制可见性——那仍然只由 `SettingsTab.visibleCases` 一处判据决定；
  /// 这里只负责「同一批分类摆在哪个标题下面」。
  private enum SettingsTabGroup: CaseIterable, Hashable {
    case serviceAndGeneration
    case readingAndAppearance
    case connectionAndData

    var title: String {
      switch self {
      case .serviceAndGeneration: "服务与生成"
      case .readingAndAppearance: "阅读与外观"
      case .connectionAndData: "连接与数据"
      }
    }

    var tabs: [SettingsTab] {
      switch self {
      case .serviceAndGeneration: [.service, .generation]
      case .readingAndAppearance: [.appearance, .labs]
      case .connectionAndData: [.browserSupport, .siteLogin, .mediaStorage, .knowledgeVault, .data]
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
  @ObservedObject var dataAssets: DataAssetsViewModel
  @State private var apiKeyInput = ""
  @State private var selectedTab: SettingsTab = .service
  @State private var isCustomOutputLanguage = false
  @State private var translationModelSearchQuery = ""
  @State private var pendingDeletionID: String?
  /// 「清除授权记录」按下之后的一行反馈。成功和失败都要说，因为清除本身没有可见效果。
  @State private var consentRevokeNotice: String?
  /// 当前展开的服务商。同时只展开一家：模型清单落在网格下面，同时摊开两家就分不清
  /// 哪一段属于谁。默认全部收起——归拢的意义就是先只看「有哪几家」。
  @State private var expandedLibraryProvider: String?
  @State private var activeAssignmentPicker: AssignmentPicker?
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
  @ViewBuilder private var readingFontPreview: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("预览")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("众所周知，搜索是 Agent 最基础的能力之一。模型的知识停在训练截止那天。")
        .font(resolvedReadingFont.body())
        .lineSpacing(MarkdownPresentation.bodyLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
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
        VStack(alignment: .leading, spacing: 4) {
          Text(ProductDisplay.name).font(.title3.weight(.semibold))
          Text("设置").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
      }
      // 实测 `navigationSplitViewColumnWidth` 的 min 在这个窗口压不住:设成 205
      // 之后侧栏仍然只有 148pt(分栏宽度被拖动后持久化了)。所以改成对内容加
      // 硬性 minWidth——那是布局约束,分栏必须让位。
      //
      // 190/205 都装不下「模型与识别」「浏览器支持」,会被截成「模型与…」。
      // 导航项被截断是最不该省的那种省:用户要靠它认路。
      .frame(minWidth: 205)
      .navigationSplitViewColumnWidth(min: 205, ideal: 215, max: 260)
      // 去掉 NavigationSplitView 自动塞进工具栏的侧栏折叠按钮：设置窗口的分类栏是
      // 导航主轴，不该被折叠，那个图标只是噪声。
      //
      // 必须挂在**侧栏这一栏的内容**上，挂在 NavigationSplitView 整体上不生效——
      // 那个按钮属于侧栏列的工具栏，外层拿不到它。
      .toolbar(removing: .sidebarToggle)
    } detail: {
      Group {
        switch selectedTab {
        case .service: serviceTab
        case .generation: generationTab
        case .appearance: appearanceTab
        case .labs: labsTab
        case .mediaStorage:
          MediaStorageSettingsView(model: mediaStorage)
        case .knowledgeVault:
          KnowledgeVaultSettingsView(model: knowledgeVault)
        case .data:
          DataAssetsSettingsView(model: dataAssets)
        case .siteLogin:
          SiteLoginSettingsView(mediaStorage: mediaStorage)
        case .browserSupport:
          BrowserSupportSettingsView(model: browserSupport, appModel: appModel)
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
      pageHeader(for: .service, caption: "配置总结、翻译和转写各自要用的模型服务。")

      settingCard(
        title: "功能与模型",
        summary: "视频转文字和图片文字默认在本机处理，网页正文先保存在本机。",
        details: "只有总结、翻译，以及你主动指派给在线模型的转写，才会访问所选服务商。",
        controlWidth: .full
      ) {
        capabilityAssignmentRows
      }

      settingCard(
        title: "已添加的模型",
        summary: "每个模型配置都有独立的 Base URL、模型名和 API Key。",
        details: "密钥只保存在本机钥匙串，不写进历史库、导出文件或日志。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 8) {
          if model.libraryEntryDisplays.isEmpty {
            Text("还没有添加模型。添加后即可在上方为每个功能选择模型。")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 168), spacing: 8, alignment: .top)],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(libraryProviderGroups) { group in
                libraryProviderCard(group)
              }
            }
            // 展开的那一家的模型清单落在网格下面，整行宽度都归它——每行要放
            // 模型 ID、指派徽标和编辑/删除两个按钮，挤在一张 168pt 的卡里放不下。
            if let expandedID = expandedLibraryProvider,
               let group = libraryProviderGroups.first(where: { $0.id == expandedID }) {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(group.entries) { entry in
                  libraryRow(entry)
                }
              }
              .padding(.top, 2)
            }
          }
          // 错误必须留在控件旁边。挪进 footer 就会离「添加模型…」很远，
          // 而它恰恰是解释这个按钮为什么没成功的那句话。
          if let errorText = model.libraryErrorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(appTheme.danger)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("model-library-error")
          }
          HStack {
            Button("添加模型…") { model.beginAddModel() }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .tint(settingsTheme.accent)
              .disabled(model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels)
              .accessibilityIdentifier("add-library-model")
            Spacer()
            if model.isEditorVisible {
              Button("收起编辑") { model.closeEditor() }
                .disabled(model.isSaving || model.isTestingConnection || model.isLoadingModels)
                .accessibilityIdentifier("close-library-editor")
            }
          }
        }
      }

      if model.isEditorVisible {
        editorSections
      }
    }
    .controlSize(.regular)
    .onChange(of: apiKeyInput) { oldValue, newValue in
      if oldValue != newValue { model.apiKeyDraftDidChange() }
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
  }

  // MARK: - 功能与模型指派

  private enum AssignmentPicker: String, Identifiable {
    case summary
    case transcription

    var id: String { rawValue }
  }

  // 标签在左、当前值靠右：LabeledContent 只有在 Form 里才会自动两端撑开，
  // 手排页上会抱团靠左，所以这里显式用 HStack + Spacer 排。
  @ViewBuilder private var capabilityAssignmentRows: some View {
    if model.libraryEntryDisplays.isEmpty {
      HStack(alignment: .firstTextBaseline) {
        Text("总结与翻译")
        Spacer(minLength: 16)
        Text("先在下方添加模型").foregroundStyle(.secondary)
      }
    } else {
      assignmentPickerRow(
        title: "总结与翻译",
        kind: .summary,
        selectedEntry: model.summaryEntryDisplays.first(where: { $0.id == model.summaryAssignmentID })
      )
    }

    assignmentPickerRow(
      title: "视频转文字",
      kind: .transcription,
      selectedEntry: model.transcriptionEntryDisplays.first(where: { $0.id == model.transcriptionAssignmentID })
    )

    HStack(alignment: .firstTextBaseline) {
      Text("图片文字")
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 2) {
        Text("Apple Vision").fontWeight(.medium)
        Text("本机 · 离线").font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("image-text-assignment-picker")
  }

  private func assignmentPickerRow(
    title: String,
    kind: AssignmentPicker,
    selectedEntry: ProviderSettingsViewModel.LibraryEntryDisplay?
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 16)
      Button {
        activeAssignmentPicker = kind
      } label: {
        HStack(spacing: 8) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(assignmentDisplayName(kind: kind, entry: selectedEntry))
              .fontWeight(.medium)
              .foregroundStyle(.primary)
            Text(assignmentDetail(kind: kind, entry: selectedEntry))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
      Text(kind == .transcription ? "选择视频转写模型" : "选择总结与翻译模型")
        .font(.headline)
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
            assignmentSectionTitle(kind == .transcription ? "在线模型" : "已添加的模型")
            ForEach(assignmentProviderTitles(in: entries), id: \.self) { providerTitle in
              Text(providerTitle)
                .font(.caption.weight(.semibold))
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
              .font(.caption)
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
      .font(.caption.weight(.semibold))
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
            .font(.headline)
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

  /// 按服务商归拢的模型库。一家一张卡，展开才列它下面的模型。
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

  /// 已添加的服务商卡片。和下面「选择服务商」那张网格用同一个外壳、同一套列宽，
  /// 因为它们说的是同一件事的两面：这里是「已经有哪几家」，那里是「还能加哪几家」。
  ///
  /// 展开的模型清单不塞进卡片里，而是落在整张网格下面。塞进去的话，展开哪一张，
  /// 那一整行卡片就被撑到同样高——网格立刻参差；模型行还要放编辑和删除两个按钮，
  /// 168pt 宽的卡片也装不下。
  private func libraryProviderCard(_ group: LibraryProviderGroup) -> some View {
    let expanded = expandedLibraryProvider == group.id
    let hasSummary = group.entries.contains { model.summaryAssignmentID == $0.id }
    let hasTranscription = group.entries.contains { model.transcriptionAssignmentID == $0.id }
    return Button {
      expandedLibraryProvider = expanded ? nil : group.id
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          providerIcon(group.preset, fallbackName: group.id)
          Text(group.id)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 4)
          if hasSummary { assignmentBadge("总结") }
          if hasTranscription { assignmentBadge("转写") }
        }
        HStack(spacing: 4) {
          Text("\(group.entries.count) 个模型")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
      }
      .modifier(SettingsCardChrome(selected: expanded, theme: appTheme))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("library-provider-group")
  }

  private func libraryRow(_ entry: ProviderSettingsViewModel.LibraryEntryDisplay) -> some View {
    HStack(spacing: 10) {
      providerIcon(entry.preset, fallbackName: entry.title)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName).font(.headline)
        // 服务商名已经写在这张卡的标题上，行里再写一遍是噪音；模型 ID 留着，
        // 它是同一家里区分两个模型的唯一凭据。
        Text(entry.modelName).font(.caption).foregroundStyle(.secondary)
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
      // 换掉 `.borderless`：那个样式在静止和悬停时长得一模一样，这两个图标
      // 看起来像图例而不是能点的东西。`.appIcon` 给出 hover 底色和按下缩放。
      .buttonStyle(.appIcon)
      .help("编辑这个模型配置")
      // accessibilityIdentifier 是给自动化测试用的，VoiceOver 不读它。
      // 纯图标按钮必须另外声明 label，否则读出来只有一个符号名。
      .accessibilityLabel("编辑这个模型配置")
      .accessibilityIdentifier("edit-library-model")
      Button {
        pendingDeletionID = entry.id
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.appIcon)
      .help("删除这个模型配置")
      .accessibilityLabel("删除这个模型配置")
      .accessibilityIdentifier("delete-library-model")
    }
    .contentShape(Rectangle())
  }

  private func assignmentBadge(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.15), in: Capsule())
      .foregroundStyle(Color.accentColor)
  }

  // MARK: - 模型编辑器

  @ViewBuilder private var editorSections: some View {
      SettingsCardGroup(
        header: model.editingProfileID == nil ? "添加模型：选择服务商" : "编辑模型：服务商",
        footer: model.selectedPreset.documentationHint
      ) {
        // 12 家服务商排成一列时，每行连着行内距和分隔线要占 54pt，光这一块
        // 就吃掉约 650pt——一屏几乎装不下，选个服务商得先滚半天。
        //
        // 换成多列卡片后约 200pt。这里每一项只有图标、名字和一句话，本来就
        // 不需要整行宽度；一列排下去纯属浪费横向空间。
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 168), spacing: 8, alignment: .top)],
          alignment: .leading,
          spacing: 8
        ) {
          ForEach(ProviderPreset.allCases) { preset in
            Button { model.selectPreset(preset) } label: {
              providerCard(preset)
            }
            .buttonStyle(.plain)
            .disabled(model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels)
          }
          .accessibilityIdentifier("provider-preset")
        }
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(header: "连接") {
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
                Button("更换", action: model.beginAPIKeyReplacement)
                  .disabled(!model.canBeginAPIKeyReplacement)
                  .accessibilityIdentifier("replace-provider-api-key")
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(header: "模型", footer: model.modelCatalogStatusText) {
        Group {
        HStack(spacing: 12) {
          Button("验证并配置模型") {
            let submittedKey = apiKeyInput
            Task {
              if model.shouldShowAPIKeyInput {
                await model.loadModels(apiKey: submittedKey)
              } else {
                await model.loadModels()
              }
            }
          }
          .disabled(
            !model.canLoadModelCatalog
              || (model.shouldShowAPIKeyInput && apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          .accessibilityIdentifier("load-provider-models")
          if model.isLoadingModels { ProgressView().controlSize(.small) }
        }

        if model.isAddingModelBatch {
          LabeledContent("搜索模型") {
            TextField("", text: $model.modelSearchQuery, prompt: Text("输入关键词过滤"))
              .labelsHidden()
              .accessibilityLabel("搜索模型")
              .accessibilityIdentifier("provider-model-search")
          }

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.filteredModels, id: \.self) { name in
                Button {
                  model.toggleCatalogModel(name)
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: model.selectedCatalogModels.contains(name) ? "checkmark.square.fill" : "square")
                      .foregroundStyle(model.selectedCatalogModels.contains(name) ? Color.accentColor : .secondary)
                    Text(name)
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                    Spacer()
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 8)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            .font(.caption)
            .foregroundStyle(model.selectedCatalogModelCount == 0 ? .secondary : Color.accentColor)
            .accessibilityIdentifier("provider-model-selection-count")
        } else {
          modelSelector(title: "模型", selection: Binding(
            get: { model.modelName },
            set: { model.selectModel($0) }
          ), forTranslation: false)
        }

        if model.shouldOfferManualModelEntry {
          Button("高级：手动填写模型名", action: model.enableManualModelEntry)
            .accessibilityIdentifier("enable-manual-provider-model")
        }
        }
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
      }

      SettingsCardGroup(
        footer: "测试只发送“Reply with OK.”的极短提示；不会创建历史记录或保存回复内容。"
      ) {
        Group {
        actionRow(status: model.statusText, color: statusColor, showsProgress: model.isSaving, statusIdentifier: "provider-settings-status") {
          Button(model.isAddingModelBatch ? "保存 \(model.selectedCatalogModelCount) 个模型" : "保存模型配置") {
            let submittedKey = apiKeyInput
            Task {
              await model.save(apiKey: submittedKey)
              apiKeyInput = ""
            }
          }
          .disabled(!model.canSaveConfiguration)
          .accessibilityIdentifier("save-provider-settings")
        }

        actionRow(status: connectionStatusText, color: connectionStatusColor, showsProgress: model.isTestingConnection, statusIdentifier: "provider-connection-status") {
          Button("测试连接") { Task { await model.testConnection() } }
            .disabled(!model.canTestConnection || !apiKeyInput.isEmpty)
            .accessibilityIdentifier("test-provider-connection")
            .accessibilityHint(testConnectionBlocked ? unsavedChangesText : "发送极短提示验证当前已保存配置")
        }
        }
        .padding(.vertical, DesignTokens.Space.md)
        .padding(.horizontal, DesignTokens.Space.lg)
        .modifier(SettingsThemedCardChrome())
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
            Text(group.title)
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
      } icon: {
        SettingsSidebarChip(symbol: tab.symbol, fill: sidebarChipFill(tab))
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
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(settingsTheme.accent)
          .frame(width: 3, height: 18)
          .padding(.leading, DesignTokens.Space.xxs)
          .matchedGeometryEffect(id: "settings-sidebar-accent", in: sidebarSelectionNamespace)
      }
    }
    .foregroundStyle(settingsTheme.primaryText)
    .fontWeight(isSelected ? .semibold : .regular)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  // MARK: - 外观

  /// 设置窗口与主窗口共用同一套主题令牌，保证外观切换全局一致。
  private var settingsTheme: HistoryThemeTokens {
    (AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass).tokens
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
                Text("时间").font(.caption).foregroundStyle(.secondary)
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
            Text("从不使用的词").font(.caption).foregroundStyle(.secondary)
            TextField("赋能、抓手、闭环…", text: voiceBinding(\.forbiddenWords))
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("voice-forbidden-words")
          }

          VStack(alignment: .leading, spacing: 5) {
            Text("参考段落").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: voiceBinding(\.sample))
              .font(.callout)
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
      pageHeader(for: .appearance, caption: "选择界面主题，调整文章的阅读字体与字号。")

      settingCard(
        title: "主题",
        summary: "选择界面明暗与阅读纸色；切换即时生效。",
        details: "浅色为纸质米黄，暖褐更黄、对比更低，深色为石墨灰，高对比为纯黑白，系统跟随 macOS。暖褐和浅色默认用宋体排文章；指定阅读字体后不再随主题变化。",
        controlWidth: .full
      ) {
        ThemeSwatchPicker(selection: $appearanceThemeRaw)
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
        details: "列表只收录自带中文字形的字体家族。像 New York、Georgia 这类只有拉丁字形的字体，中文要逐字回退且不做标点挤压，每个「，」「。」后面都会裂开一道缝，所以不列出来。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
          HStack(spacing: DesignTokens.Space.sm) {
            Text("字体")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            // 每一项用它自己的字形显示，选之前就能看出长什么样。
            Picker("阅读字体", selection: $readingFontRaw) {
              Text("跟随主题").tag(ReadingFontSelection.defaultStoredValue)
              Divider()
              ForEach(ReadingFontCatalog.cjkCapableFamilies(), id: \.self) { family in
                Text(family).font(.custom(family, size: 13)).tag(family)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("appearance-reading-font-picker")
            Spacer(minLength: 0)
          }

          Divider()

          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            HStack(spacing: DesignTokens.Space.sm) {
              Text("正文字号")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Spacer(minLength: 0)
            }
            Text("标题与引用按同一比例跟着缩放，不会只有正文变大。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
              Slider(
                value: $readingFontSizeRaw,
                in: Double(ReadingFontSize.minimum)...Double(ReadingFontSize.maximum),
                step: Double(ReadingFontSize.step)
              )
              .frame(maxWidth: 220)
              .accessibilityIdentifier("appearance-reading-font-size-slider")
              Text(String(format: "%.1f", readingFontSizeRaw))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
              Spacer(minLength: 0)
            }
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
      pageHeader(for: .generation, caption: "控制总结、翻译输出，以及新内容进来后自动跑哪些步骤。")

      // 高频的语言/模型行组挪到页首：这几项才是大多数人打开这一页真正要调的东西，
      // 长文本框「总结提示词」排在页首反而会占掉半屏，把它们推到下面才要滚一屏找。
      //
      // 原来这六项各占一整张卡，但每项都只是「一个下拉/开关 + 一句说明」，
      // 和系统设置里一屏能看到七八行的密度差得远。收进一张行式卡片：
      // 标签左、控件右，hairline 分隔，说明和详细说明还是逐行各自的——
      // 只是不再各自单占一张卡的空白。
      SettingsRowGroup {
          // 原来是裸 Section("输出语言") + Picker("输出语言")，section 标题和 picker
          // 标签都是「输出语言」，同一句话出现两遍。收进行控件后不再重复。
          SettingsRow(
            title: "输出语言",
            caption: "总结、翻译等生成结果统一用这个语言输出。"
          ) {
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
              Picker("输出语言", selection: outputLanguageSelection) {
                ForEach(Self.outputLanguagePresets, id: \.self) { Text($0).tag($0) }
                Text("自定义…").tag(Self.customOutputLanguageTag)
              }
              .labelsHidden()
              .fixedSize()
              .accessibilityIdentifier("output-language")
              if showsCustomOutputLanguageField {
                LabeledContent("自定义语言") {
                  // 无边框 + 右对齐时，光标落在一片空白里，找不到该点哪。
                  TextField("例如：Italiano", text: $model.targetLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("output-language-custom")
                }
              }
            }
          }

          // 原来这里是一个开关：关着的时候只说「默认与总结共用 X」，不说打开会怎样；
          // 打开之后才在下面长出一个模型选择器。于是「用哪个模型」这一个问题被拆成了
          // 两步，而这一整页其余每一项（输出语言、翻译并发、在线视频转文字、转写稿
          // 整理）都是一个下拉直接答完。
          //
          // 隔着两行的「转写稿整理」早就把同样的问题解对了——下拉的第一项就是
          // 「跟随总结模型」。翻译改成同一个写法：空值即跟随，选了就是另用一个。
          SettingsRow(
            title: "翻译模型",
            caption: "不另选就与总结共用同一个模型。",
            details: "翻译和总结是两种活：总结要概括，翻译要贴原文。想让翻译走更便宜或更擅长语言的模型时，在这里另选一个。"
          ) {
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
              modelChoicePicker(
                label: "翻译模型",
                emptyOptionTitle: "跟随总结模型",
                options: model.summaryEntryDisplays,
                text: $model.translationModelName,
                identifier: "translation-model-name"
              )
              modelChoiceCustomField(
                placeholder: "模型名称",
                options: model.summaryEntryDisplays,
                text: $model.translationModelName,
                identifier: "translation-model-name"
              )
            }
          }

          // 这是个性能旋钮，不是开关：长文翻译会被切成多片同时发，这个数就是同时
          // 在飞的片数。放在翻译模型下面，因为它只影响翻译。
          SettingsRow(
            title: "翻译并发",
            caption: "长文翻译会切成多段同时发送，段数越多越快。",
            details: "只对超过约 8000 字的正文生效，短文仍是单次请求。免费或有速率限制的服务商调高后可能被限流，遇到限流会自动退避重试。"
          ) {
            Picker("翻译并发", selection: $model.translationConcurrency) {
              ForEach(
                Array(ModelPreferences.translationConcurrencyRange),
                id: \.self
              ) { value in
                Text(value == 1 ? "不并发" : "\(value) 段").tag(value)
              }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("translation-concurrency")
          }

          SettingsRow(
            title: "在线视频转文字",
            caption: "给超过 200MB、无法本机导入的视频用。选「不使用」时只跑 Apple 本机转写。",
            details: "配置后，App 会从直连视频流提取短 M4A 分片并调用 /audio/transcriptions；每次上传前仍会确认。"
          ) {
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
              modelChoicePicker(
                label: "在线转写模型",
                emptyOptionTitle: "不使用：只用 Apple 本机转写",
                // 只列声明支持在线转写的服务，选到一个用不了的模型没有意义。
                options: model.transcriptionEntryDisplays,
                text: $model.transcriptionModelName,
                identifier: "transcription-model-name"
              )
              modelChoiceCustomField(
                placeholder: "例如 whisper-large-v3-turbo",
                options: model.transcriptionEntryDisplays,
                text: $model.transcriptionModelName,
                identifier: "transcription-model-name"
              )
            }
          }

          SettingsRow(
            title: "转写稿模型校对",
            caption: "把转写文字发送给聊天模型修正标点、分段和明显错别字，不改写内容。",
            details: "只发送文字本身，原始转写稿保留在历史中。"
          ) {
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
              modelChoicePicker(
                label: "校对模型",
                emptyOptionTitle: "跟随总结模型",
                // 整理是纯文本改写，用的是聊天模型这一侧。
                options: model.summaryEntryDisplays,
                text: $model.tidyModelName,
                identifier: "tidy-model-name"
              )
              modelChoiceCustomField(
                placeholder: "模型名称",
                options: model.summaryEntryDisplays,
                text: $model.tidyModelName,
                identifier: "tidy-model-name"
              )
            }
          }

          // 发送确认从「每跑一次问一次」改成「问一次就记住」之后，必须有一条把它
          // 收回来的路，否则那一次点击就是不可逆的。
          SettingsRow(
            title: "已记住的发送授权",
            caption: "首次把内容发往某个服务商、或首次使用在线转写、模型校对、生成脑图时会各告知一次，之后不再重复询问。",
            details: "清除后，下一次发送会重新告知一遍。清除只影响本机记录，不改动任何模型配置或密钥。"
          ) {
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xs) {
              Button("清除授权记录") {
                Task {
                  let cleared = await appModel.revokeRememberedConsents()
                  consentRevokeNotice = cleared ? "已清除。下一次发送会重新询问。" : "清除失败：无法写入本机记录。"
                }
              }
              .accessibilityIdentifier("revoke-remembered-consents")
              if let consentRevokeNotice {
                Text(consentRevokeNotice)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
      }

      settingCard(
        title: "总结提示词",
        summary: "无论用内置还是自定义提示词，\(ProductDisplay.name) 都会追加输出语言指令。",
        details: "提示词只保存在本机，不随任何请求以外的途径离开这台机器。",
        controlWidth: .full
      ) {
        VStack(alignment: .leading, spacing: 8) {
          TextEditor(text: $model.summaryPrompt)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 96, maxHeight: 140)
            .padding(10)
            // 圆角 6 在主界面只用于侧栏选中药丸；描边容器一律 8 起。
            .background(settingsTheme.isNative ? Color(nsColor: .textBackgroundColor) : settingsTheme.listPane)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(settingsTheme.hairline, lineWidth: 1))
            .accessibilityIdentifier("summary-prompt")
          HStack {
            Spacer()
            Button("重置为默认提示词", action: model.resetSummaryPrompt)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(Color.secondary)
              .disabled(model.preferencesState == .saving)
              .accessibilityIdentifier("reset-summary-prompt")
          }
        }
      }

      // 这条链在代码里严格串行且有依赖，所以画成有序链条而不是四个平级开关。
      //
      // 这张卡原来在 Form 的 Section 里靠 `SettingsFormRowTint`（只染 Form 自己的
      // 行背景）取得卡片外观；离开 Form 之后自己直接套 `SettingsThemedCardChrome`，
      // 和站点登录页 `sitesCard` 的做法一致。
      VStack(alignment: .leading, spacing: 10) {
        Text("自动处理管线").font(.headline)
        Text("新内容到达后按编号顺序串行执行已开启的步骤。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 0) {
          pipelineStep(
            index: 1,
            title: "本机转写",
            trailingNote: "不出网",
            isOn: $model.autoTranscribeNewCaptures,
            identifier: "auto-pipeline-transcribe"
          )
          pipelineStep(
            index: 2,
            title: "模型校对",
            trailingNote: "只发送文字",
            // 这句只针对**自动管线**这一个场景：新内容自动进来时，① 不开就没有
            // 转写稿给 ② 用。但它长得像前置条件警告，读起来像「② 依赖 ①」——
            // 实际上手动点「转写」完成后，只要 ② 开着就会自动整理，与 ① 无关。
            // 收到过按此误解的反馈，所以把适用范围写进文案本身。
            requirementUnmet: model.autoTranscribeNewCaptures
              ? nil
              : "仅影响自动进来的新内容：① 未开启就没有转写稿可整理。你手动点「转写」时，本步照常生效",
            isOn: $model.autoTidyTranscription,
            identifier: "auto-tidy-transcription"
          )
          pipelineStep(
            index: 3,
            title: "总结",
            trailingNote: "只发送文字",
            isOn: $model.autoSummarizeNewCaptures,
            identifier: "auto-pipeline-summarize"
          )
          pipelineStep(
            index: 4,
            title: "脑图",
            trailingNote: "优先用总结产物",
            isLast: true,
            requirementUnmet: model.autoSummarizeNewCaptures
              ? nil
              : "③ 未开启：将直接读原文生成，质量通常不如先总结",
            isOn: $model.autoMindMapNewCaptures,
            identifier: "auto-pipeline-mindmap"
          )
        }
        .padding(.top, 2)

        // 数据去向紧贴着造成出网的那几个开关，而不是另起一张卡。
        //
        // 必须留在 DisclosureGroup 外面：这些开关一开就是持久授权，之后自动执行
        // 不再逐次弹确认（就是下面那段文案说的），那之后这一行是「内容发去哪」
        // 唯一的常驻可见位置。折起来等于自动模式下再也看不到目的地。
        //
        // 原来它是页面底部一张独立的「数据去向」卡：只读的东西却和上面可操作的卡
        // 同等分量，读者会先以为能点；而且把「调开关 → 保存」的动线从中间截断。
        SettingsCrossReference(
          message: dataDestinationLine.message,
          systemImage: dataDestinationLine.symbol
        )
        .accessibilityIdentifier("data-destination-card")

        DisclosureGroup("了解更多") {
          VStack(alignment: .leading, spacing: 6) {
            Text("开启即视为持久授权，自动执行时不再逐次弹出发送确认；首次使用某个模型服务时仍会按数据去向流程确认一次。本机转写不出网；校对/总结/脑图只发送文字。")
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
            // 完整 Base URL 是排障才看的东西，收进来；上面那行只留 host 和模型，
            // 那两个才是「发给谁、用什么」的日常答案。
            if let identity = model.dataDestinationCard {
              LabeledContent("Base URL", value: identity.normalizedBaseURL)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        }
        .font(.caption)
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())

      actionRow(status: model.preferencesStatusText, color: preferencesStatusColor, showsProgress: model.preferencesState == .saving, statusIdentifier: "model-preferences-status") {
        Button("保存生成偏好") { Task { await model.savePreferences() } }
          .disabled(!model.canSavePreferences)
          .accessibilityIdentifier("save-model-preferences")
      }
      .padding(.vertical, DesignTokens.Space.md)
      .padding(.horizontal, DesignTokens.Space.lg)
      .modifier(SettingsThemedCardChrome())
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
    Picker(label, selection: Binding(
      get: { isCustomModelName(text.wrappedValue, in: options) ? Self.customModelTag : text.wrappedValue },
      set: { selected in
        // 选「自定义…」时不清空已有值，否则改一次下拉就丢掉手填的名字。
        if selected != Self.customModelTag { text.wrappedValue = selected }
      }
    )) {
      Text(emptyOptionTitle).tag("")
      if !options.isEmpty {
        Divider()
        ForEach(options) { option in
          Text("\(option.modelName)（\(option.title)）").tag(option.modelName)
        }
      }
      Divider()
      Text("自定义…").tag(Self.customModelTag)
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier(identifier)
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
  /// - Parameter requirementUnmet: 上游没开时的原因。这里**只置灰视觉、不禁用开关**：
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
          .font(.caption2.weight(.bold).monospacedDigit())
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
            .font(.caption2)
            .foregroundStyle(appTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(trailingNote)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .opacity(requirementUnmet == nil ? 1 : 0.55)
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
          .font(.subheadline.weight(.semibold))
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .modifier(SettingsCardChrome(selected: selected, theme: appTheme))
  }

  /// 「已添加的模型」和「选择服务商」两张网格必须长得一模一样：它们相邻、都是
  /// 「一家服务商一张卡」，只要圆角、边框、内距、选中态有任何一处不同，看上去
  /// 就是两套东西凑在一起。所以卡片外壳收在这一个 modifier 里，两处共用。
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
/// 主题从 3 套涨到 5 套之后 segmented 就装不下了：中文名加图标挤在一行，
/// 每格窄到只剩两个字。但真正的问题不是宽度——是「浅色」「暖褐」「高对比」
/// 这三个名字并排放着，选之前根本不知道差在哪。主题是纯视觉的东西，
/// 让人靠名字猜颜色本身就是错的分工。
///
/// 所以每格直接把该主题的画布色画出来，右下角压一条强调色：
/// 画布色分开浅色系和深色系，强调色（品牌橙 / 赭石 / 纯黑）分开同为近白底的
/// 浅色、暖褐和高对比。
private struct ThemeSwatchPicker: View {
  @Binding var selection: String

  // adaptive 而不是固定列数：设置窗口可以拖宽，固定 5 列在窄窗口会溢出，
  // 固定 3 列在宽窗口又留一大片空白。
  private let columns = [GridItem(.adaptive(minimum: 74, maximum: 104), spacing: 10, alignment: .leading)]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      ForEach(AppearanceTheme.allCases) { theme in
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
        .font(.caption2)
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
