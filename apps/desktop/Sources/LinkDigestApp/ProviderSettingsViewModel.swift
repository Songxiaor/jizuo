import Combine
import Foundation
import Observation
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

/// 用 Observation 而不是 ObservableObject：视图只在自己读过的属性变化时重绘。
/// 原来这里任何一个属性变化都会让整张设置页（以及同时观察它的历史窗口）重求值。
@MainActor
@Observable
final class ProviderSettingsViewModel {
  private static let modelCatalogLimit = 500
  var baseURL = "" {
    didSet {
      handleDraftEdit(from: oldValue, to: baseURL, invalidatesModelCatalog: true)
      if selectedPreset.baseURLTemplate != baseURL { selectedPreset = .custom }
    }
  }
  var modelName = "" {
    didSet { handleDraftEdit(from: oldValue, to: modelName, invalidatesModelCatalog: false) }
  }
  private(set) var selectedPreset: ProviderPreset = .custom
  var modelSearchQuery = ""
  private(set) var availableModels: [String] = []
  private(set) var selectedCatalogModels: Set<String> = []
  private(set) var modelCatalogState: ModelCatalogState = .idle
  private(set) var state: ProviderSettingsState = .unconfigured
  private(set) var connectionTestState: ConnectionTestState = .idle
  private(set) var savedIdentity: DataDestinationIdentity?
  var summaryPrompt = ModelPreferences.defaultSummaryPrompt {
    didSet { schedulePreferenceAutosave(from: oldValue, to: summaryPrompt, debounce: .milliseconds(800)) }
  }
  var targetLanguage = ModelPreferences.defaultTargetLanguage {
    didSet { schedulePreferenceAutosave(from: oldValue, to: targetLanguage, debounce: .milliseconds(600)) }
  }
  /// 「翻译是否另用一个模型」不再是一个独立的开关状态，而是从模型名推出来的：
  /// 名字为空就是跟随总结。原来它是一个 `@Published` 布尔量，于是同一件事有了
  /// 两个真相源——开关开着但名字为空、或名字填了开关却是关的，两种矛盾状态都能
  /// 存在，落盘时还得靠 `usesSeparateTranslationModel ? name : nil` 现场调和。
  var usesSeparateTranslationModel: Bool {
    !translationModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var translationModelName = "" {
    didSet { schedulePreferenceAutosave(from: oldValue, to: translationModelName, debounce: .milliseconds(600)) }
  }
  var transcriptionModelName = "" {
    didSet { schedulePreferenceAutosave(from: oldValue, to: transcriptionModelName, debounce: .milliseconds(600)) }
  }
  var tidyModelName = "" {
    didSet { schedulePreferenceAutosave(from: oldValue, to: tidyModelName, debounce: .milliseconds(600)) }
  }
  /// 四个管线开关拨下去就要落盘：它们是持久授权，不是草稿。
  /// 以前只改内存、要另点「保存生成偏好」，退出后再打开就会回到上次真正写下的值。
  var autoTidyTranscription = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoTidyTranscription) }
  }
  var autoLocalizeTitleNewCaptures = true {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoLocalizeTitleNewCaptures) }
  }
  var autoTranscribeNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoTranscribeNewCaptures) }
  }
  var autoSummarizeNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoSummarizeNewCaptures) }
  }
  var autoMindMapNewCaptures = false {
    didSet { persistPipelinePreferenceIfChanged(from: oldValue, to: autoMindMapNewCaptures) }
  }
  var translationConcurrency = ModelPreferences.defaultTranslationConcurrency {
    didSet { schedulePreferenceAutosave(from: oldValue, to: translationConcurrency, debounce: .zero) }
  }
  private(set) var preferencesState: ModelPreferencesState = .loading
  private(set) var savedPreferences = ModelPreferences.default
  private(set) var isReplacingAPIKey = false
  private(set) var isManualModelEntryEnabled = false
  private(set) var isConfigurationLoading = true
  private(set) var libraryProfiles: [ProviderProfile] = []
  private(set) var summaryAssignmentID: String?
  private(set) var transcriptionAssignmentID: String?
  private(set) var libraryErrorText: String?
  /// nil while adding a new model; otherwise the library entry being edited.
  private(set) var editingProfileID: String?
  private(set) var isEditorVisible = false
  private(set) var lastSavedProfileCount = 0

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let modelCatalogLoader: (any ModelCatalogLoading)?
  private let preferencesStore: any ModelPreferencesStore
  @ObservationIgnored private var hasStartedConfigurationLoad = false
  @ObservationIgnored private var draftGeneration: UInt64 = 0
  /// 读盘或写回自己的快照时，不要把赋值再当成一次用户拨杆。
  @ObservationIgnored private var isApplyingLoadedPreferences = false
  /// 连续拨杆串成一条保存链，后来的等待先到的写完，再按最新开关落盘。
  @ObservationIgnored private var preferencesSaveTail: Task<Void, Never>?
  @ObservationIgnored private var activeTestRequest: ConnectionTestRequest?
  @ObservationIgnored private var activeModelCatalogRequest: ModelCatalogRequest?

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

  /// 模型可用状态记录。测试可以注入独立实例。
  let modelHealth: ModelHealthRegistry

  init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider,
    modelCatalogLoader: (any ModelCatalogLoading)? = nil,
    preferencesStore: any ModelPreferencesStore = InMemoryDefaultModelPreferencesStore(),
    modelHealth: ModelHealthRegistry? = nil
  ) {
    self.modelHealth = modelHealth ?? .shared
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
    if isReplacingAPIKey { return true }
    // 编辑模型库里已有的一条：它的密钥一定存在钥匙串里。是否要求重新输入只看用户有没有点「更换」，
    // 不看整体的 `state`——前面任何一次保存或请求失败都会把 `state` 变成 `.failed`，
    // 原来就因此把输入框放出来，保存时还报「密钥还没填」，而密钥其实好好存着。
    if isEditingLibraryEntry { return false }
    return !hasConfiguredAPIKey && !isReusingProviderKey
  }

  /// 「拉取最新模型」：给已添加的服务商再加模型时，沿用那一家已保存的密钥。
  ///
  /// 只记是哪一条模型配置的密钥、它的服务地址；密钥本身只在读列表和保存那一刻从钥匙串里取。
  private struct BorrowedProviderKey: Equatable {
    let profileID: String
    let baseURL: URL
  }
  private var borrowedProviderKey: BorrowedProviderKey?

  /// 当前添加窗口是否在沿用已保存的密钥。服务地址被改掉就不再沿用，要求重新填。
  var isReusingProviderKey: Bool {
    guard editingProfileID == nil, let borrowedProviderKey else { return false }
    return validatedCatalogBaseURL == borrowedProviderKey.baseURL
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
      && (modelCatalogLoader == nil || hasConfiguredAPIKey || isEditingLibraryEntry || modelCatalogState == .loaded || isManualModelEntryEnabled)
  }

  var isAddingModelBatch: Bool {
    editingProfileID == nil && modelCatalogState == .loaded && !availableModels.isEmpty
  }

  /// 保存时跳过了几个已在列表里的模型；保存成功的状态行用它替换「模型配置已保存」。
  private(set) var duplicateSkipNotice: String?

  /// 同一个 Base URL 下已经有这个模型名。列表里标「已添加」、不可勾选，保存时也跳过。
  func isModelAlreadyInLibrary(_ name: String) -> Bool {
    guard let base = validatedCatalogBaseURL?.absoluteString else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return libraryProfiles.contains {
      $0.id != editingProfileID && $0.baseURL.absoluteString == base && $0.model == trimmed
    }
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
      && (hasConfiguredAPIKey || isEditingLibraryEntry)
      && !isReplacingAPIKey
      && !hasUnsavedIdentityChanges
  }

  var canBeginAPIKeyReplacement: Bool {
    !isConfigurationLoading && (hasConfiguredAPIKey || isReusingProviderKey || isEditingLibraryEntry) && !isSaving && !isTestingConnection
  }

  var apiKeyStatusText: String {
    isReusingProviderKey || (isEditingLibraryEntry && !hasConfiguredAPIKey) ? "✓ 沿用已保存的密钥" : "✓ 已配置"
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
  /// 「内容发去哪」那一行的显示名：服务商名 + 模型显示名。
  ///
  /// 不再直接印 `identity.host` 和 `identity.model`——那是 `api.deepinfra.com` 和
  /// `Qwen/Qwen2.5-72B-Instruct` 这种东西，用户在设置里从没见过它们，认不出自己
  /// 配的是哪一家。模型库里已经有人话名字（服务商标题 + `friendlyModelName`），
  /// 这里就用那一份，和列表里看到的完全一致。
  ///
  /// 库里找不到（旧的单槽配置、或刚填了草稿还没保存）时才退回 host，
  /// 那至少比完整 URL 短，也仍然指得出是哪一家。
  var dataDestinationDisplay: (provider: String, model: String)? {
    guard let identity = dataDestinationCard else { return nil }
    if let entry = libraryEntryDisplays.first(where: { $0.modelName == identity.model }) {
      return (entry.title, entry.displayName)
    }
    return (identity.host, Self.friendlyModelName(identity.model))
  }
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
    case .idle:
      selectedPreset == .commandCode
        ? "填好密钥就能读公开模型列表；套餐里有没有权限，要保存之后测试连接才知道。"
        : "先填服务地址和密钥，再读取模型列表；能对上推荐模型时会自动帮你选好。"
    case .loading: "正在读取模型列表…"
    case .loaded:
      "已读取 \(availableModels.count) 个模型；已选择 \(selectedCatalogModels.count) 个。"
        + (selectedPreset == .commandCode ? "这是公开模型目录，不代表已验证密钥或套餐权限；保存后可测试连接，测试会使用套餐额度。" : "")
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
  /// has finished populating this draft. Unchanged drafts stay disabled.
  var canSavePreferences: Bool {
    preferencesState != .loading && preferencesState != .saving && hasUnsavedPreferences
  }

  var hasUnsavedPreferences: Bool {
    guard preferencesState != .loading else { return false }
    do {
      return try currentDraftPreferences() != savedPreferences
    } catch {
      return true
    }
  }

  var preferencesStatusText: String {
    switch preferencesState {
    case .loading:
      return "正在读取生成偏好…"
    case .saving:
      return "正在保存生成偏好…"
    case let .failed(message):
      return message
    case .idle, .saved:
      if hasUnsavedPreferences { return "有未保存的修改" }
      return preferencesState == .saved ? "生成偏好已保存" : "使用已保存的生成偏好"
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
      selectedPreset == .commandCode
        ? "先读取模型列表并选择模型，再保存；套餐权限需通过测试连接确认。"
        : "先读取模型列表并选一个模型，再保存；出于安全，\(ProductDisplay.name) 不会把已存的密钥显示出来。"
    case .saving:
      "正在安全保存…"
    case .configured:
      duplicateSkipNotice ?? (lastSavedProfileCount > 1 ? "已保存 \(lastSavedProfileCount) 个模型配置" : "模型配置已保存")
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
      if selectedPreset == .commandCode && code == ModelProviderErrorCode.authForbidden.rawValue {
        "Command Code 拒绝访问。请确认套餐支持 API（Go 不支持），并已开通所选模型权限。"
      } else {
        V02ErrorCatalog.presentation(for: code).visibleText
      }
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
      // 不在打开设置时自动对照模型列表：那要读每家服务商的密钥，签名不稳定时
      // 会连弹好几个钥匙串授权框。对照改在用户点「检测可用性」时做。
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreReadFailed.rawValue)
    }
  }

  // MARK: - 模型库

  struct LibraryEntryDisplay: Identifiable, Equatable {
    let id: String
    let baseURL: String
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
        baseURL: profile.baseURL.absoluteString,
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

  /// 按模型名认语音转写模型。服务商的模型列表不说模型能干什么，只能靠名字。
  ///
  /// 除了 whisper / transcribe 这些通用词，也认国内外常见的语音识别模型名
  /// （SenseVoice、Paraformer、Voxtral、FunASR……）。名字带 tts（语音合成）的排除：
  /// 它是把文字念出来，方向正好相反。
  static func isTranscriptionModel(_ modelName: String) -> Bool {
    let normalized = modelName.lowercased()
    let tokens = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if tokens.contains("tts") { return false }
    let substrings = ["whisper", "transcrib", "speech-to-text", "speech_to_text", "sensevoice", "paraformer", "voxtral", "funasr"]
    if substrings.contains(where: normalized.contains) { return true }
    return tokens.contains("asr") || tokens.contains("stt")
      || tokens.contains(where: { $0.hasSuffix("asr") && $0.count > 3 })
  }

  // MARK: - 在线备用转写

  /// 在线转写实际用的是模型库里「转写」指派的那条配置（有自己的服务地址和密钥）。
  /// 下拉显示和修改都落在这个指派上；旧版本单独存的模型名只在没有指派时作为当前值展示。
  var onlineTranscriptionModelName: String {
    if let assignmentID = transcriptionAssignmentID,
       let profile = libraryProfiles.first(where: { $0.id == assignmentID }) {
      return profile.model
    }
    return transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func selectOnlineTranscriptionModel(_ name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      await assignTranscriptionModel(nil)
      transcriptionModelName = ""
      return
    }
    guard let profile = libraryProfiles.first(where: { $0.model == trimmed && Self.isTranscriptionModel($0.model) }) else {
      return
    }
    await assignTranscriptionModel(profile.id)
    // 模型名以指派的那条配置为准，旧的单独模型名清掉，免得两处说法不一。
    transcriptionModelName = ""
  }

  struct TranscriptionModelCandidate: Identifiable, Equatable {
    let baseURL: URL
    let providerTitle: String
    let model: String
    /// 共用这条配置的密钥来添加。
    let sourceProfileID: String
    var id: String { baseURL.absoluteString + "|" + model }
  }

  enum TranscriptionDiscoveryState: Equatable {
    case idle
    case searching
    case found([TranscriptionModelCandidate])
    /// 查了这么多家服务商，都没有语音模型。
    case none(searchedProviders: Int)
    case failed
  }

  private(set) var transcriptionDiscoveryState: TranscriptionDiscoveryState = .idle

  /// 在已经添加的服务商里找语音转写模型：每家读一次模型列表（读列表不收费），按名字挑出来。
  func discoverTranscriptionModels() async {
    guard let modelCatalogLoader else {
      transcriptionDiscoveryState = .failed
      return
    }
    transcriptionDiscoveryState = .searching
    var seen = Set<URL>()
    var candidates: [TranscriptionModelCandidate] = []
    var searched = 0
    var anyListed = false
    for profile in libraryProfiles where seen.insert(profile.baseURL).inserted {
      guard let credentials = try? await configurationService.loadCredentials(profileID: profile.id),
            let models = try? await modelCatalogLoader.listModels(baseURL: profile.baseURL, apiKey: credentials.apiKey)
      else { continue }
      searched += 1
      anyListed = true
      let preset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      let title = preset == .custom ? (profile.baseURL.host ?? "自定义") : preset.displayName
      let existing = Set(libraryProfiles.filter { $0.baseURL == profile.baseURL }.map(\.model))
      for model in models where Self.isTranscriptionModel(model) && !existing.contains(model) {
        candidates.append(.init(baseURL: profile.baseURL, providerTitle: title, model: model, sourceProfileID: profile.id))
      }
    }
    if !candidates.isEmpty {
      transcriptionDiscoveryState = .found(candidates)
    } else {
      transcriptionDiscoveryState = anyListed ? .none(searchedProviders: searched) : .failed
    }
  }

  /// 添加找到的语音模型（共用那家服务商已保存的密钥），并直接设为在线备用转写。
  func addDiscoveredTranscriptionModel(_ candidate: TranscriptionModelCandidate) async {
    do {
      let added = try await configurationService.addProfiles(
        baseURL: candidate.baseURL.absoluteString,
        models: [candidate.model],
        sharingSecretOf: candidate.sourceProfileID,
        allowLoopbackHTTP: Self.isExactLoopbackHTTP(candidate.baseURL.absoluteString)
      )
      await refreshLibrary()
      if let profile = added.first {
        await assignTranscriptionModel(profile.id)
        transcriptionModelName = ""
      }
      if case let .found(list) = transcriptionDiscoveryState {
        let remaining = list.filter { $0.id != candidate.id }
        transcriptionDiscoveryState = remaining.isEmpty ? .idle : .found(remaining)
      }
    } catch {
      libraryErrorText = "没能添加这个语音模型，请稍后再试。"
    }
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
    borrowedProviderKey = nil
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
    duplicateSkipNotice = nil
    invalidateModelCatalog()
  }

  /// 从某家已添加的服务商拉取最新模型列表：打开添加窗口、填好服务地址、沿用那家的密钥并立即读列表。
  /// 已经添加过的模型在列表里标「已添加」，勾选新的保存即可。
  func beginAddModelsFromProvider(profileID: String) async {
    guard !isSaving, !isTestingConnection, !isLoadingModels,
          let profile = libraryProfiles.first(where: { $0.id == profileID })
    else { return }
    beginAddModel()
    baseURL = profile.baseURL.absoluteString
    selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
    borrowedProviderKey = BorrowedProviderKey(profileID: profile.id, baseURL: profile.baseURL)
    await loadModels()
  }

  func beginEditModel(_ id: String) {
    guard !isSaving, !isTestingConnection, !isLoadingModels,
          let profile = libraryProfiles.first(where: { $0.id == id })
    else { return }
    borrowedProviderKey = nil
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
    duplicateSkipNotice = nil
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

  /// 一次删掉一个服务商下的全部模型：逐条走既有的单条删除，任一条失败就停下并提示，
  /// 已删的不回滚（每条都是独立记录，回滚反而会把用户已经确认要删的又加回来）。
  func deleteModels(_ ids: [String]) async {
    guard !isSaving, !isTestingConnection, !isLoadingModels else { return }
    for id in ids {
      do {
        _ = try await configurationService.deleteProfile(id: id)
      } catch {
        libraryErrorText = "有模型没删干净，请展开该服务商检查。"
        break
      }
      if editingProfileID == id {
        editingProfileID = nil
        isEditorVisible = false
        savedIdentity = nil
        state = .unconfigured
      }
    }
    await refreshLibrary()
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

  /// 输出语言、翻译并发、三个模型名和总结提示词改完即存，和管线开关一样不再需要
  /// 「保存生成偏好」按钮——原来翻译模型在「模型与识别」页改，却要回「生成偏好」
  /// 页按保存才生效，两页之间没有任何提示。
  ///
  /// 文本类字段带去抖：每敲一个字就写一次盘没必要；停手 0.6–0.8 秒后再存。
  @ObservationIgnored private var preferenceAutosaveTask: Task<Void, Never>?

  private func schedulePreferenceAutosave<Value: Equatable>(
    from oldValue: Value, to newValue: Value, debounce: Duration
  ) {
    guard !isApplyingLoadedPreferences, oldValue != newValue, preferencesState != .loading else {
      return
    }
    preferenceAutosaveTask?.cancel()
    preferenceAutosaveTask = Task { @MainActor [weak self] in
      if debounce > .zero {
        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else { return }
      }
      await self?.savePreferences()
    }
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
      // 自动保存期间用户可能还在打字：草稿和刚存的不一致就再存一轮，
      // 不能拿存过的旧值把正在输入的内容盖掉。
      if (try? currentDraftPreferences()) != preferences {
        continue
      }
      applyLoadedPreferences(preferences)
      preferencesState = .saved
      return
    }
  }

  private var pipelineFlagSnapshot: (Bool, Bool, Bool, Bool, Bool) {
    (
      autoLocalizeTitleNewCaptures,
      autoTidyTranscription,
      autoTranscribeNewCaptures,
      autoSummarizeNewCaptures,
      autoMindMapNewCaptures
    )
  }

  private func currentDraftPreferences() throws -> ModelPreferences {
    try ModelPreferences(
      summaryPrompt: summaryPrompt,
      targetLanguage: targetLanguage,
      translationModel: usesSeparateTranslationModel ? translationModelName : nil,
      transcriptionModel: transcriptionModelName,
      tidyModel: tidyModelName,
      autoTidyTranscription: autoTidyTranscription,
      autoLocalizeTitleNewCaptures: autoLocalizeTitleNewCaptures ? nil : false,
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
    autoLocalizeTitleNewCaptures = preferences.effectiveAutoLocalizeTitleNewCaptures
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
    guard isAddingModelBatch, availableModels.contains(value), !isModelAlreadyInLibrary(value) else { return }
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

  /// 「验证并保存」：保存成功后立刻用极短提示测一次连接，结果留在同一行状态里。
  ///
  /// 添加流程原来保存完就把编辑器关掉，测试结果没地方显示；这里保存期间先把编辑器
  /// 留着，测完再由用户自己关。
  func saveAndVerify(apiKey: String) async {
    keepsEditorOpenAfterSave = true
    await save(apiKey: apiKey)
    keepsEditorOpenAfterSave = false
    guard state == .configured, canTestConnection else { return }
    await testConnection()
  }

  @ObservationIgnored private var keepsEditorOpenAfterSave = false

  func save(apiKey: String) async {
    guard canSaveConfiguration else {
      return
    }
    connectionTestState = .idle
    duplicateSkipNotice = nil
    state = .saving
    let submittedBaseURL = baseURL
    let submittedModels = isAddingModelBatch
      ? orderedSelectedCatalogModels
      : [modelName]
    let wasAddingNewEntry = editingProfileID == nil

    do {
      let savedProfiles: [ProviderProfile]
      // 新增时先把同一 Base URL 下已经存在的模型名剔掉：同一个模型点两次「保存」
      // 不该在列表里出现两份。全部已存在就直接沿用已有的那条，不写库。
      let freshModels = wasAddingNewEntry
        ? submittedModels.filter { !isModelAlreadyInLibrary($0) }
        : submittedModels
      let skippedCount = submittedModels.count - freshModels.count
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
      } else if freshModels.isEmpty,
                let base = validatedCatalogBaseURL?.absoluteString,
                let existing = libraryProfiles.first(where: {
                  $0.baseURL.absoluteString == base && submittedModels.contains($0.model)
                }) {
        savedProfiles = [existing]
      } else if isReusingProviderKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let borrowedProviderKey {
        // 沿用已保存的密钥：直接共用那条钥匙串记录，连读都不用读。
        savedProfiles = try await configurationService.addProfiles(
          baseURL: submittedBaseURL,
          models: freshModels,
          sharingSecretOf: borrowedProviderKey.profileID,
          allowLoopbackHTTP: Self.isExactLoopbackHTTP(submittedBaseURL)
        )
      } else {
        savedProfiles = try await configurationService.addProfiles(
          baseURL: submittedBaseURL,
          models: freshModels,
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
      if skippedCount > 0 {
        duplicateSkipNotice = freshModels.isEmpty
          ? "这些模型已经在列表里，没有重复添加。"
          : "已保存 \(savedProfiles.count) 个模型；另外 \(skippedCount) 个已在列表里，跳过。"
      }
      connectionTestState = .idle
      isReplacingAPIKey = false
      state = .configured
      selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      await refreshLibrary()
      if wasAddingNewEntry {
        selectedCatalogModels = []
        // 刚存进去的那条就是接下来「测试连接」要用的凭据。不接管的话，测试会去读
        // 总结位上的另一个模型，报「模型目的地已变化」，而且再也保存不了。
        editingProfileID = profile.id
        if !keepsEditorOpenAfterSave { isEditorVisible = false }
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
      modelHealth.applyCatalog(
        baseURL: request.baseURL.absoluteString,
        catalog: models,
        savedModels: libraryProfiles.filter { $0.baseURL == request.baseURL }.map(\.model),
        isTruncated: models.count >= Self.modelCatalogLimit
      )
      if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let recommended = selectedPreset.recommendedChatModel,
           availableModels.contains(recommended) {
          modelName = recommended
        } else if availableModels.count == 1, let onlyModel = availableModels.first {
          modelName = onlyModel
        }
      }
      if editingProfileID == nil, isModelAlreadyInLibrary(modelName) { modelName = "" }
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
  // MARK: - 模型可用性

  func healthBadge(baseURL: String, model: String) -> ModelHealthBadge {
    ModelHealthBadge(record: modelHealth.record(for: baseURL, model: model), nowMilliseconds: modelHealth.nowMilliseconds)
  }

  func healthRecord(baseURL: String, model: String) -> ModelHealthRecord? {
    modelHealth.record(for: baseURL, model: model)
  }

  /// 编辑窗口里正在看的服务地址。
  var editorHealthBaseURL: String? { validatedCatalogBaseURL?.absoluteString }

  /// 下拉列表的顺序：能用的在前，确定用不了的沉底；同档保持服务商原顺序。
  var healthSortedFilteredModels: [String] {
    guard let base = editorHealthBaseURL else { return filteredModels }
    return filteredModels.enumerated().sorted { lhs, rhs in
      let left = rank(base: base, model: lhs.element)
      let right = rank(base: base, model: rhs.element)
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
  }

  private func rank(base: String, model: String) -> Int {
    // 未检测排在「可用」和「暂时不可用」之间。
    modelHealth.record(for: base, model: model)?.status.sortRank ?? 1
  }

  enum ModelProbeState: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(available: Int, total: Int)
  }

  /// 「检测可用性」要检测的一组模型，免费和付费分开，付费的要用户确认才发。
  struct ModelProbePlan: Equatable {
    let freeModels: [String]
    let paidModels: [String]
    var total: Int { freeModels.count + paidModels.count }
  }

  private(set) var modelProbeState: ModelProbeState = .idle
  @ObservationIgnored private var modelProbeTask: Task<Void, Never>?
  /// 每次检测一个编号：旧任务收尾时先确认「还是我这一次」，不去清掉或覆盖新一次的状态。
  @ObservationIgnored private var modelProbeRunID = UUID()
  /// 一次检测最多这么多个，免得一口气对上百个模型发请求。
  static let modelProbeLimit = 40

  /// 编辑窗口里读到的模型列表（受过滤词影响）。
  var catalogProbePlan: ModelProbePlan {
    Self.probePlan(for: Array(filteredModels.prefix(Self.modelProbeLimit)))
  }

  static func probePlan(for models: [String]) -> ModelProbePlan {
    ModelProbePlan(
      freeModels: models.filter(ModelHealthKey.looksFree),
      paidModels: models.filter { !ModelHealthKey.looksFree($0) }
    )
  }

  /// 对编辑窗口列表里的模型各发一条极短请求。`includesPaid` 为 false 时只测免费模型。
  func probeCatalogModels(includesPaid: Bool, submittedAPIKey: String?) {
    guard modelProbeTask == nil, let baseURL = validatedCatalogBaseURL else { return }
    let plan = catalogProbePlan
    let models = plan.freeModels + (includesPaid ? plan.paidModels : [])
    guard !models.isEmpty else { return }
    let allowLoopback = Self.isExactLoopbackHTTP(baseURL.absoluteString)
    let runID = UUID()
    modelProbeRunID = runID
    // 用手填的密钥检测时，结论不能落到已保存的模型上：填错一个字，同一地址下好好的模型
    // 就会被记成「密钥无效」。这种情况下只记和密钥无关的结论（下架、仅限官方客户端…）。
    let usesTypedKey = submittedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    modelProbeTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.modelProbeRunID == runID { self.modelProbeTask = nil } }
      let credentials: (profile: ProviderProfile, apiKey: String)?
      if let submittedAPIKey, !submittedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        credentials = (try? ProviderProfile(
          id: ModelHealthObservation.probeProfileID, baseURL: baseURL.absoluteString, model: models[0],
          secretReference: SecretReference(rawValue: "model-probe"), allowLoopbackHTTP: allowLoopback
        )).map { ($0, submittedAPIKey) }
      } else {
        credentials = try? await self.loadEditorCredentials()
      }
      guard let credentials, credentials.profile.baseURL == baseURL else {
        self.modelProbeState = .idle
        return
      }
      await self.runProbes(
        models: models, template: credentials.profile, apiKey: credentials.apiKey,
        runID: runID, recordsKeyDependentStates: !usesTypedKey
      )
    }
  }

  /// 检测已经添加到模型库里的全部模型（各自用自己的密钥）。
  func probeLibraryModels(includesPaid: Bool) {
    guard modelProbeTask == nil else { return }
    let profiles = libraryProfiles.filter { includesPaid || ModelHealthKey.looksFree($0.model) }
    guard !profiles.isEmpty else { return }
    let runID = UUID()
    modelProbeRunID = runID
    modelProbeTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.modelProbeRunID == runID { self.modelProbeTask = nil } }
      let total = profiles.count
      var done = 0
      var available = 0
      self.modelProbeState = .running(done: 0, total: total)
      // 先对照一次模型列表（不收费），已下架的直接标出来。
      await self.checkSavedModelsAgainstCatalogs()
      for profile in profiles {
        guard !Task.isCancelled, self.modelProbeRunID == runID else { return }
        if let credentials = try? await self.configurationService.loadCredentials(profileID: profile.id) {
          if await self.probeOnce(profile: credentials.profile, apiKey: credentials.apiKey) { available += 1 }
        }
        done += 1
        guard self.modelProbeRunID == runID else { return }
        self.modelProbeState = .running(done: done, total: total)
        self.modelProbeProgress = (done, available)
      }
      guard !Task.isCancelled, self.modelProbeRunID == runID else { return }
      self.modelProbeState = .finished(available: available, total: total)
    }
  }

  var libraryProbePlan: ModelProbePlan {
    Self.probePlan(for: libraryProfiles.map(\.model))
  }

  /// 已经测过几个、其中几个可用。停止时用它显示真实的结果。
  @ObservationIgnored private var modelProbeProgress: (done: Int, available: Int) = (0, 0)

  func cancelModelProbe() {
    modelProbeTask?.cancel()
    modelProbeTask = nil
    // 换一个编号：旧任务收尾时发现不是自己，不再改状态。
    modelProbeRunID = UUID()
    if case .running = modelProbeState {
      modelProbeState = .finished(available: modelProbeProgress.available, total: modelProbeProgress.done)
    }
    modelProbeProgress = (0, 0)
  }

  private func runProbes(
    models: [String], template: ProviderProfile, apiKey: String,
    runID: UUID, recordsKeyDependentStates: Bool
  ) async {
    let total = models.count
    var done = 0
    var available = 0
    modelProbeProgress = (0, 0)
    modelProbeState = .running(done: 0, total: total)
    // 三个一组并发：够快，又不至于一口气把服务商的限流打满。
    for chunk in stride(from: 0, to: models.count, by: 3).map({ Array(models[$0..<min($0 + 3, models.count)]) }) {
      guard !Task.isCancelled, modelProbeRunID == runID else { return }
      let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
        for model in chunk {
          guard let profile = try? ProviderProfile(
            id: ModelHealthObservation.probeProfileID, baseURL: template.baseURL.absoluteString, model: model,
            apiMode: template.apiMode, secretReference: template.secretReference,
            allowLoopbackHTTP: Self.isExactLoopbackHTTP(template.baseURL.absoluteString)
          ) else { continue }
          group.addTask { await self.probeOnce(profile: profile, apiKey: apiKey, recordsKeyDependentStates: recordsKeyDependentStates) }
        }
        var collected: [Bool] = []
        for await result in group { collected.append(result) }
        return collected
      }
      done += chunk.count
      available += results.filter { $0 }.count
      guard modelProbeRunID == runID else { return }
      modelProbeProgress = (done, available)
      modelProbeState = .running(done: done, total: total)
    }
    guard !Task.isCancelled, modelProbeRunID == runID else { return }
    modelProbeState = .finished(available: available, total: total)
  }

  /// 发一条「Reply with OK.」。结果通过适配层的旁路通知记进 modelHealth；
  /// 这里再按来源为「检测」补记一次，覆盖掉旧的真实调用结论。
  private func probeOnce(profile: ProviderProfile, apiKey: String, recordsKeyDependentStates: Bool = true) async -> Bool {
    do {
      for try await event in provider.stream(profile: profile, apiKey: apiKey, intent: .connectionTest) {
        if case .completed = event { break }
      }
      modelHealth.record(baseURL: profile.baseURL.absoluteString, model: profile.model, status: .available, source: .probe)
      return true
    } catch let failure as ModelProviderFailure {
      if let status = ModelHealthStatus(failure: failure.code),
         recordsKeyDependentStates || !Self.isKeyDependent(status) {
        modelHealth.record(baseURL: profile.baseURL.absoluteString, model: profile.model, status: status, source: .probe)
      }
      return false
    } catch {
      return false
    }
  }

  /// 取决于用的是哪把密钥的结论（密钥无效、没开通、需充值）。
  static func isKeyDependent(_ status: ModelHealthStatus) -> Bool {
    status == .keyInvalid || status == .notEntitled || status == .billingLimited
  }

  /// 静默对照：每个服务地址读一次模型列表，找出已保存但已下架的模型。失败就算了，不打扰。
  func checkSavedModelsAgainstCatalogs() async {
    guard let modelCatalogLoader else { return }
    var seen = Set<URL>()
    for profile in libraryProfiles where seen.insert(profile.baseURL).inserted {
      guard let credentials = try? await configurationService.loadCredentials(profileID: profile.id),
            let models = try? await modelCatalogLoader.listModels(baseURL: profile.baseURL, apiKey: credentials.apiKey)
      else { continue }
      modelHealth.applyCatalog(
        baseURL: profile.baseURL.absoluteString,
        catalog: models,
        savedModels: libraryProfiles.filter { $0.baseURL == profile.baseURL }.map(\.model),
        isTruncated: models.count >= Self.modelCatalogLimit
      )
    }
  }

  private func loadEditorCredentials() async throws -> (profile: ProviderProfile, apiKey: String)? {
    if configurationService.supportsModelLibrary, let editingProfileID {
      return try await configurationService.loadCredentials(profileID: editingProfileID)
    }
    if configurationService.supportsModelLibrary, isReusingProviderKey, let borrowedProviderKey {
      return try await configurationService.loadCredentials(profileID: borrowedProviderKey.profileID)
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
      "这把密钥不对，或者它没有读取模型列表的权限。你已保存的配置没有变化。请核对一次密钥再点「读取模型列表」，或点「手动填写模型名」。"
    case .endpointNotFound:
      "这个服务地址上没有模型列表可读。你已保存的配置没有变化。请照服务商文档核对服务地址，或点「手动填写模型名」。"
    case .networkInterrupted, .providerUnavailable, .rateLimited:
      "网络或模型服务这会儿用不了，没能读到模型列表。你已保存的配置没有变化。请稍后重试，或点「手动填写模型名」。"
    case .inputTooLarge:
      "这家服务商的模型太多，一次读不完，汲作没有截一半给你看。你已保存的配置没有变化。请点「手动填写模型名」直接填你要用的那个。"
    case .baseURLInvalid:
      "这个服务地址汲作用不了。已保存的配置没有变化。请填以 https:// 开头的地址（本机调试可以用 127.0.0.1）。"
    default:
      "这家服务商返回的模型列表格式汲作看不懂。你已保存的配置没有变化。请核对服务商文档，或点「手动填写模型名」。"
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
