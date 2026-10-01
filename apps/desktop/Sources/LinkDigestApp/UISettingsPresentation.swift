import Foundation
import LinkDigestCore

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

  static let recommendedProvidersTitle = "推荐服务商"
  static let recommendedProvidersSummary = "总结、翻译、校对、脑图要用模型，得先在服务商那里注册、拿一把密钥。下面几家国内能直接用、接口和汲作兼容。"
  /// 不写人民币数字：价格随时会变，没有一手来源的数字不写进界面（2026-10-01）。
  static let recommendedProvidersCostNote = "按用量付费；一篇几千字的文章总结大约用几千 token，具体价格以服务商价格页为准。"
  static let noModelCapabilitiesNote = "不配模型也能用：网页和视频收集、本机转写（Apple 听写）、按意思搜、导出都不需要模型，也不花钱。"
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
      audience: "想要中文总结写得好、直接用官方接口的人。",
      keyPageURL: URL(string: "https://platform.deepseek.com/api_keys")!,
      pricingURL: URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing")!
    ),
    RecommendedProvider(
      preset: .dashScope,
      name: "阿里云百炼",
      audience: "已有阿里云账号的人；通义千问等模型都在这一家。",
      keyPageURL: URL(string: "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key")!,
      pricingURL: URL(string: "https://help.aliyun.com/zh/model-studio/model-pricing")!
    ),
    RecommendedProvider(
      preset: .siliconFlow,
      name: "硅基流动",
      audience: "想多试几种开源模型的人；一把密钥能用 DeepSeek、Qwen 等多家模型。",
      keyPageURL: URL(string: "https://cloud.siliconflow.cn/account/ak")!,
      pricingURL: URL(string: "https://siliconflow.cn/pricing")!
    ),
  ]
}
