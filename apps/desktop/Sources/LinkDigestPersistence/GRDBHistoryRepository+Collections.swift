import Foundation
import GRDB
import LinkDigestCore

// MARK: - 合集（Migration024）

/// 合集的读写。表结构和删除语义见 `Migration024`。
///
/// 「看得见的条目」统一是：没进回收站、不是稿件。计数、按合集取条目、列表
/// （`historyPage` 带 `collectionID`）三处口径一致——侧栏写着 12 条，点进去就是 12 条。
extension GRDBHistoryRepository: CollectionStoring {
  /// 合集里算数的内容。`t` 是 tasks 的别名。
  static let visibleCollectionTaskSQL = "t.deleted_at_ms IS NULL AND t.content_kind <> '\(TaskClassificationSQL.draftKind)'"

  private static let collectionSummarySelect = """
    SELECT c.id, c.name, c.origin, c.folder_path, c.created_at_ms, c.updated_at_ms,
      (
        SELECT COUNT(*) FROM collection_items ci
        INNER JOIN tasks t ON t.id = ci.task_id
        WHERE ci.collection_id = c.id AND \(visibleCollectionTaskSQL)
      ) AS item_count
    FROM collections c
    """

  private static func collectionNow() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
  }

  public func createCollection(name: String) throws -> HistoryCollectionSummary {
    guard let normalized = HistoryCollectionNaming.normalized(name) else { throw RepositoryFailure.invalidInput }
    let id = CollectionID(UUID())
    let now = Self.collectionNow()
    return try database.write { db in
      let createdAt = try Self.nextCreatedAt(db, now: now)
      try db.execute(
        sql: """
          INSERT INTO collections (id, name, origin, folder_path, created_at_ms, updated_at_ms)
          VALUES (?, ?, '\(HistoryCollectionOrigin.manual.rawValue)', NULL, ?, ?)
          """,
        arguments: [id.rawValue, normalized, createdAt, createdAt]
      )
      guard let summary = try Self.collectionSummary(db, id: id) else { throw RepositoryFailure.unavailable }
      return summary
    }
  }

  public func renameCollection(id: CollectionID, to name: String) throws -> HistoryCollectionSummary {
    guard let normalized = HistoryCollectionNaming.normalized(name) else { throw RepositoryFailure.invalidInput }
    let now = Self.collectionNow()
    return try database.write { db in
      try db.execute(
        sql: "UPDATE collections SET name = ?, updated_at_ms = ? WHERE id = ?",
        arguments: [normalized, now, id.rawValue]
      )
      guard db.changesCount == 1, let summary = try Self.collectionSummary(db, id: id) else {
        throw RepositoryFailure.notFound
      }
      return summary
    }
  }

  public func deleteCollection(id: CollectionID) throws {
    try database.write { db in
      // 条目关系随 ON DELETE CASCADE 一起走；tasks 一行不碰。
      try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id.rawValue])
      guard db.changesCount == 1 else { throw RepositoryFailure.notFound }
    }
  }

  public func collections() throws -> [HistoryCollectionSummary] {
    try database.read { db in
      try Row.fetchAll(db, sql: "\(Self.collectionSummarySelect) ORDER BY c.created_at_ms, c.id")
        .compactMap(Self.collectionSummary)
    }
  }

  public func collection(id: CollectionID) throws -> HistoryCollectionSummary? {
    try database.read { db in try Self.collectionSummary(db, id: id) }
  }

  @discardableResult
  public func addTasks(_ taskIDs: [TaskID], toCollection id: CollectionID) throws -> Int {
    guard !taskIDs.isEmpty else { return 0 }
    let now = Self.collectionNow()
    return try database.write { db in
      guard try Self.collectionExists(db, id: id) else { throw RepositoryFailure.notFound }
      let added = try Self.appendTasks(db, taskIDs, to: id, at: now)
      if added > 0 { try Self.touchCollection(db, id: id, at: now) }
      return added
    }
  }

  @discardableResult
  public func removeTasks(_ taskIDs: [TaskID], fromCollection id: CollectionID) throws -> Int {
    guard !taskIDs.isEmpty else { return 0 }
    let now = Self.collectionNow()
    return try database.write { db in
      guard try Self.collectionExists(db, id: id) else { throw RepositoryFailure.notFound }
      var removed = 0
      for taskID in Set(taskIDs) {
        try db.execute(
          sql: "DELETE FROM collection_items WHERE collection_id = ? AND task_id = ?",
          arguments: [id.rawValue, taskID.rawValue]
        )
        removed += db.changesCount
      }
      if removed > 0 { try Self.touchCollection(db, id: id, at: now) }
      return removed
    }
  }

  public func moveTasks(_ taskIDs: [TaskID], inCollection id: CollectionID, after anchor: TaskID?) throws {
    let now = Self.collectionNow()
    try database.write { db in
      guard try Self.collectionExists(db, id: id) else { throw RepositoryFailure.notFound }
      // 回收站里的也要一起排：它们恢复后回到原位，重排时不能被挤到最后。
      let current = try Row.fetchAll(
        db,
        sql: "SELECT task_id, position FROM collection_items WHERE collection_id = ? ORDER BY position, task_id",
        arguments: [id.rawValue]
      ).map { (taskID: $0["task_id"] as String, position: $0["position"] as Int64) }
      let members = Set(current.map(\.taskID))
      var seen = Set<String>()
      let moving = taskIDs.map(\.rawValue).filter { members.contains($0) && seen.insert($0).inserted }
      guard !moving.isEmpty else { return }
      let movingSet = Set(moving)
      if let anchor, movingSet.contains(anchor.rawValue) { throw RepositoryFailure.invalidInput }
      var order = current.map(\.taskID).filter { !movingSet.contains($0) }
      let insertionIndex: Int
      if let anchor {
        guard let index = order.firstIndex(of: anchor.rawValue) else { throw RepositoryFailure.notFound }
        insertionIndex = index + 1
      } else {
        insertionIndex = 0
      }
      order.insert(contentsOf: moving, at: insertionIndex)
      // 位置整段重写成 0…n-1，只动真变了的行。
      let previous = Dictionary(uniqueKeysWithValues: current.map { ($0.taskID, $0.position) })
      var changed = false
      for (index, taskID) in order.enumerated() where previous[taskID] != Int64(index) {
        try db.execute(
          sql: "UPDATE collection_items SET position = ? WHERE collection_id = ? AND task_id = ?",
          arguments: [Int64(index), id.rawValue, taskID]
        )
        changed = true
      }
      if changed { try Self.touchCollection(db, id: id, at: now) }
    }
  }

  public func collectionItems(id: CollectionID) throws -> [HistoryCollectionItem] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ci.task_id, ci.position, ci.added_at_ms
          FROM collection_items ci
          INNER JOIN tasks t ON t.id = ci.task_id
          WHERE ci.collection_id = ? AND \(Self.visibleCollectionTaskSQL)
          ORDER BY ci.position, ci.task_id
          """,
        arguments: [id.rawValue]
      ).compactMap { row in
        guard let taskID = TaskID(row["task_id"] as String) else { return nil }
        return HistoryCollectionItem(taskID: taskID, position: row["position"], addedAtMilliseconds: row["added_at_ms"])
      }
    }
  }

  public func collections(containing taskID: TaskID) throws -> [HistoryCollectionSummary] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          \(Self.collectionSummarySelect)
          WHERE c.id IN (SELECT collection_id FROM collection_items WHERE task_id = ?)
          ORDER BY c.created_at_ms, c.id
          """,
        arguments: [taskID.rawValue]
      ).compactMap(Self.collectionSummary)
    }
  }

  @discardableResult
  public func createOrUpdateImportedFolderCollection(
    name: String,
    folderPath: String,
    orderedTaskIDs: [TaskID]
  ) throws -> HistoryCollectionSummary? {
    let path = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw RepositoryFailure.invalidInput }
    // 文件夹名全是空白这种极端情况，退回用路径最后一段。
    guard let normalizedName = HistoryCollectionNaming.normalized(name)
      ?? HistoryCollectionNaming.normalized(URL(fileURLWithPath: path).lastPathComponent)
    else { throw RepositoryFailure.invalidInput }
    let now = Self.collectionNow()
    return try database.write { db in
      if let raw = try String.fetchOne(
        db,
        sql: "SELECT id FROM collections WHERE folder_path = ?",
        arguments: [path]
      ), let existing = CollectionID(raw) {
        // 同一个文件夹再导入一次：已有顺序不动，新的追加在后面；名字不改（用户可能改过）。
        let added = try Self.appendTasks(db, orderedTaskIDs, to: existing, at: now)
        if added > 0 { try Self.touchCollection(db, id: existing, at: now) }
        return try Self.collectionSummary(db, id: existing)
      }
      // 一条有效内容都没有（全部导入失败）时不建空合集——那只是侧栏里多一行噪音。
      let hasValidTask = try orderedTaskIDs.contains { taskID in
        try Self.taskCanJoinCollection(db, taskID: taskID)
      }
      guard hasValidTask else { return nil }
      let id = CollectionID(UUID())
      let createdAt = try Self.nextCreatedAt(db, now: now)
      try db.execute(
        sql: """
          INSERT INTO collections (id, name, origin, folder_path, created_at_ms, updated_at_ms)
          VALUES (?, ?, '\(HistoryCollectionOrigin.importedFolder.rawValue)', ?, ?, ?)
          """,
        arguments: [id.rawValue, normalizedName, path, createdAt, createdAt]
      )
      _ = try Self.appendTasks(db, orderedTaskIDs, to: id, at: now)
      return try Self.collectionSummary(db, id: id)
    }
  }

  // MARK: 内部

  /// 侧栏按创建先后排。同一毫秒里连建两个（导入一批文件夹时会发生）时，排序会退回到
  /// 随机的 id 上，所以创建时间保证严格递增。
  private static func nextCreatedAt(_ db: Database, now: Int64) throws -> Int64 {
    let latest = try Int64.fetchOne(db, sql: "SELECT MAX(created_at_ms) FROM collections") ?? Int64.min
    return latest >= now ? latest + 1 : now
  }

  private static func collectionExists(_ db: Database, id: CollectionID) throws -> Bool {
    try Int.fetchOne(db, sql: "SELECT 1 FROM collections WHERE id = ?", arguments: [id.rawValue]) == 1
  }

  /// 稿件是「过程」，不进任何浏览列表，也不进合集。
  private static func taskCanJoinCollection(_ db: Database, taskID: TaskID) throws -> Bool {
    try Int.fetchOne(
      db,
      sql: "SELECT 1 FROM tasks WHERE id = ? AND content_kind <> '\(TaskClassificationSQL.draftKind)'",
      arguments: [taskID.rawValue]
    ) == 1
  }

  /// 按传入顺序追加到末尾。已在合集里的、不存在的、稿件都跳过。返回新加的条数。
  private static func appendTasks(_ db: Database, _ taskIDs: [TaskID], to id: CollectionID, at now: Int64) throws -> Int {
    var next = try Int64.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM collection_items WHERE collection_id = ?",
      arguments: [id.rawValue]
    ) ?? 0
    var seen = Set<TaskID>()
    var added = 0
    for taskID in taskIDs where seen.insert(taskID).inserted {
      guard try taskCanJoinCollection(db, taskID: taskID) else { continue }
      // 外键约束不吃 OR IGNORE，存在性已在上一行确认；这里只挡「已经在合集里」。
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO collection_items (collection_id, task_id, position, added_at_ms)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [id.rawValue, taskID.rawValue, next, now]
      )
      if db.changesCount == 1 {
        next += 1
        added += 1
      }
    }
    return added
  }

  private static func touchCollection(_ db: Database, id: CollectionID, at now: Int64) throws {
    try db.execute(sql: "UPDATE collections SET updated_at_ms = ? WHERE id = ?", arguments: [now, id.rawValue])
  }

  private static func collectionSummary(_ db: Database, id: CollectionID) throws -> HistoryCollectionSummary? {
    try Row.fetchOne(db, sql: "\(collectionSummarySelect) WHERE c.id = ?", arguments: [id.rawValue])
      .flatMap(collectionSummary)
  }

  private static func collectionSummary(_ row: Row) -> HistoryCollectionSummary? {
    guard let id = CollectionID(row["id"] as String),
          let origin = HistoryCollectionOrigin(rawValue: row["origin"] as String)
    else { return nil }
    return HistoryCollectionSummary(
      id: id,
      name: row["name"],
      origin: origin,
      folderPath: row["folder_path"],
      itemCount: row["item_count"],
      createdAtMilliseconds: row["created_at_ms"],
      updatedAtMilliseconds: row["updated_at_ms"]
    )
  }
}
