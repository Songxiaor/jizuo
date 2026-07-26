import Foundation

/// Preference for B 站「重新获取播放」时请求的清晰度上限。
/// Public playurl without browser session may still clamp below the requested
/// ceiling (login / VIP streams stay unavailable); we always pick the best
/// stream among what the API actually returns.
public enum BilibiliStreamQualityPreference: String, Codable, Sendable, Equatable, CaseIterable {
  /// Request the highest public tier (4K/1080P60 when the API allows).
  case highest
  /// Prefer ~1080P when available — good default for most screens.
  case balanced
  /// Prefer ~720P for faster first frame on long videos.
  case dataSaver

  public static let `default`: BilibiliStreamQualityPreference = .highest

  public var settingsTitle: String {
    switch self {
    case .highest: "尽量高清"
    case .balanced: "均衡（约 1080P）"
    case .dataSaver: "更快起播（约 720P）"
    }
  }

  public var settingsExplanation: String {
    switch self {
    case .highest:
      return "重新获取时优先最高可用清晰度。未登录公开接口仍可能拿不到会员专属档；长视频高清首帧也会更慢一些。"
    case .balanced:
      return "优先约 1080P，在画质与起播速度之间折中。"
    case .dataSaver:
      return "优先约 720P，首帧通常更快，适合长视频预览。"
    }
  }

  /// B 站 playurl `qn` 请求上限。返回列表里仍按实际带宽/分辨率择优。
  public var requestedQN: Int {
    switch self {
    case .highest: 127
    case .balanced: 80
    case .dataSaver: 64
    }
  }
}
