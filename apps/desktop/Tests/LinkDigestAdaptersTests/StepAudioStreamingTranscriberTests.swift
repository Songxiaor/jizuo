import XCTest

@testable import LinkDigestAdapters

/// 流式转写这条路径上，三类错误都不会崩、也不会报错，只会安静地产出坏结果：
/// 分片切大了被服务端拒、并发增量按到达顺序拼成乱序文稿、非阶跃端点被误导
/// 到只有阶跃才有的路径。三类都在这里钉住。
final class StepAudioStreamingTranscriberTests: XCTestCase {
  func testChunkSizeStaysUnderBase64BudgetAndOnFrameBoundary() {
    let budget = 9 * 1_024 * 1_024
    let raw = PCMChunkExtractor.rawBytesPerChunk(base64Budget: budget)
    // base64 每 3 字节涨到 4 字符；反推时必须除回去，乘上去就会超限被拒。
    let encodedLength = (raw + 2) / 3 * 4
    XCTAssertLessThanOrEqual(encodedLength, budget)
    XCTAssertLessThanOrEqual(encodedLength, 10 * 1_024 * 1_024)
    // 从采样中间劈开会让那一帧变噪声。
    XCTAssertEqual(raw % PCMChunkExtractor.bytesPerFrame, 0)
  }

  func testEstimatedChunkCountCoversWholeDuration() {
    let raw = PCMChunkExtractor.rawBytesPerChunk(base64Budget: 9 * 1_024 * 1_024)
    let duration = 788.0
    let count = PCMChunkExtractor.estimatedChunkCount(
      durationSeconds: duration,
      rawBytesPerChunk: raw
    )
    // 估少了会让进度条显示不全；必须向上取整覆盖整段。
    XCTAssertGreaterThanOrEqual(
      Double(count * raw),
      duration * Double(PCMChunkExtractor.bytesPerSecond)
    )
    XCTAssertEqual(
      PCMChunkExtractor.estimatedChunkCount(durationSeconds: 0, rawBytesPerChunk: raw),
      1
    )
  }

  func testOnlyStepFunHostsUseStreamingEndpoint() {
    XCTAssertTrue(StepAudioStreamingTranscriber.handles(
      baseURL: URL(string: "https://api.stepfun.com/v1")!
    ))
    XCTAssertTrue(StepAudioStreamingTranscriber.handles(
      baseURL: URL(string: "https://api.stepfun.ai/v1")!
    ))
    XCTAssertFalse(StepAudioStreamingTranscriber.handles(
      baseURL: URL(string: "https://api.openai.com/v1")!
    ))
    // 后缀匹配不能被 `stepfun.com.evil.example` 这种域名骗过去。
    XCTAssertFalse(StepAudioStreamingTranscriber.handles(
      baseURL: URL(string: "https://api.stepfun.com.evil.example/v1")!
    ))
  }

  func testStreamingEndpointReplacesPathRootInsteadOfAppending() {
    let url = StepAudioStreamingTranscriber.endpointURL(
      baseURL: URL(string: "https://api.stepfun.com/v1")!
    )
    // SSE 不在 `/v1` 下，接后缀会得到 `/v1/step_plan/...` 这种 404 地址。
    XCTAssertEqual(url?.absoluteString, "https://api.stepfun.com/step_plan/v1/audio/asr/sse")
  }

  func testPartialTranscriptWithholdsLaterChunksUntilEarlierOnesFinish() async {
    let recorder = PreviewRecorder()
    let collector = PartialTranscriptCollector(
      onAdvance: { recorder.record($0) },
      publishInterval: .zero
    )

    // 第 1 片先出字：第 0 片还没完成，它一个字都不能露出来，
    // 否则用户读到的是倒着的文稿。
    await collector.append(index: 1, delta: "后半段")
    XCTAssertEqual(recorder.latest, nil)

    await collector.append(index: 0, delta: "前半段")
    XCTAssertEqual(recorder.latest, "前半段")

    await collector.commit(index: 0, text: "前半段（定稿）")
    // 第 0 片定稿后，第 1 片的在途文字才接得上。
    XCTAssertEqual(recorder.latest, "前半段（定稿）\n后半段")

    await collector.commit(index: 1, text: "后半段（定稿）")
    XCTAssertEqual(recorder.latest, "前半段（定稿）\n后半段（定稿）")
  }

  func testRapidTranscriptDeltasCoalescePreviewUpdatesAndFlushFinalPrefix() async {
    let recorder = PreviewRecorder()
    let collector = PartialTranscriptCollector(
      onAdvance: { recorder.record($0) },
      publishInterval: .seconds(30)
    )

    for _ in 0..<200 {
      await collector.append(index: 0, delta: "字")
    }
    await collector.flush()

    XCTAssertEqual(recorder.latest, String(repeating: "字", count: 200))
    XCTAssertLessThanOrEqual(recorder.count, 2)
  }
}

private final class PreviewRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  private var recordedCount = 0

  var latest: String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }


  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCount
  }

  func record(_ text: String) {
    lock.lock()
    value = text
    recordedCount += 1
    lock.unlock()
  }
}
