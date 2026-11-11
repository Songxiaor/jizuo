import Foundation

/// 一条记录的存疑清单。
public struct TranscriptDoubtEntry: Codable, Equatable, Sendable {
  public var doubts: [TranscriptDoubt]
  /// 这次校对改了几处；稿子太长没算时为 nil。
  public var changeCount: Int?
  public var updatedAtMilliseconds: Int64

  public init(doubts: [TranscriptDoubt], changeCount: Int?, updatedAtMilliseconds: Int64) {
    self.doubts = doubts
    self.changeCount = changeCount
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }

  public var pending: [TranscriptDoubt] { doubts.filter { $0.status == .pending } }
}

struct TranscriptDoubtsDocument: Codable, Equatable {
  var version = 1
  var tasks: [String: TranscriptDoubtEntry] = [:]
}

/// 校对时拿不准的地方。存在数据目录里的 JSON（`transcript-doubts.json`），不动数据库结构：
/// 数据库里只有两份稿子（机器原稿和校对稿），存疑清单是校对稿上的待办，丢了也只是
/// 少一份提示，稿子本身不受影响。读不懂的文件改名留底，与常用标签表同一做法。
public final class TranscriptDoubtStore: @unchecked Sendable {
  public static let fileName = "transcript-doubts.json"
  public static let maximumTasks = 500

  private let fileURL: URL
  private let lock = NSLock()
  private let now: @Sendable () -> Int64
  private var corruptName: String?
  /// 内存缓存：第一次读盘后常驻，写入时一并更新，界面重绘不再每次读文件。
  private var cache: TranscriptDoubtsDocument?

  public init(
    directoryURL: URL,
    now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
  ) {
    self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
    self.now = now
  }

  public var corruptBackupName: String? {
    lock.lock(); defer { lock.unlock() }
    return corruptName
  }

  public func entry(taskID: String) -> TranscriptDoubtEntry? {
    lock.lock(); defer { lock.unlock() }
    return loadLocked().tasks[taskID]
  }

  public var taskIDs: Set<String> {
    lock.lock(); defer { lock.unlock() }
    return Set(loadLocked().tasks.keys)
  }

  /// 一次新校对：整条替换（旧的存疑项属于上一份校对稿，已经没意义）。
  /// 没有存疑项也没有改动数时直接清掉这条。
  ///
  /// 超过 `maximumTasks` 条时按这个顺序淘汰：先删已经不存在的记录，再删没有待处理项的，
  /// 最后才按时间删最旧的；刚写入的这条永远不淘汰。`existingTaskIDs` 只在超限时才会被调用，
  /// 返回 nil（查不到）就跳过第一档。
  public func replace(
    taskID: String, doubts: [TranscriptDoubt], changeCount: Int?,
    existingTaskIDs: () -> Set<String>? = { nil }
  ) {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    if doubts.isEmpty && changeCount == nil {
      doc.tasks[taskID] = nil
    } else {
      doc.tasks[taskID] = .init(doubts: doubts, changeCount: changeCount, updatedAtMilliseconds: now())
    }
    if doc.tasks.count > Self.maximumTasks {
      Self.evict(&doc, keeping: taskID, existing: existingTaskIDs())
    }
    try? saveLocked(doc)
  }

  static func evict(_ doc: inout TranscriptDoubtsDocument, keeping protected: String, existing: Set<String>?) {
    func overflow() -> Int { doc.tasks.count - maximumTasks }
    func drop(_ candidates: [(key: String, value: TranscriptDoubtEntry)]) {
      let ordered = candidates.filter { $0.key != protected }
        .sorted { $0.value.updatedAtMilliseconds < $1.value.updatedAtMilliseconds }
      for (key, _) in ordered.prefix(max(overflow(), 0)) { doc.tasks[key] = nil }
    }
    if let existing { drop(doc.tasks.filter { !existing.contains($0.key) }.map { ($0.key, $0.value) }) }
    if overflow() > 0 { drop(doc.tasks.filter { $0.value.pending.isEmpty }.map { ($0.key, $0.value) }) }
    if overflow() > 0 { drop(doc.tasks.map { ($0.key, $0.value) }) }
  }

  public func setStatus(taskID: String, doubtID: String, status: TranscriptDoubt.Status) {
    setStatus(taskID: taskID, doubtIDs: [doubtID], status: status)
  }

  public func setStatus(taskID: String, doubtIDs: [String], status: TranscriptDoubt.Status) {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    guard var entry = doc.tasks[taskID] else { return }
    let ids = Set(doubtIDs)
    for index in entry.doubts.indices where ids.contains(entry.doubts[index].id) {
      entry.doubts[index].status = status
    }
    entry.updatedAtMilliseconds = now()
    doc.tasks[taskID] = entry
    try? saveLocked(doc)
  }

  public func remove(taskID: String) {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    guard doc.tasks[taskID] != nil else { return }
    doc.tasks[taskID] = nil
    try? saveLocked(doc)
  }

  /// 只留下 `existing` 里还在的记录。删除资料、清空回收站之后用，免得文件里留着已删记录的原文片段。
  @discardableResult
  public func prune(keeping existing: Set<String>) -> Int {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    let stale = doc.tasks.keys.filter { !existing.contains($0) }
    guard !stale.isEmpty else { return 0 }
    for key in stale { doc.tasks[key] = nil }
    try? saveLocked(doc)
    return stale.count
  }

  private func loadLocked() -> TranscriptDoubtsDocument {
    if let cache { return cache }
    guard let data = try? Data(contentsOf: fileURL) else {
      cache = TranscriptDoubtsDocument()
      return TranscriptDoubtsDocument()
    }
    if let doc = try? JSONDecoder().decode(TranscriptDoubtsDocument.self, from: data) {
      cache = doc
      return doc
    }
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(Self.fileName).corrupt-\(now())")
    if (try? FileManager.default.moveItem(at: fileURL, to: backupURL)) != nil {
      corruptName = backupURL.lastPathComponent
    }
    cache = TranscriptDoubtsDocument()
    return TranscriptDoubtsDocument()
  }

  /// 写盘成功才更新缓存；写失败时缓存仍是磁盘上的样子，界面不会显示一份没存住的状态。
  private func saveLocked(_ doc: TranscriptDoubtsDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try encoder.encode(doc).write(to: fileURL, options: .atomic)
    cache = doc
  }
}

extension TranscriptDoubtStore {
  /// 按库里还在的记录清理：查不到库（出错）时什么都不删，免得把有用的清单误清掉。
  @discardableResult
  public func prune(using history: HistoryApplicationService) -> Int? {
    let known = taskIDs
    guard !known.isEmpty, let existing = try? history.existingTaskIDs(in: known) else { return nil }
    return prune(keeping: existing)
  }
}

/// 名字表相关的提示文案。
public enum KnownNameMessage {
  public static let writeFailed = "没能保存名字表（可能是磁盘已满或没有写入权限），请稍后再试。"
  public static let full = "名字表已满（\(KnownNamePolicy.maximumNames) 个），请先删掉不用的。"
  public static let invalid = "名字不能为空，也不能超过 \(KnownNamePolicy.maximumCharacters) 个字。"
  public static let alreadyListed = "已经在名字表里了。"

  public static func message(for result: KnownNameStore.AddResult) -> String? {
    switch result {
    case .added: nil
    case .alreadyListed: alreadyListed
    case .invalid: invalid
    case .full: full
    case .writeFailed: writeFailed
    }
  }
}
