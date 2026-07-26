import Foundation

/// Non-secret starter values for common OpenAI-compatible services. Selecting
/// one only fills an editable Base URL; it never creates, stores, or displays
/// credentials.
public enum ProviderPreset: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
  case openAI
  case deepSeek
  case deepInfra
  case openRouter
  case groq
  case siliconFlow
  case dashScope
  case zhipu
  case stepFun
  case ollama
  case custom

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .deepSeek: "DeepSeek"
    case .deepInfra: "DeepInfra"
    case .openRouter: "OpenRouter"
    case .groq: "Groq"
    case .siliconFlow: "SiliconFlow"
    case .dashScope: "阿里云百炼"
    case .zhipu: "智谱 BigModel"
    case .stepFun: "阶跃星辰"
    case .ollama: "Ollama（本地）"
    case .custom: "自定义"
    }
  }
  public var baseURLTemplate: String {
    switch self {
    case .openAI: "https://api.openai.com/v1"
    case .deepSeek: "https://api.deepseek.com/v1"
    case .deepInfra: "https://api.deepinfra.com/v1/openai"
    case .openRouter: "https://openrouter.ai/api/v1"
    case .groq: "https://api.groq.com/openai/v1"
    case .siliconFlow: "https://api.siliconflow.cn/v1"
    case .dashScope: "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
    case .stepFun: "https://api.stepfun.com/v1"
    case .ollama: "http://127.0.0.1:11434/v1"
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
    case .groq: "G"
    case .siliconFlow: "SF"
    case .dashScope: "Q"
    case .zhipu: "Z"
    case .stepFun: "阶"
    case .ollama: "OL"
    case .custom: "＋"
    }
  }
  public var accentHex: UInt32 {
    switch self {
    case .openAI: 0x111827
    case .deepSeek: 0x4D6BFE
    case .deepInfra: 0x7C3AED
    case .openRouter: 0x6D28D9
    case .groq: 0xF55036
    case .siliconFlow: 0x0F766E
    case .dashScope: 0x615CED
    case .zhipu: 0x2563EB
    case .stepFun: 0x165DFF
    case .ollama: 0x334155
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
  public var documentationHint: String {
    switch self {
    case .ollama: "本地端点：请确认 Ollama 正在运行，并查看其本机 API 文档。"
    case .custom: "请输入 OpenAI-compatible Chat Completions API root。"
    default: "请在 \(displayName) 控制台查看 API 文档与模型可用性。"
    }
  }
}
