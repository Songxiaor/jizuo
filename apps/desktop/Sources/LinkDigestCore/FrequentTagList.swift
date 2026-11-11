import Foundation

/// 「常用标签表」（2026-11 第二批）：用户自己维护的一份固定词表，存在数据目录的小 JSON 里。
///
/// 为什么不再靠「最常用 100 个 + 每篇最多新建 1 个」：那条约束拦得住一篇里的泛滥，拦不住
/// 长期积累——375 个标签里 335 个只用过一次。表非空时，新内容的标签**只能**从表里选；
/// 模型想用的表外标签不写到资料上，记进「建议加入」，由用户在标签管理里采纳或忽略。
///
/// 表为空时一切照旧（`HistoryTagVocabulary` 原有逻辑），所以这份文件不存在就等于没有这个功能。
public struct FrequentTagsDocument: Codable, Equatable, Sendable {
  public struct Suggestion: Codable, Equatable, Sendable {
    public var name: String
    /// 被模型提议过几次，越多越值得采纳。
    public var count: Int
    public var lastSeenAtMilliseconds: Int64

    public init(name: String, count: Int, lastSeenAtMilliseconds: Int64) {
      self.name = name
      self.count = count
      self.lastSeenAtMilliseconds = lastSeenAtMilliseconds
    }
  }

  public var version: Int
  /// 常用标签的显示名，顺序即用户看到的顺序。
  public var tags: [String]
  public var suggestions: [Suggestion]
  /// 用户点过「忽略」的标签（规范化名），不再出现在建议里。
  public var dismissed: [String]

  public init(version: Int = 1, tags: [String] = [], suggestions: [Suggestion] = [], dismissed: [String] = []) {
    self.version = version
    self.tags = tags
    self.suggestions = suggestions
    self.dismissed = dismissed
  }
}

public enum FrequentTagPolicy {
  /// 常用标签表里最多放这么多个；再多就失去「收拢」的意义，提示词也会变长。
  public static let maximumTags = 120
  /// 候选最多留这么多条，超出丢最旧的。
  public static let maximumSuggestions = 200

  /// 保留标签：素材类型、系统标记、「真人口播」。它们的写入路径不受常用标签表约束，
  /// 也永远不进建议、不进整理方案。
  public static func isReserved(normalizedName: String) -> Bool {
    MaterialCatalog.reservedTagNormalizedNames.contains(normalizedName)
  }

  /// 模型来源的标签一律过这道：去掉系统标记和「真人口播」（不论常用表空不空）。
  public static func strippingModelForbidden(_ tags: [HistoryTag]) -> [HistoryTag] {
    tags.filter { !MaterialCatalog.modelForbiddenTagNormalizedNames.contains($0.normalizedName) }
  }

  public static func strippingModelForbidden(names: [String]) -> [String] {
    names.filter {
      guard let key = HistoryTagNormalizer.normalized($0)?.normalizedName else { return true }
      return !MaterialCatalog.modelForbiddenTagNormalizedNames.contains(key)
    }
  }

  /// 表非空时的过滤：留在表里的（用表里的写法），保留标签原样放行，其余进 `rejected`。
  /// 表为空时全部放行——和没有这个功能时完全一样。
  public static func filter(
    _ tags: [HistoryTag],
    allowed: [String]
  ) -> (accepted: [HistoryTag], rejected: [HistoryTag]) {
    guard !allowed.isEmpty else { return (tags, []) }
    var known: [String: HistoryTag] = [:]
    for name in allowed {
      if let tag = HistoryTag(rawValue: name), known[tag.normalizedName] == nil {
        known[tag.normalizedName] = tag
      }
    }
    var accepted: [HistoryTag] = []
    var rejected: [HistoryTag] = []
    var seen = Set<String>()
    for tag in tags {
      if let listed = known[tag.normalizedName] {
        if seen.insert(listed.normalizedName).inserted { accepted.append(listed) }
      } else if isReserved(normalizedName: tag.normalizedName) {
        if seen.insert(tag.normalizedName).inserted { accepted.append(tag) }
      } else {
        rejected.append(tag)
      }
    }
    return (accepted, rejected)
  }

  /// 表非空时拼进提示词的那一句：只许从表里选，不许新建。
  public static func restrictedInstruction(allowed: [String]) -> String {
    guard !allowed.isEmpty else { return "" }
    return "Choose tags ONLY from this fixed list, copied exactly as written: \(allowed.joined(separator: ", ")). Do not invent new tags; if nothing fits, output fewer tags."
  }
}

/// 常用标签表的文件读写。线程安全；文件不存在或损坏一律当空表（失败方向是「回到原来的行为」）。
public final class FrequentTagStore: @unchecked Sendable {
  public static let fileName = "frequent-tags.json"

  private let fileURL: URL
  private let lock = NSLock()
  private let now: @Sendable () -> Int64

  public init(
    directoryURL: URL,
    now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
  ) {
    self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
    self.now = now
  }

  public func load() -> FrequentTagsDocument {
    lock.lock(); defer { lock.unlock() }
    return loadLocked()
  }

  /// 供新内容打标签用的白名单；空数组 = 功能未启用。
  public var allowedNames: [String] { load().tags }

  /// 上一次读到损坏文件时，被改名留底的文件名（如 `frequent-tags.json.corrupt-1731300000000`）。
  /// 界面据此提示一句；用户看过后可清掉。
  public private(set) var corruptBackupName: String?

  public func acknowledgeCorruptNotice() {
    lock.lock(); defer { lock.unlock() }
    corruptBackupName = nil
  }

  /// 文件不存在 → 空表。文件存在但读不懂 → 降级为空表（行为回到「没有这个功能」），
  /// 同时把坏文件改名留底，避免下一次保存把它直接覆盖掉。
  private func loadLocked() -> FrequentTagsDocument {
    guard let data = try? Data(contentsOf: fileURL) else { return FrequentTagsDocument() }
    if let doc = try? JSONDecoder().decode(FrequentTagsDocument.self, from: data) { return doc }
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(Self.fileName).corrupt-\(now())")
    if (try? FileManager.default.moveItem(at: fileURL, to: backupURL)) != nil {
      corruptBackupName = backupURL.lastPathComponent
    }
    return FrequentTagsDocument()
  }

  private func saveLocked(_ doc: FrequentTagsDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(doc)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }

  @discardableResult
  private func mutate(_ body: (inout FrequentTagsDocument) -> Void) throws -> FrequentTagsDocument {
    lock.lock(); defer { lock.unlock() }
    var doc = loadLocked()
    body(&doc)
    try saveLocked(doc)
    return doc
  }

  /// 整表替换（「AI 整理标签」确认后、或用户编辑后）。保留标签、重名、超长的丢掉。
  @discardableResult
  public func replaceTags(_ names: [String]) throws -> FrequentTagsDocument {
    try mutate { doc in
      doc.tags = Self.cleaned(names)
      let listed = Set(doc.tags.compactMap { HistoryTag(rawValue: $0)?.normalizedName })
      doc.suggestions.removeAll { s in
        HistoryTag(rawValue: s.name).map { listed.contains($0.normalizedName) } ?? true
      }
    }
  }

  @discardableResult
  public func addTag(_ rawName: String) throws -> FrequentTagsDocument {
    try mutate { doc in
      doc.tags = Self.cleaned(doc.tags + [rawName])
      Self.dropSuggestion(rawName, from: &doc)
    }
  }

  @discardableResult
  public func removeTag(normalizedName: String) throws -> FrequentTagsDocument {
    try mutate { doc in
      doc.tags.removeAll { HistoryTag(rawValue: $0)?.normalizedName == normalizedName }
    }
  }

  /// 把模型提议的表外标签记进候选。保留标签、已在表里的、用户忽略过的不记。
  public func recordSuggestions(_ tags: [HistoryTag]) {
    guard !tags.isEmpty else { return }
    let stamp = now()
    _ = try? mutate { doc in
      let listed = Set(doc.tags.compactMap { HistoryTag(rawValue: $0)?.normalizedName })
      let dismissed = Set(doc.dismissed)
      for tag in tags {
        let key = tag.normalizedName
        guard !FrequentTagPolicy.isReserved(normalizedName: key), !listed.contains(key), !dismissed.contains(key) else { continue }
        if let index = doc.suggestions.firstIndex(where: { HistoryTag(rawValue: $0.name)?.normalizedName == key }) {
          doc.suggestions[index].count += 1
          doc.suggestions[index].lastSeenAtMilliseconds = stamp
        } else {
          doc.suggestions.append(.init(name: tag.name, count: 1, lastSeenAtMilliseconds: stamp))
        }
      }
      if doc.suggestions.count > FrequentTagPolicy.maximumSuggestions {
        doc.suggestions.sort { $0.lastSeenAtMilliseconds > $1.lastSeenAtMilliseconds }
        doc.suggestions = Array(doc.suggestions.prefix(FrequentTagPolicy.maximumSuggestions))
      }
    }
  }

  /// 采纳：进表，并从候选里拿掉。
  @discardableResult
  public func acceptSuggestion(normalizedName: String) throws -> FrequentTagsDocument {
    try mutate { doc in
      guard let index = doc.suggestions.firstIndex(where: { HistoryTag(rawValue: $0.name)?.normalizedName == normalizedName }) else { return }
      let name = doc.suggestions[index].name
      doc.tags = Self.cleaned(doc.tags + [name])
      doc.suggestions.remove(at: index)
    }
  }

  /// 忽略：从候选里拿掉，之后不再提议。
  @discardableResult
  public func dismissSuggestion(normalizedName: String) throws -> FrequentTagsDocument {
    try mutate { doc in
      doc.suggestions.removeAll { HistoryTag(rawValue: $0.name)?.normalizedName == normalizedName }
      if !doc.dismissed.contains(normalizedName) { doc.dismissed.append(normalizedName) }
    }
  }

  private static func dropSuggestion(_ rawName: String, from doc: inout FrequentTagsDocument) {
    guard let key = HistoryTag(rawValue: rawName)?.normalizedName else { return }
    doc.suggestions.removeAll { HistoryTag(rawValue: $0.name)?.normalizedName == key }
  }

  /// 规范化、去重、去保留标签、截到上限。
  static func cleaned(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in names {
      guard let tag = HistoryTag(rawValue: raw),
            !FrequentTagPolicy.isReserved(normalizedName: tag.normalizedName),
            seen.insert(tag.normalizedName).inserted else { continue }
      result.append(tag.name)
      if result.count >= FrequentTagPolicy.maximumTags { break }
    }
    return result
  }
}
