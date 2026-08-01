import Combine
import Foundation
import LinkDigestCore

/// 笔记写作窗口的状态与自动保存。
///
/// 写作窗口没有「保存」按钮，改动自动落库。这不是省一个按钮的问题——有保存按钮就
/// 意味着「没点保存 = 白写」，而人在写东西时最不该分心的就是这件事。
@MainActor
final class NoteEditorModel: ObservableObject {
  @Published var title = ""
  @Published var body = ""
  @Published private(set) var statusText = ""

  private var ingestor: CaptureIngestService?
  private var history: HistoryApplicationService?
  private var nowMilliseconds: (() -> Int64)?
  /// 当前正在编辑的笔记。新建时先为 nil，第一次保存后填上。
  private var taskID: TaskID?
  private var snapshotID: ContentSnapshotID?
  private var saveTask: Task<Void, Never>?
  private var isLoading = false
  /// 已落库的内容。用来判断「真的变了吗」，避免每次光标移动都写一次库。
  private var savedTitle = ""
  private var savedBody = ""
  private var cancellables: Set<AnyCancellable> = []

  /// 停止输入多久之后落库。
  ///
  /// 太短会把每个字都写进数据库，太长则关窗时容易丢。0.8 秒接近一次自然停顿，
  /// 而关窗、切窗都会另外强制 flush 一次，所以这个值只影响「写作途中」的落盘密度。
  private static let autosaveDelay: Duration = .milliseconds(800)

  init() {
    // 标题和正文任一变化都排一次延迟保存。
    Publishers.CombineLatest($title, $body)
      .dropFirst()
      .sink { [weak self] _, _ in self?.scheduleSave() }
      .store(in: &cancellables)
  }

  func configure(
    history: HistoryApplicationService?,
    ingestor: CaptureIngestService?,
    nowMilliseconds: @escaping () -> Int64
  ) {
    self.history = history
    self.ingestor = ingestor
    self.nowMilliseconds = nowMilliseconds
  }

  /// 打开一条已有笔记；`taskID` 为 nil 表示新建。
  func load(taskID: TaskID?) async {
    isLoading = true
    defer { isLoading = false }
    saveTask?.cancel()

    guard let taskID, let history else {
      self.taskID = nil
      snapshotID = nil
      title = ""
      body = ""
      savedTitle = ""
      savedBody = ""
      statusText = "尚未保存"
      return
    }

    self.taskID = taskID
    let detail = try? history.detail(taskID: taskID)
    let snapshot = detail?.snapshots.last
    snapshotID = snapshot?.id
    title = snapshot?.title ?? ""
    body = snapshot.map { MarkdownNoteFrontmatter.parse($0.bodyText).body } ?? ""
    savedTitle = title
    savedBody = body
    statusText = "已保存"
  }

  private func scheduleSave() {
    guard !isLoading else { return }
    statusText = "正在输入…"
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: Self.autosaveDelay)
      guard !Task.isCancelled else { return }
      await self?.save()
    }
  }

  /// 关窗或切窗时立刻落库，不等那 0.8 秒。
  func flushPendingSave() {
    saveTask?.cancel()
    Task { await save() }
  }

  private func save() async {
    guard title != savedTitle || body != savedBody else { return }
    // 全空的新笔记不建：打开窗口又直接关掉，不该在列表里留一条空记录。
    let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasContent else { return }

    if taskID == nil {
      await createNote()
    } else {
      updateExistingNote()
    }
  }

  private func createNote() async {
    guard let ingestor else { return }
    do {
      let document = try UserNoteDocument.make(title: title, body: body)
      let capture = try await ingestor.ingest(document)
      taskID = capture.taskID
      snapshotID = capture.snapshotID
      savedTitle = title
      savedBody = body
      statusText = "已保存"
    } catch {
      statusText = "保存失败，内容仍在窗口里"
    }
  }

  private func updateExistingNote() {
    guard let history, let taskID, let snapshotID, let nowMilliseconds else { return }
    do {
      try history.updateSnapshotBodyText(
        taskID: taskID,
        snapshotID: snapshotID,
        bodyText: body,
        updatedAtMilliseconds: nowMilliseconds()
      )
      savedTitle = title
      savedBody = body
      statusText = "已保存"
    } catch {
      statusText = "保存失败，内容仍在窗口里"
    }
  }
}
