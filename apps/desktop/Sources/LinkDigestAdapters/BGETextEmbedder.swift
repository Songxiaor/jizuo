import Accelerate
import Foundation

/// 本机「按意思搜」的文本向量模型：BAAI/bge-small-zh-v1.5（MIT，4 层 BERT，512 维）。
///
/// 为什么自己在 Swift 里跑，而不是转成 Core ML（2026-09-29）：模型只有 2400 万参数，
/// Accelerate 的矩阵乘法一条 500 字的文本几十毫秒；转换要装 torch/coremltools，
/// 运行时也不需要任何新依赖。系统自带的 NLEmbedding / NLContextualEmbedding 实测
/// 在中文检索上分不开相关与无关内容，不能直接用。
///
/// 与官方实现对齐的部分（改动前先跑 `BGETextEmbedderTests` 里的参考向量）：
/// - 分词：BertNormalizer（clean_text、中文逐字、不转小写、不去重音）+ BertPreTokenizer + WordPiece。
/// - 取 [CLS] 位置的最后一层输出，再做 L2 归一化。
public final class BGETextEmbedder: @unchecked Sendable {
  public static let dimension = 512
  /// 含 [CLS] 与 [SEP]。
  public static let maximumTokens = 512

  public enum LoadError: Error, Equatable {
    case missingFile(String)
    case malformedWeights(String)
    case malformedVocabulary
  }

  private let tokenizer: BGEWordPieceTokenizer
  private let weights: Weights

  public init(directory: URL) throws {
    let vocabURL = directory.appendingPathComponent("vocab.txt")
    let weightsURL = directory.appendingPathComponent("model.safetensors")
    guard FileManager.default.fileExists(atPath: vocabURL.path) else { throw LoadError.missingFile("vocab.txt") }
    guard FileManager.default.fileExists(atPath: weightsURL.path) else { throw LoadError.missingFile("model.safetensors") }
    tokenizer = try BGEWordPieceTokenizer(vocabularyText: String(contentsOf: vocabURL, encoding: .utf8))
    weights = try Weights(tensors: SafeTensorsFile(url: weightsURL))
  }

  /// 分词结果（含 [CLS]/[SEP]，超长截断），给测试核对用。
  public func tokenIDs(for text: String) -> [Int] {
    tokenizer.encode(text, maximumTokens: Self.maximumTokens)
  }

  /// 一段文字的向量（已归一化，两向量点积即余弦相似度）。
  public func embed(_ text: String) -> [Float] {
    let ids = tokenIDs(for: text)
    return weights.encode(ids)
  }
}

// MARK: - 分词

struct BGEWordPieceTokenizer: Sendable {
  private let vocabulary: [String: Int]
  private let unknownID: Int
  private let classID: Int
  private let separatorID: Int

  init(vocabularyText: String) throws {
    var vocabulary: [String: Int] = [:]
    // 只按 "\n" 切：词表里有 U+2028 这类字符本身就是词，`enumerateLines` 会把它们当换行，
    // 之后所有编号错一位（实测）。
    for (index, raw) in vocabularyText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
      if vocabulary[line] == nil { vocabulary[line] = index }
    }
    guard let unknown = vocabulary["[UNK]"], let cls = vocabulary["[CLS]"], let sep = vocabulary["[SEP]"] else {
      throw BGETextEmbedder.LoadError.malformedVocabulary
    }
    self.vocabulary = vocabulary
    unknownID = unknown
    classID = cls
    separatorID = sep
  }

  func encode(_ text: String, maximumTokens: Int) -> [Int] {
    var ids = [classID]
    let budget = maximumTokens - 2
    outer: for word in preTokenize(normalize(text)) {
      for id in wordPiece(word) {
        if ids.count - 1 >= budget { break outer }
        ids.append(id)
      }
    }
    ids.append(separatorID)
    return ids
  }

  /// BertNormalizer：去控制字符、空白统一成空格、中文字前后加空格。不转小写、不去重音。
  private func normalize(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let value = scalar.value
      if value == 0 || value == 0xFFFD || Self.isControl(scalar) { continue }
      if Self.isWhitespace(scalar) {
        out.append(" ")
      } else if Self.isChineseCharacter(value) {
        out.append(" "); out.append(scalar); out.append(" ")
      } else {
        out.append(scalar)
      }
    }
    return String(out)
  }

  /// BertPreTokenizer：按空白切，再把每个标点单独切出来。
  private func preTokenize(_ text: String) -> [String] {
    var words: [String] = []
    var current = String.UnicodeScalarView()
    func flush() {
      if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
    }
    for scalar in text.unicodeScalars {
      if scalar == " " {
        flush()
      } else if Self.isPunctuation(scalar) {
        flush()
        words.append(String(scalar))
      } else {
        current.append(scalar)
      }
    }
    flush()
    return words
  }

  private func wordPiece(_ word: String) -> [Int] {
    let scalars = Array(word.unicodeScalars)
    if scalars.count > 100 { return [unknownID] }
    var pieces: [Int] = []
    var start = 0
    while start < scalars.count {
      var end = scalars.count
      var found: Int?
      while start < end {
        var piece = String(String.UnicodeScalarView(scalars[start..<end]))
        if start > 0 { piece = "##" + piece }
        if let id = vocabulary[piece] { found = id; break }
        end -= 1
      }
      guard let id = found else { return [unknownID] }
      pieces.append(id)
      start = end
    }
    return pieces
  }

  private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return true }
    return scalar.properties.generalCategory == .spaceSeparator
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
    switch scalar.properties.generalCategory {
    case .control, .format: return true
    default: return false
    }
  }

  private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {
      return true
    }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation:
      return true
    default:
      return false
    }
  }

  private static func isChineseCharacter(_ value: UInt32) -> Bool {
    (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
      || (0x20000...0x2A6DF).contains(value) || (0x2A700...0x2B73F).contains(value)
      || (0x2B740...0x2B81F).contains(value) || (0x2B820...0x2CEAF).contains(value)
      || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
  }
}

// MARK: - 权重文件

/// safetensors：8 字节小端头长度 + JSON 头 + 连续的原始数据。这里只需要 F32。
struct SafeTensorsFile {
  private let data: Data
  private let base: Int
  private let entries: [String: (shape: [Int], start: Int, end: Int, dtype: String)]

  init(url: URL) throws {
    data = try Data(contentsOf: url, options: .alwaysMapped)
    guard data.count >= 8 else { throw BGETextEmbedder.LoadError.malformedWeights("header") }
    let headerLength = data.prefix(8).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
    guard headerLength > 0, 8 + headerLength <= data.count,
          let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any]
    else { throw BGETextEmbedder.LoadError.malformedWeights("header") }
    base = 8 + headerLength
    var entries: [String: (shape: [Int], start: Int, end: Int, dtype: String)] = [:]
    for (name, value) in header where name != "__metadata__" {
      guard let info = value as? [String: Any],
            let dtype = info["dtype"] as? String,
            let shape = info["shape"] as? [Int],
            let offsets = info["data_offsets"] as? [Int], offsets.count == 2
      else { continue }
      entries[name] = (shape, offsets[0], offsets[1], dtype)
    }
    self.entries = entries
  }

  func floats(_ name: String, shape expected: [Int]) throws -> [Float] {
    guard let entry = entries[name] else { throw BGETextEmbedder.LoadError.malformedWeights("missing \(name)") }
    guard entry.dtype == "F32", entry.shape == expected else {
      throw BGETextEmbedder.LoadError.malformedWeights("\(name) \(entry.dtype) \(entry.shape)")
    }
    let count = expected.reduce(1, *)
    guard entry.end - entry.start == count * 4, base + entry.end <= data.count else {
      throw BGETextEmbedder.LoadError.malformedWeights("\(name) size")
    }
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBytes { target in
      _ = data.copyBytes(to: target, from: (base + entry.start)..<(base + entry.end))
    }
    return out
  }
}

// MARK: - BERT 前向

private struct Weights: Sendable {
  struct Layer: Sendable {
    let query: Linear, key: Linear, value: Linear, attentionOutput: Linear
    let attentionNorm: Norm
    let intermediate: Linear, output: Linear
    let outputNorm: Norm
  }
  struct Linear: Sendable {
    let weight: [Float]  // [out, in]，行优先
    let bias: [Float]
    let input: Int
    let output: Int
  }
  struct Norm: Sendable {
    let gamma: [Float]
    let beta: [Float]
  }

  static let hidden = BGETextEmbedder.dimension
  static let heads = 8
  static let intermediateSize = 2048
  static let vocabularySize = 21128
  static let layerCount = 4

  let wordEmbeddings: [Float]
  let positionEmbeddings: [Float]
  let tokenTypeEmbeddings: [Float]
  let embeddingNorm: Norm
  let layers: [Layer]

  init(tensors: SafeTensorsFile) throws {
    let h = Self.hidden
    func linear(_ prefix: String, _ input: Int, _ output: Int) throws -> Linear {
      Linear(weight: try tensors.floats("\(prefix).weight", shape: [output, input]),
             bias: try tensors.floats("\(prefix).bias", shape: [output]), input: input, output: output)
    }
    func norm(_ prefix: String) throws -> Norm {
      Norm(gamma: try tensors.floats("\(prefix).weight", shape: [h]), beta: try tensors.floats("\(prefix).bias", shape: [h]))
    }
    wordEmbeddings = try tensors.floats("embeddings.word_embeddings.weight", shape: [Self.vocabularySize, h])
    positionEmbeddings = try tensors.floats("embeddings.position_embeddings.weight", shape: [BGETextEmbedder.maximumTokens, h])
    tokenTypeEmbeddings = try tensors.floats("embeddings.token_type_embeddings.weight", shape: [2, h])
    embeddingNorm = try norm("embeddings.LayerNorm")
    layers = try (0..<Self.layerCount).map { index in
      let p = "encoder.layer.\(index)"
      return Layer(
        query: try linear("\(p).attention.self.query", h, h),
        key: try linear("\(p).attention.self.key", h, h),
        value: try linear("\(p).attention.self.value", h, h),
        attentionOutput: try linear("\(p).attention.output.dense", h, h),
        attentionNorm: try norm("\(p).attention.output.LayerNorm"),
        intermediate: try linear("\(p).intermediate.dense", h, Self.intermediateSize),
        output: try linear("\(p).output.dense", Self.intermediateSize, h),
        outputNorm: try norm("\(p).output.LayerNorm")
      )
    }
  }

  func encode(_ ids: [Int]) -> [Float] {
    let n = ids.count
    let h = Self.hidden
    var x = [Float](repeating: 0, count: n * h)
    for (row, id) in ids.enumerated() {
      let token = min(max(id, 0), Self.vocabularySize - 1)
      for c in 0..<h {
        x[row * h + c] = wordEmbeddings[token * h + c] + positionEmbeddings[row * h + c] + tokenTypeEmbeddings[c]
      }
    }
    layerNorm(&x, rows: n, norm: embeddingNorm)
    for layer in layers {
      let q = apply(layer.query, to: x, rows: n)
      let k = apply(layer.key, to: x, rows: n)
      let v = apply(layer.value, to: x, rows: n)
      let context = attention(q: q, k: k, v: v, rows: n)
      var attended = apply(layer.attentionOutput, to: context, rows: n)
      vDSP_vadd(attended, 1, x, 1, &attended, 1, vDSP_Length(n * h))
      layerNorm(&attended, rows: n, norm: layer.attentionNorm)
      var inner = apply(layer.intermediate, to: attended, rows: n)
      gelu(&inner)
      var out = apply(layer.output, to: inner, rows: n)
      vDSP_vadd(out, 1, attended, 1, &out, 1, vDSP_Length(n * h))
      layerNorm(&out, rows: n, norm: layer.outputNorm)
      x = out
    }
    var cls = Array(x[0..<h])
    var norm: Float = 0
    vDSP_svesq(cls, 1, &norm, vDSP_Length(h))
    var scale = 1 / max(norm.squareRoot(), 1e-12)
    vDSP_vsmul(cls, 1, &scale, &cls, 1, vDSP_Length(h))
    return cls
  }

  /// y = x · Wᵀ + b
  private func apply(_ linear: Linear, to x: [Float], rows: Int) -> [Float] {
    var y = [Float](repeating: 0, count: rows * linear.output)
    for row in 0..<rows { y.replaceSubrange((row * linear.output)..<((row + 1) * linear.output), with: linear.bias) }
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                Int32(rows), Int32(linear.output), Int32(linear.input),
                1, x, Int32(linear.input), linear.weight, Int32(linear.input),
                1, &y, Int32(linear.output))
    return y
  }

  private func attention(q: [Float], k: [Float], v: [Float], rows n: Int) -> [Float] {
    let h = Self.hidden
    let headSize = h / Self.heads
    let scale = 1 / Float(headSize).squareRoot()
    var context = [Float](repeating: 0, count: n * h)
    var scores = [Float](repeating: 0, count: n * n)
    q.withUnsafeBufferPointer { qp in
      k.withUnsafeBufferPointer { kp in
        v.withUnsafeBufferPointer { vp in
          context.withUnsafeMutableBufferPointer { cp in
            for head in 0..<Self.heads {
              let offset = head * headSize
              cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(headSize),
                          scale, qp.baseAddress! + offset, Int32(h), kp.baseAddress! + offset, Int32(h),
                          0, &scores, Int32(n))
              for row in 0..<n { softmax(&scores, offset: row * n, count: n) }
              cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(headSize), Int32(n),
                          1, scores, Int32(n), vp.baseAddress! + offset, Int32(h),
                          0, cp.baseAddress! + offset, Int32(h))
            }
          }
        }
      }
    }
    return context
  }

  private func softmax(_ values: inout [Float], offset: Int, count: Int) {
    values.withUnsafeMutableBufferPointer { buffer in
      let row = buffer.baseAddress! + offset
      var maximum: Float = 0
      vDSP_maxv(row, 1, &maximum, vDSP_Length(count))
      var negated = -maximum
      vDSP_vsadd(row, 1, &negated, row, 1, vDSP_Length(count))
      var length = Int32(count)
      vvexpf(row, row, &length)
      var sum: Float = 0
      vDSP_sve(row, 1, &sum, vDSP_Length(count))
      var inverse = 1 / sum
      vDSP_vsmul(row, 1, &inverse, row, 1, vDSP_Length(count))
    }
  }

  private func layerNorm(_ x: inout [Float], rows: Int, norm: Norm) {
    let h = Self.hidden
    for row in 0..<rows {
      let start = row * h
      var mean: Float = 0
      var variance: Float = 0
      for c in 0..<h { mean += x[start + c] }
      mean /= Float(h)
      for c in 0..<h { let d = x[start + c] - mean; variance += d * d }
      variance /= Float(h)
      let inverse = 1 / (variance + 1e-12).squareRoot()
      for c in 0..<h { x[start + c] = (x[start + c] - mean) * inverse * norm.gamma[c] + norm.beta[c] }
    }
  }

  /// HF 的 "gelu" 是 erf 精确版。
  private func gelu(_ x: inout [Float]) {
    for i in x.indices { x[i] = 0.5 * x[i] * (1 + erf(x[i] / 2.0.squareRoot().float)) }
  }
}

private extension Double {
  var float: Float { Float(self) }
}
