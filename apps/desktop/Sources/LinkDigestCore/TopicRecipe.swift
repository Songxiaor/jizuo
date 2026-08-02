import Foundation

/// 选题板的配方:读哪些素材、怎么问、要什么。
///
/// 存在的理由不是「多给几个选项」,而是**让预置的判断可见**。
/// 「最近 7 天取 10 条」「出 5 条」「最后一条越界」原本写死在代码里,
/// 用户看到的只有五条结果——他没法判断这五条为什么是这五条,
/// 也就没法改进它。看不见的默认值,和不存在的功能差别不大。
///
/// 但预置仍然是预置:不填任何东西也能跑。配置是可选项,不是必经之路——
/// 低代码工具的死法是给一张空白画布让用户自己配。
public struct TopicRecipe: Sendable, Equatable, Codable {
  // MARK: ① 读哪些素材

  /// 最近多少天之内。
  public var recentDays: Int
  /// 这一路取几条。0 = 关掉这一路。
  public var recentLimit: Int
  /// 多少天以上没再碰过的。
  public var dormantSinceDays: Int
  /// 这一路取几条。0 = 关掉这一路。
  public var dormantLimit: Int
  /// 只要带这些标签的。空 = 不限。
  public var tags: [String]
  /// 每份素材在提示词里放多少字。
  public var excerptLimit: Int

  // MARK: ② 怎么问

  /// 用户改过的提示词。nil 或空白 = 用预置那份。
  ///
  /// 存的是「用户的版本」而不是「当前生效的版本」,这样 App 升级时
  /// 预置模板能跟着变,而改过的人不会被悄悄覆盖。
  public var template: String?

  // MARK: ③ 要什么

  /// 出几条。
  public var count: Int
  /// 其中几条标成「越界」。0 = 不要越界候选。
  public var boundaryCount: Int

  public init(
    recentDays: Int = 7,
    recentLimit: Int = 10,
    dormantSinceDays: Int = 30,
    dormantLimit: Int = 5,
    tags: [String] = [],
    excerptLimit: Int = TopicPrompt.excerptCharacterLimit,
    template: String? = nil,
    count: Int = 5,
    boundaryCount: Int = 1
  ) {
    self.recentDays = recentDays
    self.recentLimit = recentLimit
    self.dormantSinceDays = dormantSinceDays
    self.dormantLimit = dormantLimit
    self.tags = tags
    self.excerptLimit = excerptLimit
    self.template = template
    self.count = count
    self.boundaryCount = boundaryCount
  }

  /// 出厂默认:一路新的,一路旧的。
  ///
  /// 两路而不是一路,是因为「碰撞」需要距离。全取最近 7 天,得到的
  /// 只会是同一件事的五个说法;掺进几条三十天没碰过的东西,
  /// 才可能出现自己想不到的组合。
  ///
  /// 10 + 5 不是拍的:一次送进模型的素材超过十几份,它就开始逐份转述
  /// 而不是找关系——那正是这块板最没用的失败方式。
  public static let `default` = TopicRecipe()

  // MARK: - 取数

  /// 折成取数层能用的召回规格。
  ///
  /// 限额为 0 的那一路直接不出现,而不是发一条取 0 条的查询:
  /// 「关掉旧素材那一路」是用户会做的事,它不该在 SQL 里留个空跑的分支。
  public var recall: TopicRecall {
    let clean = sanitized()
    var lanes: [TopicRecall.Lane] = []
    if clean.recentLimit > 0 {
      lanes.append(.init(
        name: "最近在看的",
        window: .recent(days: clean.recentDays),
        limit: clean.recentLimit,
        tags: clean.tags
      ))
    }
    if clean.dormantLimit > 0 {
      lanes.append(.init(
        name: "翻出来的旧东西",
        window: .dormant(sinceDays: clean.dormantSinceDays),
        limit: clean.dormantLimit,
        tags: clean.tags
      ))
    }
    return TopicRecall(lanes: lanes)
  }

  // MARK: - 提示词

  /// 用户是不是改过提示词。
  public var isTemplateCustomized: Bool {
    guard let template else { return false }
    return !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// 当前生效的那份提示词。
  public var effectiveTemplate: String {
    isTemplateCustomized ? (template ?? "") : TopicPrompt.presetTemplate
  }

  // MARK: - 存取

  public static let storageKey = "workbench.topics.recipe"

  public func encoded() -> String {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  public static func decoded(from raw: String) -> TopicRecipe {
    guard let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(TopicRecipe.self, from: data)
    else { return .default }
    return value.sanitized()
  }

  /// 把数值夹回可用范围。
  ///
  /// 界面上是输入框,而输入框里能出现任何东西:0 天、-3 条、一次取
  /// 五百份素材。夹在这里而不是界面里,是因为存下来的值还会被定时触发
  /// 和试跑读到——每个读的地方各夹一次,迟早有一处忘了。
  public func sanitized() -> TopicRecipe {
    var value = self
    value.recentDays = min(365, max(1, recentDays))
    value.recentLimit = min(50, max(0, recentLimit))
    value.dormantSinceDays = min(365, max(1, dormantSinceDays))
    value.dormantLimit = min(50, max(0, dormantLimit))
    value.excerptLimit = min(5000, max(100, excerptLimit))
    value.count = min(20, max(1, count))
    value.boundaryCount = min(value.count, max(0, boundaryCount))
    value.tags = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return value
  }
}
