import Foundation

/// 模型在界面上的名字：渠道、模型名、厂商三部分（2026-10-09 Syc）。
///
/// - 渠道：从哪条路调用的，只拿来分组。直连服务商就是服务商本身（「DeepSeek」）；
///   Magpie 这类网关再细到它里面的那条订阅（「Magpie · Claude Code」）。
/// - 每一项写「模型名 · 厂商」：「Claude Haiku 5.5 · Anthropic」。
/// - 不分组的地方（提示、工序面板、生成记录）把渠道补在括号里。
///
/// 原来各处各写各的：有的原样显示 `claude/claude-haiku-5-5`，有的只去前缀，有的自动美化成
/// 「Claude Haiku 5 5」（版本号被切开、渠道丢掉）。全 App 只用这一处。
public struct ModelLabel: Equatable, Sendable {
  /// 原始模型 ID，只在悬停、导出里出现。
  public let id: String
  public let name: String
  public let vendor: String?
  public let channel: String

  /// 「模型名 · 厂商」。厂商认不出时只有模型名。
  public var title: String { vendor.map { "\(name) · \($0)" } ?? name }
  /// 不分组的地方：「Claude Haiku 5.5 · Anthropic（Magpie · Claude Code）」。
  public var titleWithChannel: String { channel.isEmpty ? title : "\(title)（\(channel)）" }
  /// 导出：名字之外留下原始 ID，对账、查渠道问题靠它。
  public var exportText: String { name == id ? title : "\(title)（\(id)）" }
}

/// 服务商在模型列表里多给的名字（Magpie 的显示名、渠道名）。读列表时记下，别处查。
public struct ModelNameHints: Equatable, Codable, Sendable {
  public var displayName: String?
  public var channelLabel: String?
  public init(displayName: String? = nil, channelLabel: String? = nil) {
    self.displayName = displayName
    self.channelLabel = channelLabel
  }
}

public enum ModelNaming {
  /// 统一入口。`baseURL` 用来认服务商（渠道的第一段）；`hints` 来自读过的模型列表，没有就自己推。
  public static func label(baseURL: String?, model rawModel: String, hints: ModelNameHints? = nil) -> ModelLabel {
    let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let preset = baseURL.flatMap(preset(forBaseURL:))
    let parts = model.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let prefix = parts.count > 1 ? parts[0].lowercased() : nil
    let leaf = parts.last ?? model

    let name = hints?.displayName?.nonEmpty ?? prettify(leaf)
    let vendor = vendorName(leaf: leaf, prefix: prefix, preset: preset)

    let provider = providerName(baseURL: baseURL, preset: preset)
    var channel = provider
    // 网关：「/」前那段是它里面的订阅或账号，不是厂商。
    if preset == .magpie, let sub = hints?.channelLabel?.nonEmpty ?? prefix.map(magpieChannelName) {
      channel = provider.isEmpty ? sub : "\(provider) · \(sub)"
    }
    return ModelLabel(id: model, name: name, vendor: vendor, channel: channel)
  }

  // MARK: - 服务商

  static func preset(forBaseURL baseURL: String) -> ProviderPreset? {
    ProviderPreset.allCases.first { $0 != .custom && $0.baseURLTemplate == baseURL }
  }

  /// 渠道里的服务商名：去掉「（本地）」这类注解；自定义服务商用域名。
  static func providerName(baseURL: String?, preset: ProviderPreset?) -> String {
    if let preset {
      return preset.displayName.replacingOccurrences(of: "（本地）", with: "")
    }
    guard let baseURL, let host = URL(string: baseURL)?.host else { return "" }
    return host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
  }

  /// Magpie 里服务商 ID → 给人看的名字。读过列表的话用它自己给的（`magpie_label`）。
  static func magpieChannelName(_ id: String) -> String {
    let known: [String: String] = [
      "claude": "Claude Code", "anthropic": "Anthropic", "cursor": "Cursor", "workbuddy": "WorkBuddy",
      "antigravity": "Antigravity", "grok-plugin": "Grok", "mirasim": "Mirasim", "codex": "Codex",
      "chatgpt": "ChatGPT", "copilot": "Copilot", "gemini": "Gemini CLI", "kiro": "Kiro", "openrouter": "OpenRouter",
    ]
    return known[id] ?? id.prefix(1).uppercased() + id.dropFirst()
  }

  // MARK: - 厂商

  /// 模型名属于哪一系 → 厂商。先看模型名，再看 OpenRouter 式的「厂商/模型」前缀，最后看直连的服务商。
  static func vendorName(leaf: String, prefix: String?, preset: ProviderPreset?) -> String? {
    let lower = leaf.lowercased()
    let families: [(String, String)] = [
      ("claude", "Anthropic"), ("gpt", "OpenAI"), ("chatgpt", "OpenAI"), ("o1", "OpenAI"), ("o3", "OpenAI"),
      ("o4", "OpenAI"), ("whisper", "OpenAI"), ("codex", "OpenAI"), ("gemini", "Google"), ("gemma", "Google"),
      ("grok", "xAI"), ("deepseek", "DeepSeek"), ("glm", "智谱"), ("kimi", "月之暗面"), ("moonshot", "月之暗面"),
      ("qwen", "阿里"), ("qwq", "阿里"), ("minimax", "MiniMax"), ("abab", "MiniMax"), ("mimo", "小米"),
      ("doubao", "字节"), ("seed", "字节"), ("hunyuan", "腾讯"), ("ernie", "百度"),
      ("mistral", "Mistral"), ("codestral", "Mistral"), ("llama", "Meta"), ("longcat", "美团"),
      ("step", "阶跃星辰"), ("stepaudio", "阶跃星辰"), ("cogview", "智谱"),
    ]
    if let hit = families.first(where: { lower.hasPrefix($0.0) }) { return hit.1 }
    // 混元的新名字「hy4-…」：只认 hy 后面紧跟数字，免得「hybrid-…」被认成腾讯。
    if lower.hasPrefix("hy"), lower.dropFirst(2).first?.isNumber == true { return "腾讯" }
    let vendorPrefixes: [String: String] = [
      "openai": "OpenAI", "anthropic": "Anthropic", "google": "Google", "x-ai": "xAI", "xai": "xAI",
      "deepseek": "DeepSeek", "z-ai": "智谱", "zhipu": "智谱", "moonshotai": "月之暗面", "qwen": "阿里",
      "minimax": "MiniMax", "mistralai": "Mistral", "meta-llama": "Meta", "xiaomi": "小米", "bytedance": "字节",
      "tencent": "腾讯", "baidu": "百度", "stepfun": "阶跃星辰",
    ]
    if let prefix, let vendor = vendorPrefixes[prefix] { return vendor }
    switch preset {
    case .deepSeek: return "DeepSeek"
    case .zhipu: return "智谱"
    case .stepFun: return "阶跃星辰"
    case .dashScope: return "阿里"
    case .openAI: return "OpenAI"
    default: return nil
    }
  }

  // MARK: - 模型名

  /// 服务商没给显示名时自己推：`claude-haiku-5-5` → 「Claude Haiku 5.5」。
  ///
  /// 原来按「-」切开逐词大写，版本号 5-5 被切成「5 5」。连着的一两位数字是版本号，用点连回去；
  /// 四位数（年份、日期）不连。
  public static func prettify(_ leaf: String) -> String {
    let trimmed = leaf.trimmingCharacters(in: CharacterSet(charactersIn: "~ "))
    let tokens = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
    var words: [String] = []
    for token in tokens {
      if isShortNumber(token), let last = words.last, isVersionTail(last) {
        words[words.count - 1] = last + "." + token
      } else {
        words.append(styled(token))
      }
    }
    return words.isEmpty ? trimmed : words.joined(separator: " ")
  }

  private static func isShortNumber(_ token: String) -> Bool {
    (1...2).contains(token.count) && token.allSatisfy(\.isNumber)
  }

  /// 前一个词以版本号结尾（「5」「4.6」「V4」），且不是四位年份。
  private static func isVersionTail(_ word: String) -> Bool {
    guard let last = word.last, last.isNumber else { return false }
    let digits = word.reversed().prefix { $0.isNumber || $0 == "." }
    return !(digits.count == 4 && word.count == 4)
  }

  private static let casing: [String: String] = [
    "asr": "ASR", "tts": "TTS", "gpt": "GPT", "glm": "GLM", "llm": "LLM", "ocr": "OCR", "api": "API",
    "deepseek": "DeepSeek", "stepaudio": "StepAudio", "minimax": "MiniMax", "mimo": "MiMo", "longcat": "LongCat",
    "xai": "xAI", "ai": "AI", "vl": "VL", "omni": "Omni", "hy": "HY", "qwq": "QwQ",
  ]

  private static func styled(_ token: String) -> String {
    let lower = token.lowercased()
    if let fixed = casing[lower] { return fixed }
    if lower.hasPrefix("v"), lower.dropFirst().first?.isNumber == true { return "V" + lower.dropFirst() }
    guard let first = token.first else { return token }
    return String(first).uppercased() + token.dropFirst()
  }
}

private extension String {
  var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
