import CloudKit
import Foundation

/// CloudKit 私有库的笔记卡存取。生产用真库；测试注入 Fake。
public protocol CloudKitNoteDatabase: Sendable {
  func fetchAllNoteCards() async throws -> [SyncNoteCard]
  func saveNoteCards(_ cards: [SyncNoteCard]) async throws
}

/// 进程内假远端，验证推拉合并而不碰真实 iCloud。
public actor FakeCloudKitNoteDatabase: CloudKitNoteDatabase {
  private var cards: [UUID: SyncNoteCard]
  public private(set) var saveCallCount = 0
  public private(set) var fetchCallCount = 0

  public init(seed: [SyncNoteCard] = []) {
    self.cards = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
  }

  public func fetchAllNoteCards() async throws -> [SyncNoteCard] {
    fetchCallCount += 1
    return cards.values.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }

  public func saveNoteCards(_ cards: [SyncNoteCard]) async throws {
    saveCallCount += 1
    for card in cards {
      try SyncNoteCardValidator.validate(card)
      if let existing = self.cards[card.id] {
        self.cards[card.id] = SyncNoteCardFactory.merge(local: existing, remote: card)
      } else {
        self.cards[card.id] = card
      }
    }
  }

  public func storedCards() -> [SyncNoteCard] {
    cards.values.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
  }
}

/// 真 CloudKit 私有数据库。
public struct LiveCloudKitNoteDatabase: CloudKitNoteDatabase {
  private let database: CKDatabase

  public init(database: CKDatabase) {
    self.database = database
  }

  /// 仅在进程签名已包含该 CloudKit 容器时创建真库。
  /// 缺 entitlement 时 `CKContainer(identifier:)` 会 SIGTRAP，故这里先探测再构造。
  public static func make(
    containerIdentifier: String = CloudKitNoteCardSync.defaultContainerIdentifier
  ) throws -> LiveCloudKitNoteDatabase {
    guard CloudKitCapability.isContainerEntitled(containerIdentifier) else {
      throw CloudKitNoteCardSync.SyncError.containerUnavailable(containerIdentifier)
    }
    return LiveCloudKitNoteDatabase(
      database: CKContainer(identifier: containerIdentifier).privateCloudDatabase
    )
  }

  public func fetchAllNoteCards() async throws -> [SyncNoteCard] {
    var collected: [SyncNoteCard] = []
    var cursor: CKQueryOperation.Cursor?
    repeat {
      let (cards, next) = try await fetchPage(cursor: cursor)
      collected.append(contentsOf: cards)
      cursor = next
    } while cursor != nil
    return collected
  }

  public func saveNoteCards(_ cards: [SyncNoteCard]) async throws {
    guard !cards.isEmpty else { return }

    // 先取已有 record，保留 change tag，降低冲突。
    let recordIDs = cards.map {
      CKRecord.ID(recordName: $0.id.uuidString.lowercased())
    }
    let existing = try await database.records(for: recordIDs)

    var toSave: [CKRecord] = []
    toSave.reserveCapacity(cards.count)
    for card in cards {
      let recordID = CKRecord.ID(recordName: card.id.uuidString.lowercased())
      if let result = existing[recordID], case .success(let record) = result {
        try CloudKitNoteCardSync.apply(card, to: record)
        toSave.append(record)
      } else {
        toSave.append(try CloudKitNoteCardSync.makeRecord(from: card))
      }
    }

    try await saveRecords(toSave)
  }

  private func fetchPage(
    cursor: CKQueryOperation.Cursor?
  ) async throws -> (cards: [SyncNoteCard], next: CKQueryOperation.Cursor?) {
    if let cursor {
      return try await withCheckedThrowingContinuation { continuation in
        let operation = CKQueryOperation(cursor: cursor)
        runQueryOperation(operation, continuation: continuation)
      }
    }

    let query = CKQuery(
      recordType: CloudKitNoteCardSync.recordType,
      predicate: NSPredicate(value: true)
    )
    query.sortDescriptors = [
      NSSortDescriptor(
        key: CloudKitNoteCardSync.Field.updatedAtMilliseconds.rawValue,
        ascending: false
      ),
    ]
    return try await withCheckedThrowingContinuation { continuation in
      let operation = CKQueryOperation(query: query)
      operation.resultsLimit = 100
      runQueryOperation(operation, continuation: continuation)
    }
  }

  private func runQueryOperation(
    _ operation: CKQueryOperation,
    continuation: CheckedContinuation<(cards: [SyncNoteCard], next: CKQueryOperation.Cursor?), Error>
  ) {
    var page: [SyncNoteCard] = []
    var finished = false

    operation.recordMatchedBlock = { _, result in
      switch result {
      case .success(let record):
        if let card = try? CloudKitNoteCardSync.makeCard(from: record) {
          page.append(card)
        }
      case .failure:
        break
      }
    }

    operation.queryResultBlock = { result in
      guard !finished else { return }
      finished = true
      switch result {
      case .success(let nextCursor):
        continuation.resume(returning: (page, nextCursor))
      case .failure(let error):
        if Self.isEmptySchemaError(error) {
          continuation.resume(returning: ([], nil))
        } else {
          continuation.resume(throwing: error)
        }
      }
    }

    database.add(operation)
  }

  private static func isEmptySchemaError(_ error: Error) -> Bool {
    if let ckError = error as? CKError, ckError.code == .unknownItem {
      return true
    }
    let text = error.localizedDescription.lowercased()
    return text.contains("record type") || text.contains("did not find")
  }

  private func saveRecords(_ records: [CKRecord]) async throws {
    for chunk in stride(from: 0, to: records.count, by: 100).map({
      Array(records[$0..<min($0 + 100, records.count)])
    }) {
      try await saveRecordChunk(chunk)
    }
  }

  private func saveRecordChunk(_ records: [CKRecord]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
      operation.savePolicy = .changedKeys
      operation.isAtomic = false
      var finished = false

      operation.modifyRecordsResultBlock = { result in
        guard !finished else { return }
        finished = true
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      database.add(operation)
    }
  }
}
