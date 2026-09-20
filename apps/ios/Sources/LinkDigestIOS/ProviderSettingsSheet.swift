import SwiftUI

/// BYOK：对齐 Mac 流程——填端点与 Key → 拉取模型 → 勾选添加 → 选当前 → 测试连接。
struct ProviderSettingsSheet: View {
  @Bindable var model: NotesViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var selectedPreset: IOSProviderPreset = .openCodeGo
  @State private var baseURL = ""
  @State private var modelName = ""
  @State private var addedModels: [String] = []
  @State private var outputLanguage = OpenAICompatibleSummarizer.defaultOutputLanguage
  @State private var apiKey = ""
  @State private var hasStoredKey = false
  @State private var saveError: String?
  @State private var didSave = false
  @State private var isSaving = false
  @State private var testMessage: String?
  @State private var isTesting = false

  @State private var catalogModels: [String] = []
  @State private var catalogSelection: Set<String> = []
  @State private var catalogSearch = ""
  @State private var isFetchingModels = false
  @State private var modelsMessage: String?
  @State private var showManualEntry = false

  private var filteredCatalog: [String] {
    let query = catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let base = query.isEmpty
      ? catalogModels
      : catalogModels.filter { $0.lowercased().contains(query) }
    return IOSModelCatalogSupport.sortedForDisplay(base, baseURL: baseURL)
  }

  private var hideUnsupportedCatalogModels: Bool {
    IOSModelCatalogSupport.isOpenCodeGoBaseURL(baseURL)
  }

  private var visibleCatalog: [String] {
    guard hideUnsupportedCatalogModels else { return filteredCatalog }
    // 默认只展示 chat/completions 可用 + 未知；不可用折叠，避免误选。
    return filteredCatalog.filter {
      IOSModelCatalogSupport.compatibility(modelID: $0, baseURL: baseURL) != .unsupportedTransport
    }
  }

  private var hiddenUnsupportedCount: Int {
    guard hideUnsupportedCatalogModels else { return 0 }
    return filteredCatalog.filter {
      IOSModelCatalogSupport.compatibility(modelID: $0, baseURL: baseURL) == .unsupportedTransport
    }.count
  }

  private var canFetchModels: Bool {
    !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var canTestConnection: Bool {
    !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canFetchModels
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("服务商", selection: $selectedPreset) {
            ForEach(IOSProviderPreset.allCases) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .onChange(of: selectedPreset) { _, preset in
            applyPreset(preset)
          }
        } header: {
          Text("快捷预设")
        } footer: {
          Text(selectedPreset.footerHint)
        }

        Section {
          TextField("https://opencode.ai/zen/go/v1", text: $baseURL)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .onChange(of: baseURL) { _, newValue in
              selectedPreset = IOSProviderPreset.matching(baseURL: newValue)
              resetCatalog()
            }
        } header: {
          Text("连接")
        } footer: {
          Text("根地址不要带 /chat/completions。下一步先保存或填写 API Key，再获取模型。")
        }

        Section {
          SecureField(hasStoredKey ? "已保存（留空则不改；填新值覆盖）" : "API Key", text: $apiKey)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onChange(of: apiKey) { _, _ in
              resetCatalog()
            }
          if hasStoredKey {
            Button("清除已保存的 API Key", role: .destructive) {
              do {
                try persist(apiKeyValue: "")
                hasStoredKey = false
                apiKey = ""
                didSave = true
              } catch {
                saveError = error.localizedDescription
              }
            }
          }
        } header: {
          Text("API Key")
        } footer: {
          if hasStoredKey {
            Text("本机钥匙串里已有 Key，获取模型 / 测试连接会自动用它，不必每次重填。要换 Key 就在上面输入新值后保存；要作废就点「清除」。Key 不进 iCloud。")
          } else {
            Text("Key 只进本机钥匙串。获取模型与测试连接都需要 Key（填一次保存后，下次可留空）。")
          }
        }

        Section {
          Button {
            Task { await fetchModels() }
          } label: {
            if isFetchingModels {
              HStack {
                ProgressView()
                Text("获取模型中…")
              }
            } else {
              Text("获取模型")
            }
          }
          .disabled(!canFetchModels || isFetchingModels || isTesting)

          if !catalogModels.isEmpty {
            TextField("搜索模型", text: $catalogSearch)
              #if os(iOS)
              .textInputAutocapitalization(.never)
              #endif
              .autocorrectionDisabled()

            ForEach(visibleCatalog, id: \.self) { id in
              let compatibility = IOSModelCatalogSupport.compatibility(modelID: id, baseURL: baseURL)
              Button {
                guard compatibility != .unsupportedTransport else { return }
                toggleCatalog(id)
              } label: {
                HStack {
                  Image(systemName: catalogSelection.contains(id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(
                      compatibility == .unsupportedTransport
                        ? Color.secondary.opacity(0.4)
                        : (catalogSelection.contains(id) ? Color.accentColor : .secondary)
                    )
                  Text(id)
                    .foregroundStyle(compatibility == .unsupportedTransport ? Color.secondary : .primary)
                    .lineLimit(1)
                  if let badge = IOSModelCatalogSupport.badgeText(for: compatibility) {
                    Text(badge)
                      .font(.caption2.weight(.semibold))
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(Color.secondary.opacity(0.15), in: Capsule())
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                }
              }
              .buttonStyle(.plain)
              .disabled(compatibility == .unsupportedTransport)
            }

            if hiddenUnsupportedCount > 0 {
              Text("已隐藏 \(hiddenUnsupportedCount) 个不支持 chat/completions 的模型（如 Qwen / MiniMax / Grok）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Text("已勾选 \(catalogSelection.count) 个")
              .font(.footnote)
              .foregroundStyle(catalogSelection.isEmpty ? Color.secondary : Color.accentColor)

            Button("添加所选到列表") {
              addSelectedToList()
            }
            .disabled(catalogSelection.isEmpty)
          }

          if let modelsMessage {
            Text(modelsMessage)
              .font(.footnote)
              .foregroundStyle(
                modelsMessage.hasPrefix("已") || modelsMessage.hasPrefix("成功")
                  ? Color.secondary
                  : Color.red
              )
          }
        } header: {
          Text("从服务商拉取")
        } footer: {
          Text("与 Mac 相同：先 GET /models，勾选后可点「添加所选到列表」，或直接点右上角保存（会自动带上勾选项）。OpenCode Go 里部分模型走 messages/responses，当前 App 只支持 chat/completions（如 glm-5.3-flash、deepseek-v4-flash、kimi-k2.6）；选错会测连失败。")
        }

        Section {
          if addedModels.isEmpty {
            Text("还没有已添加的模型。请先「获取模型」并勾选添加。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            Picker("当前使用", selection: $modelName) {
              ForEach(addedModels, id: \.self) { id in
                Text(displayNameForAddedModel(id)).tag(id)
              }
            }
            .pickerStyle(.menu)

            if !modelName.isEmpty {
              Text("总结 / 翻译 / 测试连接将使用：\(modelName)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
            }
            ForEach(addedModels, id: \.self) { id in
              HStack(spacing: 12) {
                Button {
                  modelName = id
                } label: {
                  HStack {
                    Text(id)
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                    if id == modelName {
                      Text("使用中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Form 里默认 Button 会占满整行，点模型名也会误触删除；必须 borderless。
                Button("移除", role: .destructive) {
                  removeAdded(id)
                }
                .font(.caption)
                .buttonStyle(.borderless)
              }
            }
          }

          Button(showManualEntry ? "收起手动填写" : "高级：手动填写模型名") {
            showManualEntry.toggle()
          }
          if showManualEntry {
            TextField("手动模型名", text: $modelName)
              #if os(iOS)
              .textInputAutocapitalization(.never)
              #endif
              .autocorrectionDisabled()
              .onChange(of: modelName) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !addedModels.contains(trimmed) else { return }
                addedModels.append(trimmed)
              }
          }
        } header: {
          Text("已添加的模型")
        } footer: {
          Text("可添加多个；总结 / 翻译 / 测试连接使用「当前使用」这一项。")
        }

        Section {
          TextField("简体中文", text: $outputLanguage)
        } header: {
          Text("输出语言")
        }

        Section {
          Button {
            Task { await runConnectionTest() }
          } label: {
            if isTesting {
              HStack {
                ProgressView()
                Text("测试中…")
              }
            } else {
              Text("测试连接")
            }
          }
          .disabled(!canTestConnection || isTesting || isFetchingModels || isSaving)
          if let testMessage {
            Text(testMessage)
              .font(.footnote)
              .foregroundStyle(testMessage.hasPrefix("成功") ? Color.secondary : Color.red)
          }
        } footer: {
          Text("先选好当前模型再测。会发一条极短 chat/completions，确认订阅 / Key / 端点。")
        }

        if let saveError {
          Section {
            Text(saveError)
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
        if didSave {
          Section {
            Text(modelsMessage?.hasPrefix("已保存") == true ? (modelsMessage ?? "已保存。") : "已保存。")
              .foregroundStyle(.secondary)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("模型设置")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
          } else {
            Button(catalogSelection.isEmpty ? "保存" : "保存(\(catalogSelection.count))") {
              save()
            }
            .disabled(isSaving || isTesting || isFetchingModels)
          }
        }
      }
      .onAppear { loadExisting() }
    }
  }

  private func loadExisting() {
    let profile = model.loadProviderProfile()
    if profile.baseURL.isEmpty {
      applyPreset(.openCodeGo)
    } else {
      baseURL = profile.baseURL
      modelName = profile.modelName
      addedModels = profile.addedModels
      selectedPreset = IOSProviderPreset.matching(baseURL: profile.baseURL)
    }
    outputLanguage = profile.outputLanguage.isEmpty
      ? OpenAICompatibleSummarizer.defaultOutputLanguage
      : profile.outputLanguage
    hasStoredKey = model.hasStoredAPIKey()
  }

  private func applyPreset(_ preset: IOSProviderPreset) {
    selectedPreset = preset
    if !preset.baseURL.isEmpty {
      baseURL = preset.baseURL
    }
    // 不自动填过期模型名；等用户拉取后勾选。
    resetCatalog()
  }

  private func resetCatalog() {
    catalogModels = []
    catalogSelection = []
    catalogSearch = ""
    modelsMessage = nil
  }

  private func displayNameForAddedModel(_ id: String) -> String {
    switch IOSModelCatalogSupport.compatibility(modelID: id, baseURL: baseURL) {
    case .unsupportedTransport:
      return "\(id)（可能不可用）"
    case .unknown:
      return "\(id)（未验证）"
    case .supported:
      return id
    }
  }

  private func toggleCatalog(_ id: String) {
    if IOSModelCatalogSupport.compatibility(modelID: id, baseURL: baseURL) == .unsupportedTransport {
      return
    }
    if catalogSelection.contains(id) {
      catalogSelection.remove(id)
    } else {
      catalogSelection.insert(id)
    }
  }

  private func addSelectedToList() {
    let ordered = mergeCatalogSelectionIntoAddedModels()
    guard !ordered.isEmpty else {
      modelsMessage = "请先勾选至少一个可用模型。"
      return
    }
    modelsMessage = "已添加 \(ordered.count) 个模型。请确认「当前使用」，再测试连接或点保存。"
  }

  /// 把当前勾选并入「已添加」；返回本次勾选的有序列表。
  @discardableResult
  private func mergeCatalogSelectionIntoAddedModels() -> [String] {
    let ordered = catalogModels.filter {
      catalogSelection.contains($0)
        && IOSModelCatalogSupport.compatibility(modelID: $0, baseURL: baseURL) != .unsupportedTransport
    }
    guard !ordered.isEmpty else { return [] }
    var next = addedModels
    for id in ordered where !next.contains(id) {
      next.append(id)
    }
    addedModels = next
    if modelName.isEmpty || !addedModels.contains(modelName) {
      modelName = ordered[0]
    }
    return ordered
  }

  private func removeAdded(_ id: String) {
    addedModels.removeAll { $0 == id }
    if modelName == id {
      modelName = addedModels.first ?? ""
    }
  }

  private func persist(apiKeyValue: String?) throws {
    try model.saveProviderSettings(
      baseURL: baseURL,
      modelName: modelName,
      apiKey: apiKeyValue,
      outputLanguage: outputLanguage,
      addedModels: addedModels
    )
  }

  private func save() {
    saveError = nil
    didSave = false
    // 勾选后直接点「保存」应等同「添加所选 + 落盘」，不要看起来没反应。
    if !catalogSelection.isEmpty {
      mergeCatalogSelectionIntoAddedModels()
    }
    let active = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    if addedModels.isEmpty || active.isEmpty {
      saveError = "还没有可保存的模型。请先「获取模型」，勾选后点保存（或先点「添加所选到列表」）。"
      return
    }
    if IOSModelCatalogSupport.compatibility(modelID: active, baseURL: baseURL) == .unsupportedTransport {
      saveError = "当前模型 \(active) 不支持 chat/completions，请改选 glm / deepseek / kimi / hy3 等。"
      return
    }
    if !addedModels.contains(active) {
      addedModels.insert(active, at: 0)
    }
    isSaving = true
    defer { isSaving = false }
    do {
      try persist(apiKeyValue: apiKey.isEmpty ? nil : apiKey)
      hasStoredKey = model.hasStoredAPIKey()
      apiKey = ""
      didSave = true
      modelsMessage = "已保存 \(addedModels.count) 个模型，当前使用：\(active)。"
      catalogSelection = []
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }

  private func fetchModels() async {
    isFetchingModels = true
    modelsMessage = nil
    defer { isFetchingModels = false }
    do {
      // 若表单里刚填了 Key，先落盘，避免只拉一次却测连时还没 Key。
      if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try persist(apiKeyValue: apiKey)
        hasStoredKey = model.hasStoredAPIKey()
        apiKey = ""
      }
      let models = try await model.listProviderModels(
        baseURL: baseURL,
        apiKeyOverride: nil
      )
      catalogModels = IOSModelCatalogSupport.sortedForDisplay(models, baseURL: baseURL)
      catalogSelection = Set(
        models.filter {
          addedModels.contains($0)
            && IOSModelCatalogSupport.compatibility(modelID: $0, baseURL: baseURL) != .unsupportedTransport
        }
      )
      if let active = models.first(where: { $0 == modelName }),
         IOSModelCatalogSupport.compatibility(modelID: active, baseURL: baseURL) != .unsupportedTransport
      {
        catalogSelection.insert(active)
      }
      let usable = models.filter {
        IOSModelCatalogSupport.compatibility(modelID: $0, baseURL: baseURL) != .unsupportedTransport
      }.count
      modelsMessage = "已获取 \(models.count) 个模型（约 \(usable) 个可用于本 App），勾选后保存即可。"
    } catch {
      catalogModels = []
      catalogSelection = []
      modelsMessage = error.localizedDescription
    }
  }

  private func runConnectionTest() async {
    isTesting = true
    testMessage = nil
    defer { isTesting = false }
    do {
      try persist(apiKeyValue: apiKey.isEmpty ? nil : apiKey)
      hasStoredKey = model.hasStoredAPIKey()
      apiKey = ""
      let reply = try await model.testProviderConnection()
      testMessage = "成功：\(reply)"
      didSave = true
    } catch {
      testMessage = error.localizedDescription
    }
  }
}
