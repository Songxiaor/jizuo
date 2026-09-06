import Foundation
import LinkDigestCore
import LinkDigestShared
import Observation

/// Mac ↔ iOS Companion CloudKit 同步协调器。
@MainActor
@Observable
final class CompanionNoteSyncCoordinator {
  private(set) var status: NoteSyncStatus = NoteSyncStatus()
  private(set) var isRunning = false
  private(set) var lastExportedCount = 0
  private(set) var lastAppliedCount = 0

  private var history: HistoryApplicationService?
  private let sync: any NoteCardSyncing
  private let enabled: Bool

  init(
    sync: (any NoteCardSyncing)? = nil,
    enabled: Bool? = nil
  ) {
    let entitled = CloudKitCapability.isContainerEntitled()
    self.sync = sync ?? CloudKitNoteCardSync(enabled: entitled)
    self.enabled = enabled ?? entitled
    if !(enabled ?? entitled) {
      self.status = NoteSyncStatus(
        phase: .failed,
        lastErrorMessage: CloudKitCapability.unavailableMessage()
      )
    }
  }

  func configure(history: HistoryApplicationService?) {
    self.history = history
  }

  var canSync: Bool { enabled && history != nil && !isRunning }

  var statusSummary: String {
    if isRunning { return "正在同步…" }
    if !enabled {
      return CloudKitCapability.unavailableMessage()
    }
    if let error = status.lastErrorMessage, status.phase == .failed {
      return error
    }
    if let ms = status.lastSuccessAtMilliseconds {
      let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      return "上次成功：\(formatter.string(from: date))（导出 \(lastExportedCount) · 写回 \(lastAppliedCount)）"
    }
    return "尚未同步"
  }

  func synchronize() async {
    guard !isRunning else { return }
    guard enabled else {
      status = NoteSyncStatus(
        phase: .failed,
        lastErrorMessage: "手机同步未启用。"
      )
      return
    }
    guard let history else {
      status = NoteSyncStatus(
        phase: .failed,
        lastErrorMessage: "历史存储尚未就绪。"
      )
      return
    }

    isRunning = true
    status = NoteSyncStatus(phase: .pulling)
    defer { isRunning = false }

    do {
      let bridge = HistoryCompanionNoteBridge(history: history)
      let store = try await LocalJSONNoteCardStore.applicationSupportStore(
        subdirectory: "LinkDigest",
        fileName: "companion-note-cards-v1.json"
      )

      let exported = try bridge.exportCards()
      lastExportedCount = exported.count
      for card in exported {
        try await store.upsert(card)
      }

      let syncResult = try await sync.synchronize(local: store)
      status = syncResult
      guard syncResult.phase != .failed else { return }

      let merged = try await store.list(includeDeleted: true)
      var applied = 0
      var queuedTranscription = 0
      for var card in merged {
        if card.transcriptionRequestedAtMilliseconds != nil,
           card.kind == .link,
           !(card.isDeleted),
           (card.transcript?.hasPrefix("【Mac 转写完成】") != true)
        {
          // 先导入 History，供用户本机转写；状态写回投影，下次 sync 给手机。
          card.transcript = """
          【Mac 转写排队】已导入电脑历史。请在汲作打开该链接，使用「本机转写」；完成后点 Companion 同步，手机会收到正文。
          """
          card.transcriptionRequestedAtMilliseconds = nil
          card.updatedAtMilliseconds = SyncNoteCardFactory.nowMilliseconds()
          try await store.upsert(card)
          queuedTranscription += 1
        }
        try bridge.apply(card)
        applied += 1
      }
      lastAppliedCount = applied
      if queuedTranscription > 0 {
        status = NoteSyncStatus(
          phase: syncResult.phase,
          lastSuccessAtMilliseconds: syncResult.lastSuccessAtMilliseconds
            ?? SyncNoteCardFactory.nowMilliseconds(),
          lastErrorMessage: syncResult.lastErrorMessage
            ?? "已为 \(queuedTranscription) 条手机请求导入转写队列（请在历史中完成本机转写）。"
        )
      }
      // 成功写回后刷新列表，让手机新建的笔记立刻可见。
      NotificationCenter.default.post(name: .companionNoteSyncDidFinish, object: nil)
    } catch {
      status = NoteSyncStatus(
        phase: .failed,
        lastErrorMessage: "同步失败：\(error.localizedDescription)"
      )
    }
  }
}

extension Notification.Name {
  static let companionNoteSyncDidFinish = Notification.Name("LinkDigest.CompanionNoteSyncDidFinish")
}
