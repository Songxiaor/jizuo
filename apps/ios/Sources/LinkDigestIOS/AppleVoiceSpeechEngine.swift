import AVFoundation
import Foundation
import Speech

/// 本机 Speech + AVAudioEngine 连续中文转写。
public actor AppleVoiceSpeechEngine: VoiceSpeechEngining {
  public static let defaultLocaleIdentifier = "zh-CN"

  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var isStopping = false

  public init() {}

  public func requestPermissions() async -> VoicePermissionStatus {
    let speechOk = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        cont.resume(returning: status == .authorized)
      }
    }
    if !speechOk {
      switch SFSpeechRecognizer.authorizationStatus() {
      case .denied:
        return .denied(message: "未授权语音识别。请到「设置 → 汲作」打开语音识别权限。")
      case .restricted:
        return .restricted(message: "系统限制了语音识别（家长控制或设备策略）。")
      case .notDetermined:
        return .denied(message: "未完成语音识别授权。")
      case .authorized:
        break
      @unknown default:
        return .denied(message: "语音识别权限状态未知。")
      }
    }

    #if os(iOS)
    let micOk = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      AVAudioApplication.requestRecordPermission { allowed in
        cont.resume(returning: allowed)
      }
    }
    if !micOk {
      return .denied(message: "未授权麦克风。请到「设置 → 汲作」打开麦克风权限后再口述。")
    }
    #endif

    return .granted
  }

  public func startRecognition(
    localeIdentifier: String,
    onPartial: @escaping @Sendable (String) -> Void,
    onFinal: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    await stopRecognition()
    isStopping = false

    let locale = Locale(identifier: localeIdentifier)
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw VoiceSpeechEngineError.recognizerUnavailable
    }

    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      throw VoiceSpeechEngineError.audioSessionFailed(error.localizedDescription)
    }
    #endif

    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw VoiceSpeechEngineError.engineStartFailed(error.localizedDescription)
    }

    audioEngine = engine
    recognitionRequest = request

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      if let result {
        let text = result.bestTranscription.formattedString
        if result.isFinal {
          onFinal(text)
        } else {
          onPartial(text)
        }
      }
      if let error {
        Task {
          let stopping = await self?.isStopping ?? true
          if stopping { return }
          if Self.isCancellation(error) { return }
          onError(error.localizedDescription)
        }
      }
    }
  }

  public func stopRecognition() async {
    isStopping = true
    let request = recognitionRequest
    let engine = audioEngine
    let task = recognitionTask
    recognitionRequest = nil
    audioEngine = nil
    recognitionTask = nil

    request?.endAudio()
    task?.finish()
    task?.cancel()
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      if engine.isRunning {
        engine.stop()
      }
    }

    #if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
  }

  private static func isCancellation(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
    if ns.domain == "kAFAssistantErrorDomain", ns.code == 216 || ns.code == 203 { return true }
    let message = ns.localizedDescription.lowercased()
    return message.contains("cancel") || message.contains("canceled") || message.contains("cancelled")
  }
}
