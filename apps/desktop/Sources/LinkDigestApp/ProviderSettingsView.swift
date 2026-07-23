import SwiftUI
import LinkDigestCore

struct ProviderSettingsView: View {
  private enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case service, generation, appearance, mediaStorage, browserSupport
    var id: String { rawValue }
    var title: String {
      switch self {
      case .service: "模型与识别"
      case .generation: "生成偏好"
      case .appearance: "外观"
      case .mediaStorage: "视频存储"
      case .browserSupport: "浏览器支持"
      }
    }
    var symbol: String {
      switch self {
      case .service: "sparkles.rectangle.stack"
      case .generation: "text.badge.checkmark"
      case .appearance: "paintpalette"
      case .mediaStorage: "externaldrive"
      case .browserSupport: "puzzlepiece.extension"
      }
    }
  }

  private static let outputLanguagePresets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Español", "Français", "Deutsch"]
  private static let customOutputLanguageTag = "__custom__"

  @ObservedObject var model: ProviderSettingsViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @State private var apiKeyInput = ""
  @State private var selectedTab: SettingsTab = .service
  @State private var isCustomOutputLanguage = false
  @State private var translationModelSearchQuery = ""
  @State private var pendingDeletionID: String?
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(ReadingFontPreference.storageKey) private var readingFontRaw = ReadingFontPreference.theme.rawValue

  /// 只有浅色纸质主题接管设置窗口的侧栏与工具栏；系统与深色暂不动。
  private var isPaperTheme: Bool {
    AppearanceTheme(rawValue: appearanceThemeRaw) == .paper
  }

  var body: some View {
    NavigationSplitView {
      Group {
        if isPaperTheme {
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
          Text("LinkDigest").font(.title2.weight(.bold))
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
            .scrollContentBackground(isPaperTheme ? .hidden : .automatic)
            .background(isPaperTheme ? settingsTheme.canvas : Color.clear)
        case .browserSupport:
          BrowserSupportSettingsView(model: browserSupport)
            .scrollContentBackground(isPaperTheme ? .hidden : .automatic)
            .background(isPaperTheme ? settingsTheme.canvas : Color.clear)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(selectedTab.title)
    }
    .toolbarBackground(isPaperTheme ? settingsTheme.canvas : Color.clear, for: .windowToolbar)
    .toolbarBackground(isPaperTheme ? .visible : .automatic, for: .windowToolbar)
    .frame(minWidth: 860, minHeight: 680)
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
        capabilityAssignmentRows
      } header: {
        Text("功能与模型")
      } footer: {
        Text("视频转文字和图片文字默认在本机处理；网页正文先保存在本机。只有总结、翻译和你指派给在线模型的转写会访问所选服务商。")
      }

      Section {
        if model.libraryEntryDisplays.isEmpty {
          Text("还没有添加模型。添加后即可在上方为每个功能选择模型。")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(model.libraryEntryDisplays) { entry in
            libraryRow(entry)
          }
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
      } header: {
        Text("已添加的模型")
      } footer: {
        if let errorText = model.libraryErrorText {
          Text(errorText).foregroundStyle(.red)
        } else {
          Text("每个模型配置都有独立的 Base URL、模型名和 API Key；密钥只保存在本机钥匙串。")
        }
      }

      if model.isEditorVisible {
        editorSections
      }
    }
    .formStyle(.grouped)
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

  @ViewBuilder private var capabilityAssignmentRows: some View {
    if model.libraryEntryDisplays.isEmpty {
      LabeledContent("总结与翻译") {
        Text("先在下方添加模型").foregroundStyle(.secondary)
      }
    } else {
      Picker("总结与翻译", selection: summaryAssignmentSelection) {
        if model.summaryAssignmentID == nil {
          Text("未指派").tag("")
        }
        ForEach(model.libraryEntryDisplays) { entry in
          Text("\(entry.title) · \(entry.modelName)").tag(entry.id)
        }
      }
      .accessibilityIdentifier("summary-assignment-picker")
    }

    Picker("视频转文字", selection: transcriptionAssignmentSelection) {
      Text("本机（Apple 听写）").tag("")
      ForEach(model.libraryEntryDisplays) { entry in
        Text("\(entry.title) · 在线转写").tag(entry.id)
      }
    }
    .accessibilityIdentifier("transcription-assignment-picker")

    Picker("图片文字", selection: .constant("local")) {
      Text("本机（Apple Vision）").tag("local")
    }
    .disabled(true)
    .accessibilityIdentifier("image-text-assignment-picker")
  }

  private var summaryAssignmentSelection: Binding<String> {
    Binding(
      get: { model.summaryAssignmentID ?? "" },
      set: { newValue in
        guard !newValue.isEmpty, newValue != model.summaryAssignmentID else { return }
        Task { await model.assignSummaryModel(newValue) }
      }
    )
  }

  private var transcriptionAssignmentSelection: Binding<String> {
    Binding(
      get: { model.transcriptionAssignmentID ?? "" },
      set: { newValue in
        let id = newValue.isEmpty ? nil : newValue
        guard id != model.transcriptionAssignmentID else { return }
        Task { await model.assignTranscriptionModel(id) }
      }
    )
  }

  // MARK: - 模型库列表

  private func libraryRow(_ entry: ProviderSettingsViewModel.LibraryEntryDisplay) -> some View {
    HStack(spacing: 10) {
      providerIcon(entry.preset)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title).font(.body.weight(.medium))
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
        LabeledContent("Base URL") {
          TextField("https://…", text: $model.baseURL)
            .multilineTextAlignment(.trailing)
            .disabled(model.isSaving || model.isConfigurationLoading || model.isLoadingModels)
            .accessibilityIdentifier("provider-base-url")
        }

        LabeledContent("API Key") {
          if model.shouldShowAPIKeyInput {
            SecureField("输入密钥", text: $apiKeyInput)
              .multilineTextAlignment(.trailing)
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
          }
        }
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

        modelSelector(title: "总结模型", selection: Binding(
          get: { model.modelName },
          set: { model.selectModel($0) }
        ), forTranslation: false)

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
          Button("保存模型配置") {
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
        .buttonStyle(.plain)
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(
          selectedTab == tab ? settingsTheme.selectionFill : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selectedTab == tab ? settingsTheme.selectionText : settingsTheme.primaryText)
        .fontWeight(selectedTab == tab ? .semibold : .regular)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
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
      Section {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
              Text("主题").font(.body.weight(.semibold))
              Text("选择 LinkDigest 界面使用的颜色模式。系统跟随 macOS 的原生玻璃质感。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Picker("主题", selection: $appearanceThemeRaw) {
              ForEach(AppearanceTheme.allCases) { option in
                Label(option.displayName, systemImage: option.systemImageName)
                  .tag(option.rawValue)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .accessibilityIdentifier("appearance-theme-picker")
          }
        }
        .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
              Text("阅读字体").font(.body.weight(.semibold))
              Text("只作用于文章阅读区；界面控件保持系统字体，代码块保持等宽。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Picker("阅读字体", selection: $readingFontRaw) {
              ForEach(ReadingFontPreference.allCases) { option in
                Text(option.displayName).tag(option.rawValue)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .accessibilityIdentifier("appearance-reading-font-picker")
          }
        }
        .padding(.vertical, 4)
      } header: {
        Text("外观")
      } footer: {
        Text("浅色为纸质米黄质感，深色为石墨灰质感；「跟随主题」在浅色使用衬线、其它使用无衬线。切换即时生效，无需重启。")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
  }

  // MARK: - 生成与数据

  private var generationTab: some View {
    Form {
      Section {
        TextEditor(text: $model.summaryPrompt)
          .font(.system(size: 12))
          .frame(minHeight: 120)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
          .accessibilityIdentifier("summary-prompt")
        HStack {
          Spacer()
          Button("重置为默认提示词", action: model.resetSummaryPrompt)
            .disabled(model.preferencesState == .saving)
            .accessibilityIdentifier("reset-summary-prompt")
        }
      } header: {
        Text("总结提示词")
      } footer: {
        Text("无论使用内置或自定义提示词，LinkDigest 都会追加输出语言指令；提示词只保存在本机。")
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
        Toggle("翻译使用不同模型", isOn: $model.usesSeparateTranslationModel)
          .accessibilityIdentifier("use-separate-translation-model")
        if model.usesSeparateTranslationModel {
          modelSelector(title: "翻译模型", selection: Binding(
            get: { model.translationModelName },
            set: { model.selectModel($0, forTranslation: true) }
          ), forTranslation: true)
        }
      } header: {
        Text("翻译模型")
      } footer: {
        if !model.usesSeparateTranslationModel {
          Text("默认与总结共用“\(model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前模型" : model.modelName)”。")
        }
      }

      Section {
        LabeledContent("在线转写模型") {
          TextField("例如 whisper-large-v3-turbo", text: $model.transcriptionModelName)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("transcription-model-name")
        }
      } header: {
        Text("在线视频转文字")
      } footer: {
        Text("留空时只使用 Apple 本机转写。配置后，App 会从直连视频流提取短 M4A 分片并调用 /audio/transcriptions，适合超过 200MB、无法本机导入的视频；每次上传前仍会确认。")
      }

      Section {
        LabeledContent("整理模型") {
          TextField("留空时使用总结模型", text: $model.tidyModelName)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("tidy-model-name")
        }
      } header: {
        Text("转写稿整理")
      } footer: {
        Text("把转写文字发送给聊天模型修正标点、分段和明显错别字，不改写内容。只发送文字本身，原始转写稿保留在历史中。")
      }

      Section {
        Toggle("自动转写（本机）", isOn: $model.autoTranscribeNewCaptures)
          .accessibilityIdentifier("auto-pipeline-transcribe")
        Toggle("转写后自动整理", isOn: $model.autoTidyTranscription)
          .accessibilityIdentifier("auto-tidy-transcription")
        Toggle("自动总结", isOn: $model.autoSummarizeNewCaptures)
          .accessibilityIdentifier("auto-pipeline-summarize")
        Toggle("自动生成脑图", isOn: $model.autoMindMapNewCaptures)
          .accessibilityIdentifier("auto-pipeline-mindmap")
      } header: {
        Text("自动处理管线")
      } footer: {
        Text("新内容到达后按顺序自动执行勾选的步骤：本机转写 → 整理文稿 → 总结 → 脑图。勾选即视为持久授权，自动执行时不再逐次弹出发送确认；首次使用某个模型服务时仍会按数据去向流程确认一次。本机转写不出网；整理/总结/脑图只发送文字。")
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
    .scrollContentBackground(.hidden)
    .background(settingsTheme.isNative ? Color(nsColor: .windowBackgroundColor) : settingsTheme.canvas)
  }

  // MARK: - 共用构件

  private func providerRow(_ preset: ProviderPreset) -> some View {
    HStack(spacing: 10) {
      providerIcon(preset)
      VStack(alignment: .leading, spacing: 2) {
        Text(preset.displayName)
          .font(.body.weight(.medium))
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
      Text(ProviderIconCatalog.fallbackInitial(for: preset))
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(ProviderIconCatalog.fallbackColor(for: preset), in: Circle())
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
