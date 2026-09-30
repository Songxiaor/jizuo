import AppKit
import Foundation
import LinkDigestAdapters
import LinkDigestCore

/// 本机素材导入：同步语音备忘录、导入拖进来的文件和文件夹。
///
/// 落库复用 `CaptureIngestService`（与手动链接、笔记同一条通道），媒体复用
/// `LocalMediaStore` + `attachMedia`（与抖音/B 站视频同一条通道）。这里只负责
/// 「从本机读出来」和把结果讲清楚，不另开写入口。
///
/// 2026-09-29 起拖进来的音视频**只引用原文件**，不复制进 App 的数据目录（见
/// `LocalMediaStore.externalReferenceAsset`）；文件夹递归展开、导入前先确认；
/// 可以勾「导入后转写」，导入完逐个本机转写；下载来的文件按来源标记判为外部。
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
    /// 本地文件逐个的归属判断（这次新收进来的）。每条都能在结果里「改」。
    var ownership: [OwnershipItem] = []
    /// 勾了「导入后转写」、排进本机转写队列的音视频条数。
    var queuedForTranscription = 0
  }

  /// 导入结果里的一行：这个文件判成了自有还是外部、依据是什么。
  struct OwnershipItem: Equatable, Identifiable {
    let id: TaskID
    let name: String
    let canonicalURL: String
    var ownership: ContentOwnership
    /// 「微信下载」这类来源说明；没有下载标记时为 nil（按自有算）。
    let source: String?
  }

  /// 导入前的确认：找到了哪些文件、要不要导入后转写。
  struct ImportPlan: Equatable {
    let scan: LocalImportScan
    var offersTranscription: Bool { scan.mediaCount > 0 }
  }

  enum Phase: Equatable {
    case idle
    case running(title: String, done: Int, total: Int, step: String?)
    case confirming(ImportPlan)
    case finished(title: String, summary: Summary, revealHost: String?)
    case failed(title: String, message: String, settingsLink: SettingsLink?)
  }

  /// 「导入后转写」队列的进度：窗口右下角那条小胶囊显示它，关掉结果窗口也照常往下转。
  struct TranscriptionQueueStatus: Equatable {
    var total = 0
    /// 已经处理完（成功、失败、已有转写都算）的条数。
    var finished = 0
    var succeeded = 0
    var alreadyTranscribed = 0
    var currentName: String?
    var failures: [String] = []
    var isRunning = false
    var wasStopped = false
    /// 「转写中 3/12」里的 3。
    var position: Int { min(finished + 1, max(total, 1)) }
  }

  /// 给「合集」的挂钩：每个被导入的顶层文件夹处理完调用一次，taskIDs 按文件夹内的自然排序
  /// （含之前已导入、这次去重命中的条目，不含失败的）。默认 nil；由总控集成时接线。
  var onFolderImported: ((_ folderName: String, _ folderURL: URL, _ orderedTaskIDs: [TaskID]) -> Void)?

  @Published private(set) var transcriptionQueue: TranscriptionQueueStatus?
  private var transcriptionBacklog: [(taskID: TaskID, name: String)] = []
  private var transcriptionQueueTask: Task<Void, Never>?

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
    // 原文件被移动、改名后书签会「过期」但仍找得到：把新书签写回媒体记录，下次直接命中。
    if let history {
      mediaStore?.setExternalReferenceRefresher { asset in
        Task.detached(priority: .utility) { try? history.attachMedia(.init(asset: asset)) }
      }
    } else {
      mediaStore?.setExternalReferenceRefresher(nil)
    }
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
    guard !explainNotReady("同步语音备忘录") else { return }
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
    guard !explainNotReady("同步备忘录") else { return }
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

  /// 资料库还没接好（刚启动、只读模式）时点了导入：说明原因，而不是什么都不发生。
  private func explainNotReady(_ title: String) -> Bool {
    guard !canImport else { return false }
    if !isRunning {
      phase = .failed(title: title, message: "资料库还在准备或处于只读状态，请稍等几秒再试。", settingsLink: nil)
    }
    return true
  }

  func chooseFiles() {
    guard !explainNotReady("导入本地文件") else { return }
    let panel = NSOpenPanel()
    panel.title = "导入本地文件"
    panel.prompt = "导入"
    panel.message = "可以选文件或整个文件夹（会连子文件夹一起导入）。支持文档（PDF、Word、TXT、Markdown）、图片（自动识别文字）、音频与视频（可在本机转写）。音视频只记住原文件的位置，不会复制一份。"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    guard panel.runModal() == .OK else { return }
    importFiles(panel.urls)
  }

  /// 拖放和「导入本地文件…」共用。先把文件夹展开成清单；有文件夹、有多个文件或有音视频时
  /// 先确认（顺便问要不要导入后转写），只拖进一个文档就直接导入。
  /// 不支持的文件不拦截整批，逐个说明。
  func importFiles(_ urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard canImport, !files.isEmpty else { return }
    let title = "导入本地文件"
    phase = .running(title: title, done: 0, total: 0, step: "正在查找可以导入的文件…")
    task = Task { [weak self] in
      let scan = await Task.detached(priority: .userInitiated) { LocalFileImportReader.scanForImport(files) }.value
      guard let self else { return }
      guard !Task.isCancelled else {
        phase = .idle
        return
      }
      let plan = ImportPlan(scan: scan)
      if scan.entries.isEmpty {
        finish(title: title, summary: Self.skippedSummary(plan), host: LocalImportSource.files.rawValue)
      } else if Self.needsConfirmation(plan) {
        phase = .confirming(plan)
      } else {
        startImport(plan, transcribe: false)
      }
    }
  }

  /// 只拖进一个文档（或图片）时照旧直接导入、直接打开；其余都先让用户看一眼规模。
  static func needsConfirmation(_ plan: ImportPlan) -> Bool {
    !plan.scan.folders.isEmpty || plan.scan.entries.count > 1 || plan.offersTranscription || plan.scan.truncated
  }

  func confirmImport(transcribe: Bool) {
    guard case let .confirming(plan) = phase else { return }
    startImport(plan, transcribe: transcribe && plan.offersTranscription)
  }

  func cancelConfirmation() {
    if case .confirming = phase { phase = .idle }
  }

  private func startImport(_ plan: ImportPlan, transcribe: Bool) {
    let entries = plan.scan.entries
    let title = entries.count == 1 ? "导入「\(entries[0].url.lastPathComponent)」" : "导入 \(entries.count) 个文件"
    phase = .running(title: title, done: 0, total: entries.count, step: nil)
    task = Task { [weak self] in
      guard let self else { return }
      var summary = Self.skippedSummary(plan)
      var lastTaskID: TaskID?
      var folderTaskIDs: [Int: [TaskID]] = [:]
      var toTranscribe: [(taskID: TaskID, name: String)] = []
      var processed = 0
      for (index, entry) in entries.enumerated() {
        if Task.isCancelled { break }
        processed += 1
        setStep(Self.step(for: entry.url), title: title, done: index, total: entries.count)
        if let taskID = await importFile(entry, summary: &summary) {
          lastTaskID = taskID
          if let folder = entry.folderIndex, !(folderTaskIDs[folder] ?? []).contains(taskID) {
            folderTaskIDs[folder, default: []].append(taskID)
          }
          if transcribe, entry.kind == .video || entry.kind == .audio,
             !toTranscribe.contains(where: { $0.taskID == taskID }) {
            toTranscribe.append((taskID, entry.url.lastPathComponent))
          }
        }
        // 同一个顶层文件夹的文件在清单里是连着的：下一项换了文件夹（或到头了）就算这个文件夹导完。
        if let folder = entry.folderIndex, index + 1 == entries.count || entries[index + 1].folderIndex != folder,
           let ordered = folderTaskIDs[folder], !ordered.isEmpty, plan.scan.folders.indices.contains(folder) {
          let info = plan.scan.folders[folder]
          onFolderImported?(info.name, info.url, ordered)
        }
      }
      if processed < entries.count {
        summary.failures.append("导入被停止了，还有 \(entries.count - processed) 个文件没有处理。")
        // 点了「停止」就都停：已经导入的也不再排队转写，需要时在条目里点「转写」。
        toTranscribe.removeAll()
      }
      if !toTranscribe.isEmpty {
        enqueueTranscription(toTranscribe)
        summary.queuedForTranscription = toTranscribe.count
      }
      // 只导入一个文件时直接打开它；一批文件则落到「本地文件」分组里看全貌。
      if entries.count == 1, let lastTaskID, summary.failures.isEmpty {
        historyModel?.reveal(taskID: lastTaskID)
        phase = .idle
        return
      }
      finish(title: title, summary: summary, host: LocalImportSource.files.rawValue)
    }
  }

  /// 扫描时就知道导入不了的文件（格式不支持、读不出来、太多没收），先写进结果。
  private static func skippedSummary(_ plan: ImportPlan) -> Summary {
    var summary = Summary()
    summary.failures = plan.scan.skipped.map { "\($0.displayName)：\($0.reason)" }
    let unlisted = plan.scan.skippedCount - plan.scan.skipped.count
    if unlisted > 0 { summary.failures.append("另有 \(unlisted) 个文件同样不支持，没有逐个列出。") }
    if plan.scan.truncated {
      summary.failures.append("文件太多：这次只导入了按顺序的前 \(LocalFileImportReader.scanFileLimit) 个，其余请分批导入。")
    }
    return summary
  }

  private func importFile(_ entry: LocalImportScan.Entry, summary: inout Summary) async -> TaskID? {
    guard let history else { return nil }
    let url = entry.url
    let name = url.lastPathComponent
    do {
      // 算哈希要把整个文件读一遍（几 GB 的视频也一样），和读来源标记一起放到后台。
      let (sha, provenance) = try await Task.detached(priority: .userInitiated) {
        (try LocalFileImportReader.contentSHA256(of: url), LocalFileImportReader.provenance(of: url))
      }.value
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
      let sourceLabel = provenance?.sourceLabel ?? LocalFileProvenance.plainSourceLabel
      let reader = reader
      let content = try await Task.detached { try await reader.read(url) }.value
      let taskID: TaskID
      switch content {
      case let .text(text, method, completeness):
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name, text: text,
          completeness: completeness, method: method, fileDate: fileDate
        )
        taskID = try await ingest(document.withSourceLabel(sourceLabel)).taskID
      case let .image(data, recognized):
        let reference = identity.value
        let body = LocalImportDocument.imageBody(fileName: name, reference: reference, recognizedText: recognized)
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name, text: body,
          completeness: "partial", method: "local_file_image", fileDate: fileDate
        )
        let capture = try await ingest(document.withSourceLabel(sourceLabel))
        guard let imageCache else { throw RepositoryFailure.unavailable }
        // 图片仍在图片缓存里留一份用于显示：阅读页从缓存里读图，不经过媒体记录。
        try imageCache.storeLocalImage(data, reference: reference, taskID: capture.taskID, snapshotID: capture.snapshotID)
        taskID = capture.taskID
      case let .mediaFile(duration, hasVideo):
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name,
          text: LocalImportDocument.mediaPlaceholder(fileName: name, durationSeconds: duration, hasVideo: hasVideo),
          completeness: "partial", method: hasVideo ? "local_file_video" : "local_file_audio", fileDate: fileDate
        )
        taskID = try await storeReference(
          document: document.withSourceLabel(sourceLabel), fileURL: url, contentSHA256: sha, durationSeconds: duration
        )
      case let .media(data, duration, hasVideo):
        // 本地文件不再走这条（音视频只引用原文件）；留着只为读取器将来返回拷贝时不至于丢数据。
        let document = try LocalImportDocument.file(
          contentSHA256: sha, fileName: name,
          text: LocalImportDocument.mediaPlaceholder(fileName: name, durationSeconds: duration, hasVideo: hasVideo),
          completeness: "partial", method: hasVideo ? "local_file_video" : "local_file_audio", fileDate: fileDate
        )
        taskID = try await store(document: document.withSourceLabel(sourceLabel), media: data, durationSeconds: duration, platform: .files)
      }
      summary.added += 1
      summary.ownership.append(applyOwnership(provenance, taskID: taskID, canonicalURL: identity.value, name: entry.displayName))
      return taskID
    } catch {
      summary.failures.append("\(entry.displayName)：\(Self.message(for: error))")
      return nil
    }
  }

  /// 下载来的文件（带 quarantine 标记）贴上保留标签「外部」，其余按本地文件的默认规则算自有、不贴标签。
  private func applyOwnership(_ provenance: LocalFileProvenance?, taskID: TaskID, canonicalURL: String, name: String) -> OwnershipItem {
    let host = LocalImportSource.files.rawValue
    let target: ContentOwnership = provenance == nil ? .own : .external
    if let history, provenance != nil {
      let changes = ContentOwnership.tagChanges(to: target, canonicalURL: canonicalURL, host: host)
      for raw in changes.remove {
        if let normalized = HistoryTagNormalizer.normalized(raw)?.normalizedName {
          try? history.removeTag(normalizedName: normalized, from: taskID)
        }
      }
      if !changes.add.isEmpty { _ = try? history.addTags(changes.add, to: taskID) }
    }
    return OwnershipItem(id: taskID, name: name, canonicalURL: canonicalURL, ownership: target, source: provenance?.summaryLabel)
  }

  /// 结果里的「改」：自有 ⇄ 外部。走阅读页同一个改归属入口（`setOwnership`）。
  func toggleOwnership(_ id: TaskID) {
    guard case .finished(let title, var summary, let host) = phase,
          let index = summary.ownership.firstIndex(where: { $0.id == id })
    else { return }
    let target: ContentOwnership = summary.ownership[index].ownership == .own ? .external : .own
    historyModel?.setOwnership(target, taskID: id, canonicalURL: summary.ownership[index].canonicalURL, host: LocalImportSource.files.rawValue)
    summary.ownership[index].ownership = target
    phase = .finished(title: title, summary: summary, revealHost: host)
  }

  // MARK: 导入后转写

  /// 「待转写」的「全部转写」：以前导入、同步来的音视频补转写，和导入后转写排同一条队列、
  /// 用同一个右下角进度。已经在排的不重复排。
  func transcribeBacklog(_ items: [(taskID: TaskID, name: String)]) {
    let queued = Set(transcriptionBacklog.map(\.taskID))
    enqueueTranscription(items.filter { !queued.contains($0.taskID) })
  }

  var isTranscriptionQueueRunning: Bool { transcriptionQueue?.isRunning == true }

  /// 排进本机转写队列。队列在跑就接到后面，总数跟着涨。
  private func enqueueTranscription(_ items: [(taskID: TaskID, name: String)]) {
    guard !items.isEmpty else { return }
    var status = transcriptionQueue?.isRunning == true ? (transcriptionQueue ?? .init()) : .init()
    status.total += items.count
    status.isRunning = true
    status.wasStopped = false
    transcriptionBacklog.append(contentsOf: items)
    transcriptionQueue = status
    guard transcriptionQueueTask == nil else { return }
    transcriptionQueueTask = Task { [weak self] in await self?.runTranscriptionQueue() }
  }

  /// 一条一条地转：本机转写同一时刻只有一个通道。单条失败记下原因接着转下一条。
  private func runTranscriptionQueue() async {
    while !Task.isCancelled, !transcriptionBacklog.isEmpty, let historyModel {
      let item = transcriptionBacklog.removeFirst()
      transcriptionQueue?.currentName = item.name
      let outcome = await historyModel.transcribeImportedMedia(taskID: item.taskID)
      switch outcome {
      case .completed:
        transcriptionQueue?.succeeded += 1
        // 正看着「待转写」时，转好一条就从列表里拿掉、侧栏数字跟着减。
        historyModel.refreshAfterBacklogTranscription()
      case .alreadyTranscribed: transcriptionQueue?.alreadyTranscribed += 1
      case let .failed(message): transcriptionQueue?.failures.append("\(item.name)：\(message)")
      case .cancelled:
        if !Task.isCancelled { transcriptionQueue?.failures.append("\(item.name)：转写被取消了。") }
      }
      if !(Task.isCancelled && outcome == .cancelled) { transcriptionQueue?.finished += 1 }
    }
    let stopped = Task.isCancelled
    if stopped { transcriptionBacklog.removeAll() }
    transcriptionQueue?.isRunning = false
    transcriptionQueue?.wasStopped = stopped
    transcriptionQueue?.currentName = nil
    transcriptionQueueTask = nil
    historyModel?.reload()
  }

  /// 胶囊上的「停止」：停掉正在转的这一条，后面排着的都不转了。已经转好的留着。
  func stopTranscriptionQueue() {
    transcriptionQueueTask?.cancel()
  }

  func dismissTranscriptionQueue() {
    guard transcriptionQueue?.isRunning != true else { return }
    transcriptionQueue = nil
  }

  private func setStep(_ step: String, title: String, done: Int, total: Int) {
    phase = .running(title: title, done: done, total: total, step: step)
  }

  /// 进度里写清楚正在做哪一步：识图、核对大文件可能要十几秒，只有一条进度条会被当成卡死。
  private static func step(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    let name = url.lastPathComponent
    if LocalFileImportReader.imageExtensions.contains(ext) { return "正在识别「\(name)」里的文字…" }
    if LocalFileImportReader.audioExtensions.contains(ext) { return "正在读取音频「\(name)」…" }
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

  /// 拖进来的音视频：先落条目，再挂一条「引用原文件」的媒体记录（书签），原文件一个字节都不复制。
  private func storeReference(
    document: CapturedDocument,
    fileURL: URL,
    contentSHA256: String,
    durationSeconds: Double?
  ) async throws -> TaskID {
    guard let history, let mediaStore else { throw RepositoryFailure.unavailable }
    let capture = try await ingest(document)
    // 回收站里复活的旧条目：当初复制进 Media/ 的那份还在就原样保留（旧条目不迁移）。
    if let existing = try? history.mediaAsset(taskID: capture.taskID),
       existing.contentSHA256 == contentSHA256,
       !ExternalMediaReference.isExternal(existing),
       (try? mediaStore.resolve(existing)) != nil {
      return capture.taskID
    }
    let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    guard size > 0 else { throw LocalFileImportError.unreadable }
    let asset = try mediaStore.externalReferenceAsset(
      fileURL: fileURL,
      taskID: capture.taskID,
      snapshotID: capture.snapshotID,
      contentSHA256: contentSHA256,
      byteSize: size,
      durationSeconds: durationSeconds,
      platform: LocalImportSource.files.rawValue,
      createdAtMilliseconds: Self.milliseconds(Date())
    )
    try history.attachMedia(.init(asset: asset))
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
    case let error as ExternalMediaReferenceError: return error.userMessage
    case let error as MediaDownloadError: return error.userMessage
    case let error as VoiceMemosLibraryError: return error.userMessage
    case let error as AppleNotesLibraryError: return error.userMessage
    case is StorageWriteGateFailure, is RepositoryFailure: return "写入本地资料库失败，请检查存储状态后重试。"
    default: return "导入失败，请重试。"
    }
  }
}

private extension CapturedDocument {
  /// 同一份文档换一个来源标签：下载来的本地文件把「下载自哪个 App / 网址」记在这里（不改表）。
  func withSourceLabel(_ label: String) -> CapturedDocument {
    guard label != sourceLabel else { return self }
    return CapturedDocument(
      requestID: requestID,
      createdAt: createdAt,
      idempotencyKey: idempotencyKey,
      origin: origin,
      url: url,
      title: title,
      platform: platform,
      method: method,
      text: text,
      characterCount: characterCount,
      completeness: completeness,
      capturedAt: capturedAt,
      sourceLabel: label,
      usedCookie: usedCookie,
      media: media
    )
  }
}
