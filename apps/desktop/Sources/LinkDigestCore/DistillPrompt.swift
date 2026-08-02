import Foundation

/// 「从我的修改里提炼出方法」的提示词。
///
/// 原料是 `DraftRevisionPair`:AI 写成这样、我改成了那样。两者的差异
/// 就是「我和它的分歧」,而反复出现的分歧才是方法。
///
/// 这是判断沉淀真正兑现价值的地方——在此之前那张表只是在攒数据。
public enum DistillPrompt {
  /// 一对差异在提示词里的样子。
  public struct Pair: Sendable, Equatable {
    public let generated: String
    public let revised: String

    public init(generated: String, revised: String) {
      self.generated = generated
      self.revised = revised
    }
  }

  /// 每一版截断到这个长度。
  ///
  /// 提炼要的是「哪里改了」,不需要读完整篇。两版各放全文时,
  /// 五六对就能把上下文吃满,而模型真正该做的是横向对比。
  public static let versionCharacterLimit = 1500

  /// 少于这么多对不值得跑。
  ///
  /// 一两对里看到的「规律」多半是巧合。让模型从两对里总结,
  /// 它一定会给出五条听起来很像回事的规则——而那些规则是编的。
  public static let minimumPairs = 3

  public static func build(pairs: [Pair], existing: [String] = []) -> String {
    var lines: [String] = []

    lines.append("""
    下面是几组对照:每组的第一版是 AI 写的,第二版是我改完的。
    找出**反复出现**的差异,写成我可以复用的写法。
    """)

    for (index, pair) in pairs.enumerated() {
      lines.append("""

      ## 第 \(index + 1) 组

      ### AI 写的
      \(truncate(pair.generated))

      ### 我改成的
      \(truncate(pair.revised))
      """)
    }

    if !existing.isEmpty {
      lines.append("""

      ## 我已经有的方法
      \(existing.map { "- \($0)" }.joined(separator: "\n"))

      不要重复这些。
      """)
    }

    lines.append("""

    ## 要求
    - **只写在多组里都出现的差异**。只出现一次的是这一篇的特殊情况,不是方法
    - 每条必须是一个**能照着做的动作**,不是对结果的评价
      ✓「每段控制在三句以内,超了就拆开」
      ✗「要写得更简洁」——这种不许写
    - 说清在哪一步做:开头、每段、结尾、还是整篇
    - 最多 3 条。找不到就少写几条,一条都没有就直说「没看出反复出现的差异」
    - 一行一条,不要编号,不要解释,不要写任何别的话
    """)

    return lines.joined(separator: "\n")
  }

  private static func truncate(_ text: String) -> String {
    text.count > versionCharacterLimit
      ? String(text.prefix(versionCharacterLimit)) + "…(已截断)"
      : text
  }

  /// 从产出里取出候选方法。
  ///
  /// 只做拆行和去装饰。真正的门槛在 `MethodAdmission`——那道门是确定性的,
  /// 而这里的产出来自模型,不能让它自己判自己合不合格。
  public static func parse(_ text: String) -> [String] {
    text
      .split(separator: "\n")
      .map { line in
        line
          .trimmingCharacters(in: .whitespaces)
          // 去掉列表符号和编号:`- `、`1. `、`1、`
          .replacingOccurrences(
            of: #"^[-*•]\s*|^\d+[.、)]\s*"#, with: "", options: .regularExpression
          )
          .replacingOccurrences(of: "*", with: "")
          .trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }
}
