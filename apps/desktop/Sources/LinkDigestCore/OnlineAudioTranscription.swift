import Foundation

public enum OnlineAudioTranscriptionError: Error, Sendable, Equatable {
  case modelNotConfigured
  case providerNotSupported
  case mediaURLInvalid
  case authInvalid
  case responseRejected
  case emptyTranscript
  case networkInterrupted
  case cancelled

  public var userMessage: String {
    switch self {
    case .modelNotConfigured: "请先在设置中保存模型服务，并填写在线转写模型。"
    case .providerNotSupported: "这个服务没有兼容的 /audio/transcriptions 接口。请切换 OpenAI、Groq、OpenRouter 或兼容端点。"
    case .mediaURLInvalid: "在线转写地址已失效，请回到浏览器重新发送。"
    case .authInvalid: "在线转写 API Key 无效或没有权限。"
    case .responseRejected: "在线转写服务拒绝了请求，请检查模型名和账户额度。"
    case .emptyTranscript: "在线服务没有返回可保存的文字。"
    case .networkInterrupted: "在线转写连接中断，请稍后重试。"
    case .cancelled: "已取消在线转写。"
    }
  }
}

public protocol OnlineAudioTranscribing: Sendable {
  /// Reads a short-lived public media URL, extracts audio locally, then sends
  /// audio chunks to an explicitly configured STT provider. The provider
  /// secret and signed media URL must stay inside the adapter.
  func transcribe(remoteMediaURL: URL, model: String, language: String?) async throws -> String
}
