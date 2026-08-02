import Foundation

/// 「从这些素材里出 N 条选题」的提示词。
///
/// 这块板最容易的失败方式是逐份转述——五条候选其实是五份素材的摘要,
/// 那种东西用户扫一眼就知道没用,但它看起来又「像模像样」。
/// 所以要求里花最多篇幅说的是这件事。
public enum TopicPrompt {
  public struct Material: Sendable, Equatable {
    public let index: Int
    public let title: String
    public let lane: String
    public let excerpt: String

    public init(index: Int, title: String, lane: String, excerpt: String) {
      self.index = index
      self.title = title
      self.lane = lane
      self.excerpt = excerpt
    }
  }

  /// 每份素材在提示词里只放这么多字。
  ///
  /// 比起草(3000)短得多:选题只需要知道每份素材在说什么,不需要细节。
  /// 十几份素材各放 3000 字会把上下文吃满,而模型真正要做的是找关系。
  public static let excerptCharacterLimit = 600

  /// 提示词里能用的变量。
  ///
  /// 列在这里是为了界面上能照着显示——用户改模板时最需要知道的
  /// 就是「有哪些东西可以填进去」,而不是让他从预置文本里反推。
  public enum Placeholder {
    public static let materials = "{素材}"
    public static let materialCount = "{素材份数}"
    public static let count = "{条数}"
    public static let boundaryCount = "{越界条数}"
    public static let recentTopics = "{最近出过的选题}"
    public static let voice = "{我的表达方式}"

    public static let all = [
      (materials, "所有素材的正文摘录，按编号排好"),
      (materialCount, "这次取到几份素材"),
      (count, "要出几条选题"),
      (boundaryCount, "其中几条标成「越界」"),
      (recentTopics, "最近已经出过的选题标题"),
      (voice, "设置里那份「我的表达方式」"),
    ]
  }

  /// 预置的那份提示词。
  ///
  /// 它和用户改过的版本走的是同一条渲染路径——预置不享受任何特权,
  /// 否则「改成我的版本」之后行为会莫名其妙地变。
  public static let presetTemplate = """
  你是这个人的选题搭档。从下面这些素材里,给出 {条数} 条**不同角度**的选题。

  ## 素材(共 {素材份数} 份)
  {素材}

  ## 最近已经出过的选题(不要再出这些角度)
  {最近出过的选题}

  ## 我的表达方式
  {我的表达方式}

  ## 要求
  - **每条选题必须让至少两份素材发生关系**。一份素材的摘要不是选题
  - {条数} 条要是 {条数} 个不同角度,不是同一件事的 {条数} 种说法
  - 其中 {越界条数} 条标成「越界」:不必贴合我的偏好,可以是我平时不会写的角度
  - 只用素材里出现过的事实。素材里没有的不要编
  - 标题一句话说清主张,不要用「浅谈」「探析」这类词
  - 摘要控制在 60 字以内:我要扫一眼就能决定要不要,读不完的选题等于没出

  ## 输出格式
  严格按下面的格式,每条之间空一行,不要写任何别的东西:

  标题: <一句话主张>
  摘要: <60 字以内>
  素材: <用到的素材编号,逗号分隔>
  越界: <是 / 否>
  """

  public static func build(
    materials: [Material],
    count: Int = 5,
    recentTopics: [String] = [],
    voice: String? = nil,
    boundaryCount: Int = 1,
    excerptLimit: Int = excerptCharacterLimit,
    template: String = presetTemplate
  ) -> String {
    render(
      template: template,
      values: [
        Placeholder.materials: materialsBlock(materials, excerptLimit: excerptLimit),
        Placeholder.materialCount: "\(materials.count)",
        Placeholder.count: "\(count)",
        // 0 条越界时给空串,让那一行整行消失——写成「其中 0 条标成越界」
        // 是在让模型处理一条自相矛盾的要求。
        Placeholder.boundaryCount: boundaryCount > 0 ? "\(boundaryCount)" : "",
        // 重复是这块板第二容易的失败方式,而且用户很难一眼看出——
        // 他只会觉得「怎么老是这些」,说不清哪条和上周撞了。
        Placeholder.recentTopics: recentTopics.map { "- \($0)" }.joined(separator: "\n"),
        Placeholder.voice: voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      ]
    )
  }

  private static func materialsBlock(_ materials: [Material], excerptLimit: Int) -> String {
    materials.map { material in
      let excerpt = material.excerpt.count > excerptLimit
        ? String(material.excerpt.prefix(excerptLimit)) + "…"
        : material.excerpt
      return """
      ### \(material.index)｜\(material.title)
      (\(material.lane))

      \(excerpt)
      """
    }.joined(separator: "\n\n")
  }

  /// 把变量填进模板。
  ///
  /// 空值的处理规则只有两条,因为用户要能预测它:
  ///
  /// 1. **占位符的值为空,它所在的那一行整行消失。** 不然「最近已经出过的
  ///    选题」下面会跟着一片空白,模型会当成「一条都没出过」还是「这里
  ///    本该有东西」全看运气。
  /// 2. **一段只剩下标题行,整段消失。** 上一条删完之后,`## 我的表达方式`
  ///    经常会孤零零地留在那里。
  public static func render(template: String, values: [String: String]) -> String {
    let lines = template.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var kept: [String] = []
    for line in lines {
      let used = values.filter { line.contains($0.key) }
      guard !used.contains(where: { $0.value.isEmpty }) else { continue }
      var rendered = line
      for (key, value) in used {
        rendered = rendered.replacingOccurrences(of: key, with: value)
      }
      kept.append(rendered)
    }

    let blocks = kept.joined(separator: "\n").components(separatedBy: "\n\n")
    let surviving = blocks.filter { block in
      let meaningful = block
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !meaningful.isEmpty else { return false }
      return !meaningful.allSatisfy { $0.hasPrefix("#") }
    }
    return surviving.joined(separator: "\n\n")
  }

  /// 一条解析出来的候选。
  public struct Parsed: Sendable, Equatable {
    public let title: String
    public let summary: String
    public let materialIndexes: [Int]
    public let isOutOfBounds: Bool
  }

  /// 从模型的输出里解析候选。
  ///
  /// 宽松解析:少了「素材」或「越界」行就按默认值走,只有标题为空才丢。
  /// 严格解析的代价是模型偶尔多写一句寒暄就整批作废,而用户看到的是
  /// 「今天没出选题」——他不会知道是因为格式差一行。
  public static func parse(_ text: String) -> [Parsed] {
    var results: [Parsed] = []
    var title: String?
    var summary = ""
    var indexes: [Int] = []
    var outOfBounds = false

    func flush() {
      if let title, !title.isEmpty {
        results.append(.init(
          title: title, summary: summary,
          materialIndexes: indexes, isOutOfBounds: outOfBounds
        ))
      }
      title = nil
      summary = ""
      indexes = []
      outOfBounds = false
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard let (key, value) = splitField(line) else { continue }
      switch key {
      case "标题":
        // 新的一条开始了,把上一条收了。
        flush()
        title = value
      case "摘要":
        summary = value
      case "素材":
        indexes = value
          .split(whereSeparator: { !$0.isNumber })
          .compactMap { Int($0) }
      case "越界":
        outOfBounds = value.hasPrefix("是") || value.lowercased().hasPrefix("y")
      default:
        continue
      }
    }
    flush()
    return results
  }

  /// 拆 `键: 值`。同时认全角冒号和 Markdown 的加粗包装。
  ///
  /// 模型很爱把字段名写成 `**标题**:`——认不出来的话整批候选会静默变空。
  private static func splitField(_ line: String) -> (String, String)? {
    let cleaned = line
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "：", with: ":")
      .trimmingCharacters(in: .whitespaces)
      // 列表项也放行:`- 标题: …`
      .drop(while: { $0 == "-" || $0 == " " })
    guard let colon = cleaned.firstIndex(of: ":") else { return nil }
    let key = String(cleaned[cleaned.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    let value = String(cleaned[cleaned.index(after: colon)...])
      .trimmingCharacters(in: .whitespaces)
    return (key, value)
  }
}
