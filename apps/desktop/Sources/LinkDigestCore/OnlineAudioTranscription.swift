import Foundation

public enum OnlineAudioTranscriptionError: Error, Sendable, Equatable {
  case modelNotConfigured
  case providerNotSupported
  case mediaURLInvalid
  case authInvalid
  case responseRejected
  case emptyTranscript
  case networkInterrupted
  /// 本机音频提取阶段失败（还没碰到网络）。detail 是非敏感的阶段+错误码，
  /// 例如 "export .failed AVFoundationErrorDomain -11828"。
  ///
  /// 之前这类失败全被 catch-all 折叠成 networkInterrupted，用户看到
  /// 「连接中断」，实际请求根本没发出——同一句文案连续三轮掩盖了
  /// 取错轨、缺 MIME 提示两个真实缺陷。
  case audioExtractionFailed(detail: String)
  /// 服务端明确拒绝了请求，detail 是服务端原话（已截断，不含密钥）。
  /// 模型名不被该端点接受、额度不足、分片超限这几类只有服务端知道，
  /// 折叠成 `responseRejected` 会让人无从下手。
  case providerRejected(detail: String)
  case cancelled

  public var userMessage: String {
    switch self {
    case .modelNotConfigured: "请先在设置的「模型服务」里保存服务商，并填好在线转写模型。"
    case .providerNotSupported: "这个服务商不支持在线转写。可以换成 OpenAI、Groq、OpenRouter，或其他支持语音转文字的服务商。"
    case .mediaURLInvalid: "视频的播放地址过期了，请回到浏览器重新保存这个页面。"
    case .authInvalid: "在线转写的密钥无效或没有权限，请到设置的「模型服务」里检查密钥。"
    case .responseRejected: "在线转写服务拒绝了请求，请检查模型名和账户余额。"
    case .emptyTranscript: "在线转写服务没有返回文字，可以稍后再试，或改用本机转写。"
    case .networkInterrupted: "在线转写的连接断了，请检查网络后重试。"
    // 阶段与错误码、服务端原话只进日志（见 `diagnosticDetail`），界面只说人话和下一步（2026-10-01）。
    case .audioExtractionFailed:
      "没能从视频里取出声音（还没发送任何数据）。请稍后重试；一直不行可以改用本机转写。"
    case .providerRejected:
      "在线转写服务拒绝了请求，常见原因是模型名填错或账户余额不足，请到设置的「模型服务」里检查。"
    case .cancelled: "已取消在线转写。"
    }
  }

  /// 给日志用的原始细节。界面不再拼接它：用户看不懂错误域和错误码，
  /// 但我们排查时离不开，所以留在错误值里、由调用方写进 AppLog（2026-10-01）。
  public var diagnosticDetail: String? {
    switch self {
    case let .audioExtractionFailed(detail), let .providerRejected(detail): detail
    default: nil
    }
  }
}

public protocol OnlineAudioTranscribing: Sendable {
  /// Reads a short-lived public media URL, extracts audio locally, then sends
  /// audio chunks to an explicitly configured STT provider. The provider
  /// secret and signed media URL must stay inside the adapter.
  ///
  /// `progress` 报告「已完成分片数 / 总分片数」。长音频要跑几分钟，
  /// 没有分片进度时用户无法区分「在跑」和「又挂了」。
  func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> String
}

extension OnlineAudioTranscribing {
  public func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?
  ) async throws -> String {
    try await transcribe(
      remoteMediaURL: remoteMediaURL, model: model, language: language, progress: nil
    )
  }
}

/// 边转写边出字的能力。分片进度只能告诉用户「在跑」，SSE 增量能让第一段文字
/// 在几秒内就出现——长音频的等待感主要由这个决定，而不是总耗时。
///
/// 单独立协议而不是加到 `OnlineAudioTranscribing`：批量端点没有增量，
/// 让它假装支持只会多出一条永远不触发的死路径。
public protocol StreamingOnlineAudioTranscribing: OnlineAudioTranscribing {
  /// `partialTranscript` 给的是**当前已确定的完整前缀**，不是增量片段。
  /// 分片是并发的，调用方无法自己拼接乱序到达的增量；由适配器只在
  /// 「从第 0 片起连续可用」的部分推进，调用方直接整段替换即可。
  func transcribe(
    remoteMediaURL: URL,
    model: String,
    language: String?,
    progress: (@Sendable (Int, Int) -> Void)?,
    partialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String
}
