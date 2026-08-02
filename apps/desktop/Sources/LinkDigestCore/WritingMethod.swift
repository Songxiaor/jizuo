import Foundation

/// 方法库里的一条。
///
/// 可复用的写法:选题角度、结构模板、常用论证方式。它反哺画板——
/// 启用的方法会进起草和改写的提示词。
///
/// 所以入库标准必须是硬的。方案里那条风险说得很直白:
/// 「要有深度」「要有共鸣」一旦进来,整个库就没人看了。
public struct WritingMethod: Sendable, Equatable, Identifiable {
  public let id: UUID
  /// 方法本身。必须是一个**能照着做的动作**。
  public let body: String
  /// 从哪来。手写的,还是从判断里提炼的。
  public enum Origin: String, Sendable, Equatable {
    case handwritten
    /// 从「AI 写成这样、我改成了那样」的差异里提炼出来的。
    case distilled
  }
  public let origin: Origin
  /// 启用的才进提示词。停用不是删除——试过发现不合适的方法本身也是信息。
  public var isEnabled: Bool
  public let createdAtMilliseconds: Int64

  public init(
    id: UUID = UUID(),
    body: String,
    origin: Origin = .handwritten,
    isEnabled: Bool = true,
    createdAtMilliseconds: Int64
  ) {
    self.id = id
    self.body = body
    self.origin = origin
    self.isEnabled = isEnabled
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

/// 入库自检。
///
/// 这道门是整个方法库有没有用的分界。放进去一条「要写得有深度」,
/// 它会进每一次起草的提示词,而模型对这句话的唯一反应是把形容词加密——
/// 产出更糟,原因还看不出来。
///
/// 检查是**确定性**的,不调模型:一道会随机放行的门等于没有门。
public enum MethodAdmission {
  public enum Rejection: Equatable, Sendable {
    /// 太短,说不清一个动作。
    case tooShort
    /// 只描述了品质,没说该做什么。`term` 是撞上的那个词。
    case qualityWithoutAction(term: String)
    /// 已经有一条一样的了。
    case duplicate

    public var message: String {
      switch self {
      case .tooShort:
        "太短了。一条方法要说清「先做什么、再做什么」。"
      case let .qualityWithoutAction(term):
        "「\(term)」说的是结果好不好，不是该怎么做。改成一个能照着做的动作，比如「先给一个反直觉的数据，再解释为什么反直觉」。"
      case .duplicate:
        "库里已经有一条一样的了。"
      }
    }
  }

  /// 一条方法至少要这么长。
  ///
  /// 不是凑字数:短于这个长度基本不可能同时说清动作和时机。
  /// 「先给结论」四个字看着像动作,但它没说给什么结论、在哪给。
  public static let minimumLength = 12

  /// 这些词描述的是**结果好不好**,不是该怎么做。
  ///
  /// 它们不是被禁止的字眼——「让开头有冲击力，先写最反常的那个数字」
  /// 是合格的,因为后半句给了动作。拦的是只有前半句的那种。
  static let qualityTerms = [
    "有深度", "深度", "有共鸣", "共鸣", "高质量", "质量高", "引人入胜",
    "干货", "有价值", "打动人", "有力量", "精彩", "生动", "接地气",
    "有网感", "抓人", "有意思", "写得好", "更好看", "提升质感",
    "简洁", "流畅", "自然", "清晰", "有逻辑", "专业",
  ]

  /// 有这些词，说明句子里有一个能照着做的动作。
  ///
  /// 判据是「说了顺序或位置」:方法之所以可执行，是因为它指定了
  /// **在哪一步做什么**。光有一个动词不算——「深入分析」也有动词。
  static let actionMarkers = [
    "先", "再", "然后", "开头", "结尾", "第一段", "最后", "之前", "之后",
    "每", "不要", "别", "改成", "换成", "拆", "删", "加上", "举", "用",
  ]

  public static func check(
    _ body: String, against existing: [WritingMethod] = []
  ) -> Rejection? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

    if existing.contains(where: {
      $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
    }) { return .duplicate }

    // 品质检查排在长度前面。
    //
    // 「要写得有深度」两条都撞——它既短又是废话。但对用户有用的理由
    // 只有一个:说的是结果不是做法。告诉他「太短了」，他会写成
    // 「要写得非常有深度，让读者产生强烈共鸣」，然后再被拦一次。
    //
    // 两个条件都满足才拦:只看品质词会拦掉「让开头有冲击力，先写最
    // 反常的那个数字」这种合格的写法。那种误伤比漏放几条更伤——
    // 用户被拦一次说不清为什么，就再也不会往库里加东西了。
    if let term = qualityTerms.first(where: { trimmed.contains($0) }),
       !actionMarkers.contains(where: { trimmed.contains($0) }) {
      return .qualityWithoutAction(term: term)
    }

    guard trimmed.count >= minimumLength else { return .tooShort }
    return nil
  }

  public static func isAdmissible(_ body: String, against existing: [WritingMethod] = []) -> Bool {
    check(body, against: existing) == nil
  }
}
