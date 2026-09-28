import Foundation

/// 设置三页（模型与识别 / 生成偏好 / 外观）的纯展示文案与步骤标题。
///
/// 只放界面用字，不碰偏好键、保存或网络。集中在一处是为了避免
/// 「总结与翻译」这类标题和独立翻译配置各写一份后互相打架。
enum UISettingsPresentation {
  static let modelServicesCardTitle = "模型服务"
  static let modelServicesSummary = "按服务商归拢；每个模型有自己的服务地址和密钥。"
  static let modelServicesDetails = "密钥只保存在本机钥匙串，不写进历史库、导出文件或日志。"
  static let summaryAssignmentTitle = "总结模型"
  static let translationAssignmentTitle = "翻译模型"
  static let translationFollowsSummaryHint = "不另选就与总结共用同一个模型。"
  static let localTranscriptionTitle = "本地转写"
  static let onlineTranscriptionTitle = "在线备用转写"
  static let tidyAssignmentTitle = "校对模型"
  static let imageRecognitionTitle = "图片识别"
}
