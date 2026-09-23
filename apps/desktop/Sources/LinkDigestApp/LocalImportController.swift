import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore

/// 本机素材导入：同步语音备忘录、导入拖进来的文件。
///
/// 落库复用 `CaptureIngestService`（与手动链接、笔记同一条通道），媒体复用
/// `LocalMediaStore` + `attachMedia`（与抖音/B 站视频同一条通道）。这里只负责
/// 「从本机读出来」和把结果讲清楚，不另开写入口。
@MainActor
final class LocalImportController: ObservableObject {
  struct Summary: Equatable {
    var added = 0
    var skipped = 0
    /// 录音只在 iCloud、还没下载到这台 Mac 上。
    var notDownloaded = 0
    /// 备忘录内容有变化、已更新到汲作里的条数。
    var updated = 0
    /// 加了密码、读不到正文的备忘录。
    var locked = 0
    /// 在敏感文件夹里、或看起来含密钥 / 账号密码的备忘录：不导入汲作。
    var sensitiveSkipped = 0
    /// 其中之前已经导入过、这次从汲作里彻底删掉的条数（备忘录 App 里的原件不动）。
    var sensitivePurged = 0
    var failures: [String] = []
  }

  enum Phase: Equatable {
    case idle
    case running(title: String, done: Int, total: Int, step: String?)
    case finished(title: String, summary: Summary, revealHost: String?)
    case failed(title: String, message: String, settingsLink: SettingsLink?)
  }

  @Published private(set) var phase: Phase = .idle
  var isPresented: Bool {
    get { phase != .idle }
    set { if !newValue, !isRunning { phase = .idle } }
  }
  var isRunning: Bool {
    if case .running = phase { return true }
    return false
  }

  private weak var manualLink: ManualLinkViewModel?
  private weak var historyModel: HistoryViewModel?
  private var history: HistoryApplicationService?
  private let mediaStore: LocalMediaStore?
  private let imageCache: GitHubREADMEImageCache?
  private let voiceMemos: VoiceMemosLibrary
  private let appleNotes: AppleNotesLibrary
  private let reader: LocalFileImportReader
  private var task: Task<Void, Never>?

  init(
    mediaStore: LocalMediaStore?,
    imageCache: GitHubREADMEImageCache?,
    voiceMemos: VoiceMemosLibrary = .system(),
    appleNotes: AppleNotesLibrary = AppleNotesLibrary(),
    reader: LocalFileImportReader = LocalFileImportReader()
  ) {
    self.mediaStore = mediaStore
    self.imageCache = imageCache
    self.voiceMemos = voiceMemos
    self.appleNotes = appleNotes
    self.reader = reader
  }

  func configure(history: HistoryApplicationService?, manualLink: ManualLinkViewModel, historyModel: HistoryViewModel) {
    self.history = history
    self.manualLink = manualLink
    self.historyModel = historyModel
    // `canImport` 是算出来的，不是 @Published：接上资料库之后要主动通知一次，
    // 否则菜单停留在启动那一刻的「不可用」。
    objectWillChange.send()
  }

  var canImport: Bool { history != nil && manualLink?.ingestor != nil && !isRunning }

  func cancel() {
    task?.cancel()
  }

  // MARK: 语音备忘录

  func syncVoiceMemos() {
    guard canImport else { return }
    let title = "同步语音备忘录"
    phase = .running(title: title, done: 0, total: 0, step: "正在读取语音备忘录的录音列表…")
    task = Task { [weak self] in
      guard let self else { return }
      let recordings: [VoiceMemoRecording]
      do {
        let library = voiceMemos
        recordings = try await Task.detached { try library.recordings() }.value
      } catch let error as VoiceMemosLibraryError {
        phase = .failed(title: title, message: error.userMessage, settingsLink: error == .permissionDenied ? .fullDiskAccess : nil)
        return
      } catch {
        phase = .failed(title: title, message: VoiceMemosLibraryError.unreadable.userMessage, settingsLink: nil)
        return
      }
      guard !recordings.isEmpty else {
        phase = .finished(title: title, summary: .init(), revealHost: nil)
        return
      }
      var summary = Summary()
      for (index, recording) in recordings.enumerated() {
        if Task.isCancelled { break }
        phase = .running(title: title, done: index, total: recordings.count, step: "正在导入「\(recording.title ?? "语音备忘录")」…")
        await importVoiceMemo(recording, summary: &summary)
      }
      finish(title: title, summary: summary, host: LocalImportSource.voiceMemos.rawValue)
    }
  }

  private func importVoiceMemo(_ recording: VoiceMemoRecording, summary: inout Summary) async {
    guard let history else { return }
    do {
      let document = try LocalImportDocument.voiceMemo(
        recordingID: recording.id,
        title: recording.title,
        recordedAt: recording.recordedAt,
        durationSeconds: recording.durationSeconds
      )
      // 已经收过的录音不再读音频、不再转码——同步第二次只拉新录音。
      if let existing = try history.taskID(forCanonicalURL: CanonicalURL(document.url)) {
        if let recordedAt = recording.recordedAt {
          try? history.alignArchiveTaskTime(taskID: existing, originalMilliseconds: Self.milliseconds(recordedAt))
        }
        // 早期版本把录制时间串当成了标题；再同步一次就更正过来。只改这种标题，
        // 列表时间传 0 不动（updated_at 取较大值），不会把几十条旧录音顶到最前面。
        let current = try history.detail(taskID: existing).snapshots.last?.title ?? ""
        if LocalImportDocument.isMachineTimestamp(current), let title = document.title, current != title {
          try history.updateTaskTitle(taskID: existing, title: title, updatedAtMilliseconds: 0)
          summary.updated += 1
        } else {
          summary.skipped += 1
        }
        return
      }
      guard recording.isDownloaded else {
        summary.notDownloaded += 1
        return
      }
      let reader = reader
      let content = try await Task.detached { try await reader.readAudio(recording.fileURL) }.value
      guard case let .media(data, duration, _) = content else { throw LocalFileImportError.noAudio }
      try await store(
        document: document, media: data, durationSeconds: recording.durationSeconds ?? duration, platform: .voiceMemos,
        receivedAt: recording.recordedAt.map(Self.milliseconds)
      )
      summary.added += 1
    } catch {
      summary.failures.append("\(recording.title ?? recording.id)：\(Self.message(for: error))")
    }
  }

  // MARK: 备忘录

  func syncAppleNotes() {
    guard canImport else { return }
    let title = "同步备忘录"
    phase = .running(title: title, done: 0, total: 0, step: "正在读取「备忘录」… 第一次使用时，请在系统弹窗里允许汲作访问备忘录。")
    task = Task { [weak self] in
      guard let self else { return }
      let notes: [AppleNote]
      do {
        notes = try await appleNotes.notes()
      } catch let error as AppleNotesLibraryError {
        phase = .failed(title: title, message: error.userMessage, settingsLink: (error == .permissionDenied || error == .timedOut) ? .automation : nil)
        return
      } catch {
        phase = .failed(title: title, message: AppleNotesLibraryError.failed("未知错误").userMessage, settingsLink: nil)
        return
      }
      var summary = Summary()
      var purge: Set<TaskID> = []
      for (index, note) in notes.enumerated() {
        if Task.isCancelled { break }
        if index % 10 == 0 {
          phase = .running(title: title, done: index, total: notes.count, step: "正在导入「\(note.name ?? "备忘录")」…")
          await Task.yield()
        }
        await importAppleNote(note, summary: &summary, purge: &purge)
      }
      // 敏感备忘录之前已导入的副本：从汲作彻底删除（不进回收站），备忘录 App 里的原件不动。
      if let history, !purge.isEmpty {
        let removed = (try? history.deleteTasks(taskIDs: purge).deletedTaskIDs.count) ?? 0
        summary.sensitivePurged = removed
      }
      finish(title: title, summary: summary, host: LocalImportSource.appleNotes.rawValue)
    }
  }

  private func importAppleNote(_ note: AppleNote, summary: inout Summary, purge: inout Set<TaskID>) async {
    guard let history else { return }
    guard !note.locked, let html = note.body else {
      summary.locked += 1
      return
    }
    do {
      let text = Self.noteBody(html: html, title: note.name)
      let document = try LocalImportDocument.appleNote(
        noteID: note.id, title: note.name, folder: note.folder, createdAt: note.createdAt, text: text
      )
      let identity = try CanonicalURL(document.url)
      let existing = try history.taskID(forCanonicalURL: identity)
      // 敏感内容不进素材库：素材会被检索、总结、交给 MCP 那头的 AI 工具。
      let extraExcluded = UserDefaults.standard.stringArray(forKey: SensitiveContent.excludedFoldersDefaultsKey) ?? []
      if SensitiveContent.isExcludedNotesFolder(note.folder, extra: extraExcluded)
        || SensitiveContent.looksSensitive((note.name ?? "") + "\n" + text) {
        summary.sensitiveSkipped += 1
        if let existing { purge.insert(existing) }
        return
      }
      if let existing, let createdAt = note.createdAt {
        try? history.alignArchiveTaskTime(taskID: existing, originalMilliseconds: Self.milliseconds(createdAt))
      }
      // 在汲作里删掉（移到回收站）的备忘录，下次同步不悄悄带回来。
      if existing != nil, try !history.containsCanonicalURL(identity) {
        summary.skipped += 1
        return
      }
      // 内容没变就不再落库：避免每次同步都在列表里把几百条备忘录「顶」到最新。
      if let existing, try history.detail(taskID: existing).snapshots.contains(where: { $0.bodyText == document.text }) {
        summary.skipped += 1
        return
      }
      _ = try await ingest(document, receivedAt: note.createdAt.map(Self.milliseconds))
      if existing == nil { summary.added += 1 } else { summary.updated += 1 }
    } catch {
      summary.failures.append("\(note.name ?? "无标题备忘录")：\(Self.message(for: error))")
    }
  }

  /// 备忘录的第一行通常就是标题；阅读页已经显示标题，正文里不再重复一次。
  static func noteBody(html: String, title: String?) -> String {
    let markdown = AppleNoteHTML.markdown(from: html)
    guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return markdown }
    var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let first = lines.first {
      let plain = first.replacingOccurrences(of: "**", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
      if plain == title { lines.removeFirst() }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: 本地文件

  func chooseFiles() {
    guard canImport else { return }
    let panel = NSOpenPanel()
    panel.title = "导入本地文件"
    panel.prompt = "导入"
    panel.message = "支持文档（PDF、Word、TXT、Markdown）、图片（自动识别文字）、音频与视频（可在本机转写）。"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK else { return }
    importFiles(panel.urls)
  }

  /// 拖放和「导入本地文件…」共用。不支持的文件不拦截整批，逐个说明。
  func importFiles(_ urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard canImport, !files.isEmpty else { return }
    let title = files.count == 1 ? "导入「\(files[0].lastPathComponent)」" : "导入 \(files.count) 个文件"
    phase = .running(title: title, done: 0, total: files.count, step: nil)
    task = Task { [weak self] in
      guard let self else { return }
      var summary = Summary()
      var lastTaskID: TaskID?
      for (index, url) in files.enumerated() {
        if Task.isCancelled { break }
        setStep(Self.step(for: url), title: title, done: index, total: files.count)
        if let taskID = await importFile(url, summary: &summary) { lastTaskID = taskID }
      }
      // 只导入一个文件时直接打开它；一批文件则落到「本地文件」分组里看全貌。
      if files.count == 1, let lastTaskID, summary.failures.isEmpty {
        historyModel?.reveal(taskID: lastTaskID)
        phase = .idle
        return
      }
      finish(title: title, summary: summary, host: LocalImportSource.files.rawValue)
    }
  }

  private func importFile(_ url: URL, summary: inout Summary) async -> TaskID? {
    guard let history else { return nil }
    let name = url.lastPathComponent
    guard LocalFileImportReader.isSupported(url) else {
      summary.failures.append("\(name)：\(LocalFileImportError.unsupportedType(url.pathExtension.lowercased()).userMessage)")
      return nil
    }
    do {
      let sha = try await Task.detached { try LocalFileImportReader.contentSHA256(of: url) }.value
      let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
      let identity = try CanonicalURL.localImport(source: LocalImportSource.files.rawValue, identifier: sha)
      // 回收站里的不算已导入：用户把删掉的文件再拖进来，就是想把它拿回来，
      // 落库时 `acceptCapture` 会把原条目复活。语音备忘录相反——同步是批量的，
      // 在汲作里删掉的录音不该被下一次同步悄悄带回来。
      if try history.containsCanonicalURL(identity), let existing = try history.taskID(forCanonicalURL: identity) {
        // 早期版本导入图片只存了识别出的文字。再拖一次同一张图就把原图补上，
        // 不必让用户先删掉再导入。
        let needsImage = LocalFileImportReader.imageExtensions.contains(url.pathExtension.lowercased())
          && imageCache?.firstLocalImageURL(taskID: existing) == nil
        if !needsImage {
          summary.skipped += 1
          return existing
        }
      }
      let reader = reader
      let content = try await Task.detached { try await reader.read(url) }.value
      switch content {
      case let .text(text, method, completeness):
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name, text: text,
          completeness: completeness, method: method, fileDate: fileDate
        )
        let capture = try await ingest(document)
        summary.added += 1
        return capture.taskID
      case let .image(data, recognized):
        let reference = identity.value
        let body = LocalImportDocument.imageBody(fileName: name, reference: reference, recognizedText: recognized)
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name, text: body,
          completeness: "partial", method: "local_file_image", fileDate: fileDate
        )
        let capture = try await ingest(document)
        guard let imageCache else { throw RepositoryFailure.unavailable }
        try imageCache.storeLocalImage(data, reference: reference, taskID: capture.taskID, snapshotID: capture.snapshotID)
        summary.added += 1
        return capture.taskID
      case let .media(data, duration, hasVideo):
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name,
          text: LocalImportDocument.mediaPlaceholder(fileName: name, durationSeconds: duration, hasVideo: hasVideo),
          completeness: "partial", method: hasVideo ? "local_file_video" : "local_file_audio", fileDate: fileDate
        )
        let taskID = try await store(document: document, media: data, durationSeconds: duration, platform: .files)
        summary.added += 1
        return taskID
      }
    } catch {
      summary.failures.append("\(name)：\(Self.message(for: error))")
      return nil
    }
  }

  private func setStep(_ step: String, title: String, done: Int, total: Int) {
    phase = .running(title: title, done: done, total: total, step: step)
  }

  /// 进度里写清楚正在做哪一步：识图、转码可能要十几秒，只有一条进度条会被当成卡死。
  private static func step(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    let name = url.lastPathComponent
    if LocalFileImportReader.imageExtensions.contains(ext) { return "正在识别「\(name)」里的文字…" }
    if LocalFileImportReader.audioExtensions.contains(ext) { return "正在转换「\(name)」的音频…" }
    if LocalFileImportReader.videoExtensions.contains(ext) { return "正在读取视频「\(name)」…" }
    return "正在读取「\(name)」…"
  }

  // MARK: 落库

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private func ingest(_ document: CapturedDocument, receivedAt: Int64? = nil) async throws -> CurrentCapture {
    guard let ingestor = manualLink?.ingestor else { throw RepositoryFailure.unavailable }
    // 导入是「收素材」，不是「读完就要结果」：不自动总结、不自动转写，也不抢走
    // 用户当前正在看的那条。花不花模型费用由用户在条目里自己决定。
    return try await ingestor.ingest(
      document,
      suppressesAutomaticEnrichment: true,
      navigationIntent: .keepCurrent,
      receivedAtMilliseconds: receivedAt
    )
  }

  /// 先落条目再挂媒体。挂媒体失败时回收刚写的文件，条目本身保留（正文仍可看、可重试）。
  @discardableResult
  private func store(
    document: CapturedDocument,
    media data: Data,
    durationSeconds: Double?,
    platform: LocalImportSource,
    receivedAt: Int64? = nil
  ) async throws -> TaskID {
    guard let history, let mediaStore else { throw RepositoryFailure.unavailable }
    let capture = try await ingest(document, receivedAt: receivedAt)
    let stored = try await Task.detached {
      try mediaStore.storeDetailed(data: data, preferredExtension: "mp4")
    }.value
    let asset = MediaAsset(
      taskID: capture.taskID,
      snapshotID: capture.snapshotID,
      relativePath: stored.relativePath,
      fileBookmark: stored.fileBookmark,
      contentSHA256: stored.sha256,
      byteSize: Int64(data.count),
      durationSeconds: durationSeconds,
      platform: platform.rawValue,
      createdAtMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    )
    do {
      try history.attachMedia(.init(asset: asset))
    } catch {
      mediaStore.rollbackCreatedFile(stored)
      throw error
    }
    return capture.taskID
  }

  private func finish(title: String, summary: Summary, host: String) {
    historyModel?.reload()
    phase = .finished(title: title, summary: summary, revealHost: summary.added + summary.skipped > 0 ? host : nil)
  }

  func reveal(host: String) {
    historyModel?.selectHost(host)
    phase = .idle
  }

  enum SettingsLink: Equatable {
    case fullDiskAccess
    case automation

    var url: URL? {
      switch self {
      case .fullDiskAccess: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
      case .automation: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
      }
    }
  }

  func open(_ link: SettingsLink) {
    if let url = link.url { NSWorkspace.shared.open(url) }
  }

  private static func message(for error: Error) -> String {
    switch error {
    case let error as LocalFileImportError: return error.userMessage
    case let error as MediaDownloadError: return error.userMessage
    case let error as VoiceMemosLibraryError: return error.userMessage
    case let error as AppleNotesLibraryError: return error.userMessage
    case is StorageWriteGateFailure, is RepositoryFailure: return "写入本地资料库失败，请检查存储状态后重试。"
    default: return "导入失败，请重试。"
    }
  }
}
