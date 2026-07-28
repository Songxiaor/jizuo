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

  /// 两句话必须让人**不用试**就能选。
  ///
  /// 原来写的是「更省流量，也更可预期」——形容词，没说清实际会遇到什么不同。
  /// 用户的原话是「主要是没清楚两个功能的区别」，那是这两句没写好，不是他没读。
  /// 所以这里只写两件事：你要多做什么动作，以及代价具体落在哪。
  public var settingsExplanation: String {
    switch self {
    case .automatic:
      return "打开一条视频记录就自动去取地址，取到直接能播。代价是每打开一条就发一次请求：B 站、X 很轻，抖音要在后台渲染整页、最慢 20 秒。"
    case .manual:
      return "打开时只标明这条有视频，想看再点一下「重新获取播放」。只对你真要看的那条发请求，路过的不发。"
    }
  }
}
