import Foundation

/// 把笔记卡持久化到本地 JSON。iOS / Mac 投影层共用，避免各写一份。
public actor LocalJSONNoteCardStore: NoteCardStore {
  private let fileURL: URL
  private var cards: [UUID: SyncNoteCard]
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL) async throws {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.decoder = JSONDecoder()
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let data = try Data(contentsOf: fileURL)
      let list = try decoder.decode([SyncNoteCard].self, from: data)
      self.cards = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    } else {
      self.cards = [:]
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
  }

  public static func applicationSupportStore(
    subdirectory: String,
    fileName: String = "note-cards-v1.json"
  ) async throws -> LocalJSONNoteCardStore {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let dir = root.appendingPathComponent(subdirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try await LocalJSONNoteCardStore(fileURL: dir.appendingPathComponent(fileName))
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
    try persist()
  }

  public func softDelete(id: UUID, atMilliseconds: Int64) async throws {
    guard var card = cards[id] else { return }
    card.deletedAtMilliseconds = atMilliseconds
    card.updatedAtMilliseconds = max(card.updatedAtMilliseconds + 1, atMilliseconds)
    cards[id] = card
    try persist()
  }

  private func persist() throws {
    let list = cards.values.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
    let data = try encoder.encode(list)
    try data.write(to: fileURL, options: [.atomic])
  }
}
