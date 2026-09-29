import Foundation

/// 「按意思搜」（2026-09-29）：本机文本向量 + 余弦相似度，给关键词搜索补「意思相近」的结果。
///
/// 这里只放与界面、模型实现都无关的部分：喂给模型的文本怎么取、索引怎么存、怎么排名。
/// 模型本身见 `LinkDigestAdapters.BGETextEmbedder`，调度见 App 的 `SemanticSearchService`。

/// 把一段文字变成归一化向量。
public protocol TextEmbedding: Sendable {
  func embed(_ text: String) -> [Float]
}

public enum SemanticDocumentText {
  /// bge 中文模型官方建议：短查询前加这句检索指令，文档一侧不加。
  /// 2026-09-29 用 300 条真实收藏对比过：加了以后排在前面的无关内容更少。
  public static let queryInstruction = "为这个句子生成表示以用于检索相关文章："

  /// 一条内容参与「按意思搜」的文字：标题 + 正文开头。
  ///
  /// 模型一次最多读 512 个词片，中文约 500 字，所以只取开头。去掉元数据块、图片与链接地址、
  /// 评论区：它们不是这条内容在讲什么，链接里的字母还会把中文内容拉偏。正文太短
  /// （视频只有一句配文）时用总结补上。
  public static func make(title: String?, sourcePreview: String?, artifactPreview: String?, limit: Int = 480) -> String {
    let heading = clean(title ?? "")
    var body = clean(stripMarkup(sourcePreview ?? ""))
    if body.hasPrefix(heading), !heading.isEmpty { body = String(body.dropFirst(heading.count)).trimmingCharacters(in: .whitespaces) }
    if body.count < 60, let artifact = artifactPreview {
      let summary = clean(stripMarkup(artifact))
      if !summary.isEmpty { body = body.isEmpty ? summary : "\(body) \(summary)" }
    }
    let text = heading.isEmpty ? body : (body.isEmpty ? heading : "\(heading)\n\(body)")
    return String(text.prefix(limit))
  }

  private static func stripMarkup(_ markdown: String) -> String {
    var text = MarkdownNoteFrontmatter.parse(markdown).body
    if let comments = text.range(of: #"(?m)^## 评论"#, options: .regularExpression) {
      text = String(text[..<comments.lowerBound])
    }
    for pattern in [#"<!--[\s\S]*?-->"#, #"!\[[^\]]*\]\([^)]*\)"#, #"\]\([^)]*\)"#, #"https?://\S+"#, #"(?m)^#{1,6}\s+"#] {
      text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    return text.replacingOccurrences(of: "[", with: " ")
  }

  private static func clean(_ text: String) -> String {
    text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// 全库的向量：每条内容一个。1,369 条 × 512 维约 2.8MB，整份放内存、整份写盘。
///
/// 单独一个文件，不进主数据库：随时可以删掉重建，换模型也只是换文件，不牵涉迁移。
public struct SemanticIndex: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public let updatedAtMilliseconds: Int64
    public let vector: [Float]
    public init(updatedAtMilliseconds: Int64, vector: [Float]) {
      self.updatedAtMilliseconds = updatedAtMilliseconds
      self.vector = vector
    }
  }

  public enum DecodingError: Error, Equatable { case unsupported, truncated }

  private static let magic = Data("LDSI".utf8)
  private static let version: UInt32 = 1

  public let modelID: String
  public let dimension: Int
  public private(set) var entries: [String: Entry]

  public init(modelID: String, dimension: Int, entries: [String: Entry] = [:]) {
    self.modelID = modelID
    self.dimension = dimension
    self.entries = entries
  }

  public mutating func set(_ taskID: String, _ entry: Entry) {
    precondition(entry.vector.count == dimension)
    entries[taskID] = entry
  }

  public mutating func remove(_ taskID: String) { entries[taskID] = nil }

  /// 相似度从高到低。只留 `minimumScore` 以上、且离第一名不超过 `relativeWindow` 的：
  /// 实测相关内容集中在 0.5–0.7，无关的在 0.45 以下，第一名很低时整组都不可靠。
  public func ranked(query: [Float], limit: Int, minimumScore: Float, relativeWindow: Float) -> [(taskID: String, score: Float)] {
    guard query.count == dimension, limit > 0 else { return [] }
    var scored: [(taskID: String, score: Float)] = []
    scored.reserveCapacity(entries.count)
    for (taskID, entry) in entries {
      var dot: Float = 0
      for index in 0..<dimension { dot += query[index] * entry.vector[index] }
      if dot >= minimumScore { scored.append((taskID, dot)) }
    }
    scored.sort { $0.score == $1.score ? $0.taskID < $1.taskID : $0.score > $1.score }
    guard let top = scored.first?.score else { return [] }
    return Array(scored.prefix { $0.score >= top - relativeWindow }.prefix(limit))
  }

  /// 文件格式：`LDSI` + 版本 + 维度 + 模型名长度与内容 + 条数，然后每条 36 字节 id + 8 字节时间 + 向量。
  public func encoded() -> Data {
    var data = Self.magic
    append(Self.version, to: &data)
    append(UInt32(dimension), to: &data)
    let model = Data(modelID.utf8)
    append(UInt32(model.count), to: &data)
    data.append(model)
    append(UInt32(entries.count), to: &data)
    for (taskID, entry) in entries.sorted(by: { $0.key < $1.key }) {
      var id = Data(taskID.utf8)
      id.append(contentsOf: [UInt8](repeating: 0, count: max(0, 36 - id.count)))
      data.append(id.prefix(36))
      append(UInt64(bitPattern: entry.updatedAtMilliseconds), to: &data)
      entry.vector.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    }
    return data
  }

  public init(data: Data) throws {
    var reader = Reader(data: data)
    guard try reader.bytes(4) == Self.magic, try reader.uint32() == Self.version else { throw DecodingError.unsupported }
    let dimension = Int(try reader.uint32())
    let modelLength = Int(try reader.uint32())
    guard let modelID = String(data: try reader.bytes(modelLength), encoding: .utf8) else { throw DecodingError.unsupported }
    let count = Int(try reader.uint32())
    var entries: [String: Entry] = [:]
    entries.reserveCapacity(count)
    for _ in 0..<count {
      let rawID = try reader.bytes(36)
      guard let taskID = String(data: rawID.prefix { $0 != 0 }, encoding: .utf8) else { throw DecodingError.unsupported }
      let updated = Int64(bitPattern: try reader.uint64())
      let vectorBytes = try reader.bytes(dimension * 4)
      var vector = [Float](repeating: 0, count: dimension)
      _ = vector.withUnsafeMutableBytes { vectorBytes.copyBytes(to: $0) }
      entries[taskID] = Entry(updatedAtMilliseconds: updated, vector: vector)
    }
    self.init(modelID: modelID, dimension: dimension, entries: entries)
  }

  private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private struct Reader {
    let data: Data
    var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
      guard count >= 0, offset + count <= data.count else { throw DecodingError.truncated }
      defer { offset += count }
      return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }
    mutating func uint32() throws -> UInt32 {
      try bytes(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
    mutating func uint64() throws -> UInt64 {
      try bytes(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
  }
}
