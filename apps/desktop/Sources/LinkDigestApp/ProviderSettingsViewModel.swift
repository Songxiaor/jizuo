import Combine
import Foundation
import LinkDigestCore

enum ProviderSettingsState: Equatable {
  case unconfigured
  case saving
  case configured
  case failed(code: String)
}

enum ConnectionTestState: Equatable {
  case idle
  case testing
  case success
  case failure(code: String)
  case blockedUnsavedChanges
}

enum ModelPreferencesState: Equatable {
  case loading
  case idle
  case saving
  case saved
  case failed(String)
}

enum ModelCatalogState: Equatable {
  case idle
  case loading
  case loaded
  case failed(code: ModelProviderErrorCode)
}

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
  private static let modelCatalogLimit = 500
  @Published var baseURL = "" {
    didSet {
      handleDraftEdit(from: oldValue, to: baseURL, invalidatesModelCatalog: true)
      if selectedPreset.baseURLTemplate != baseURL { selectedPreset = .custom }
    }
  }
  @Published var modelName = "" {
    didSet { handleDraftEdit(from: oldValue, to: modelName, invalidatesModelCatalog: false) }
  }
  @Published private(set) var selectedPreset: ProviderPreset = .custom
  @Published var modelSearchQuery = ""
  @Published private(set) var availableModels: [String] = []
  @Published private(set) var selectedCatalogModels: Set<String> = []
  @Published private(set) var modelCatalogState: ModelCatalogState = .idle
  @Published private(set) var state: ProviderSettingsState = .unconfigured
  @Published private(set) var connectionTestState: ConnectionTestState = .idle
  @Published private(set) var savedIdentity: DataDestinationIdentity?
  @Published var summaryPrompt = ModelPreferences.defaultSummaryPrompt
  @Published var targetLanguage = ModelPreferences.defaultTargetLanguage
  /// 「翻译是否另用一个模型」不再是一个独立的开关状态，而是从模型名推出来的：
  /// 名字为空就是跟随总结。原来它是一个 `@Published` 布尔量，于是同一件事有了
  /// 两个真相源——开关开着但名字为空、或名字填了开关却是关的，两种矛盾状态都能
  /// 存在，落盘时还得靠 `usesSeparateTranslationModel ? name : nil` 现场调和。
  var usesSeparateTranslationModel: Bool {
    !translationModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  @Published var translationModelName = ""
  @Published var transcriptionModelName = ""
  @Published var tidyModelName = ""
  /// 四个管线开关拨下去就要落盘：它们是持久授权，不是草稿。
  /// 以前只改内存、要另点「保存生成偏好」，退出后再打开就会回到上次真正写下的值。
  @Published var autoTidyTranscription = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoTidyTranscription) }
  }
  @Published var autoTranscribeNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoTranscribeNewCaptures) }
  }
  @Published var autoSummarizeNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoSummarizeNewCaptures) }
  }
  @Published var autoMindMapNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoMindMapNewCaptures) }
  }
  @Published var translationConcurrency = ModelPreferences.defaultTranslationConcurrency
  @Published private(set) var preferencesState: ModelPreferencesState = .loading
  @Published private(set) var savedPreferences = ModelPreferences.default
  @Published private(set) var isReplacingAPIKey = false
  @Published private(set) var isManualModelEntryEnabled = false
  @Published private(set) var isConfigurationLoading = true
  @Published private(set) var libraryProfiles: [ProviderProfile] = []
  @Published private(set) var summaryAssignmentID: String?
  @Published private(set) var transcriptionAssignmentID: String?
  @Published private(set) var libraryErrorText: String?
  /// nil while adding a new model; otherwise the library entry being edited.
  @Published private(set) var editingProfileID: String?
  @Published private(set) var isEditorVisible = false
  @Published private(set) var lastSavedProfileCount = 0

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let modelCatalogLoader: (any ModelCatalogLoading)?
  private let preferencesStore: any ModelPreferencesStore
  private var hasStartedConfigurationLoad = false
  private var draftGeneration: UInt64 = 0
  /// 读盘或写回自己的快照时，不要把赋值再当成一次用户拨杆。
  private var isApplyingLoadedPreferences = false
  /// 连续拨杆串成一条保存链，后来的等待先到的写完，再按最新开关落盘。
  private var preferencesSaveTail: Task<Void, Never>?
  private var activeTestRequest: ConnectionTestRequest?
  private var activeModelCatalogRequest: ModelCatalogRequest?

  private struct ConnectionTestRequest {
    let id: UUID
    let generation: UInt64
    let identity: DataDestinationIdentity
  }

  /// Non-secret request ownership. The API key remains a local parameter in
  /// `loadModels` and is never retained by observable or request state.
  private struct ModelCatalogRequest {
    let id: UUID
    let generation: UInt64
    let baseURL: URL
  }

  init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider,
    modelCatalogLoader: (any ModelCatalogLoading)? = nil,
    preferencesStore: any ModelPreferencesStore = InMemoryDefaultModelPreferencesStore()
  ) {
    self.configurationService = configurationService
    self.provider = provider
    self.modelCatalogLoader = modelCatalogLoader ?? (provider as? any ModelCatalogLoading)
    self.preferencesStore = preferencesStore
  }

  var isSaving: Bool {
    state == .saving
  }

  var isTestingConnection: Bool {
    activeTestRequest != nil
  }

  var hasConfiguredAPIKey: Bool {
    state == .configured
  }

  var shouldShowAPIKeyInput: Bool {
    !hasConfiguredAPIKey || isReplacingAPIKey
  }

  var canSaveConfiguration: Bool {
    let hasModelSelection = isAddingModelBatch
      ? !selectedCatalogModels.isEmpty
      : !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return !isConfigurationLoading
      && !isSaving
      && !isTestingConnection
      && (!hasConfiguredAPIKey || isReplacingAPIKey || isEditingLibraryEntry)
      && hasModelSelection
      && (modelCatalogLoader == nil || hasConfiguredAPIKey || modelCatalogState == .loaded || isManualModelEntryEnabled)
  }

  var isAddingModelBatch: Bool {
    editingProfileID == nil && modelCatalogState == .loaded && !availableModels.isEmpty
  }

  var selectedCatalogModelCount: Int { selectedCatalogModels.count }

  var orderedSelectedCatalogModels: [String] {
    availableModels.filter { selectedCatalogModels.contains($0) }
  }

  /// Multi-profile editing keeps the stored secret, so saving endpoint/model
  /// changes without re-entering the key is only offered with library support.
  private var isEditingLibraryEntry: Bool {
    configurationService.supportsModelLibrary && editingProfileID != nil
  }

  var canTestConnection: Bool {
    !isConfigurationLoading
      && !isSaving
      && !isTestingConnection
      && hasConfiguredAPIKey
      && !isReplacingAPIKey
      && !hasUnsavedIdentityChanges
  }

  var canBeginAPIKeyReplacement: Bool {
    !isConfigurationLoading && hasConfiguredAPIKey && !isSaving && !isTestingConnection
  }

  var apiKeyStatusText: String {
    "✓ 已配置"
  }

  var runPreferences: ModelPreferences { savedPreferences }
  var outputLanguage: String {
    get { targetLanguage }
    set { targetLanguage = newValue }
  }
  /// 详情页徽标等「当前生效模型」的只读展示源。`modelName` 是设置编辑器的
  /// 草稿字段：点开「添加模型」表单会被清空、关闭表单不恢复，切换总结指派
  /// 也不会同步它，所以不能当真相源。真正决定下次总结用哪个模型的是模型库
  /// 里被指派为总结的 profile（运行取凭据走的同一条链），这里直接从它读；
  /// 没有模型库（旧单槽配置）时再回落到草稿字段。
  var activeSummaryModelName: String {
    let assigned = libraryProfiles
      .first(where: { $0.id == summaryAssignmentID })?
      .model
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let assigned, !assigned.isEmpty { return assigned }
    return modelName.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var effectiveTranslationModelName: String {
    usesSeparateTranslationModel ? translationModelName : activeSummaryModelName
  }
  /// Online transcription requires both an explicit per-capability assignment
  /// (the default stays local) and a transcription model name.
  var effectiveTranscriptionModelName: String? {
    guard let assignmentID = transcriptionAssignmentID else { return nil }
    // 旧的手填模型名只作显式覆盖；正常路径直接取 assignment 指向的 profile。
    //
    // 之前这里只读手填字段：用户在「视频转文字」下拉里选好了模型
    // （transcriptionAssignmentID 已设、转写凭据也能解析），但因为从没在旧
    // 文本框里填过名字，这里返回 nil，「在线转写」就永远是灰的——设置页
    // 显示已配置、菜单却说未配置，两套体系在这断开。模型名本来就存在
    // profile 里，凭据解析（loadTranscriptionCredentials）走的也是同一个
    // profile，从这取才是同一条链。
    let manual = transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !manual.isEmpty { return manual }
    let assigned = libraryProfiles.first(where: { $0.id == assignmentID })?.model
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return assigned?.isEmpty == false ? assigned : nil
  }
  /// nil inherits the summary/chat model inside the tidy adapter.
  var effectiveTidyModelName: String? {
    let value = tidyModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
  var dataDestinationCard: DataDestinationIdentity? { draftIdentity ?? savedIdentity }
  var isLocalEndpoint: Bool { dataDestinationCard?.isLocalEndpoint == true }
  var isLoadingModels: Bool { activeModelCatalogRequest != nil }
  var filteredModels: [String] {
    let query = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return query.isEmpty ? availableModels : availableModels.filter { $0.lowercased().contains(query) }
  }
  var canLoadModelCatalog: Bool {
    modelCatalogLoader != nil
      && !isConfigurationLoading
      && !isSaving
      && !isTestingConnection
      && !isLoadingModels
      && validatedCatalogBaseURL != nil
  }
  var shouldOfferManualModelEntry: Bool {
    if case .failed = modelCatalogState { return !isManualModelEntryEnabled }
    return false
  }
  var modelCatalogStatusText: String {
    switch modelCatalogState {
    case .idle: "先填写 Base URL 和 API Key，再验证模型列表；匹配推荐模型时会自动选择。"
    case .loading: "正在读取模型列表…"
    case .loaded:
      "已读取 \(availableModels.count) 个模型；已选择 \(selectedCatalogModels.count) 个。"
    // secret-hygiene:reviewed code 是内部错误码枚举，经 modelCatalogFailureText 映射成
    // 固定本地文案后才显示——这正是本规则要求的做法，provider 原文不跨边界。
    case let .failed(code): modelCatalogFailureText(code)  // secret-hygiene:reviewed
    }
  }

  var arePreferencesReady: Bool {
    preferencesState != .loading
  }

  /// The preference save action follows the same rule at both the SwiftUI and
  /// ViewModel boundaries. A load in flight owns the persisted value until it
  /// has finished populating this draft.
  var canSavePreferences: Bool {
    preferencesState != .loading && preferencesState != .saving
  }

  var preferencesStatusText: String {
    switch preferencesState {
    case .loading: "正在读取生成偏好…"
    case .idle: "使用已保存的生成偏好"
    case .saving: "正在保存生成偏好…"
    case .saved: "生成偏好已保存"
    case let .failed(message): message
    }
  }

  var hasUnsavedIdentityChanges: Bool {
    guard let savedIdentity, let draftIdentity else { return true }
    return draftIdentity != savedIdentity
  }

  var statusText: String {
    if isConfigurationLoading {
      return "正在读取模型配置…"
    }
    return switch state {
    case .unconfigured:
      "先验证模型列表并选择模型，再保存；\(ProductDisplay.name) 不会回显完整 API Key。"
    case .saving:
      "正在安全保存…"
    case .configured:
      lastSavedProfileCount > 1 ? "已保存 \(lastSavedProfileCount) 个模型配置" : "模型配置已保存"
    case let .failed(code):
      V02ErrorCatalog.presentation(for: code).visibleText
    }
  }

  var connectionTestStatusText: String {
    switch connectionTestState {
    case .idle:
      "尚未测试连接"
    case .testing:
      "正在测试连接…"
    case .success:
      "连接成功。"
    case let .failure(code):
      V02ErrorCatalog.presentation(for: code).visibleText
    case .blockedUnsavedChanges:
      "有未保存更改，请先保存后再测试"
    }
  }

  func load() async {
    guard !hasStartedConfigurationLoad else {
      return
    }
    hasStartedConfigurationLoad = true
    isConfigurationLoading = true
    defer { isConfigurationLoading = false }

    preferencesState = .loading
    do {
      let preferences = try await preferencesStore.load()
      applyLoadedPreferences(preferences)
      preferencesState = .idle
    } catch {
      preferencesState = .failed("无法读取生成偏好，当前使用默认值。")
    }

    do {
      guard let profile = try await configurationService.load() else {
        savedIdentity = nil
        state = .unconfigured
        await refreshLibrary()
        isEditorVisible = libraryProfiles.isEmpty
        editingProfileID = nil
        return
      }
      baseURL = profile.baseURL.absoluteString
      modelName = profile.model
      selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      savedIdentity = DataDestinationIdentity(profile: profile)
      connectionTestState = .idle
      state = .configured
      await refreshLibrary()
      // The populated form belongs to the summary-assigned entry so an
      // immediate save updates it instead of appending a duplicate.
      editingProfileID = libraryProfiles.first(where: { $0.id == summaryAssignmentID })?.id
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreReadFailed.rawValue)
    }
  }

  // MARK: - 模型库

  struct LibraryEntryDisplay: Identifiable, Equatable {
    let id: String
    let title: String
    let modelName: String
    let displayName: String
    let preset: ProviderPreset
    let supportsOnlineTranscription: Bool
  }

  var libraryEntryDisplays: [LibraryEntryDisplay] {
    libraryProfiles.map { profile in
      let preset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      let title = preset == .custom ? (profile.baseURL.host ?? "自定义") : preset.displayName
      return LibraryEntryDisplay(
        id: profile.id,
        title: title,
        modelName: profile.model,
        displayName: Self.friendlyModelName(profile.model),
        preset: preset,
        supportsOnlineTranscription: Self.isTranscriptionModel(profile.model)
      )
    }
  }

  var transcriptionEntryDisplays: [LibraryEntryDisplay] {
    libraryEntryDisplays.filter(\.supportsOnlineTranscription)
  }

  var summaryEntryDisplays: [LibraryEntryDisplay] {
    libraryEntryDisplays.filter { !$0.supportsOnlineTranscription }
  }

  static func friendlyModelName(_ modelName: String) -> String {
    let leaf = modelName
      .split(separator: "/")
      .last
      .map(String.init)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "~"))
      ?? modelName
    let replacements: [String: String] = [
      "asr": "ASR",
      "tts": "TTS",
      "gpt": "GPT",
      "glm": "GLM",
      "llm": "LLM",
      "ocr": "OCR",
      "api": "API",
      "deepseek": "DeepSeek",
      "stepaudio": "StepAudio",
      "step": "Step",
      "whisper": "Whisper",
      "qwen": "Qwen",
      "llama": "Llama",
      "gemini": "Gemini",
      "claude": "Claude",
      "flash": "Flash",
      "turbo": "Turbo",
      "mini": "Mini",
      "nano": "Nano",
      "pro": "Pro",
      "chat": "Chat",
      "realtime": "Realtime",
      "latest": "Latest",
    ]
    let words = leaf
      .split(whereSeparator: { $0 == "-" || $0 == "_" })
      .map(String.init)
      .map { word -> String in
        let lowercased = word.lowercased()
        if let replacement = replacements[lowercased] { return replacement }
        if lowercased.hasPrefix("v"), lowercased.dropFirst().first?.isNumber == true {
          return "V" + lowercased.dropFirst()
        }
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
      }
    return words.isEmpty ? modelName : words.joined(separator: " ")
  }

  static func isTranscriptionModel(_ modelName: String) -> Bool {
    let normalized = modelName.lowercased()
    return normalized.contains("whisper")
      || normalized.contains("transcrib")
      || normalized.contains("speech-to-text")
      || normalized.contains("speech_to_text")
      || normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("asr")
  }

  func refreshLibrary() async {
    do {
      let library = try await configurationService.loadLibrary()
      libraryProfiles = library.profiles
      summaryAssignmentID = library.summaryProfileID
      transcriptionAssignmentID = library.transcriptionProfileID
      libraryErrorText = nil
    } catch {
      libraryErrorText = "无法读取已添加的模型列表。"
    }
  }

  func beginAddModel() {
    guard !isSaving, !isTestingConnection, !isLoadingModels else { return }
    editingProfileID = nil
    isEditorVisible = true
    baseURL = ""
    modelName = ""
    selectedPreset = .custom
    savedIdentity = nil
    isReplacingAPIKey = false
    connectionTestState = .idle
    state = .unconfigured
    selectedCatalogModels = []
    lastSavedProfileCount = 0
    invalidateModelCatalog()
  }

  func beginEditModel(_ id: String) {
    guard !isSaving, !isTestingConnection, !isLoadingModels,
          let profile = libraryProfiles.first(where: { $0.id == id })
    else { return }
    editingProfileID = id
    isEditorVisible = true
    baseURL = profile.baseURL.absoluteString
    modelName = profile.model
    selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
    savedIdentity = DataDestinationIdentity(profile: profile)
    isReplacingAPIKey = false
    connectionTestState = .idle
    state = .configured
    selectedCatalogModels = []
    lastSavedProfileCount = 0
    invalidateModelCatalog()
  }

  func closeEditor() {
    guard !isSaving, !isTestingConnection, !isLoadingModels else { return }
    isEditorVisible = false
  }

  func deleteModel(_ id: String) async {
    guard !isSaving, !isTestingConnection, !isLoadingModels else { return }
    do {
      _ = try await configurationService.deleteProfile(id: id)
      await refreshLibrary()
      if editingProfileID == id {
        editingProfileID = nil
        isEditorVisible = false
        savedIdentity = nil
        state = .unconfigured
      }
    } catch {
      libraryErrorText = "无法删除该模型配置。"
    }
  }

  func assignSummaryModel(_ id: String?) async {
    guard summaryAssignmentID != id else { return }
    do {
      try await configurationService.assignSummaryProfile(id: id)
      await refreshLibrary()
    } catch {
      libraryErrorText = "无法切换总结与翻译使用的模型。"
      await refreshLibrary()
    }
  }

  func assignTranscriptionModel(_ id: String?) async {
    guard transcriptionAssignmentID != id else { return }
    do {
      try await configurationService.assignTranscriptionProfile(id: id)
      await refreshLibrary()
    } catch {
      libraryErrorText = "无法切换视频转文字使用的模型。"
      await refreshLibrary()
    }
  }

  func savePreferences() async {
    guard preferencesState != .loading else { return }
    let previous = preferencesSaveTail
    let task = Task { @MainActor in
      await previous?.value
      await self.performSavePreferencesOnce()
    }
    preferencesSaveTail = task
    await task.value
  }

  func resetSummaryPrompt() {
    summaryPrompt = ModelPreferences.defaultSummaryPrompt
  }

  private func persistPipelinePreferenceIfChanged(from oldValue: Bool, to newValue: Bool) {
    guard !isApplyingLoadedPreferences, oldValue != newValue, preferencesState != .loading else {
      return
    }
    Task { await savePreferences() }
  }

  private func performSavePreferencesOnce() async {
    guard preferencesState != .loading else { return }
    while true {
      preferencesState = .saving
      let snapshot = pipelineFlagSnapshot
      let preferences: ModelPreferences
      do {
        preferences = try currentDraftPreferences()
        try await preferencesStore.save(preferences)
      } catch let error as ModelPreferencesError {
        applyPreferencesSaveFailure(error)
        return
      } catch {
        preferencesState = .failed("无法保存生成偏好，请稍后重试。")
        return
      }
      if pipelineFlagSnapshot != snapshot {
        continue
      }
      applyLoadedPreferences(preferences)
      preferencesState = .saved
      return
    }
  }

  private var pipelineFlagSnapshot: (Bool, Bool, Bool, Bool) {
    (autoTidyTranscription, autoTranscribeNewCaptures, autoSummarizeNewCaptures, autoMindMapNewCaptures)
  }

  private func currentDraftPreferences() throws -> ModelPreferences {
    try ModelPreferences(
      summaryPrompt: summaryPrompt,
      targetLanguage: targetLanguage,
      translationModel: usesSeparateTranslationModel ? translationModelName : nil,
      transcriptionModel: transcriptionModelName,
      tidyModel: tidyModelName,
      autoTidyTranscription: autoTidyTranscription,
      autoTranscribeNewCaptures: autoTranscribeNewCaptures,
      autoSummarizeNewCaptures: autoSummarizeNewCaptures,
      autoMindMapNewCaptures: autoMindMapNewCaptures,
      translationConcurrency: translationConcurrency
    )
  }

  private func applyLoadedPreferences(_ preferences: ModelPreferences) {
    isApplyingLoadedPreferences = true
    defer { isApplyingLoadedPreferences = false }
    summaryPrompt = preferences.summaryPrompt
    targetLanguage = preferences.targetLanguage
    translationModelName = preferences.translationModel ?? ""
    transcriptionModelName = preferences.transcriptionModel ?? ""
    tidyModelName = preferences.tidyModel ?? ""
    autoTidyTranscription = preferences.autoTidyTranscription == true
    autoTranscribeNewCaptures = preferences.autoTranscribeNewCaptures == true
    autoSummarizeNewCaptures = preferences.autoSummarizeNewCaptures == true
    autoMindMapNewCaptures = preferences.autoMindMapNewCaptures == true
    translationConcurrency = preferences.effectiveTranslationConcurrency
    savedPreferences = preferences
  }

  private func applyPreferencesSaveFailure(_ error: ModelPreferencesError) {
    switch error {
    case .summaryPromptTooLong:
      preferencesState = .failed("总结提示词不能超过 4,000 个字符。")
    case .targetLanguageRequired:
      preferencesState = .failed("请选择或填写翻译目标语言。")
    case .targetLanguageTooLong:
      preferencesState = .failed("翻译目标语言不能超过 100 个字符。")
    case .translationModelTooLong:
      preferencesState = .failed("翻译模型名不能超过 256 个字符。")
    case .transcriptionModelTooLong:
      preferencesState = .failed("在线转写模型名不能超过 256 个字符。")
    case .tidyModelTooLong:
      preferencesState = .failed("校对模型名不能超过 256 个字符。")
    case .readFailed, .writeFailed:
      preferencesState = .failed("无法保存生成偏好，请稍后重试。")
    }
  }

  func beginAPIKeyReplacement() {
    guard canBeginAPIKeyReplacement else { return }
    isReplacingAPIKey = true
  }

  func selectPreset(_ preset: ProviderPreset) {
    guard !isConfigurationLoading, !isSaving, !isTestingConnection, !isLoadingModels else { return }
    selectedPreset = preset
    if !preset.baseURLTemplate.isEmpty {
      baseURL = preset.baseURLTemplate
    }
    if transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let recommended = preset.recommendedTranscriptionModel {
      transcriptionModelName = recommended
    }
  }

  func selectModel(_ value: String, forTranslation: Bool = false) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if forTranslation {
      translationModelName = trimmed
    } else {
      if isAddingModelBatch, availableModels.contains(trimmed) {
        selectedCatalogModels = [trimmed]
      }
      modelName = trimmed
    }
  }

  func toggleCatalogModel(_ value: String) {
    guard isAddingModelBatch, availableModels.contains(value) else { return }
    if selectedCatalogModels.contains(value) {
      selectedCatalogModels.remove(value)
    } else {
      selectedCatalogModels.insert(value)
    }
    modelName = orderedSelectedCatalogModels.first ?? ""
  }

  func apiKeyDraftDidChange() {
    invalidateModelCatalog()
  }

  func enableManualModelEntry() {
    guard shouldOfferManualModelEntry else { return }
    isManualModelEntryEnabled = true
  }

  func save(apiKey: String) async {
    guard canSaveConfiguration else {
      return
    }
    connectionTestState = .idle
    state = .saving
    let submittedBaseURL = baseURL
    let submittedModels = isAddingModelBatch
      ? orderedSelectedCatalogModels
      : [modelName]

    do {
      let savedProfiles: [ProviderProfile]
      if let editingProfileID {
        // Replacing the key requires a fresh value; otherwise keep the
        // stored secret and only update endpoint/model.
        let submittedKey: String? = shouldShowAPIKeyInput ? apiKey : nil
        savedProfiles = [try await configurationService.updateProfile(
          id: editingProfileID,
          baseURL: submittedBaseURL,
          model: submittedModels[0],
          apiKey: submittedKey,
          allowLoopbackHTTP: Self.isExactLoopbackHTTP(submittedBaseURL)
        )]
      } else {
        savedProfiles = try await configurationService.addProfiles(
          baseURL: submittedBaseURL,
          models: submittedModels,
          apiKey: apiKey,
          allowLoopbackHTTP: Self.isExactLoopbackHTTP(submittedBaseURL)
        )
      }
      guard let profile = savedProfiles.first else {
        throw ProviderConfigurationError.modelRequired
      }
      savedIdentity = DataDestinationIdentity(profile: profile)
      modelName = profile.model
      lastSavedProfileCount = savedProfiles.count
      connectionTestState = .idle
      isReplacingAPIKey = false
      state = .configured
      selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      await refreshLibrary()
      if editingProfileID == nil {
        selectedCatalogModels = []
        isEditorVisible = false
      }
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreWriteFailed.rawValue)
    }
  }

  func testConnection() async {
    guard canTestConnection, let savedIdentity
    else {
      connectionTestState = .blockedUnsavedChanges
      return
    }

    let request = ConnectionTestRequest(
      id: UUID(),
      generation: draftGeneration,
      identity: savedIdentity
    )
    activeTestRequest = request
    connectionTestState = .testing
    defer { releaseTestRequest(ifOwner: request.id) }

    do {
      guard canUseSavedConfiguration(for: request) else {
        connectionTestState = .blockedUnsavedChanges
        return
      }
      guard let credentials = try await loadEditorCredentials() else {
        applyTestResult(
          .failure(code: ModelRunErrorCode.modelNotConfigured.rawValue),
          for: request
        )
        return
      }
      guard DataDestinationIdentity(profile: credentials.profile) == request.identity else {
        applyTestResult(
          .failure(code: ProviderConfigurationError.configurationChanged.rawValue),
          for: request
        )
        return
      }
      var completed = false
      for try await event in provider.stream(
        profile: credentials.profile,
        apiKey: credentials.apiKey,
        intent: .connectionTest
      ) {
        if case .completed = event {
          completed = true
          break
        }
      }
      applyTestResult(
        completed ? .success : .failure(code: ModelProviderErrorCode.networkInterrupted.rawValue),
        for: request
      )
    } catch let error as ProviderConfigurationError {
      applyTestResult(.failure(code: error.rawValue), for: request)
    } catch let failure as ModelProviderFailure {
      applyTestResult(
        .failure(code: failure.code.rawValue),
        for: request
      )
    } catch {
      applyTestResult(
        .failure(code: ModelProviderErrorCode.networkInterrupted.rawValue),
        for: request
      )
    }
  }

  func loadModels(apiKey: String) async {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      modelCatalogState = .failed(code: .authInvalid)
      availableModels = []
      isManualModelEntryEnabled = false
      return
    }
    await loadModels(submittedAPIKey: apiKey)
  }

  /// Reloads the catalog for an already-saved configuration. The Keychain
  /// value is read only for this call and is never copied into ViewModel state.
  func loadModels() async {
    await loadModels(submittedAPIKey: nil)
  }

  private func loadModels(submittedAPIKey: String?) async {
    guard canLoadModelCatalog,
          let requestBaseURL = validatedCatalogBaseURL,
          let modelCatalogLoader
    else {
      if validatedCatalogBaseURL == nil {
        modelCatalogState = .failed(code: .baseURLInvalid)
      }
      return
    }
    let request = ModelCatalogRequest(id: UUID(), generation: draftGeneration, baseURL: requestBaseURL)
    activeModelCatalogRequest = request
    modelCatalogState = .loading
    availableModels = []
    isManualModelEntryEnabled = false
    defer {
      if activeModelCatalogRequest?.id == request.id {
        activeModelCatalogRequest = nil
      }
    }
    do {
      let key: String
      if let submittedAPIKey {
        key = submittedAPIKey
      } else {
        guard let credentials = try await loadEditorCredentials(),
              credentials.profile.baseURL == request.baseURL
        else {
          applyCatalogFailure(.authInvalid, for: request)
          return
        }
        key = credentials.apiKey
      }
      let models = try await modelCatalogLoader.listModels(baseURL: request.baseURL, apiKey: key)
      guard canApplyCatalogResult(for: request) else { return }
      availableModels = Array(models.prefix(Self.modelCatalogLimit))
      if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let recommended = selectedPreset.recommendedChatModel,
           availableModels.contains(recommended) {
          modelName = recommended
        } else if availableModels.count == 1, let onlyModel = availableModels.first {
          modelName = onlyModel
        }
      }
      selectedCatalogModels = availableModels.contains(modelName) ? [modelName] : []
      modelCatalogState = .loaded
      isManualModelEntryEnabled = false
    } catch is CancellationError {
      applyCatalogFailure(.networkInterrupted, for: request)
    } catch let failure as ModelProviderFailure {
      applyCatalogFailure(failure.code, for: request)
    } catch let error as ProviderConfigurationError {
      applyCatalogFailure(
        error == .baseURLInvalid || error == .baseURLRequired ? .baseURLInvalid : .authInvalid,
        for: request
      )
    } catch {
      applyCatalogFailure(.networkInterrupted, for: request)
    }
  }

  /// Reads the key belonging to the entry open in the editor. Falls back to
  /// the single-slot credentials when the library is unsupported.
  private func loadEditorCredentials() async throws -> (profile: ProviderProfile, apiKey: String)? {
    if configurationService.supportsModelLibrary, let editingProfileID {
      return try await configurationService.loadCredentials(profileID: editingProfileID)
    }
    return try await configurationService.loadCredentials()
  }

  private var draftIdentity: DataDestinationIdentity? {
    try? DataDestinationIdentity(
      baseURL: baseURL,
      model: modelName,
      allowLoopbackHTTP: Self.isExactLoopbackHTTP(baseURL)
    )
  }

  private var validatedCatalogBaseURL: URL? {
    try? ProviderProfile.validatedBaseURL(
      baseURL,
      allowLoopbackHTTP: Self.isExactLoopbackHTTP(baseURL)
    )
  }

  private func handleDraftEdit(
    from oldValue: String,
    to newValue: String,
    invalidatesModelCatalog: Bool
  ) {
    guard oldValue != newValue else { return }
    draftGeneration &+= 1
    if invalidatesModelCatalog {
      clearModelCatalog()
    }
    connectionTestState = hasUnsavedIdentityChanges ? .blockedUnsavedChanges : .idle
  }

  private func invalidateModelCatalog() {
    draftGeneration &+= 1
    clearModelCatalog()
  }

  private func clearModelCatalog() {
    activeModelCatalogRequest = nil
    modelCatalogState = .idle
    availableModels = []
    selectedCatalogModels = []
    isManualModelEntryEnabled = false
  }

  private func applyCatalogFailure(_ code: ModelProviderErrorCode, for request: ModelCatalogRequest) {
    guard canApplyCatalogResult(for: request) else { return }
    availableModels = []
    modelCatalogState = .failed(code: code)
    isManualModelEntryEnabled = false
  }

  private func canApplyCatalogResult(for request: ModelCatalogRequest) -> Bool {
    !isConfigurationLoading
      && !isSaving
      && activeModelCatalogRequest?.id == request.id
      && draftGeneration == request.generation
      && validatedCatalogBaseURL == request.baseURL
  }

  private func modelCatalogFailureText(_ code: ModelProviderErrorCode) -> String {
    switch code {
    case .authInvalid:
      "API Key 无效或没有读取模型的权限。请检查后重试，或展开高级手动填写。"
    case .endpointNotFound:
      "该 Base URL 没有 /models 接口（404）。请检查地址，或展开高级手动填写。"
    case .networkInterrupted, .providerUnavailable, .rateLimited:
      "网络或模型服务暂时不可用。请稍后重试，或展开高级手动填写。"
    case .inputTooLarge:
      "模型列表超过安全读取上限（1 MiB 或 500 项）。可展开高级手动填写。"
    case .baseURLInvalid:
      "Base URL 无效；仅支持 HTTPS，开发调试可使用 127.0.0.1。"
    default:
      "服务返回的 /models 协议不兼容。请检查服务说明，或展开高级手动填写。"
    }
  }

  private func applyTestResult(_ result: ConnectionTestState, for request: ConnectionTestRequest) {
    guard canUseSavedConfiguration(for: request)
    else { return }
    connectionTestState = result
  }

  private func canUseSavedConfiguration(for request: ConnectionTestRequest) -> Bool {
    !isConfigurationLoading
      && !isSaving
      && !isReplacingAPIKey
      && activeTestRequest?.id == request.id
      && draftGeneration == request.generation
      && savedIdentity == request.identity
      && !hasUnsavedIdentityChanges
  }

  private func releaseTestRequest(ifOwner requestID: UUID) {
    guard activeTestRequest?.id == requestID else { return }
    activeTestRequest = nil
  }

  private static func isExactLoopbackHTTP(_ value: String) -> Bool {
    guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return components.scheme?.lowercased() == "http" && components.host == "127.0.0.1"
  }
}

private actor InMemoryDefaultModelPreferencesStore: ModelPreferencesStore {
  private var value = ModelPreferences.default
  func load() async throws -> ModelPreferences { value }
  func save(_ preferences: ModelPreferences) async throws { value = preferences }
}
