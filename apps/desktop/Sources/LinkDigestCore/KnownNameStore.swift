import Foundation

/// 常用名字表里的一条：说话人、人名或专有名词的正确写法。
public struct KnownName: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable {
    case speakerRename
    case adoptedDoubt
    case manual
  }

  public var text: String
  public var source: Source
  public var addedAtMilliseconds: Int64

  public init(text: String, source: Source, addedAtMilliseconds: Int64) {
    self.text = text
    self.source = source
    self.addedAtMilliseconds = addedAtMilliseconds
  }
}

public struct KnownNamesDocument: Codable, Equatable, Sendable {
  public var version = 1
  public var names: [KnownName] = []
  public init() {}
}

public enum KnownNamePolicy {
  public static let maximumNames = 200
  public static let maximumCharacters = 30

  /// 去空白；过长、含换行、空的不要。
  public static func cleaned(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumCharacters,
          !trimmed.contains(where: \.isNewline) else { return nil }
    return trimmed
  }

  /// 查重用：NFKC、忽略大小写和空白。
  public static func identity(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
  }
}

/// 常用名字表：数据目录里的一个小 JSON，最多 200 条。
/// 文件不存在或读不懂都当空表；读不懂时改名留底，避免下一次保存把它覆盖掉
/// （与 `FrequentTagStore` 同一做法）。
public final class KnownNameStore: @unchecked Sendable {
  public static let fileName = "known-names.json"

  public enum AddResult: Equatable, Sendable {
    case added
    case alreadyListed
    case invalid
    case full
    /// 名字合规、表也没满，但写盘失败（磁盘满、目录不可写）。
    case writeFailed
  }

  private let fileURL: URL
  private let lock = NSLock()
  private let now: @Sendable () -> Int64
  private var corruptName: String?
  /// 内存缓存：第一次读盘后常驻，写入成功时更新。
  private var cache: KnownNamesDocument?

  public init(
    directoryURL: URL,
    now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
  ) {
    self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
    self.now = now
  }

  public func load() -> KnownNamesDocument {
    lock.lock(); defer { lock.unlock() }
    return loadLocked()
  }

  /// 给校对提示词用：只有名字和词，没有来源、时间。
  public var names: [String] { load().names.map(\.text) }

  public func contains(_ raw: String) -> Bool {
    guard let name = KnownNamePolicy.cleaned(raw) else { return false }
    let key = KnownNamePolicy.identity(name)
    return load().names.contains { KnownNamePolicy.identity($0.text) == key }
  }

  /// 上一次读到损坏文件时被改名留底的文件名，界面据此提示一句。
  public var corruptBackupName: String? {
    lock.lock(); defer { lock.unlock() }
    return corruptName
  }

  public func acknowledgeCorruptNotice() {
    lock.lock(); defer { lock.unlock() }
    corruptName = nil
  }

  @discardableResult
  public func add(_ raw: String, source: KnownName.Source) -> AddResult {
    guard let name = KnownNamePolicy.cleaned(raw) else { return .invalid }
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    let key = KnownNamePolicy.identity(name)
    if doc.names.contains(where: { KnownNamePolicy.identity($0.text) == key }) { return .alreadyListed }
    guard doc.names.count < KnownNamePolicy.maximumNames else { return .full }
    doc.names.append(.init(text: name, source: source, addedAtMilliseconds: now()))
    return (try? saveLocked(doc)) == nil ? .writeFailed : .added
  }

  @discardableResult
  public func remove(_ raw: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    let key = KnownNamePolicy.identity(raw)
    let before = doc.names.count
    doc.names.removeAll { KnownNamePolicy.identity($0.text) == key }
    guard doc.names.count != before else { return false }
    return (try? saveLocked(doc)) != nil
  }

  private func loadLocked() -> KnownNamesDocument {
    if let cache { return cache }
    guard let data = try? Data(contentsOf: fileURL) else {
      cache = KnownNamesDocument()
      return KnownNamesDocument()
    }
    if var doc = try? JSONDecoder().decode(KnownNamesDocument.self, from: data) {
      // 手改过超限的文件：只认前 200 条。
      if doc.names.count > KnownNamePolicy.maximumNames { doc.names = Array(doc.names.prefix(KnownNamePolicy.maximumNames)) }
      cache = doc
      return doc
    }
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(Self.fileName).corrupt-\(now())")
    if (try? FileManager.default.moveItem(at: fileURL, to: backupURL)) != nil {
      corruptName = backupURL.lastPathComponent
    }
    cache = KnownNamesDocument()
    return KnownNamesDocument()
  }

  /// 写盘成功才更新缓存。
  private func saveLocked(_ doc: KnownNamesDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try encoder.encode(doc).write(to: fileURL, options: .atomic)
    cache = doc
  }
}
