import Foundation

/// 「按我的表达方式把这稿子重写一遍」的提示词。
///
/// 第二块画板。和起草(`DraftPrompt`)的关键差别:这里**没有素材**,
/// 输入就是稿子本身。所以约束的方向反过来——起草要防的是「凭空编」,
/// 改写要防的是「改着改着把事实改没了」。
public enum RewritePrompt {
  /// 改写的力度。
  ///
  /// 分两档而不是一个滑块:用户能说清「只想顺一下」和「整段重来」的区别,
  /// 但说不清 0.6 和 0.7 有什么不同。
  public enum Intensity: String, Sendable, Equatable, CaseIterable {
    /// 保留结构和句子,只调语感。
    case polish
    /// 允许重新组织段落顺序和表达。
    case rewrite

    public var displayName: String {
      switch self {
      case .polish: "顺一遍"
      case .rewrite: "重写"
      }
    }
  }

  /// 超过这个长度就不整篇送了。
  ///
  /// 一次改写要把全文读进去再吐出来,太长的稿子会被模型中途放弃或截断,
  /// 结果是「改完短了一半」——那比不改还糟。
  public static let bodyCharacterLimit = 8000

  public static func build(
    body: String,
    voice: String?,
    methods: [String] = [],
    intensity: Intensity = .polish,
    outputLanguage: String = ModelPreferences.defaultTargetLanguage
  ) -> String {
    var lines: [String] = []

    lines.append("""
    把下面这篇稿子按我的表达方式重写一遍。

    ## 稿子
    \(body.count > bodyCharacterLimit
      ? String(body.prefix(bodyCharacterLimit)) + "…(已截断)"
      : body)
    """)

    if let voice, !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("\n## 我的表达方式\n\(voice)")
    } else {
      // 没设置过表达方式时得说清楚照着什么改,否则模型只会按它自己的
      // 默认审美「优化」——那正是用户最不想要的东西。
      lines.append("""

      ## 我的表达方式
      (还没设置。那就保持稿子原有的语感,只处理明显别扭的地方。)
      """)
    }

    if !methods.isEmpty {
      lines.append("""

      ## 我常用的写法
      \(methods.map { "- \($0)" }.joined(separator: "\n"))
      """)
    }

    switch intensity {
    case .polish:
      lines.append("""

      ## 要求
      - **不要改动事实、数据、引述、人名和数字**
      - 保留原有的段落顺序和小标题
      - 只调整措辞和断句,让它读起来像我写的
      - 篇幅和原文接近,不要扩写也不要删节
      - 保留原有的 Markdown 结构
      - 直接输出改写后的全文,不要写「好的」「以下是」,也不要解释你改了什么
      """)
    case .rewrite:
      lines.append("""

      ## 要求
      - **不要改动事实、数据、引述、人名和数字**。原文没有的不要加
      - 可以重新组织段落顺序,让论证更顺
      - 按我的表达方式重写措辞
      - 篇幅和原文接近,不要扩写
      - 用 Markdown:`##` 分节,该列举的地方用列表
      - 直接输出改写后的全文,不要写「好的」「以下是」,也不要解释你改了什么
      """)
    }

    return PromptOutputLanguage.applying(outputLanguage, to: lines.joined(separator: "\n"))
  }
}
