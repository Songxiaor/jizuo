import Foundation
import XCTest
@testable import LinkDigestAdapters

/// 参考答案来自官方 tokenizer.json（HF tokenizers）+ Xenova 导出的 ONNX 模型（onnxruntime），
/// 见 Fixtures/bge-small-zh/reference.json。分词只要词表，每次都跑；向量要 91MB 的权重，
/// 设 `LINKDIGEST_BGE_MODEL_DIR` 指向含 model.safetensors 与 vocab.txt 的目录才跑。
final class BGETextEmbedderTests: XCTestCase {
  private struct Reference: Decodable {
    let text: String
    let ids: [Int]
    let vector: [Float]
  }

  private func references() throws -> [Reference] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "reference", withExtension: "json", subdirectory: "Fixtures/bge-small-zh"))
    return try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
  }

  func testTokenizerMatchesOfficialTokenizer() throws {
    let vocabURL = try XCTUnwrap(Bundle.module.url(forResource: "vocab", withExtension: "txt", subdirectory: "Fixtures/bge-small-zh"))
    let tokenizer = try BGEWordPieceTokenizer(vocabularyText: String(contentsOf: vocabURL, encoding: .utf8))
    for reference in try references() {
      XCTAssertEqual(tokenizer.encode(reference.text, maximumTokens: 512), reference.ids, reference.text)
    }
    // 超长截断后仍以 [SEP] 收尾，总数不超过上限。
    let long = tokenizer.encode(String(repeating: "汲", count: 2_000), maximumTokens: 512)
    XCTAssertEqual(long.count, 512)
    XCTAssertEqual(long.last, 102)
  }

  func testVectorsMatchOfficialModel() throws {
    guard let directory = ProcessInfo.processInfo.environment["LINKDIGEST_BGE_MODEL_DIR"] else {
      throw XCTSkip("设 LINKDIGEST_BGE_MODEL_DIR 才跑（需要 91MB 模型文件）")
    }
    let embedder = try BGETextEmbedder(directory: URL(fileURLWithPath: directory))
    for reference in try references() {
      let vector = embedder.embed(reference.text)
      XCTAssertEqual(vector.count, BGETextEmbedder.dimension)
      let cosine = zip(vector, reference.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
      XCTAssertGreaterThan(cosine, 0.9999, reference.text)
    }
  }
}
