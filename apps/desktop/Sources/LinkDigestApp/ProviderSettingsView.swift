import SwiftUI
import LinkDigestCore

struct ProviderSettingsView: View {
  private enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case service, generation, appearance, mediaStorage, siteLogin, browserSupport
    var id: String { rawValue }
    var title: String {
      switch self {
      case .service: "模型与识别"
      case .generation: "生成偏好"
      case .appearance: "外观"
      case .mediaStorage: "视频存储"
      case .siteLogin: "站点登录"
      case .browserSupport: "浏览器支持"
      }
    }
    var symbol: String {
      switch self {
      case .service: "sparkles.rectangle.stack"
      case .generation: "text.badge.checkmark"
      case .appearance: "paintpalette"
      case .mediaStorage: "externaldrive"
      case .siteLogin: "person.crop.circle.badge.checkmark"
      case .browserSupport: "puzzlepiece.extension"
      }
    }
  }

  private static let outputLanguagePresets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Español", "Français", "Deutsch"]
  private static let customOutputLanguageTag = "__custom__"

  @ObservedObject var model: ProviderSettingsViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @State private var apiKeyInput = ""
  @State private var selectedTab: SettingsTab = .service
  @State private var isCustomOutputLanguage = false
  @State private var translationModelSearchQuery = ""
  @State private var pendingDeletionID: String?
  @State private var activeAssignmentPicker: AssignmentPicker?
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
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

  /// 仅用于判断是否启用 Claude 风格阅读排版——那确实只属于浅色纸质主题。
  private var isPaperTheme: Bool {
    AppearanceTheme(rawValue: appearanceThemeRaw) == .paper
  }

  private var resolvedReadingFont: ResolvedReadingFont {
    ReadingFontSelection(storedValue: readingFontRaw)
      .resolved(
        usesEditorialReadingTypography: isPaperTheme,
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
          RoundedRectangle(cornerRadius: 8)
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
            ForEach(SettingsTab.allCases) { tab in
              Label(tab.title, systemImage: tab.symbol)
                .tag(tab)
                .padding(.vertical, 4)
            }
          }
          .listStyle(.sidebar)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("LinkDigest").font(.title2.weight(.semibold))
          Text("设置").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 240)
    } detail: {
      Group {
        switch selectedTab {
        case .service: serviceTab
        case .generation: generationTab
        case .appearance: appearanceTab
        case .mediaStorage:
          MediaStorageSettingsView(model: mediaStorage)
            .scrollContentBackground(isNativeTheme ? .automatic : .hidden)
            .background(isNativeTheme ? Color.clear : settingsTheme.canvas)
        case .siteLogin:
          SiteLoginSettingsView(mediaStorage: mediaStorage)
            .scrollContentBackground(isNativeTheme ? .automatic : .hidden)
            .background(isNativeTheme ? Color.clear : settingsTheme.canvas)
        case .browserSupport:
          BrowserSupportSettingsView(model: browserSupport, appModel: appModel)
            .scrollContentBackground(isNativeTheme ? .automatic : .hidden)
            .background(isNativeTheme ? Color.clear : settingsTheme.canvas)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(selectedTab.title)
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
    .onAppear { AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw) }
    .onChange(of: appearanceThemeRaw) { _, newValue in
      AppearanceTheme.applyApplicationAppearance(newValue)
    }
    .task { await model.load() }
  }

  // MARK: - 模型服务

  private var serviceTab: some View {
    Form {
      Section {
        settingCard(
          title: "功能与模型",
          summary: "视频转文字和图片文字默认在本机处理，网页正文先保存在本机。",
          details: "只有总结、翻译，以及你主动指派给在线模型的转写，才会访问所选服务商。",
          controlWidth: .full
        ) {
          capabilityAssignmentRows
        }
      }

      Section {
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
              ForEach(model.libraryEntryDisplays) { entry in
                libraryRow(entry)
              }
            }
            // 错误必须留在控件旁边。挪进 footer 就会离「添加模型…」很远，
            // 而它恰恰是解释这个按钮为什么没成功的那句话。
            if let errorText = model.libraryErrorText {
              Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-library-error")
            }
            HStack {
              Button("添加模型…") { model.beginAddModel() }
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
      }

      if model.isEditorVisible {
        editorSections
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
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

  @ViewBuilder private var capabilityAssignmentRows: some View {
    if model.libraryEntryDisplays.isEmpty {
      LabeledContent("总结与翻译") {
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

    LabeledContent("图片文字") {
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
    LabeledContent(title) {
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

  private func libraryRow(_ entry: ProviderSettingsViewModel.LibraryEntryDisplay) -> some View {
    HStack(spacing: 10) {
      providerIcon(entry.preset)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName).font(.headline)
        Text("\(entry.title) · \(entry.modelName)").font(.caption).foregroundStyle(.secondary)
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
      .buttonStyle(.borderless)
      .help("编辑这个模型配置")
      .accessibilityIdentifier("edit-library-model")
      Button {
        pendingDeletionID = entry.id
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("删除这个模型配置")
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
      Section {
        ForEach(ProviderPreset.allCases) { preset in
          Button { model.selectPreset(preset) } label: {
            providerRow(preset)
          }
          .buttonStyle(.plain)
          .disabled(model.isSaving || model.isConfigurationLoading || model.isTestingConnection || model.isLoadingModels)
        }
        .accessibilityIdentifier("provider-preset")
      } header: {
        Text(model.editingProfileID == nil ? "添加模型：选择服务商" : "编辑模型：服务商")
      } footer: {
        Text(model.selectedPreset.documentationHint)
      }

      Section("连接") {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
          GridRow(alignment: .firstTextBaseline) {
            Text("Base URL")
              .frame(width: 86, alignment: .leading)
            TextField("", text: $model.baseURL, prompt: Text("https://api.example.com/v1"))
              .labelsHidden()
              .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
              .accessibilityIdentifier("provider-base-url")
          }

          GridRow(alignment: .firstTextBaseline) {
            Text("API Key")
              .frame(width: 86, alignment: .leading)
            if model.shouldShowAPIKeyInput {
              SecureField("", text: $apiKeyInput, prompt: Text("输入密钥"))
                .labelsHidden()
                .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
                .accessibilityIdentifier("provider-api-key")
            } else {
              HStack(spacing: 10) {
                Text(model.apiKeyStatusText).foregroundStyle(.green)
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
      }

      Section {
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
            in: RoundedRectangle(cornerRadius: 8)
          )
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(settingsTheme.hairline, lineWidth: 1))
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
      } header: {
        Text("模型")
      } footer: {
        Text(model.modelCatalogStatusText)
      }

      Section {
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
      } footer: {
        Text("测试只发送“Reply with OK.”的极短提示；不会创建历史记录或保存回复内容。")
      }
  }

  /// 纸质主题的设置侧栏：画布底色 + 主窗口同款橙色选中样式。
  private var paperSidebar: some View {
    List {
      ForEach(SettingsTab.allCases) { tab in
        Button { selectedTab = tab } label: {
          Label(tab.title, systemImage: tab.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
        .buttonStyle(.plain)
        // 行高与主界面侧栏 (`HistoryContentView.navigationButton`) 同刻度：垂直 3。
        // 原来是 7，实测选中药丸高 34pt、主界面同款药丸只有 23.5pt——同一个应用的
        // 两个侧栏差了整整 10pt，是「设置页和主界面不像一家」里肉眼最先看到的一处。
        // 水平保持 8：实测图标左缘 28.5pt，已经和主界面的 29.5pt 对齐，动它反而偏。
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(
          selectedTab == tab ? settingsTheme.selectionFill : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selectedTab == tab ? settingsTheme.selectionText : settingsTheme.primaryText)
        .fontWeight(selectedTab == tab ? .semibold : .regular)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.canvas)
  }

  // MARK: - 外观

  /// 设置窗口与主窗口共用同一套主题令牌，保证外观切换全局一致。
  private var settingsTheme: HistoryThemeTokens {
    (AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass).tokens
  }

  private var appearanceTab: some View {
    Form {
      // 主题和阅读排版是两件事，各占一张卡。原来四项挤在同一个 Section 里，
      // 「界面配色」和「文章怎么排」混成一块，找起来要逐条读。
      Section {
        settingCard(
          title: "主题",
          summary: "浅色为纸质米黄质感，深色为石墨灰质感，系统跟随 macOS 原生玻璃质感。切换即时生效，无需重启。"
        ) {
          Picker("主题", selection: $appearanceThemeRaw) {
            ForEach(AppearanceTheme.allCases) { option in
              Label(option.displayName, systemImage: option.systemImageName)
                .tag(option.rawValue)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityIdentifier("appearance-theme-picker")
        }
      }

      Section {
        settingCard(
          title: "阅读字体",
          // 这句必须跟着 ReadingFontSelection.resolved 一起改。原来写的是
          // 「浅色使用衬线、其它使用无衬线」——那是 New York 时期的行为，
          // 字体改成中文家族后就成了错的文案。
          summary: "只作用于文章阅读区；界面控件保持系统字体，代码块保持等宽。「跟随主题」在纸质主题用宋体，其余用 PingFang。",
          details: "列表只收录自带中文字形的字体家族。像 New York、Georgia 这类只有拉丁字形的字体，中文要逐字回退且不做标点挤压，每个「，」「。」后面都会裂开一道缝，所以不列出来。"
        ) {
          Picker("阅读字体", selection: $readingFontRaw) {
            Text("跟随主题").tag(ReadingFontSelection.defaultStoredValue)
            Divider()
            // 每一项用它自己的字形显示，选之前就能看出长什么样。
            ForEach(ReadingFontCatalog.cjkCapableFamilies(), id: \.self) { family in
              Text(family).font(.custom(family, size: 13)).tag(family)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(maxWidth: 240, alignment: .leading)
          .accessibilityIdentifier("appearance-reading-font-picker")
        }
      }

      Section {
        settingCard(
          title: "正文字号",
          summary: "标题与引用按同一比例跟着缩放，不会只有正文变大。"
        ) {
          VStack(alignment: .leading, spacing: 10) {
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
            readingFontPreview
          }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
  }

  // MARK: - 生成与数据

  private var generationTab: some View {
    Form {
      Section {
        settingCard(
          title: "总结提示词",
          summary: "无论用内置还是自定义提示词，LinkDigest 都会追加输出语言指令。",
          details: "提示词只保存在本机，不随任何请求以外的途径离开这台机器。",
          controlWidth: .full
        ) {
          VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.summaryPrompt)
              .font(.system(size: 12))
              .scrollContentBackground(.hidden)
              .frame(minHeight: 120)
              .padding(10)
              // 圆角 6 在主界面只用于侧栏选中药丸；描边容器一律 8 起。
              .background(settingsTheme.isNative ? Color(nsColor: .textBackgroundColor) : settingsTheme.listPane)
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(settingsTheme.hairline, lineWidth: 1))
              .accessibilityIdentifier("summary-prompt")
            HStack {
              Spacer()
              Button("重置为默认提示词", action: model.resetSummaryPrompt)
                .disabled(model.preferencesState == .saving)
                .accessibilityIdentifier("reset-summary-prompt")
            }
          }
        }
      }

      Section("输出语言") {
        Picker("输出语言", selection: outputLanguageSelection) {
          ForEach(Self.outputLanguagePresets, id: \.self) { Text($0).tag($0) }
          Text("自定义…").tag(Self.customOutputLanguageTag)
        }
        .accessibilityIdentifier("output-language")

        if showsCustomOutputLanguageField {
          LabeledContent("自定义语言") {
            TextField("例如：Italiano", text: $model.targetLanguage)
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("output-language-custom")
          }
        }
      }

      Section {
        settingCard(
          title: "翻译模型",
          summary: model.usesSeparateTranslationModel
            ? "翻译走下面这个模型，与总结分开。"
            : "默认与总结共用“\(model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前模型" : model.modelName)”。"
        ) {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("翻译使用不同模型", isOn: $model.usesSeparateTranslationModel)
              .accessibilityIdentifier("use-separate-translation-model")
            if model.usesSeparateTranslationModel {
              modelSelector(title: "翻译模型", selection: Binding(
                get: { model.translationModelName },
                set: { model.selectModel($0, forTranslation: true) }
              ), forTranslation: true)
            }
          }
        }
      }

      Section {
        settingCard(
          title: "在线视频转文字",
          summary: "给超过 200MB、无法本机导入的视频用。留空时只使用 Apple 本机转写。",
          details: "配置后，App 会从直连视频流提取短 M4A 分片并调用 /audio/transcriptions；每次上传前仍会确认。"
        ) {
          modelNameField(
            label: "在线转写模型",
            placeholder: "例如 whisper-large-v3-turbo",
            emptyStateText: "未填写：只用 Apple 本机转写",
            text: $model.transcriptionModelName,
            identifier: "transcription-model-name"
          )
        }
      }

      Section {
        settingCard(
          title: "转写稿整理",
          summary: "把转写文字发送给聊天模型修正标点、分段和明显错别字，不改写内容。",
          details: "只发送文字本身，原始转写稿保留在历史中。"
        ) {
          modelNameField(
            label: "整理模型",
            placeholder: "模型名称",
            emptyStateText: "未填写：使用总结模型",
            text: $model.tidyModelName,
            identifier: "tidy-model-name"
          )
        }
      }

      Section {
        // 这条链在代码里严格串行且有依赖，所以画成有序链条而不是四个平级开关。
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
              title: "整理文稿",
              trailingNote: "只发送文字",
              requirementUnmet: model.autoTranscribeNewCaptures
                ? nil
                : "① 未开启：新内容还没有转写稿可整理",
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

          DisclosureGroup("了解更多") {
            Text("开启即视为持久授权，自动执行时不再逐次弹出发送确认；首次使用某个模型服务时仍会按数据去向流程确认一次。本机转写不出网；整理/总结/脑图只发送文字。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
          }
          .font(.caption)
        }
        .padding(.vertical, 4)
      }

      Section("数据去向") {
        if let identity = model.dataDestinationCard {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Base URL", value: identity.normalizedBaseURL)
            LabeledContent("模型", value: identity.model)
            Label(identity.isLocalEndpoint ? "内容将发送到本地端点。" : "内容将发送至该服务商。", systemImage: identity.isLocalEndpoint ? "desktopcomputer" : "arrow.up.doc")
              .font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("data-destination-card")
        } else {
          Text("保存有效模型服务配置后，这里会显示发送目的地。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      Section {
        actionRow(status: model.preferencesStatusText, color: preferencesStatusColor, showsProgress: model.preferencesState == .saving, statusIdentifier: "model-preferences-status") {
          Button("保存生成偏好") { Task { await model.savePreferences() } }
            .disabled(!model.canSavePreferences)
            .accessibilityIdentifier("save-model-preferences")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
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

  /// 「留空时…」这类提示原来只写在 placeholder 里，右对齐显示时看起来像已经
  /// 配好的值。改成输入框左侧标注 + 未填写时显式说明当前生效的是什么。
  @ViewBuilder
  private func modelNameField(
    label: String,
    placeholder: String,
    emptyStateText: String,
    text: Binding<String>,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent(label) {
        TextField(placeholder, text: text)
          .multilineTextAlignment(.trailing)
          .accessibilityIdentifier(identifier)
      }
      if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Label(emptyStateText, systemImage: "circle.dashed")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

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
        Toggle(title, isOn: isOn)
          .accessibilityIdentifier(identifier)
        if let requirementUnmet {
          Label(requirementUnmet, systemImage: "arrow.turn.left.up")
            .font(.caption2)
            .foregroundStyle(.orange)
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

  private func providerRow(_ preset: ProviderPreset) -> some View {
    HStack(spacing: 10) {
      providerIcon(preset)
      VStack(alignment: .leading, spacing: 2) {
        Text(preset.displayName)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        Text(preset.supportsOnlineTranscription ? "支持在线音频转写" : "OpenAI-compatible")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if model.selectedPreset == preset {
        Image(systemName: "checkmark").foregroundStyle(.tint)
      }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder private func providerIcon(_ preset: ProviderPreset) -> some View {
    if let icon = ProviderIconCatalog.image(for: preset) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
    } else {
      // 与主界面的平台图标兜底完全同款（HistoryContentView 的 platformIcon）：
      // 同为 16×16 首字母块，那边用圆角矩形 + 9pt，这里原来是圆形 + 10pt。
      Text(ProviderIconCatalog.fallbackInitial(for: preset))
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(
          ProviderIconCatalog.fallbackColor(for: preset),
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
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
          .multilineTextAlignment(.trailing)
          .accessibilityIdentifier(forTranslation ? "translation-model-search" : "provider-model-search")
      }
    } else if model.isManualModelEntryEnabled || forTranslation {
      LabeledContent(title) {
        TextField("手动填写模型名", text: selection)
          .multilineTextAlignment(.trailing)
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
    if case .failed = model.preferencesState { return .red }
    if case .saved = model.preferencesState { return .green }
    return .secondary
  }
  private var statusColor: Color { if case .failed = model.state { return .red }; return .secondary }
  private var connectionStatusColor: Color {
    if case .failure = model.connectionTestState { return .red }
    if case .success = model.connectionTestState { return .green }
    return .secondary
  }
  private let unsavedChangesText = "有未保存更改，请先保存后再测试"
  private var testConnectionBlocked: Bool { !model.canTestConnection || !apiKeyInput.isEmpty }
  private var connectionStatusText: String {
    if model.hasUnsavedIdentityChanges || model.isReplacingAPIKey || !apiKeyInput.isEmpty { return unsavedChangesText }
    return model.connectionTestStatusText
  }
}
