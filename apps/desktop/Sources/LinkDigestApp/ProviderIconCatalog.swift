import AppKit
import LinkDigestCore

/// Offline provider marks used by the settings list. The release pipelines
/// freeze this directory so a packaged settings screen never needs the network
/// merely to identify a provider.
enum ProviderIconCatalog {
  static let assetDirectory = "ProviderIcons"
  static let displayPointSize: CGFloat = 16

  private static let assetTable: [ProviderPreset: String] = [
    .openAI: "openai",
    .deepSeek: "deepseek",
    .deepInfra: "deepinfra",
    .openRouter: "openrouter",
    .openCodeGo: "opencode",
    .openCodeZen: "opencode",
    .groq: "groq",
    .siliconFlow: "siliconflow",
    .dashScope: "bailian",
    .commandCode: "commandcode",
    .zhipu: "zhipu",
    .stepFun: "stepfun",
    .ollama: "ollama",
    .magpie: "magpie",
  ]

  /// 单色图标（画的是「当前文字色」）：按模板图用，跟着文字色走，深色主题下才看得见。
  private static let templateAssets: Set<String> = [
    "magpie", "anthropic", "cursor", "grok", "xai", "kimi", "githubcopilot", "xiaomimimo", "longcat", "zai", "factory",
  ]

  /// 模型来自哪家 → 图标（2026-10-09 Syc：Magpie 的模型标出上游厂商）。先看服务商 ID（Magpie 的
  /// `owned_by`、模型 ID 里「/」前那段），认不出再看模型名属于哪一系。图标来自 lobehub/lobe-icons（MIT）。
  private static let vendorTable: [String: String] = [
    "anthropic": "anthropic", "claude": "claudecode", "claude-code": "claudecode",
    "cursor": "cursor", "workbuddy": "workbuddy", "antigravity": "antigravity",
    "grok": "grok", "grok-plugin": "grok", "xai": "xai", "x-ai": "xai",
    "openai": "openai", "chatgpt": "openai", "codex": "codex",
    "gemini": "google", "google": "google", "googleai": "google",
    "deepseek": "deepseek", "kimi": "kimi", "moonshot": "kimi", "moonshotai": "kimi",
    "zhipu": "zhipu", "bigmodel": "zhipu", "zai": "zai", "z-ai": "zai",
    "qwen": "qwen", "dashscope": "bailian", "bailian": "bailian", "alibaba": "qwen",
    "minimax": "minimax", "copilot": "githubcopilot", "github-copilot": "githubcopilot",
    "codebuddy": "codebuddy", "kiro": "kiro", "mistral": "mistral", "mistralai": "mistral",
    "doubao": "doubao", "volcengine": "doubao", "bytedance": "doubao",
    "mimo": "xiaomimimo", "xiaomi": "xiaomimimo", "longcat": "longcat", "meituan": "longcat",
    "hunyuan": "hunyuan", "tencent": "hunyuan", "wenxin": "wenxin", "baidu": "wenxin",
    "factory": "factory", "openrouter": "openrouter", "groq": "groq", "ollama": "ollama",
    "siliconflow": "siliconflow", "stepfun": "stepfun", "deepinfra": "deepinfra",
    "opencode": "opencode", "commandcode": "commandcode", "magpie": "magpie",
  ]

  /// 模型名属于哪一系（`gpt-5`、`claude-…`）。服务商 ID 认不出时用。
  private static let familyPrefixes: [(String, String)] = [
    ("claude", "anthropic"), ("gpt", "openai"), ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
    ("gemini", "google"), ("grok", "grok"), ("deepseek", "deepseek"), ("kimi", "kimi"), ("glm", "zhipu"),
    ("qwen", "qwen"), ("minimax", "minimax"), ("mimo", "xiaomimimo"), ("doubao", "doubao"),
    ("hunyuan", "hunyuan"), ("hy", "hunyuan"), ("ernie", "wenxin"), ("mistral", "mistral"), ("longcat", "longcat"),
  ]

  /// 一个模型的厂商图标名。`ownedBy` 优先，其次模型 ID 的「/」前缀，最后看模型名。
  static func vendorAssetName(ownedBy: String?, modelID: String) -> String? {
    let parts = modelID.lowercased().split(separator: "/").map(String.init)
    for key in [ownedBy?.lowercased(), parts.count > 1 ? parts[0] : nil].compactMap({ $0 }) {
      if let name = vendorTable[key] { return name }
    }
    let leaf = parts.last ?? ""
    return familyPrefixes.first { leaf.hasPrefix($0.0) }?.1
  }

  static func vendorImage(ownedBy: String?, modelID: String) -> NSImage? {
    vendorAssetName(ownedBy: ownedBy, modelID: modelID).flatMap(image(named:))
  }

  /// 模型行首的图标：画厂商，和行里写的「模型名 · 厂商」一致；渠道已经是小节标题（2026-10-09 Syc）。
  /// 先看模型名属于哪一系（`cursor/grok-4.7-fast` → Grok），认不出再按服务商 ID、前缀。
  static func makerAssetName(modelID: String) -> String? {
    let leaf = modelID.lowercased().split(separator: "/").last.map(String.init) ?? modelID.lowercased()
    return familyPrefixes.first { leaf.hasPrefix($0.0) }?.1 ?? vendorAssetName(ownedBy: nil, modelID: modelID)
  }

  static func makerImage(modelID: String) -> NSImage? {
    makerAssetName(modelID: modelID).flatMap(image(named:))
  }

  /// This cache is intentionally separate from website/platform icons: provider
  /// rows have a different identity space and may be shown on every settings refresh.
  nonisolated(unsafe) private static let rasterCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  static func assetName(for preset: ProviderPreset) -> String? {
    assetTable[preset]
  }

  static func image(for preset: ProviderPreset) -> NSImage? {
    assetName(for: preset).flatMap(image(named:))
  }

  static func image(named name: String) -> NSImage? {
    if let cached = rasterCache.object(forKey: name as NSString) { return cached }
    guard let root = Bundle.main.resourceURL else { return nil }
    let url = root
      .appendingPathComponent(assetDirectory, isDirectory: true)
      .appendingPathComponent(name + ".svg")
    guard let image = crispenedIcon(from: url) else { return nil }
    image.isTemplate = templateAssets.contains(name)
    rasterCache.setObject(image, forKey: name as NSString)
    return image
  }

  /// Any future or custom endpoint must remain visually identifiable even when
  /// it has no curated brand asset.
  static func fallbackInitial(for providerName: String) -> String {
    let value = normalizedProviderName(providerName)
    guard let first = value.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
    return String(first).uppercased()
  }

  /// 自定义服务商没有品牌资产，名字直接取自 Base URL 的 host，而真实世界的
  /// Base URL 绝大多数长成 `https://api.foo.com/v1`。直接取首字母的结果是十个
  /// 互不相干的自定义服务商全都印着一个「A」，跟之前全都印「自」没差多少。
  ///
  /// 所以先按站点规则归一化（`www.`/`m.` 之类由 `HistoryHostNormalizer` 负责），
  /// 再补剥一层 `api.`：`api.deepinfra.com` → D。只剥带点的 `api.`，
  /// 「Apidog」这类真名开头不受影响。
  private static func normalizedProviderName(_ providerName: String) -> String {
    var value = HistoryHostNormalizer.normalized(providerName)
    if value.hasPrefix("api.") { value.removeFirst("api.".count) }
    return value
  }

  /// Keep provider SVGs on the exact same Retina rasterization path as the
  /// history platform icons, while retaining a provider-specific cache above.
  static func crispenedIcon(from url: URL) -> NSImage? {
    PlatformIconCatalog.crispenedIcon(from: url)
  }
}
