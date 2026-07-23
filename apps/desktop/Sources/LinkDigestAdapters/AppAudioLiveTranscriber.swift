import AVFoundation
import CoreGraphics
import Foundation
import LinkDigestCore
@preconcurrency import ScreenCaptureKit
import Speech

/// 实时音频转写：捕获**本 App 自己进程**播放的音频（YouTube 加密流无法
/// 下载，只能边播边转），流式喂给 Apple 语音引擎。全程本机、零网络；
/// 唯一的系统交互是 ScreenCaptureKit 首次需要的屏幕录制权限。
///
/// 与 `AppleSpeechVideoTranscriber`（文件离线转写）互补：那条用于抖音等
/// 可落盘视频，本条用于只能在内嵌播放器里播放的来源。
public actor AppAudioLiveTranscriber {
  public init() {}

  public enum LiveTranscriptionError: Error, Sendable, Equatable {
    case unsupportedOS
    case screenRecordingPermissionDenied
    case captureFailed
    case speechUnavailable
    case localeUnavailable
    case modelNotInstalled
    case emptyTranscript
  }

  /// 开始实时转写：调用方负责让内嵌播放器开始播放。事件流逐段回报
  /// partial 文本；从 `stopSignal` 收到任意值即**优雅结束**——停止音频
  /// 捕获、让引擎处理完剩余音频、给出 `.final` 并保存，而非硬取消丢弃。
  /// 视频播完或用户点停止都经此信号,确保 ScreenCaptureKit 流一定被关闭
  /// （菜单栏录屏图标随之消失）。
  public func transcribe(
    localeIdentifier: String,
    stopSignal: AsyncStream<Void>
  ) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard #available(macOS 26.0, *) else { throw LiveTranscriptionError.unsupportedOS }
          try await Self.runSession(
            localeIdentifier: localeIdentifier,
            stopSignal: stopSignal,
            continuation: continuation
          )
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as LiveTranscriptionError {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(throwing: LiveTranscriptionError.captureFailed)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  @available(macOS 26.0, *)
  private static func runSession(
    localeIdentifier: String,
    stopSignal: AsyncStream<Void>,
    continuation: AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>.Continuation
  ) async throws {
    guard SpeechTranscriber.isAvailable else { throw LiveTranscriptionError.speechUnavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: localeIdentifier)
    ) else { throw LiveTranscriptionError.localeUnavailable }
    // 实时字幕配置：请求 volatile（中间）结果，第一个字随说随出，
    // 不必等引擎攒够上下文再吐——`.progressiveTranscription` 偏准确度、
    // 首字延迟高，不适合"边播边看"的即时反馈。
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw LiveTranscriptionError.modelNotInstalled
    }

    // 主动触发系统「录屏与系统录音」授权：未授权时这会弹出系统对话框
    // 并把本 App 注册进权限列表，比让用户手动用 + 添加可靠得多。
    if !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
      throw LiveTranscriptionError.screenRecordingPermissionDenied
    }

    // 只捕获本进程音频：excludesCurrentProcessAudio = false，并把过滤器
    // 限定到当前应用，不录制其它 App 或麦克风。
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else { throw LiveTranscriptionError.captureFailed }
    let currentApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
    let filter: SCContentFilter
    if let currentApp {
      filter = SCContentFilter(display: display, including: [currentApp], exceptingWindows: [])
    } else {
      filter = SCContentFilter(display: display, excludingWindows: [])
    }

    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = false
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    // 视频轨最小化：只为满足 SCStream 必须有视频输出的约束。
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    let audioOutput = AudioSampleOutput(continuation: inputContinuation)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: DispatchQueue(label: "linkdigest.live-audio"))

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    // 语音引擎只接受它指定的音频格式；ScreenCaptureKit 的原始格式必须
    // 先转换，否则 AnalyzerInput 初始化直接 trap 崩溃。
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    let (analyzerInput, analyzerFeed) = AsyncStream.makeStream(of: AnalyzerInput.self)

    let pumpTask = Task {
      var converter: AVAudioConverter?
      var converterSourceFormat: AVAudioFormat?
      for await buffer in inputStream {
        try Task.checkCancellation()
        guard let analyzerFormat else {
          analyzerFeed.yield(AnalyzerInput(buffer: buffer))
          continue
        }
        if buffer.format == analyzerFormat {
          analyzerFeed.yield(AnalyzerInput(buffer: buffer))
          continue
        }
        // 源格式变化时重建转换器（SCK 通常稳定，一次即可）。
        if converter == nil || converterSourceFormat != buffer.format {
          converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
          converterSourceFormat = buffer.format
        }
        guard let converter,
              let converted = Self.convert(buffer, using: converter, to: analyzerFormat)
        else { continue }
        analyzerFeed.yield(AnalyzerInput(buffer: converted))
      }
      analyzerFeed.finish()
    }

    let resultsTask = Task { () throws -> String in
      var accumulator = TimedTranscriptionAccumulator()
      for try await result in transcriber.results {
        try Task.checkCancellation()
        let current = accumulator.apply(
          range: result.range,
          text: String(result.text.characters),
          isFinal: result.isFinal
        )
        continuation.yield(.partial(current))
      }
      return accumulator.finalText
    }

    continuation.yield(.transcribing)
    do {
      try await stream.startCapture()
    } catch {
      // ScreenCaptureKit 在未授权时抛错；映射为可操作的权限提示。
      pumpTask.cancel(); resultsTask.cancel()
      throw LiveTranscriptionError.screenRecordingPermissionDenied
    }

    // 优雅停止：收到停止信号即关流 + finish 输入，让引擎处理完剩余音频后
    // 自然结束 results（→ 走成功路径保存 final），而不是硬取消丢弃内容。
    // stopCapture 在此一定被调用，菜单栏录屏图标随之消失。
    let stopTask = Task {
      for await _ in stopSignal { break }
      try? await stream.stopCapture()
      inputContinuation.finish()
    }

    do {
      try await analyzer.start(inputSequence: analyzerInput)
      let text = try await withTaskCancellationHandler {
        try await resultsTask.value
      } onCancel: {
        pumpTask.cancel()
        inputContinuation.finish()
        Task { try? await stream.stopCapture() }
        Task { await analyzer.cancelAndFinishNow() }
      }
      stopTask.cancel()
      try? await stream.stopCapture()
      pumpTask.cancel()
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw LiveTranscriptionError.emptyTranscript }
      continuation.yield(.final(trimmed))
      continuation.finish()
    } catch {
      stopTask.cancel()
      pumpTask.cancel(); resultsTask.cancel()
      inputContinuation.finish()
      try? await stream.stopCapture()
      await analyzer.cancelAndFinishNow()
      if error is CancellationError { throw CancellationError() }
      throw LiveTranscriptionError.captureFailed
    }
  }
}

extension AppAudioLiveTranscriber {
  /// 采样率/格式转换：SCK 源缓冲 → 语音引擎要求的格式。输出容量按采样率
  /// 比例放大，避免降/升采样时截断。
  fileprivate static func convert(
    _ source: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / source.format.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
    guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, statusPointer in
      if supplied {
        statusPointer.pointee = .noDataNow
        return nil
      }
      supplied = true
      statusPointer.pointee = .haveData
      return source
    }
    guard error == nil, status != .error, output.frameLength > 0 else { return nil }
    return output
  }
}

/// SCStream 音频输出 → 16kHz 单声道 PCM buffer，转成语音引擎输入。
private final class AudioSampleOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

  init(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
    self.continuation = continuation
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid,
          let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
    // 每个 buffer 由本方法新建、立即交出、之后不再触碰，是安全的所有权转移。
    nonisolated(unsafe) let handoff = pcm
    continuation.yield(handoff)
  }

  private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDescription = sampleBuffer.formatDescription,
          var asbd = formatDescription.audioStreamBasicDescription
    else { return nil }
    // 必须传指向存活变量的指针；此前用临时数组 baseAddress 会在闭包后悬垂，
    // 让 AVAudioFormat 读到垃圾并使 AVAudioPCMBuffer 崩溃。
    guard let format = AVAudioFormat(streamDescription: &asbd),
          // AVAudioPCMBuffer 只接受标准 PCM 格式；非标准布局在此拦截，
          // 避免 init 抛出无法在 Swift 捕获的 ObjC 异常。
          format.commonFormat != .otherFormat
    else { return nil }
    let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
    guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
    buffer.frameLength = frameCount
    do {
      try sampleBuffer.copyPCMData(fromRange: 0..<Int(frameCount), into: buffer.mutableAudioBufferList)
      return buffer
    } catch {
      return nil
    }
  }
}
