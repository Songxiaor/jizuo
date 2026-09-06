import Foundation

/// 纯函数：合并本地与远端笔记卡，并算出需要推上去的集合。
public enum NoteCardSyncPlanner {
  /// 对同一 id 做 last-writer-wins；只在一边出现的原样保留。
  public static func mergeUniverse(
    local: [SyncNoteCard],
    remote: [SyncNoteCard]
  ) -> [SyncNoteCard] {
    let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
    let allIDs = Set(localByID.keys).union(remoteByID.keys)
    return allIDs.compactMap { id in
      switch (localByID[id], remoteByID[id]) {
      case let (localCard?, remoteCard?):
        SyncNoteCardFactory.merge(local: localCard, remote: remoteCard)
      case let (localCard?, nil):
        localCard
      case let (nil, remoteCard?):
        remoteCard
      case (nil, nil):
        nil
      }
    }
    .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }

  /// 合并后与拉下来的远端相比有差异（含远端没有）的卡，需要推送。
  public static func cardsNeedingPush(
    merged: [SyncNoteCard],
    remoteBefore: [SyncNoteCard]
  ) -> [SyncNoteCard] {
    let remoteByID = Dictionary(uniqueKeysWithValues: remoteBefore.map { ($0.id, $0) })
    return merged.filter { card in
      remoteByID[card.id] != card
    }
  }
}
