import Foundation

/// 「AI 整理标签」（2026-11 第二批）：一次模型调用，产出合并方案和建议的常用标签表。
///
/// 发给模型的只有**标签名和使用次数**，不含任何资料正文。模型返回的内容不可信：
/// 解析失败给大白话；方案里不存在的标签名丢弃；保留标签（系统标记、素材类型、
/// 「真人口播」）即使模型返回了也在这里过滤掉。方案只是预览，用户逐组确认后
/// 才会经现有的 `mergeTags` 执行。
public struct TagTidyPlan: Sendable, Equatable {
  public struct Merge: Sendable, Equatable, Identifiable {
    public let id: Int
    /// 合并后的名字（可以是已有标签，也可以是新名字）。用户可改。
    public var target: String
    /// 要并进去的旧标签（显示名）。
    public var sources: [String]
    /// 对应旧标签的使用次数，同序。
    public var sourceCounts: [Int]
    public var isEnabled: Bool

    public init(id: Int, target: String, sources: [String], sourceCounts: [Int], isEnabled: Bool = true) {
      self.id = id
      self.target = target
      self.sources = sources
      self.sourceCounts = sourceCounts
      self.isEnabled = isEnabled
    }

    public var affectedItemCount: Int { sourceCounts.reduce(0, +) }
  }

  public var merges: [Merge]
  /// 建议的常用标签表（显示名）。
  public var frequent: [String]

  public init(merges: [Merge], frequent: [String]) {
    self.merges = merges
    self.frequent = frequent
  }

  public var isEmpty: Bool { merges.isEmpty && frequent.isEmpty }

  /// 用户确认后真正要执行的合并：只含勾选的组，名字去空白，目标是保留标签的组整组丢掉。
  public func enabledMerges() -> [(sources: [String], target: String)] {
    merges.compactMap { merge in
      guard merge.isEnabled,
            let target = HistoryTagNormalizer.normalized(merge.target),
            !MaterialCatalog.protectedTagNormalizedNames.contains(target.normalizedName) else { return nil }
      let sources = merge.sources.compactMap { HistoryTagNormalizer.normalized($0)?.normalizedName }
        .filter { !MaterialCatalog.protectedTagNormalizedNames.contains($0) }
      guard !sources.isEmpty else { return nil }
      return (sources, target.name)
    }
  }
}

extension TagTidyPlan {
  /// 常用表里的名字按「完整合并链」解析成最终名字。
  ///
  /// 只看勾选的组：旧标签 → 该组的目标名；目标被用户改名的（`originalTargets[id]` 与现在不同）
  /// 原名 → 现名。链可以多跳（A 并进 B，B 又在另一组并进 C，最终是 C）；有环时在第一次回到
  /// 已走过的名字处停止。取消勾选的组既不改名也不转移，名字原样保留。
  public func resolvedFrequent(originalTargets: [Int: String]) -> [String] {
    var step: [String: String] = [:]   // 归一化名 → 下一跳显示名
    for merge in merges where merge.isEnabled {
      guard let target = HistoryTagNormalizer.normalized(merge.target) else { continue }
      for source in merge.sources {
        if let key = HistoryTagNormalizer.normalized(source)?.normalizedName, key != target.normalizedName {
          step[key] = target.name
        }
      }
      if let original = originalTargets[merge.id].flatMap(HistoryTagNormalizer.normalized),
         original.normalizedName != target.normalizedName, step[original.normalizedName] == nil {
        step[original.normalizedName] = target.name
      }
    }
    return frequent.map { name in
      var current = name
      var visited = Set<String>()
      while let key = HistoryTagNormalizer.normalized(current)?.normalizedName,
            visited.insert(key).inserted, let next = step[key] {
        current = next
      }
      return current
    }
  }
}

public enum TagTidyError: Error, Sendable, Equatable {
  case noTags
  case invalidResponse
  case emptyPlan
  case backupFailed
  case notAllowed

  public var userMessage: String {
    switch self {
    case .noTags: "还没有可整理的标签。"
    case .invalidResponse: "模型这次返回的内容没法读懂，没有做任何修改。可以再试一次，或换个模型。"
    case .emptyPlan: "模型觉得现有标签不需要合并，也没有给出常用标签建议。"
    case .backupFailed: "整理前的数据备份没成功，所以没有执行任何修改。请检查磁盘空间后重试。"
    case .notAllowed: "当前是只读状态，不能整理标签。"
    }
  }
}

public enum TagTidyPrompt {
  /// 最多把这么多个标签发给模型。375 个标签约 3 千 token；再多的长尾对合并帮助很小。
  public static let maximumTagsSent = 800
  /// 建议的常用标签表条数上限（产品要求「几十个」）。
  public static let maximumFrequentSuggestions = 60

  public static let system = """
    你是标签整理助手。下面是用户资料库里的全部标签，每行「标签名<TAB>使用次数」。只根据标签名和次数判断，不要编造不在列表里的旧标签。
    任务：
    1. merges：找出意思相同或高度重叠的标签（如“AI工具”“人工智能工具”“AI 工具”），给出合并方案。每组 target 是合并后的名字（优先用组里已有的、更常用的写法），sources 是要并进去的旧标签（必须原样照抄列表里的名字，且不含 target 本身）。一个旧标签只能出现在一组里。只合并你有把握是同一个意思的，拿不准就不合。
    2. frequent：建议一份“常用标签表”，30-60 个，覆盖用户最常见的主题，名字短而通用；优先用使用次数高的标签和 merges 的 target，不要放只出现一次的冷门词。
    只输出 JSON，不要解释：{"merges":[{"target":"AI 工具","sources":["AI工具","人工智能工具"]}],"frequent":["AI 工具","Claude Code"]}
    """

  /// 用户消息：标签名和次数，按次数降序。保留标签不发。
  public static func userContent(tags: [HistoryNavigationTag]) -> String {
    eligible(tags).prefix(maximumTagsSent).map { "\($0.tag.name)\t\($0.count)" }.joined(separator: "\n")
  }

  static func eligible(_ tags: [HistoryNavigationTag]) -> [HistoryNavigationTag] {
    tags
      .filter { $0.count > 0 && !MaterialCatalog.protectedTagNormalizedNames.contains($0.tag.normalizedName) }
      .sorted { $0.count == $1.count ? $0.tag.name < $1.tag.name : $0.count > $1.count }
  }

  /// 解析模型输出并按真实标签库校验。`tags` 是发出去的那份标签（含次数）。
  public static func parse(_ raw: String, tags: [HistoryNavigationTag]) throws -> TagTidyPlan {
    guard let object = decodeObject(raw) else { throw TagTidyError.invalidResponse }
    let known: [String: HistoryNavigationTag] = Dictionary(
      eligible(tags).map { ($0.tag.normalizedName, $0) }, uniquingKeysWith: { first, _ in first }
    )
    var used = Set<String>()
    var merges: [TagTidyPlan.Merge] = []
    var redirect: [String: String] = [:]   // 被并走的旧标签 → 新名字

    let rawMerges = (object["merges"] as? [Any]) ?? []
    for case let entry as [String: Any] in rawMerges {
      guard let targetRaw = entry["target"] as? String,
            let target = HistoryTagNormalizer.normalized(targetRaw),
            !MaterialCatalog.protectedTagNormalizedNames.contains(target.normalizedName) else { continue }
      var sources: [HistoryNavigationTag] = []
      for case let name as String in (entry["sources"] as? [Any]) ?? [] {
        guard let normalized = HistoryTagNormalizer.normalized(name)?.normalizedName,
              let tag = known[normalized],                 // 方案里不存在的标签名：丢弃
              normalized != target.normalizedName,
              used.insert(normalized).inserted else { continue }
        sources.append(tag)
      }
      guard !sources.isEmpty else { continue }
      sources.forEach { redirect[$0.tag.normalizedName] = target.name }
      merges.append(.init(
        id: merges.count, target: target.name,
        sources: sources.map(\.tag.name), sourceCounts: sources.map(\.count)
      ))
    }

    // 常用表：只收库里真有的标签或合并目标；被并走的旧名换成新名；去重；截断。
    let mergeTargets = Set(merges.compactMap { HistoryTagNormalizer.normalized($0.target)?.normalizedName })
    var seen = Set<String>()
    var frequent: [String] = []
    for case let name as String in (object["frequent"] as? [Any]) ?? [] {
      guard let tag = HistoryTagNormalizer.normalized(name) else { continue }
      var display = tag.name
      var key = tag.normalizedName
      if let moved = redirect[key], let movedTag = HistoryTagNormalizer.normalized(moved) {
        display = movedTag.name; key = movedTag.normalizedName
      }
      guard !MaterialCatalog.protectedTagNormalizedNames.contains(key),
            known[key] != nil || mergeTargets.contains(key),
            seen.insert(key).inserted else { continue }
      frequent.append(known[key]?.tag.name ?? display)
      if frequent.count >= maximumFrequentSuggestions { break }
    }

    let plan = TagTidyPlan(merges: merges, frequent: frequent)
    guard !plan.isEmpty else { throw TagTidyError.emptyPlan }
    return plan
  }

  /// 容忍 ```json 围栏和前后多余文字：取第一个 `{` 到最后一个 `}`。
  static func decodeObject(_ raw: String) -> [String: Any]? {
    guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
    let slice = String(raw[start ... end])
    return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
  }
}

/// 一次整理的模型调用接口：测试里换成模拟实现，不联网。
public protocol TagTidying: Sendable {
  func proposePlan(tags: [HistoryNavigationTag]) async throws -> TagTidyOutcome
}

public struct TagTidyOutcome: Sendable, Equatable {
  public let plan: TagTidyPlan
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  public let model: String?

  public init(
    plan: TagTidyPlan, promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil, model: String? = nil
  ) {
    self.model = model
    self.plan = plan
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}

/// 提示词体量的粗估，用来在发出前给用户算钱、在交付报告里给数字。
/// 中日韩字符按 1 token/字，其余按 0.3 token/字符（英文约 4 字符一个 token，留一点余量）。
public enum PromptSizeEstimator {
  public static func estimatedTokens(_ text: String) -> Int {
    var cjk = 0, other = 0
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x2E80 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF, 0x3000 ... 0x303F: cjk += 1
      default: other += 1
      }
    }
    return cjk + Int((Double(other) * 0.3).rounded(.up))
  }
}
