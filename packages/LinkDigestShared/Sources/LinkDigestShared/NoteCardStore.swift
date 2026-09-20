import Foundation

/// 本机笔记卡仓库。iOS / Mac 各自先落本地，再交给同步引擎推拉。
public protocol NoteCardStore: Sendable {
  func list(includeDeleted: Bool) async throws -> [SyncNoteCard]
  func get(id: UUID) async throws -> SyncNoteCard?
  func upsert(_ card: SyncNoteCard) async throws
  func softDelete(id: UUID, atMilliseconds: Int64) async throws
}

public enum NoteSyncPhase: String, Sendable, Equatable {
  case idle
  case pushing
  case pulling
  case failed
}

public struct NoteSyncStatus: Sendable, Equatable {
  public var phase: NoteSyncPhase
  public var lastSuccessAtMilliseconds: Int64?
  public var lastErrorMessage: String?

  public init(
    phase: NoteSyncPhase = .idle,
    lastSuccessAtMilliseconds: Int64? = nil,
    lastErrorMessage: String? = nil
  ) {
    self.phase = phase
    self.lastSuccessAtMilliseconds = lastSuccessAtMilliseconds
    self.lastErrorMessage = lastErrorMessage
  }
}

/// CloudKit（或其它传输）同步端口。实现不得读写 API Key。
public protocol NoteCardSyncing: Sendable {
  func synchronize(local: NoteCardStore) async throws -> NoteSyncStatus
}

/// 进程内仓库，供测试与尚未接通 CloudKit 的 UI 开发。
public actor InMemoryNoteCardStore: NoteCardStore {
  private var cards: [UUID: SyncNoteCard] = [:]

  public init(seed: [SyncNoteCard] = []) {
    for card in seed {
      cards[card.id] = card
    }
  }

  public func list(includeDeleted: Bool) async throws -> [SyncNoteCard] {
    cards.values
      .filter { includeDeleted || !$0.isDeleted }
      .sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }

  public func get(id: UUID) async throws -> SyncNoteCard? {
    cards[id]
  }

  public func upsert(_ card: SyncNoteCard) async throws {
    try SyncNoteCardValidator.validate(card)
    if let existing = cards[card.id] {
      cards[card.id] = SyncNoteCardFactory.merge(local: existing, remote: card)
    } else {
      cards[card.id] = card
    }
  }

  public func softDelete(id: UUID, atMilliseconds: Int64) async throws {
    guard var card = cards[id] else { return }
    card.deletedAtMilliseconds = atMilliseconds
    // 必须严格新于原 updatedAt，否则同戳合并会丢掉墓碑。
    card.updatedAtMilliseconds = max(card.updatedAtMilliseconds + 1, atMilliseconds)
    cards[id] = card
  }
}

/// 把两个仓库的变更合并进 local（last-writer-wins）。
/// CloudKit 适配器接通前，可用两个 InMemory store 验证合并语义。
public struct LocalMergeNoteCardSync: NoteCardSyncing {
  private let remote: NoteCardStore

  public init(remote: NoteCardStore) {
    self.remote = remote
  }

  public func synchronize(local: NoteCardStore) async throws -> NoteSyncStatus {
    let localCards = try await local.list(includeDeleted: true)
    let remoteCards = try await remote.list(includeDeleted: true)
    let remoteByID = Dictionary(uniqueKeysWithValues: remoteCards.map { ($0.id, $0) })
    let localByID = Dictionary(uniqueKeysWithValues: localCards.map { ($0.id, $0) })

    let allIDs = Set(localByID.keys).union(remoteByID.keys)
    for id in allIDs {
      switch (localByID[id], remoteByID[id]) {
      case let (localCard?, remoteCard?):
        let merged = SyncNoteCardFactory.merge(local: localCard, remote: remoteCard)
        try await local.upsert(merged)
        try await remote.upsert(merged)
      case let (localCard?, nil):
        try await remote.upsert(localCard)
      case let (nil, remoteCard?):
        try await local.upsert(remoteCard)
      case (nil, nil):
        break
      }
    }

    return NoteSyncStatus(
      phase: .idle,
      lastSuccessAtMilliseconds: SyncNoteCardFactory.nowMilliseconds(),
      lastErrorMessage: nil
    )
  }
}
