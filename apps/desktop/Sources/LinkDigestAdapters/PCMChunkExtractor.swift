import AVFoundation
import Foundation
import LinkDigestCore

/// 把音频解成 ASR 原生格式（16kHz 单声道 s16le）并按字节切片。
///
/// 与 `AVAssetExportSession` 的关键差别有两点：
///
/// 1. **不重编码**。导出 M4A 是 AAC→AAC 再压一遍，纯属白烧 CPU——实测 13 分钟
///    音频光切片就要 4.9s。这里只做解码 + 重采样，输出即是服务端要的格式。
/// 2. **可以边解边发**。导出必须整片写完才拿得到文件，所以老路径是「全部切完
///    再开始上传」；PCM 是流式产出的，第一片满了就能立刻发出去，解码与上传
///    重叠，省掉整个切片段的串行等待。
///
/// 按字节切也比按时长切更贴合约束：服务端限制的是请求体大小，而 s16le 的
/// 字节数与时长严格成正比（32000 B/s），一次乘除就能对齐上限，不用留余量。
public enum PCMChunkExtractor {
  public static let sampleRate = 16_000
  public static let bytesPerFrame = 2
  /// 16000 帧/秒 × 2 字节 × 单声道。切片估算和时长换算都用它。
  public static let bytesPerSecond = sampleRate * bytesPerFrame

  public struct Chunk: Sendable {
    public let index: Int
    public let data: Data
  }

  /// 写成函数而不是 `static let`：`[String: Any]` 不是 Sendable，
  /// 存成全局常量在严格并发下过不去，每次现造一份反而更省事。
  public static func audioSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  /// 按 base64 后的字符数上限反推每片可放的原始字节数。
  ///
  /// base64 每 3 字节涨到 4 字符，所以上限要**除**回去而不是乘。这里再对齐到
  /// 帧边界（2 字节）：从中间劈开一个采样会让那一帧变成噪声。
  public static func rawBytesPerChunk(base64Budget: Int) -> Int {
    let raw = base64Budget / 4 * 3
    return max(bytesPerFrame, raw - raw % bytesPerFrame)
  }

  /// 按时长预估会切出多少片。流式产出时总片数要等解码结束才真正确定，
  /// 但进度条不能等到那时候才出现，先用时长估一个。
  public static func estimatedChunkCount(durationSeconds: Double, rawBytesPerChunk: Int) -> Int {
    guard durationSeconds.isFinite, durationSeconds > 0, rawBytesPerChunk > 0 else { return 1 }
    let bytes = durationSeconds * Double(bytesPerSecond)
    return max(1, Int((bytes / Double(rawBytesPerChunk)).rounded(.up)))
  }

  /// 顺序产出 PCM 分片。消费者可以在下一片还在解码时就把当前片发出去。
  ///
  /// 收的是**造 asset 的闭包**而不是 asset 本身：`AVAsset` 不是 Sendable，
  /// 直接捕获进后台任务在严格并发下过不去；解码用的 asset 也不该和调用方
  /// 读时长用的那个共享读取状态。
  public static func chunks(
    makeAsset: @escaping @Sendable () -> AVAsset,
    rawBytesPerChunk: Int
  ) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        do {
          let asset = makeAsset()
          let tracks = try await asset.loadTracks(withMediaType: .audio)
          guard !tracks.isEmpty else {
            throw OnlineAudioTranscriptionError.audioExtractionFailed(detail: "媒体没有音频轨")
          }
          let reader = try AVAssetReader(asset: asset)
          let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: audioSettings()
          )
          // 我们只是把字节拷进自己的缓冲区，不持有 sample buffer，
          // 让 reader 复用底层内存。
          output.alwaysCopiesSampleData = false
          guard reader.canAdd(output) else {
            throw OnlineAudioTranscriptionError.audioExtractionFailed(detail: "无法添加 PCM 输出")
          }
          reader.add(output)
          guard reader.startReading() else {
            throw Self.readerFailure(reader)
          }

          var buffer = Data()
          var index = 0
          while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            Self.append(sample: sample, to: &buffer)
            while buffer.count >= rawBytesPerChunk {
              // 重新包一层 Data：切片会连着持有整个父缓冲区，而且下标不从 0 起，
              // 传出去容易踩到偏移。
              continuation.yield(.init(index: index, data: Data(buffer.prefix(rawBytesPerChunk))))
              buffer.removeFirst(rawBytesPerChunk)
              index += 1
            }
          }
          // `copyNextSampleBuffer` 返回 nil 既可能是读完，也可能是读失败，
          // 必须查 status——否则解码中断会被当成「音频只有这么长」，
          // 静默丢掉后半段文稿。
          guard reader.status == .completed else { throw Self.readerFailure(reader) }
          if !buffer.isEmpty {
            continuation.yield(.init(index: index, data: buffer))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func append(sample: CMSampleBuffer, to buffer: inout Data) {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return }
    var bytes = [UInt8](repeating: 0, count: length)
    guard CMBlockBufferCopyDataBytes(
      block,
      atOffset: 0,
      dataLength: length,
      destination: &bytes
    ) == kCMBlockBufferNoErr else { return }
    buffer.append(contentsOf: bytes)
  }

  private static func readerFailure(_ reader: AVAssetReader) -> Error {
    if reader.status == .cancelled { return CancellationError() }
    let ns = reader.error as NSError?
    return OnlineAudioTranscriptionError.audioExtractionFailed(
      detail: "PCM 读取失败 \(ns?.domain ?? "?") \(ns?.code ?? 0)"
    )
  }
}
