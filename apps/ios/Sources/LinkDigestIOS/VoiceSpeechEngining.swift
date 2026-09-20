import Foundation

public enum VoicePermissionStatus: Equatable, Sendable {
  case granted
  case denied(message: String)
  case restricted(message: String)
}

/// 可注入的语音引擎：真机走 Speech+AVAudioEngine，单测走 Fake。
public protocol VoiceSpeechEngining: Sendable {
  func requestPermissions() async -> VoicePermissionStatus
  /// 开始连续识别。回调可能在非主线程；由控制器归约到状态机。
  func startRecognition(
    localeIdentifier: String,
    onPartial: @escaping @Sendable (String) -> Void,
    onFinal: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws
  func stopRecognition() async
}

public enum VoiceSpeechEngineError: Error, LocalizedError, Equatable, Sendable {
  case recognizerUnavailable
  case audioSessionFailed(String)
  case engineStartFailed(String)
  case recognitionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .recognizerUnavailable:
      return "当前设备或系统不支持中文语音识别。"
    case .audioSessionFailed(let detail):
      return "无法启动麦克风：\(detail)"
    case .engineStartFailed(let detail):
      return "录音引擎启动失败：\(detail)"
    case .recognitionFailed(let detail):
      return "转写失败：\(detail)"
    }
  }
}
