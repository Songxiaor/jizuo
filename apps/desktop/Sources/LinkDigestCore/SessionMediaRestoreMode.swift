import Foundation

/// How history entries recover streaming playback after the in-memory
/// ephemeral descriptor is gone (app relaunch or another capture replaced it).
///
/// Signed CDN URLs are never persisted. Recovery always re-fetches a fresh
/// temporary address (or uses a durable embed path such as YouTube).
public enum SessionMediaRestoreMode: String, Codable, Sendable, Equatable, CaseIterable {
  /// Opening a history detail automatically tries to restore streaming playback.
  case automatic
  /// Show the session-media card until the user taps “重新获取播放”.
  case manual

  public static let `default`: SessionMediaRestoreMode = .manual

  public var settingsTitle: String {
    switch self {
    case .automatic: "自动恢复在线播放"
    case .manual: "手动获取在线播放"
    }
  }

  public var settingsExplanation: String {
    switch self {
    case .automatic:
      return "打开历史中的视频时，自动尝试重新获取临时播放地址并播放。完整视频不会因此保存到本机；需要扩展可用网络，部分平台可能需要原页面仍可访问。"
    case .manual:
      return "打开历史时只说明该记录包含视频；需要在线播放时再点「重新获取播放」。更省流量，也更可预期。"
    }
  }
}
