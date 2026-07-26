import XCTest

@testable import LinkDigestCore

/// 并发上传分片后，文稿必须按分片序号还原，而不是完成顺序。
///
/// 这类错误不会崩、不会报错，只表现为「转写读起来前言不搭后语」，
/// 极易被当成模型质量问题而不是代码缺陷，所以必须有测试盯着。
final class OnlineTranscriptionChunkOrderTests: XCTestCase {
  /// 复刻 transcribe() 里的还原逻辑：完成顺序乱序写入，按 key 排序取回。
  private func reassemble(_ completionOrder: [(Int, String)]) -> String {
    var results: [Int: String] = [:]
    for (index, text) in completionOrder { results[index] = text }
    return results.keys.sorted().compactMap { results[$0] }.joined(separator: "\n")
  }

  func testTranscriptFollowsChunkIndexNotCompletionOrder() {
    // 短分片先返回是常态：第 3 片最短，往往最先完成。
    let completionOrder = [(2, "第三段"), (0, "第一段"), (1, "第二段")]
    XCTAssertEqual(reassemble(completionOrder), "第一段\n第二段\n第三段")
  }

  func testDoubleDigitChunkCountsStayNumericallyOrdered() {
    // 字典序会把 10 排到 2 前面；分片数超过 10 时必须仍按数值序。
    let completionOrder = (0..<12).map { ($0, "段\($0)") }.shuffled()
    let expected = (0..<12).map { "段\($0)" }.joined(separator: "\n")
    XCTAssertEqual(reassemble(completionOrder), expected)
  }

  func testExtractionFailureIsNotReportedAsNetworkInterruption() {
    // 「连接中断」曾罩住本机提取失败，连续三轮掩盖真实缺陷。
    let extraction = OnlineAudioTranscriptionError.audioExtractionFailed(detail: "export 失败 X -11838")
    XCTAssertNotEqual(extraction.userMessage, OnlineAudioTranscriptionError.networkInterrupted.userMessage)
    XCTAssertTrue(extraction.userMessage.contains("-11838"))
    XCTAssertTrue(extraction.userMessage.contains("还未发送"))
  }
}
