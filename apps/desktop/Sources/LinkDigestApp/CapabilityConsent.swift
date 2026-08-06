import Foundation

/// 能力授权：同意一次就记住，之后不再逐次询问。
///
/// 原来在线转写、转写整理、生成脑图三件事每跑一次弹一次确认框，而每次弹出的
/// 内容都一模一样。逐次确认对第一次是必要的说明，对第十次只是一次没有信息量的
/// 点击——用户学会的是「看到框就点确认」，那时它已经不再是知情同意了。
///
/// 记的是「这台机器上，这项能力的用户已经知道它会把文字发出去」，不含任何
/// 端点、模型、内容或凭据。发到**哪里**由另一套记录管（`DataDestinationConsentStore`），
/// 换服务商时仍然会告知一次。
///
/// 撤销入口在设置 ▸ 生成偏好，`revokeAll()` 一次清空。
enum CapabilityConsent: String, CaseIterable, Sendable {
  /// 把视频音频分片发到在线转写服务。
  case onlineTranscription
  /// 把转写文字发给聊天模型修标点和分段。
  case transcriptTidy
  /// 把正文发给聊天模型提取脑图结构。
  case mindMap

  private static let storageKey = "com.syc.linkdigest.capabilityConsents.v1"

  static func isGranted(_ capability: CapabilityConsent, defaults: UserDefaults = .standard) -> Bool {
    granted(defaults: defaults).contains(capability.rawValue)
  }

  static func grant(_ capability: CapabilityConsent, defaults: UserDefaults = .standard) {
    var values = granted(defaults: defaults)
    guard !values.contains(capability.rawValue) else { return }
    values.insert(capability.rawValue)
    defaults.set(Array(values).sorted(), forKey: storageKey)
  }

  static func revokeAll(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: storageKey)
  }

  static func grantedCount(defaults: UserDefaults = .standard) -> Int {
    granted(defaults: defaults).count
  }

  /// 读不出来时当作「没授权」——失败方向必须是多问一次，而不是默默发出去。
  private static func granted(defaults: UserDefaults) -> Set<String> {
    Set((defaults.array(forKey: storageKey) as? [String]) ?? [])
  }
}
