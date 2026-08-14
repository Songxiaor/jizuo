import Foundation

/// The structured contract an LLM fills in for a mind-map. The model never
/// emits SVG: geometry and style belong to the local layout engine, so a theme
/// change re-renders for free and layout can never "break" from a bad sample.
public struct MindMapOutline: Codable, Sendable, Equatable {
  public struct Branch: Codable, Sendable, Equatable {
    public let title: String
    public let leaves: [String]

    public init(title: String, leaves: [String]) {
      self.title = title
      self.leaves = leaves
    }
  }

  public let title: String
  public let subtitle: String?
  public let branches: [Branch]
  /// 跨文章可复用的主题标签（领域/实体名），与分支标题（章节结构）严格
  /// 区分：分支标题只对本篇有意义，永远不进标签系统。可选以兼容旧存档。
  public let tags: [String]?

  public init(title: String, subtitle: String?, branches: [Branch], tags: [String]? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.branches = branches
    self.tags = tags
  }
}

public enum MindMapOutlineError: Error, Sendable, Equatable {
  case emptyInput
  case invalidJSON
  case emptyOutline

  public var userMessage: String {
    switch self {
    case .emptyInput: "没有可用于生成脑图的文字。"
    case .invalidJSON: "模型没有返回可用的脑图结构，请重试。"
    case .emptyOutline: "模型返回的脑图结构是空的，请重试。"
    }
  }
}

extension MindMapOutline {
  /// Hard caps keep any model output renderable on one canvas. Extra branches
  /// and leaves are dropped, not errors: a trimmed map beats a failed run.
  public static let maximumBranches = 8
  public static let maximumLeavesPerBranch = 6
  public static let maximumTitleCharacters = 40
  public static let maximumLeafCharacters = 42
  public static let maximumTags = 5
  public static let maximumTagCharacters = 20

  /// Parses model output into a clamped outline. Accepts raw JSON as well as
  /// the ```json fenced form models habitually produce.
  public static func fromModelOutput(_ raw: String) throws -> MindMapOutline {
    let stripped = Self.strippingCodeFence(raw)
    guard let data = stripped.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(MindMapOutline.self, from: data) else {
      throw MindMapOutlineError.invalidJSON
    }
    let clamped = decoded.clamped()
    guard !clamped.title.isEmpty, !clamped.branches.isEmpty else {
      throw MindMapOutlineError.emptyOutline
    }
    return clamped
  }

  public func clamped() -> MindMapOutline {
    let clampedBranches = branches.prefix(Self.maximumBranches).compactMap { branch -> Branch? in
      let title = Self.truncated(branch.title, to: Self.maximumTitleCharacters)
      guard !title.isEmpty else { return nil }
      let leaves = branch.leaves.prefix(Self.maximumLeavesPerBranch)
        .map { Self.truncated($0, to: Self.maximumLeafCharacters) }
        .filter { !$0.isEmpty }
      return Branch(title: title, leaves: leaves)
    }
    let subtitleValue = subtitle.map { Self.truncated($0, to: Self.maximumTitleCharacters) }
    var seenTags = Set<String>()
    let clampedTags = (tags ?? [])
      .map { Self.truncated($0, to: Self.maximumTagCharacters) }
      .filter { !$0.isEmpty && seenTags.insert($0.lowercased()).inserted }
      .prefix(Self.maximumTags)
    return MindMapOutline(
      title: Self.truncated(title, to: Self.maximumTitleCharacters),
      subtitle: subtitleValue?.isEmpty == true ? nil : subtitleValue,
      branches: Array(clampedBranches),
      tags: clampedTags.isEmpty ? nil : Array(clampedTags)
    )
  }

  private static func truncated(_ value: String, to limit: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit - 1)) + "…"
  }

  private static func strippingCodeFence(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
      // Drop the opening fence line (``` or ```json) and a trailing fence.
      if let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
      }
      if let closing = text.range(of: "```", options: .backwards) {
        text = String(text[..<closing.lowerBound])
      }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum MindMapPrompt {
  /// Fixed contract, mirrored by `MindMapOutline.fromModelOutput`. Kept in
  /// code (not user-editable) so parsing and prompting can never drift apart.
  public static let system = """
    你是脑图大纲提取器。把用户给出的内容浓缩成一张脑图的结构，只输出 JSON，不输出任何其它文字。
    JSON 结构：{"title":"中心主题(≤20字)","subtitle":"来源或副标题(可省略)","branches":[{"title":"分支标题(≤12字)","leaves":["要点(每条≤40字)"]}],"tags":["主题标签 3-5 个"]}
    规则：3-6 个分支；每个分支 2-5 条要点；要点必须来自原文事实，禁止编造；保留关键数字与名称；使用原文语言。
    tags 是跨文章可复用的主题词（领域名或实体名，如“Agent 工程”“折叠屏”“Claude Code”），\
    严禁使用分支标题、章节名或“概述/建议/要点”这类结构词。
    """

  public static func system(outputLanguage: String) -> String {
    PromptOutputLanguage.applying(outputLanguage, to: system)
  }
}

/// Provider-agnostic seam so tests can stub extraction without network.
public protocol MindMapExtracting: Sendable {
  /// `model` overrides the profile's chat model when non-empty.
  func extractOutline(
    text: String,
    model: String?,
    outputLanguage: String
  ) async throws -> MindMapExtractionOutcome
}

public extension MindMapExtracting {
  func extractOutline(text: String, model: String?) async throws -> MindMapExtractionOutcome {
    try await extractOutline(
      text: text,
      model: model,
      outputLanguage: ModelPreferences.defaultTargetLanguage
    )
  }
}

public struct MindMapExtractionOutcome: Sendable, Equatable {
  public let outline: MindMapOutline
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?

  public init(
    outline: MindMapOutline,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil
  ) {
    self.outline = outline
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}
