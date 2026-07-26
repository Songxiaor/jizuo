import Foundation

/// Platforms that may hold an App-owned login session for high-quality
/// streaming refresh. P1 ships bilibili only; other cases are reserved.
public enum SiteSessionPlatform: String, Codable, Sendable, Equatable, CaseIterable {
  case bilibili
  // Reserved for later adapters — not shown in UI yet.
  case x
  case youtube
  case douyin
  case xiaohongshu

  public var displayName: String {
    switch self {
    case .bilibili: "B 站"
    case .x: "X"
    case .youtube: "YouTube"
    case .douyin: "抖音"
    case .xiaohongshu: "小红书"
    }
  }

  /// First-ship set shown in settings.
  public static var shippedInP1: [SiteSessionPlatform] { [.bilibili] }
}
