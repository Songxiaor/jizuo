import Foundation
import LinkDigestShared

/// 桌面 History ↔ Companion 投影之间的推拉桥。
///
/// 不直接实现 `NoteCardStore`：本机真相仍是 SQLite History；同步时先导出到
/// JSON 投影，CloudKit 合并后再写回 History，墓碑也留在投影里。
public struct HistoryCompanionNoteBridge: Sendable {
  private let history: HistoryApplicationService
  private let pageSize: Int

  public init(history: HistoryApplicationService, pageSize: Int = 80) {
    self.history = history
    self.pageSize = max(1, pageSize)
  }

  /// 导出可同步条目（笔记 + 链接）。
  public func exportCards() throws -> [SyncNoteCard] {
    var cards: [SyncNoteCard] = []
    var cursor: HistoryPageCursor?
    repeat {
      let page = try history.historyPage(limit: pageSize, after: cursor, filter: .none)
      for row in page.rows where HistorySyncNoteCardMapping.isSyncable(canonicalURL: row.canonicalURL) {
        let detail = try history.detail(taskID: row.taskID)
        if let card = HistorySyncNoteCardMapping.card(from: detail) {
          cards.append(card)
        }
      }
      cursor = page.nextCursor
    } while cursor != nil
    return cards
  }

  /// 把投影里的卡写回 History（创建 / 更新正文标题 / 链接 summary→summarize / 删除）。
  public func apply(_ card: SyncNoteCard) throws {
    try SyncNoteCardValidator.validate(card)
    let canonical = try HistorySyncNoteCardMapping.canonicalURL(for: card)
    if card.isDeleted {
      if let taskID = try history.taskID(forCanonicalURL: canonical) {
        try history.deleteTask(taskID: taskID)
      }
      return
    }

    if let taskID = try history.taskID(forCanonicalURL: canonical) {
      try updateExisting(taskID: taskID, card: card)
      try applyLinkSummaryIfNeeded(taskID: taskID, card: card)
      return
    }

    let document = try HistorySyncNoteCardMapping.document(forApplying: card)
    let command = try AcceptCaptureCommand(
      document: document,
      receivedAtMilliseconds: card.updatedAtMilliseconds
    )
    let accepted = try history.acceptCapture(command)
    try applyLinkSummaryIfNeeded(taskID: accepted.taskID, card: card)
  }

  private func updateExisting(taskID: TaskID, card: SyncNoteCard) throws {
    let detail = try history.detail(taskID: taskID)
    guard let snapshot = HistorySyncNoteCardMapping.primaryContentSnapshot(in: detail) else {
      throw RepositoryFailure.notFound
    }

    if snapshot.bodyText != card.body {
      try history.updateSnapshotBodyText(
        taskID: taskID,
        snapshotID: snapshot.id,
        bodyText: card.body,
        updatedAtMilliseconds: card.updatedAtMilliseconds
      )
    }

    let currentTitle = snapshot.title ?? ""
    if currentTitle != card.title {
      // 链接标题改名目前也允许：Companion 侧是用户可见标题。
      try history.updateTaskTitle(
        taskID: taskID,
        title: card.title,
        updatedAtMilliseconds: card.updatedAtMilliseconds
      )
    }
  }

  /// 链接卡非空 summary → 一条 completed summarize run + artifact（正文=summary）。
  ///
  /// 已有相同正文的最新 completed 摘要则跳过。不走模型，只落库，便于手机摘要回灌桌面。
  private func applyLinkSummaryIfNeeded(taskID: TaskID, card: SyncNoteCard) throws {
    guard let summary = HistorySyncNoteCardMapping.linkSummaryBody(from: card) else { return }
    let detail = try history.detail(taskID: taskID)
    guard HistorySyncNoteCardMapping.needsRemoteSummaryWrite(detail: detail, remoteSummary: summary)
    else { return }
    guard let snapshot = HistorySyncNoteCardMapping.primaryContentSnapshot(in: detail) else {
      throw RepositoryFailure.notFound
    }

    let ms = card.updatedAtMilliseconds
    // 每次真正写入用新幂等键；重复同步靠「正文相同则跳过」拦住。
    let created = try history.createRun(
      CreateRunCommand(
        taskID: taskID,
        snapshotID: snapshot.id,
        idempotencyKey: "companion-sync-summary:\(taskID.rawValue):\(UUID().uuidString.lowercased())",
        kind: .summarize,
        createdAtMilliseconds: ms
      )
    )
    // finished 只能从 running 进入；同步写回也走同一状态机。
    try history.markRunRunning(
      MarkRunRunningCommand(
        runID: created.runID,
        startedAtMilliseconds: ms,
        provider: ProviderRunMetadata(model: "companion-sync")
      )
    )
    try history.finishRun(
      FinishRunCommand(
        runID: created.runID,
        status: .completed,
        finishedAtMilliseconds: ms,
        artifact: .init(
          contentFormat: .markdown,
          completeness: .complete,
          bodyText: summary
        )
      )
    )
  }
}
