import AVFoundation
import XCTest
@testable import LinkDigestAdapters

/// 聚焦覆盖 `AppAudioLiveTranscriber.convert`：这是实时音频链路里
/// SCK 源格式 → 语音引擎格式的采样率转换，历史上用带可变捕获的
/// input block 实现，容易在 Swift 并发检查下告警且行为回归无人发现。
final class AppAudioLiveTranscriberTests: XCTestCase {
  /// 48kHz → 16kHz 降采样（真实链路方向：SCK 常见源格式 → 语音引擎格式）：
  /// 输出必须是 16kHz 且真的发生了转换——帧数按采样率比例收缩，内容非零。
  func testConvertDownsamplesFrom48000To16000() throws {
    let source = try makeBuffer(sampleRate: 48_000, frameCount: 960, frequency: 440)
    let target = try makeFormat(sampleRate: 16_000)
    let converter = try makeConverter(from: source.format, to: target)

    let output = try XCTUnwrap(
      AppAudioLiveTranscriber.convert(source, using: converter, to: target),
      "downsampling conversion should produce output"
    )
    XCTAssertEqual(output.format.sampleRate, 16_000)
    XCTAssertEqual(output.format.channelCount, 1)
    XCTAssertGreaterThan(output.frameLength, 0)
    // 960 帧 @48k = 20ms → 320 帧 @16k；转换器内部按块消费，允许 ±5% 偏差。
    XCTAssertEqual(Double(output.frameLength), 320, accuracy: 16)
    XCTAssertLessThan(output.frameLength, source.frameLength, "downsampling must shrink frame count")
    XCTAssertGreaterThan(peak(of: output), 0.3, "converted audio must not be silent")
  }

  /// 8kHz → 16kHz 升采样：帧数约翻倍，内容非零。
  func testConvertUpsamplesFrom8000To16000() throws {
    let source = try makeBuffer(sampleRate: 8_000, frameCount: 800, frequency: 440)
    let target = try makeFormat(sampleRate: 16_000)
    let converter = try makeConverter(from: source.format, to: target)

    let output = try XCTUnwrap(
      AppAudioLiveTranscriber.convert(source, using: converter, to: target),
      "upsampling conversion should produce output"
    )
    XCTAssertEqual(output.format.sampleRate, 16_000)
    XCTAssertGreaterThan(output.frameLength, 0)
    // 800 帧 @8k = 100ms → 1600 帧 @16k；允许 ±5% 偏差。
    XCTAssertEqual(Double(output.frameLength), 1600, accuracy: 80)
    XCTAssertGreaterThan(output.frameLength, source.frameLength, "upsampling must grow frame count")
    XCTAssertGreaterThan(peak(of: output), 0.3, "converted audio must not be silent")
  }

  /// 转换器跨 buffer 复用（pump 循环的真实用法：converter 只建一次、
  /// 每个 buffer 各自转换），确保没有一次性状态泄漏。
  func testConverterReuseAcrossBuffers() throws {
    let target = try makeFormat(sampleRate: 16_000)
    let sourceFormat = try makeFormat(sampleRate: 44_100)
    let converter = try makeConverter(from: sourceFormat, to: target)

    for index in 0..<3 {
      let source = try makeBuffer(sampleRate: 44_100, frameCount: 2205, frequency: 440 + Float(index))
      let output = try XCTUnwrap(
        AppAudioLiveTranscriber.convert(source, using: converter, to: target),
        "reused converter should keep converting"
      )
      XCTAssertEqual(output.format.sampleRate, 16_000)
      // 2205 帧 @44.1k = 50ms → 800 帧 @16k；允许 ±5% 偏差。
      XCTAssertEqual(Double(output.frameLength), 800, accuracy: 40)
      XCTAssertGreaterThan(peak(of: output), 0.3, "converted audio must not be silent")
    }
  }

  /// SDK 没有承诺 `AVAudioConverter` 的 input block 串行或同线程调用；
  /// 并发触发时，`SingleShotConversionInput` 必须仍保证 `.haveData` 至多
  /// 一次，其余调用返回 `.noDataNow`，且返回缓冲与状态码始终配对。
  func testSingleShotInputDeliversOnceUnderConcurrentCalls() throws {
    let source = try makeBuffer(sampleRate: 48_000, frameCount: 960, frequency: 440)
    let input = SingleShotConversionInput(source: source)
    let counter = DeliveryCounter()

    let iterations = 512
    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      var status: AVAudioConverterInputStatus = .noDataNow
      let buffer = withUnsafeMutablePointer(to: &status) { pointer in
        input.next(status: pointer)
      }
      counter.record(delivered: buffer != nil, status: status)
    }

    XCTAssertEqual(counter.haveDataCount, 1, "即使并发调用也至多一次交付 .haveData")
    XCTAssertEqual(counter.noDataCount, iterations - 1, "其余调用都应返回 .noDataNow")
    XCTAssertEqual(counter.mismatchCount, 0, "交付状态必须与返回缓冲配对：.haveData 配 buffer，.noDataNow 配 nil")
  }

  // MARK: - Helpers

  private func makeFormat(sampleRate: Double) throws -> AVAudioFormat {
    try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      "unable to create \(sampleRate)Hz mono format"
    )
  }

  private func makeConverter(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) throws -> AVAudioConverter {
    try XCTUnwrap(
      AVAudioConverter(from: sourceFormat, to: targetFormat),
      "unable to create AVAudioConverter"
    )
  }

  private func makeBuffer(sampleRate: Double, frameCount: AVAudioFrameCount, frequency: Float) throws -> AVAudioPCMBuffer {
    let format = try makeFormat(sampleRate: sampleRate)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      "unable to create PCM buffer"
    )
    buffer.frameLength = frameCount
    if let channel = buffer.floatChannelData?[0] {
      for index in 0..<Int(frameCount) {
        channel[index] = 0.5 * sinf(2.0 * .pi * frequency * Float(index) / Float(sampleRate))
      }
    }
    return buffer
  }

  private func peak(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?[0] else { return 0 }
    var peak: Float = 0
    for index in 0..<Int(buffer.frameLength) {
      peak = max(peak, abs(channel[index]))
    }
    return peak
  }
}

/// 并发 hammer 测试的线程安全计数器，只记录计数，不触碰被测对象。
private final class DeliveryCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var haveData = 0
  private var noData = 0
  private var mismatches = 0

  func record(delivered: Bool, status: AVAudioConverterInputStatus) {
    lock.withLock {
      if delivered {
        haveData += 1
        if status != .haveData { mismatches += 1 }
      } else {
        noData += 1
        if status != .noDataNow { mismatches += 1 }
      }
    }
  }

  var haveDataCount: Int { lock.withLock { haveData } }
  var noDataCount: Int { lock.withLock { noData } }
  var mismatchCount: Int { lock.withLock { mismatches } }
}
