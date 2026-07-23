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
  @Published private(set) var modelCatalogState: ModelCatalogState = .idle
  @Published private(set) var state: ProviderSettingsState = .unconfigured
  @Published private(set) var connectionTestState: ConnectionTestState = .idle
  @Published private(set) var savedIdentity: DataDestinationIdentity?
  @Published var summaryPrompt = ModelPreferences.defaultSummaryPrompt
  @Published var targetLanguage = ModelPreferences.defaultTargetLanguage
  @Published var usesSeparateTranslationModel = false
  @Published var translationModelName = ""
  @Published var transcriptionModelName = ""
  @Published var tidyModelName = ""
  @Published var autoTidyTranscription = false
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

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private let modelCatalogLoader: (any ModelCatalogLoading)?
  private let preferencesStore: any ModelPreferencesStore
  private var hasStartedConfigurationLoad = false
  private var draftGeneration: UInt64 = 0
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
    !isConfigurationLoading
      && !isSaving
      && !isTestingConnection
      && (!hasConfiguredAPIKey || isReplacingAPIKey || isEditingLibraryEntry)
      && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (modelCatalogLoader == nil || hasConfiguredAPIKey || modelCatalogState == .loaded || isManualModelEntryEnabled)
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
  var effectiveTranslationModelName: String {
    usesSeparateTranslationModel && !translationModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? translationModelName
      : modelName
  }
  /// Online transcription requires both an explicit per-capability assignment
  /// (the default stays local) and a transcription model name.
  var effectiveTranscriptionModelName: String? {
    guard transcriptionAssignmentID != nil else { return nil }
    let value = transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
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
    case .loaded: "已验证 /models，并读取 \(availableModels.count) 个模型；请选择后保存。"
    case let .failed(code): modelCatalogFailureText(code)
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
      "先验证模型列表并选择模型，再保存；LinkDigest 不会回显完整 API Key。"
    case .saving:
      "正在安全保存…"
    case .configured:
      "模型配置已保存"
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
      summaryPrompt = preferences.summaryPrompt
      targetLanguage = preferences.targetLanguage
      translationModelName = preferences.translationModel ?? ""
      transcriptionModelName = preferences.transcriptionModel ?? ""
      tidyModelName = preferences.tidyModel ?? ""
      autoTidyTranscription = preferences.autoTidyTranscription == true
      usesSeparateTranslationModel = preferences.translationModel != nil
      savedPreferences = preferences
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
    let preset: ProviderPreset
  }

  var libraryEntryDisplays: [LibraryEntryDisplay] {
    libraryProfiles.map { profile in
      let preset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      let title = preset == .custom ? (profile.baseURL.host ?? "自定义") : preset.displayName
      return LibraryEntryDisplay(id: profile.id, title: title, modelName: profile.model, preset: preset)
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
    editingProfileID = nil
    isEditorVisible = true
    baseURL = ""
    modelName = ""
    selectedPreset = .custom
    savedIdentity = nil
    isReplacingAPIKey = false
    connectionTestState = .idle
    state = .unconfigured
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
    guard canSavePreferences else { return }
    preferencesState = .saving
    do {
      let preferences = try ModelPreferences(
        summaryPrompt: summaryPrompt,
        targetLanguage: targetLanguage,
        translationModel: usesSeparateTranslationModel ? translationModelName : nil,
        transcriptionModel: transcriptionModelName,
        tidyModel: tidyModelName,
        autoTidyTranscription: autoTidyTranscription
      )
      try await preferencesStore.save(preferences)
      summaryPrompt = preferences.summaryPrompt
      targetLanguage = preferences.targetLanguage
      translationModelName = preferences.translationModel ?? ""
      transcriptionModelName = preferences.transcriptionModel ?? ""
      tidyModelName = preferences.tidyModel ?? ""
      autoTidyTranscription = preferences.autoTidyTranscription == true
      usesSeparateTranslationModel = preferences.translationModel != nil
      savedPreferences = preferences
      preferencesState = .saved
    } catch let error as ModelPreferencesError {
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
        preferencesState = .failed("整理模型名不能超过 256 个字符。")
      case .readFailed, .writeFailed:
        preferencesState = .failed("无法保存生成偏好，请稍后重试。")
      }
    } catch {
      preferencesState = .failed("无法保存生成偏好，请稍后重试。")
    }
  }

  func resetSummaryPrompt() {
    summaryPrompt = ModelPreferences.defaultSummaryPrompt
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
      usesSeparateTranslationModel = true
    } else {
      modelName = trimmed
    }
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
    let submittedModel = modelName

    do {
      let profile: ProviderProfile
      if let editingProfileID {
        // Replacing the key requires a fresh value; otherwise keep the
        // stored secret and only update endpoint/model.
        let submittedKey: String? = shouldShowAPIKeyInput ? apiKey : nil
        profile = try await configurationService.updateProfile(
          id: editingProfileID,
          baseURL: submittedBaseURL,
          model: submittedModel,
          apiKey: submittedKey,
          allowLoopbackHTTP: Self.isExactLoopbackHTTP(submittedBaseURL)
        )
      } else {
        profile = try await configurationService.addProfile(
          baseURL: submittedBaseURL,
          model: submittedModel,
          apiKey: apiKey,
          allowLoopbackHTTP: Self.isExactLoopbackHTTP(submittedBaseURL)
        )
        editingProfileID = profile.id
      }
      savedIdentity = DataDestinationIdentity(profile: profile)
      connectionTestState = .idle
      isReplacingAPIKey = false
      state = .configured
      selectedPreset = ProviderPreset.allCases.first(where: { $0.baseURLTemplate == profile.baseURL.absoluteString }) ?? .custom
      await refreshLibrary()
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
