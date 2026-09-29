import XCTest
@testable import LinkDigestCore

final class SemanticSearchTests: XCTestCase {
  func testDocumentTextKeepsTitleAndProseOnly() {
    let body = """
    ---
    author: "WY (@akokoi1)"
    likes: "236"
    ---

    # 项目放到github上开源了

    项目放到github上开源了，就一个单html文件。代码：https://github.com/wy51ai/floorplan-3d
    ![](https://pbs.twimg.com/media/a.jpg)
    <!--LDQUOTE author="x" -->

    ## 评论（已保存 2 条）
    - 不该出现
    """
    let text = SemanticDocumentText.make(title: "项目放到github上开源了", sourcePreview: body, artifactPreview: nil)
    XCTAssertTrue(text.hasPrefix("项目放到github上开源了\n"))
    XCTAssertTrue(text.contains("就一个单html文件"))
    for noise in ["author", "https", "pbs.twimg", "LDQUOTE", "评论", "不该出现"] {
      XCTAssertFalse(text.contains(noise), noise)
    }
  }

  func testDocumentTextFallsBackToSummaryAndIsBounded() {
    let short = SemanticDocumentText.make(title: "视频", sourcePreview: "一句配文", artifactPreview: "## 摘要\n讲的是 AI 视频工作流。")
    XCTAssertTrue(short.contains("讲的是 AI 视频工作流"))
    let long = SemanticDocumentText.make(title: "长文", sourcePreview: String(repeating: "字", count: 5_000), artifactPreview: nil)
    XCTAssertEqual(long.count, 480)
  }

  func testRankingKeepsCloseMatchesAboveFloor() {
    var index = SemanticIndex(modelID: "test", dimension: 2)
    let unit = { (x: Float, y: Float) -> [Float] in let n = (x * x + y * y).squareRoot(); return [x / n, y / n] }
    index.set("a", .init(updatedAtMilliseconds: 1, vector: unit(1, 0)))
    index.set("b", .init(updatedAtMilliseconds: 1, vector: unit(0.9, 0.3)))
    index.set("c", .init(updatedAtMilliseconds: 1, vector: unit(0.3, 1)))
    index.set("d", .init(updatedAtMilliseconds: 1, vector: unit(0, 1)))
    let ranked = index.ranked(query: [1, 0], limit: 10, minimumScore: 0.2, relativeWindow: 0.12)
    XCTAssertEqual(ranked.map(\.taskID), ["a", "b"])
    XCTAssertTrue(index.ranked(query: [1, 0], limit: 10, minimumScore: 1.1, relativeWindow: 1).isEmpty)
  }

  func testIndexRoundTripsThroughFile() throws {
    var index = SemanticIndex(modelID: "bge-small-zh-v1.5", dimension: 3)
    index.set("40847250-39d8-4983-a3b6-e44c9bd8122c", .init(updatedAtMilliseconds: 1_790_000_000_123, vector: [0.1, -0.2, 0.3]))
    index.set("475a8233-1428-4f11-8e9a-d099cc45672f", .init(updatedAtMilliseconds: 7, vector: [1, 0, 0]))
    let decoded = try SemanticIndex(data: index.encoded())
    XCTAssertEqual(decoded, index)
    XCTAssertThrowsError(try SemanticIndex(data: index.encoded().prefix(40)))
    XCTAssertThrowsError(try SemanticIndex(data: Data("nope".utf8)))
  }
}
