import Foundation

/// 给选题板取素材的规格。
///
/// 方案里那条分界线:**取数是确定性的,加工才是模型的活**。
/// 这个类型只描述「取哪些」,不掺任何语义判断——判断留给模型,
/// 因为一旦把「哪些素材有意思」也交给模型,它就得先读完整个素材库。
public struct TopicRecall: Sendable, Equatable {
  /// 一路召回。
  public struct Lane: Sendable, Equatable {
    public enum Window: Sendable, Equatable {
      /// 最近 N 天之内。
      case recent(days: Int)
      /// N 天以前就没再碰过的。
      case dormant(sinceDays: Int)
    }

    public let name: String
    public let window: Window
    public let limit: Int
    /// 只取带这些标签的。空 = 不限。
    public let tags: [String]

    public init(name: String, window: Window, limit: Int, tags: [String] = []) {
      self.name = name
      self.window = window
      self.limit = limit
      self.tags = tags
    }
  }

  public var lanes: [Lane]

  public init(lanes: [Lane]) { self.lanes = lanes }

  /// 出厂默认:一路新的,一路旧的。
  ///
  /// 两路而不是一路,是因为「碰撞」需要距离。全取最近 7 天,得到的
  /// 只会是同一件事的五个说法;掺进几条你三十天没碰过的东西,
  /// 才可能出现你自己想不到的组合。
  ///
  /// 数字取 10 + 5 不是拍的:一次送进模型的素材超过十几份,它就开始
  /// 逐份转述而不是找关系——那正是这块板最没用的失败方式。
  public static let `default` = TopicRecall(lanes: [
    .init(name: "最近在看的", window: .recent(days: 7), limit: 10),
    .init(name: "翻出来的旧东西", window: .dormant(sinceDays: 30), limit: 5),
  ])

  /// 一路召回该覆盖的时间区间,相对于「现在」。
  ///
  /// 返回毫秒时间戳的闭区间。放在这里算而不是各自在 SQL 里拼,
  /// 是为了让「7 天」到底是不是含今天这种事只有一个答案。
  public static func range(
    for window: Lane.Window, now: Int64
  ) -> (from: Int64, through: Int64) {
    let day: Int64 = 24 * 60 * 60 * 1000
    switch window {
    case let .recent(days):
      return (now - Int64(max(0, days)) * day, now)
    case let .dormant(sinceDays):
      // 上界是「那一天」,没有下界——再老的东西同样算翻出来的旧东西。
      return (0, now - Int64(max(0, sinceDays)) * day)
    }
  }
}

/// 选题候选。
///
/// 被否决的不删。「这类角度他从来不选」这个结论只能从被否决的
/// 东西里得出来,删掉等于把唯一的负样本扔了。
public struct TopicCandidate: Sendable, Equatable, Identifiable {
  public enum Verdict: String, Sendable, Equatable {
    /// 还没看。
    case pending
    /// 选了,已经开成一件创作。
    case taken
    /// 划掉了。
    case declined
  }

  public let id: UUID
  /// 哪一天的。用当地日期的零点毫秒表示,一天一批。
  public let dayStartMilliseconds: Int64
  public let title: String
  /// 一句话说清这条要写什么。
  ///
  /// 必须短。方案里那条风险说得很清楚:如果 5 条都得读完才能选,
  /// AI 只是把「想选题」换成了「审选题」。否决必须扫一眼就能做。
  public let summary: String
  /// 这条是从哪些素材来的。
  public let materialTaskIDs: [TaskID]
  /// 不受偏好约束的那一条。
  ///
  /// 每天留一条。纯按偏好优化的必然结果是规则收敛、回音室成型——
  /// 候选越来越像你已经写过的东西。这一条是故意留的出口。
  public let isOutOfBounds: Bool
  public var verdict: Verdict
  public let createdAtMilliseconds: Int64

  public init(
    id: UUID = UUID(),
    dayStartMilliseconds: Int64,
    title: String,
    summary: String,
    materialTaskIDs: [TaskID] = [],
    isOutOfBounds: Bool = false,
    verdict: Verdict = .pending,
    createdAtMilliseconds: Int64
  ) {
    self.id = id
    self.dayStartMilliseconds = dayStartMilliseconds
    self.title = title
    self.summary = summary
    self.materialTaskIDs = materialTaskIDs
    self.isOutOfBounds = isOutOfBounds
    self.verdict = verdict
    self.createdAtMilliseconds = createdAtMilliseconds
  }

  /// 当地时间那一天的零点。
  ///
  /// 用当地日期而不是 UTC:用户说的「今天的选题」是他日历上的今天。
  public static func dayStart(of date: Date, calendar: Calendar = .current) -> Int64 {
    Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000)
  }
}
