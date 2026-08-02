import Foundation

/// 「把这几份素材变成一篇初稿」的提示词。
///
/// 单独成型而不是散在调用点,因为它是**这个功能的产品定义**:
/// 同样的素材、同样的模型,提示词决定了产出是一篇有观点的稿子,
/// 还是几段素材的转述拼接。
public enum DraftPrompt {
  /// 一份素材在提示词里的样子。
  public struct Material: Sendable, Equatable {
    public let title: String
    public let source: String
    public let body: String

    public init(title: String, source: String, body: String) {
      self.title = title
      self.source = source
      self.body = body
    }
  }

  /// 单份素材截断到这个长度。
  ///
  /// 不截断的话,几份长文就能把上下文吃满,而模型真正需要的是每份素材的
  /// 论点和证据,不是逐字全文。留 3000 字对一篇公众号长文来说够了。
  public static let materialCharacterLimit = 3000

  public static func build(
    spark: String,
    materials: [Material],
    voice: String? = nil,
    targetLength: Int = 1500
  ) -> String {
    var lines: [String] = []

    lines.append("""
    你是这个人的写作搭档。基于下面的灵感和素材,写一篇初稿。

    ## 灵感(这篇要说的事)
    \(spark)
    """)

    if materials.isEmpty {
      lines.append("""

      ## 素材
      (还没有素材)

      没有素材时不要编造事实、数据或引述。就着灵感本身把想法展开,
      需要例子的地方留一行「[这里需要一个例子]」,由作者补。
      """)
    } else {
      lines.append("\n## 素材(共 \(materials.count) 份)")
      for (index, material) in materials.enumerated() {
        let body = material.body.count > materialCharacterLimit
          ? String(material.body.prefix(materialCharacterLimit)) + "…(已截断)"
          : material.body
        lines.append("""

        ### 素材 \(index + 1)｜\(material.title)
        来源:\(material.source)

        \(body)
        """)
      }
    }

    if let voice, !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("\n## 我的表达方式\n\(voice)")
    }

    lines.append("""

    ## 要求
    - 目标 \(targetLength) 字左右
    - 先给结论或一个反直觉的判断,再用素材里的事实支撑
    - **只能用素材里出现过的事实、数据和引述**。素材里没有的不要编
    - 至少让两份素材发生关系,而不是逐份转述——单份素材的复述没有增量
    - 用 Markdown:`##` 分节,该列举的地方用列表
    - 直接输出正文,不要写「好的」「以下是」这类前后缀,也不要解释你怎么写的
    """)

    return lines.joined(separator: "\n")
  }
}
