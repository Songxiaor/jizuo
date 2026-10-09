import Foundation

/// Non-secret starter values for common OpenAI-compatible services. Selecting
/// one only fills an editable Base URL; it never creates, stores, or displays
/// credentials.
public enum ProviderPreset: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
  case openAI
  case deepSeek
  case deepInfra
  case openRouter
  /// opencode.ai 的 Go 订阅通道（区别于按量付费的 Zen）。
  case openCodeGo
  /// opencode.ai 的 Zen 按量付费通道。和 Go 是**不同端点**，模型 ID 却大量重合，
  /// 所以必须各自成为一个预设——只留一个的话，用户只能靠手改 Base URL 区分，
  /// 而指错的表现是 401 + `CreditsError`，看起来完全像 Key 出了问题。
  case openCodeZen
  case commandCode
  case groq
  case siliconFlow
  case dashScope
  case zhipu
  case stepFun
  case ollama
  /// 本机的 Magpie 网关：一个地址接上它管着的所有订阅和服务商（2026-10-09 Syc）。
  /// 两种协议都认；本机不校验密钥，可以不填。
  case magpie
  case custom

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .deepSeek: "DeepSeek"
    case .deepInfra: "DeepInfra"
    case .openRouter: "OpenRouter"
    case .openCodeGo: "OpenCode Go"
    case .openCodeZen: "OpenCode Zen"
    case .commandCode: "Command Code"
    case .groq: "Groq"
    case .siliconFlow: "SiliconFlow"
    case .dashScope: "阿里云百炼"
    case .zhipu: "智谱 BigModel"
    case .stepFun: "阶跃星辰"
    case .ollama: "Ollama（本地）"
    case .magpie: "Magpie（本地）"
    case .custom: "其他服务商"
    }
  }
  public var baseURLTemplate: String {
    switch self {
    case .openAI: "https://api.openai.com/v1"
    case .deepSeek: "https://api.deepseek.com/v1"
    case .deepInfra: "https://api.deepinfra.com/v1/openai"
    case .openRouter: "https://openrouter.ai/api/v1"
    // Go 是订阅制，走 `/zen/go/v1`；`/zen/v1` 是按量付费的 Zen，两者是不同端点。
    // 指错时的表现极具误导性：服务端返回 HTTP 401 + `CreditsError`（"余额不足"），
    // 看起来像 Key 有问题或没充值，实际是订阅额度在另一个地址上。
    case .openCodeGo: "https://opencode.ai/zen/go/v1"
    case .openCodeZen: "https://opencode.ai/zen/v1"
    case .commandCode: "https://api.commandcode.ai/provider/v1"
    case .groq: "https://api.groq.com/openai/v1"
    case .siliconFlow: "https://api.siliconflow.cn/v1"
    case .dashScope: "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
    case .stepFun: "https://api.stepfun.com/v1"
    case .ollama: "http://127.0.0.1:11434/v1"
    case .magpie: "http://127.0.0.1:3425/v1"
    case .custom: ""
    }
  }
  /// Short local mark used by the settings card. It avoids remote image loads
  /// and third-party logo licensing while still making providers scannable.
  public var iconMark: String {
    switch self {
    case .openAI: "OA"
    case .deepSeek: "DS"
    case .deepInfra: "DI"
    case .openRouter: "OR"
    case .openCodeGo: "OC"
    case .openCodeZen: "OC"
    case .commandCode: "CC"
    case .groq: "G"
    case .siliconFlow: "SF"
    case .dashScope: "Q"
    case .zhipu: "Z"
    case .stepFun: "阶"
    case .ollama: "OL"
    case .magpie: "MP"
    case .custom: "＋"
    }
  }
  public var accentHex: UInt32 {
    switch self {
    case .openAI: 0x111827
    case .deepSeek: 0x4D6BFE
    case .deepInfra: 0x7C3AED
    case .openRouter: 0x6D28D9
    case .openCodeGo: 0x1F2937
    case .openCodeZen: 0x1F2937
    case .commandCode: 0x1F2937
    case .groq: 0xF55036
    case .siliconFlow: 0x0F766E
    case .dashScope: 0x615CED
    case .zhipu: 0x2563EB
    case .stepFun: 0x165DFF
    case .ollama: 0x334155
    case .magpie: 0x1F2937
    case .custom: 0x64748B
    }
  }
  /// Safe convenience only for providers whose current official API exposes a
  /// compatible speech-to-text route. Users can always replace this model id.
  public var recommendedTranscriptionModel: String? {
    switch self {
    case .openAI: "gpt-4o-mini-transcribe"
    case .openRouter: "openai/whisper-large-v3"
    case .groq: "whisper-large-v3-turbo"
    default: nil
    }
  }
  public var recommendedChatModel: String? {
    switch self {
    case .commandCode: "deepseek/deepseek-v4-flash"
    case .deepSeek: "deepseek-v4-flash"
    case .openRouter: "~openai/gpt-latest"
    case .dashScope: "qwen3.7-plus"
    case .zhipu: "glm-5.2"
    default: nil
    }
  }
  public var supportsOnlineTranscription: Bool {
    [.openAI, .openRouter, .groq].contains(self)
  }
  /// 服务商卡片的副标题：要连的那个域名。
  ///
  /// 原来这里写的是「OpenAI-compatible」，12 家里有 9 家一模一样——在一张
  /// 「选哪家」的界面上，一句人人都有的话等于没有。域名是具体的：能一眼看出
  /// 是官方端点还是国内直连，也能在配错时对得上。
  public var endpointHost: String {
    switch self {
    case .ollama: "本机服务（11434 端口）"
    case .magpie: "本机网关（3425 端口）"
    case .custom: "自己填服务地址"
    default:
      URL(string: baseURLTemplate)?.host ?? baseURLTemplate
    }
  }
  public var documentationHint: String {
    switch self {
    // 对用户说「服务商」「密钥」「服务地址」，不说 Provider / API Key / 端点（2026-10-01）。
    case .commandCode: "支持 GOAT、Pro、Max、Team 套餐额度及按量付费；Go 套餐不支持 API。请在官网 Studio 创建密钥，模型权限与额度以你的套餐为准。不支持在线转写。"
    case .ollama: "本机服务：请确认 Ollama 正在运行。"
    case .magpie: "本机服务：请确认 Magpie 正在运行。密钥可以不填；协议两种都行，OpenAI 兼容能用上 Magpie 里的全部模型。"
    case .custom: "填服务商文档里给的接口地址，一般以 https:// 开头、以 /v1 结尾。"
    default: "模型名和可用额度，请到 \(displayName) 官网的控制台查看。"
    }
  }
}
