import Foundation
import LinkDigestCore

/// 设置三页（模型与识别 / 生成偏好 / 外观）的纯展示文案与步骤标题。
///
/// 只放界面用字，不碰偏好键、保存或网络。集中在一处是为了避免
/// 「总结与翻译」这类标题和独立翻译配置各写一份后互相打架。
enum UISettingsPresentation {
  static let modelServicesCardTitle = "模型服务"
  static let modelServicesSummary = "按服务商分组"
  static let modelServicesDetails = "密钥只存在本机钥匙串"
  /// 2026-10-04 起叫「默认模型」：总结用它，校对、翻译、脑图没单独选时也跟着它，原名只说了四分之一。
  static let summaryAssignmentTitle = "默认模型"
  static let translationAssignmentTitle = "翻译模型"
  static let translationFollowsSummaryHint = "不另选就用上面的默认模型。"
  static let localTranscriptionTitle = "本机转写"
  static let onlineTranscriptionTitle = "在线转写"
  static let tidyAssignmentTitle = "校对模型"
  static let imageRecognitionTitle = "图片识别"

  static let recommendedProvidersTitle = "推荐"
  static let recommendedProvidersSummary = "国内能直接用，注册拿到密钥就行"
  /// 不写人民币数字：价格随时会变，没有一手来源的数字不写进界面（2026-10-01）。
  static let recommendedProvidersCostNote = "按用量付费，用量大致跟文章长短成正比，总结一篇几千字的文章花得很少；具体价格以服务商价格页为准。"
  static let noModelCapabilitiesNote = "不配模型也能用：网页和视频收集、本机转写（用 Mac 自带的语音识别）、按意思搜、导出都不需要模型，也不花钱。"
}

/// 「模型服务」页的推荐服务商（2026-10-01）。
///
/// 只挑国内用户能直接注册、OpenAI 兼容、预设里已有服务地址的几家。链接都是官方
/// 控制台和价格页（2026-10-01 逐个打开核实过），不放第三方教程。
struct RecommendedProvider: Identifiable, Equatable {
  let preset: ProviderPreset
  /// 界面上的名字。硅基流动的预设名是英文 SiliconFlow，这里写国内用户熟悉的叫法。
  let name: String
  /// 一句话：适合谁。
  let audience: String
  /// 官方控制台里创建密钥的页面。
  let keyPageURL: URL
  /// 官方价格页。
  let pricingURL: URL

  var id: String { preset.rawValue }

  static let all: [RecommendedProvider] = [
    RecommendedProvider(
      preset: .deepSeek,
      name: "DeepSeek",
      audience: "中文总结好，官方直连",
      keyPageURL: URL(string: "https://platform.deepseek.com/api_keys")!,
      pricingURL: URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing")!
    ),
    RecommendedProvider(
      preset: .dashScope,
      name: "阿里云百炼",
      audience: "有阿里云账号就能用，含通义千问",
      keyPageURL: URL(string: "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key")!,
      pricingURL: URL(string: "https://help.aliyun.com/zh/model-studio/model-pricing")!
    ),
    RecommendedProvider(
      preset: .siliconFlow,
      name: "硅基流动",
      audience: "一把密钥用多家开源模型",
      keyPageURL: URL(string: "https://cloud.siliconflow.cn/account/ak")!,
      pricingURL: URL(string: "https://siliconflow.cn/pricing")!
    ),
  ]
}
