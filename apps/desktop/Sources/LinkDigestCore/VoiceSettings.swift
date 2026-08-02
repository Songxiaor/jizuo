import Foundation

/// 你的表达方式。
///
/// 这是**你主动定义的加工参数**,不是从你的修改里反推出来的猜测。
///
/// 为什么不做成「AI 从修改里学文风」:那需要大量样本、效果不稳,而且
/// 学错了你没法直接纠正——只能再改一堆稿子等它自己领悟。设置项是
/// 你随时能拧的旋钮,改一次后面所有产出跟着变。
///
/// 判断沉淀(`PieceEvent`)记的是另一回事:它服务于「什么方向值得写」,
/// 不是「用什么语气写」。两者都从你身上来,但绝不合并——混在一起会出现
/// 「因为你上次改短了句子所以这个选题不好」这种荒唐推论。
public struct VoiceSettings: Sendable, Equatable, Codable {
  public enum Tone: String, Sendable, Equatable, Codable, CaseIterable {
    case plain, formal, calm, opinionated
    public var displayName: String {
      switch self {
      case .plain: "口语"
      case .formal: "书面"
      case .calm: "冷静"
      case .opinionated: "有态度"
      }
    }
  }

  public enum SentenceLength: String, Sendable, Equatable, Codable, CaseIterable {
    case short, long, mixed
    public var displayName: String {
      switch self {
      case .short: "短句为主"
      case .long: "长句为主"
      case .mixed: "长短交替"
      }
    }
  }

  public enum Structure: String, Sendable, Equatable, Codable, CaseIterable {
    case conclusionFirst, buildUp
    public var displayName: String {
      switch self {
      case .conclusionFirst: "先给结论"
      case .buildUp: "层层推进"
      }
    }
  }

  public var tone: Tone
  public var sentenceLength: SentenceLength
  public var structure: Structure
  /// 你从来不用的词。一行一个或用顿号分隔。
  public var forbiddenWords: String
  /// 你自己写的几段,作为风格锚点。
  ///
  /// 比前面那些选项有用得多——「短句为主」是描述,而一段真实的文字
  /// 直接展示了你怎么断句、怎么起头、怎么收尾。
  public var sample: String

  public init(
    tone: Tone = .plain,
    sentenceLength: SentenceLength = .mixed,
    structure: Structure = .conclusionFirst,
    forbiddenWords: String = "",
    sample: String = ""
  ) {
    self.tone = tone
    self.sentenceLength = sentenceLength
    self.structure = structure
    self.forbiddenWords = forbiddenWords
    self.sample = sample
  }

  public static let `default` = VoiceSettings()

  /// 转成能塞进提示词的一段话。全是默认值且没填内容时返回 nil——
  /// 那种情况下塞一段「口语、长短交替、先给结论」的废话只会占上下文。
  public var promptText: String? {
    var lines = [
      "- 语气:\(tone.displayName)",
      "- 句子:\(sentenceLength.displayName)",
      "- 结构:\(structure.displayName)",
    ]
    let forbidden = forbiddenWords.trimmingCharacters(in: .whitespacesAndNewlines)
    if !forbidden.isEmpty {
      lines.append("- 从不使用这些词:\(forbidden.replacingOccurrences(of: "\n", with: "、"))")
    }
    let anchor = sample.trimmingCharacters(in: .whitespacesAndNewlines)
    if !anchor.isEmpty {
      lines.append("""

      下面是我自己写的一段,照着这个语感写:

      \(anchor)
      """)
    }
    // 只有默认三项、什么都没填时不值得占上下文。
    //
    // 这里必须比 trim 之后的值,不能直接 `self == .default`:后者比的是
    // 原始字段,用户在输入框里敲了几个回车就不再「等于默认」,于是一段
    // 全是默认值的废话被塞进提示词。
    if forbidden.isEmpty, anchor.isEmpty,
       tone == Self.default.tone,
       sentenceLength == Self.default.sentenceLength,
       structure == Self.default.structure { return nil }
    return lines.joined(separator: "\n")
  }

  // MARK: - 存取

  public static let storageKey = "workbench.voice.settings"

  public func encoded() -> String {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  public static func decoded(from raw: String) -> VoiceSettings {
    guard let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(VoiceSettings.self, from: data)
    else { return .default }
    return value
  }
}
