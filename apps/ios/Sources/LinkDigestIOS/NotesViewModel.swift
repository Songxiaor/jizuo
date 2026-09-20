import Foundation
import LinkDigestShared
import Observation

@MainActor
@Observable
public final class NotesViewModel {
  public private(set) var notes: [SyncNoteCard] = []
  public private(set) var syncStatus: NoteSyncStatus = NoteSyncStatus()
  public private(set) var loadError: String?
  public private(set) var summarizeError: String?
  public private(set) var shareImportBanner: String?
  public private(set) var isSummarizing = false
  public private(set) var isTranslating = false
  public private(set) var isTranscribing = false
  public private(set) var isSynchronizing = false
  public private(set) var isImportingShare = false
  public var searchText: String = ""

  private let store: any NoteCardStore
  private let sync: any NoteCardSyncing
  private let linkFetcher: LinkPageFetcher
  private let summarizer: OpenAICompatibleSummarizer
  private let audioTranscriber: OpenAICompatibleAudioTranscriber
  private let modelCatalog: OpenAICompatibleModelCatalog
  private let profileStore: any IOSProviderProfileStore
  private let apiKeyStore: any IOSAPIKeyStore
  @ObservationIgnored
  private var generationTask: Task<Void, Never>?

  public init(
    store: any NoteCardStore,
    sync: any NoteCardSyncing = CloudKitNoteCardSync(
      enabled: CloudKitCapability.isContainerEntitled()
    ),
    linkFetcher: LinkPageFetcher = LinkPageFetcher(),
    summarizer: OpenAICompatibleSummarizer = OpenAICompatibleSummarizer(),
    audioTranscriber: OpenAICompatibleAudioTranscriber = OpenAICompatibleAudioTranscriber(),
    modelCatalog: OpenAICompatibleModelCatalog = OpenAICompatibleModelCatalog(),
    profileStore: any IOSProviderProfileStore = UserDefaultsIOSProviderProfileStore(),
    apiKeyStore: any IOSAPIKeyStore = KeychainIOSAPIKeyStore()
  ) {
    self.store = store
    self.sync = sync
    self.linkFetcher = linkFetcher
    self.summarizer = summarizer
    self.audioTranscriber = audioTranscriber
    self.modelCatalog = modelCatalog
    self.profileStore = profileStore
    self.apiKeyStore = apiKeyStore
  }

  public var visibleNotes: [SyncNoteCard] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return notes }
    return notes.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.body.localizedCaseInsensitiveContains(query)
        || ($0.summary?.localizedCaseInsensitiveContains(query) ?? false)
        || ($0.translation?.localizedCaseInsensitiveContains(query) ?? false)
        || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false)
        || ($0.sourceURL?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  /// 列表顶同步状态文案：已同步时间 / 失败原因 / 进行中。
  public var syncStatusSummary: String {
    if isSynchronizing || syncStatus.phase == .pulling || syncStatus.phase == .pushing {
      return "正在同步…"
    }
    if syncStatus.phase == .failed, let error = syncStatus.lastErrorMessage, !error.isEmpty {
      return Self.friendlySyncMessage(error)
    }
    if let ms = syncStatus.lastSuccessAtMilliseconds {
      let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      return "已同步 \(formatter.string(from: date))"
    }
    return "尚未同步"
  }

  /// 把开发期 / CloudKit 原始报错收成用户可读说明。
  public static func friendlySyncMessage(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.contains("enabled 设为 true") || text.contains("CloudKit 同步尚未启用") {
      return "手机与 Mac 的 iCloud 同步尚未开通：需要付费 Apple Developer 账号。当前笔记只保存在本机。"
    }
    if text.contains("CKAccountStatus") || text.contains("账户不可用") || text.contains("noAccount") {
      return "本机未登录可用的 iCloud 账号。请在系统设置登录 Apple ID；真机同步还需付费开发者账号开通 CloudKit。"
    }
    if text.contains("未登录 iCloud") {
      return "未登录 iCloud。请在系统设置登录 Apple ID。"
    }
    return text
  }

  public func reload() async {
    do {
      notes = try await store.list(includeDeleted: false)
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  public func createTextNote(title: String?, body: String) async {
    let card = SyncNoteCardFactory.makeText(title: title, body: body)
    await save(card)
  }

  public func createVoiceNote(transcript: String) async {
    let card = SyncNoteCardFactory.makeVoice(transcript: transcript)
    await save(card)
  }

  public func createLinkNote(url: String, title: String?, body: String, summary: String?) async {
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: url,
      title: title,
      body: body,
      summary: summary
    )
    await save(card)
  }

  /// 粘贴 URL 后自动抓取标题/正文；抓取失败仍保存 URL + 占位正文，并返回可读警告。
  /// 有 warning 时会写入正文前缀，避免关掉新建表单后丢失。
  @discardableResult
  public func createLinkNoteFetching(
    url: String,
    titleOverride: String?,
    bodyOverride: String?,
    summary: String?
  ) async -> String? {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let manualTitle = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
    let manualBody = bodyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)

    let hasManualBody = !(manualBody?.isEmpty ?? true)
    var title = (manualTitle?.isEmpty == false) ? manualTitle : nil
    var body = hasManualBody ? manualBody! : "（待抓取正文）"
    var warning: String?

    if !hasManualBody {
      let fetched = await linkFetcher.fetch(urlString: trimmedURL)
      if title == nil { title = fetched.title }
      body = fetched.body
      warning = fetched.warningMessage
      if let warning, !warning.isEmpty {
        body = Self.bodyWithFetchWarning(body: body, warning: warning)
      }
    }

    let card = SyncNoteCardFactory.makeLink(
      sourceURL: trimmedURL,
      title: title,
      body: body,
      summary: summary
    )
    await save(card)
    return warning
  }

  public static let fetchWarningPrefix = "【抓取提示】"

  public static func bodyWithFetchWarning(body: String, warning: String) -> String {
    let trimmedWarning = warning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedWarning.isEmpty else { return body }
    if body.contains(fetchWarningPrefix) { return body }
    return "\(fetchWarningPrefix)\(trimmedWarning)\n\n\(body)"
  }

  public func update(_ card: SyncNoteCard) async {
    var next = card
    next.updatedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
    await save(next)
  }

  public func delete(_ card: SyncNoteCard) async {
    do {
      try await store.softDelete(
        id: card.id,
        atMilliseconds: SyncNoteCardFactory.nowMilliseconds()
      )
      await reload()
    } catch {
      loadError = error.localizedDescription
    }
  }

  public func synchronize() async {
    guard !isSynchronizing else { return }
    isSynchronizing = true
    syncStatus = NoteSyncStatus(
      phase: .pulling,
      lastSuccessAtMilliseconds: syncStatus.lastSuccessAtMilliseconds,
      lastErrorMessage: nil
    )
    defer { isSynchronizing = false }
    do {
      syncStatus = try await sync.synchronize(local: store)
      await reload()
    } catch {
      syncStatus = NoteSyncStatus(
        phase: .failed,
        lastSuccessAtMilliseconds: syncStatus.lastSuccessAtMilliseconds,
        lastErrorMessage: error.localizedDescription
      )
    }
  }

  public func loadProviderProfile() -> IOSProviderProfile {
    profileStore.load()
  }

  public func saveProviderSettings(
    baseURL: String,
    modelName: String,
    apiKey: String?,
    outputLanguage: String? = nil,
    addedModels: [String]? = nil
  ) throws {
    let existing = profileStore.load()
    let language = outputLanguage ?? existing.outputLanguage
    let models = addedModels ?? existing.addedModels
    profileStore.save(
      IOSProviderProfile(
        baseURL: baseURL,
        modelName: modelName,
        addedModels: models,
        outputLanguage: language
      )
    )
    if let apiKey {
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        try apiKeyStore.delete()
      } else {
        try apiKeyStore.save(trimmed)
      }
    }
  }

  public func hasStoredAPIKey() -> Bool {
    (try? apiKeyStore.read())?.isEmpty == false
  }

  /// 对已有笔记调用 BYOK 总结，写入 `summary`。
  public func summarizeNote(_ card: SyncNoteCard) async {
    await enqueueGeneration(intent: .summarize, card: card)
  }

  /// 对已有笔记调用 BYOK 翻译，写入 `translation`。
  public func translateNote(_ card: SyncNoteCard) async {
    await enqueueGeneration(intent: .translate, card: card)
  }

  /// 页面文案整理稿前缀：UI / 复制内容都能看出「不是音轨识别」。
  public static let pageTranscriptDraftPrefix = "【页面文案整理 · 非音轨识别】"

  /// 直链音频识别稿前缀。
  public static let audioTranscriptPrefix = "【在线音频转写】"

  /// 在线转写：直链音频走 `/audio/transcriptions`；其余有正文时走「页面文案整理稿」。
  public func transcribeNote(_ card: SyncNoteCard) async {
    await enqueueTranscription(card: card)
  }

  /// 停止进行中的总结 / 翻译 / 转写（可停可重试）。
  public func cancelGeneration() {
    generationTask?.cancel()
    generationTask = nil
    isSummarizing = false
    isTranslating = false
    isTranscribing = false
  }

  public static func decorateTranscript(_ raw: String, prefix: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(prefix) { return trimmed }
    return "\(prefix)\n\n\(trimmed)"
  }

  /// 详情页按钮文案：直链音频 vs 页面稿。
  public static func transcribeActionTitle(for card: SyncNoteCard, hasExisting: Bool) -> String {
    let redo = hasExisting
    if OpenAICompatibleAudioTranscriber.looksLikeDirectMediaURL(card.sourceURL ?? "") {
      return redo ? "重新转写音频" : "转写音频"
    }
    return redo ? "重新整理页面稿" : "整理页面稿"
  }

  public static func transcriptSectionTitle(for text: String) -> String {
    if text.contains("非音轨识别") || text.hasPrefix(pageTranscriptDraftPrefix) {
      return "页面稿（非音轨）"
    }
    if text.contains("在线音频转写") || text.hasPrefix(audioTranscriptPrefix) {
      return "音频转写"
    }
    return "转写"
  }

  public var isGenerating: Bool { isSummarizing || isTranslating || isTranscribing }

  private func enqueueGeneration(intent: GenerationIntent, card: SyncNoteCard) async {
    guard !isGenerating else { return }
    let task = Task { @MainActor in
      await runGeneration(intent: intent, card: card)
    }
    generationTask = task
    await task.value
    if generationTask == task {
      generationTask = nil
    }
  }

  private func enqueueTranscription(card: SyncNoteCard) async {
    guard !isGenerating else { return }
    let task = Task { @MainActor in
      await performTranscription(card: card)
    }
    generationTask = task
    await task.value
    if generationTask == task {
      generationTask = nil
    }
  }

  private func performTranscription(card: SyncNoteCard) async {
    isTranscribing = true
    summarizeError = nil
    defer { isTranscribing = false }

    do {
      try Task.checkCancellation()
      let profile = try requireConfiguredProfile()
      let apiKey = try requireAPIKey()
      let mediaURL = card.sourceURL ?? ""
      let transcript: String
      if OpenAICompatibleAudioTranscriber.looksLikeDirectMediaURL(mediaURL) {
        let raw = try await audioTranscriber.transcribeRemoteMedia(
          mediaURLString: mediaURL,
          baseURL: profile.baseURL,
          model: profile.modelName,
          apiKey: apiKey
        )
        try Task.checkCancellation()
        transcript = Self.decorateTranscript(raw, prefix: Self.audioTranscriptPrefix)
      } else if !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let raw = try await summarizer.generate(
          intent: .pageTranscript,
          title: card.title,
          body: card.body,
          sourceURL: card.sourceURL,
          baseURL: profile.baseURL,
          model: profile.modelName,
          apiKey: apiKey,
          outputLanguage: profile.outputLanguage
        )
        try Task.checkCancellation()
        transcript = Self.decorateTranscript(raw, prefix: Self.pageTranscriptDraftPrefix)
      } else {
        throw AudioTranscriberError.providerMessage(
          "当前笔记没有可转写的直链音频（mp3/m4a/wav 等），也没有足够页面正文可整理。YouTube / B 站 / 抖音完整音轨转写请用 Mac 汲作。"
        )
      }

      var next = card
      next.transcript = transcript
      next.updatedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
      await save(next)
    } catch is CancellationError {
      // 用户主动停止：不弹错误。
    } catch {
      if Task.isCancelled { return }
      summarizeError = error.localizedDescription
    }
  }

  private func requireConfiguredProfile() throws -> IOSProviderProfile {
    let profile = profileStore.load()
    guard profile.isConfigured else {
      if profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw IOSProviderSettingsError.missingBaseURL
      }
      throw IOSProviderSettingsError.missingModel
    }
    return profile
  }

  private func requireAPIKey() throws -> String {
    guard let apiKey = try apiKeyStore.read(), !apiKey.isEmpty else {
      throw IOSProviderSettingsError.missingAPIKey
    }
    return apiKey
  }

  private func runGeneration(intent: GenerationIntent, card: SyncNoteCard) async {
    switch intent {
    case .summarize: isSummarizing = true
    case .translate: isTranslating = true
    case .pageTranscript: isTranscribing = true
    }
    summarizeError = nil
    defer {
      isSummarizing = false
      isTranslating = false
      isTranscribing = false
    }

    do {
      try Task.checkCancellation()
      let profile = try requireConfiguredProfile()
      let apiKey = try requireAPIKey()

      let output = try await summarizer.generate(
        intent: intent,
        title: card.title,
        body: card.body,
        sourceURL: card.sourceURL,
        baseURL: profile.baseURL,
        model: profile.modelName,
        apiKey: apiKey,
        outputLanguage: profile.outputLanguage
      )
      try Task.checkCancellation()
      var next = card
      switch intent {
      case .summarize:
        next.summary = output
      case .translate:
        next.translation = output
      case .pageTranscript:
        next.transcript = Self.decorateTranscript(output, prefix: Self.pageTranscriptDraftPrefix)
      }
      next.updatedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
      await save(next)
    } catch is CancellationError {
      // 用户主动停止。
    } catch {
      if Task.isCancelled { return }
      summarizeError = error.localizedDescription
    }
  }

  /// 请 Mac 做完整音视频转写（经 CloudKit 同步；Mac 处理后写回 `transcript`）。
  public func requestMacTranscription(_ card: SyncNoteCard) async {
    guard card.kind == .link, let url = card.sourceURL, !url.isEmpty else {
      summarizeError = "只有带链接的笔记才能请求 Mac 完整转写。"
      return
    }
    var next = card
    next.transcriptionRequestedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
    if next.transcript?.hasPrefix("【Mac 转写") != true {
      next.transcript = "【Mac 转写排队中】下次与 Mac 同步后，请在电脑汲作打开该链接做「本机转写」；完成后再次同步即可回写手机。"
    }
    next.updatedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
    await save(next)
  }

  public func clearSummarizeError() {
    summarizeError = nil
  }

  /// 发一条极短请求验证 Base URL / 模型 / Key（含 OpenCode Go 订阅通道）。
  public func testProviderConnection() async throws -> String {
    let profile = try requireConfiguredProfile()
    let apiKey = try requireAPIKey()
    let reply = try await summarizer.summarize(
      title: "连接测试",
      body: "请只回复两个字：成功",
      sourceURL: nil,
      baseURL: profile.baseURL,
      model: profile.modelName,
      apiKey: apiKey,
      outputLanguage: profile.outputLanguage
    )
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "已连通" : String(trimmed.prefix(80))
  }

  /// `GET {base}/models` 拉取可用模型 ID（与 Mac 设置页同语义）。
  /// - Parameters:
  ///   - baseURL: 当前表单草稿；为空则用已保存 profile。
  ///   - apiKeyOverride: 表单里刚填、尚未保存的 Key；为空则读钥匙串。
  public func listProviderModels(
    baseURL: String? = nil,
    apiKeyOverride: String? = nil
  ) async throws -> [String] {
    let profile = profileStore.load()
    let resolvedBase = (baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? profile.baseURL
    guard !resolvedBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IOSProviderSettingsError.missingBaseURL
    }

    let keyFromForm = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKey: String
    if let keyFromForm, !keyFromForm.isEmpty {
      apiKey = keyFromForm
    } else {
      apiKey = try requireAPIKey()
    }

    return try await modelCatalog.listModels(baseURL: resolvedBase, apiKey: apiKey)
  }

  public func clearShareImportBanner() {
    shareImportBanner = nil
  }

  /// 消费 Share Extension / 粘贴板降级暂存，upsert 为 link 或 text 笔记。
  @discardableResult
  public func importShareInbox() async -> Int {
    guard !isImportingShare else { return 0 }
    isImportingShare = true
    defer { isImportingShare = false }

    let items = ShareInbox.consumePending()
    guard !items.isEmpty else { return 0 }

    var imported = 0
    var deepCount = 0
    for item in items {
      if let url = item.resolvedURLString {
        let bodyOverride = item.text.flatMap { ShareInbox.looksLikeHTTPURL($0) ? nil : $0 }
        if ShareDeepCapture.isDeepCapturedBody(bodyOverride) {
          deepCount += 1
        }
        _ = await createLinkNoteFetching(
          url: url,
          titleOverride: item.title,
          bodyOverride: bodyOverride,
          summary: nil
        )
        imported += 1
      } else if let text = item.text, !text.isEmpty {
        await createTextNote(title: item.title, body: text)
        imported += 1
      }
    }

    if imported > 0 {
      if deepCount > 0 {
        shareImportBanner = "已从当前页导入 \(imported) 条（含正文，未再联网抓取）"
      } else {
        shareImportBanner = "已从分享导入 \(imported) 条"
      }
    }
    return imported
  }

  private func save(_ card: SyncNoteCard) async {
    do {
      try await store.upsert(card)
      await reload()
    } catch {
      loadError = error.localizedDescription
    }
  }
}
