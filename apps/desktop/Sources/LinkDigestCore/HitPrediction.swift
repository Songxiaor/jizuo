import Foundation

/// 爆款实验室的一次盲预测。
///
/// **它不是预测模型,是校准循环**:发布前写下预测(不看结果),
/// 几天后拿真实数据对照,偏差本身就是信号。
///
/// 盲预测的价值不在于准。准不准取决于平台推荐、发布时间、运气;
/// 而「我以为会爆的那些为什么没爆」是能学的——前提是预测在看到结果
/// **之前**就已经落定,而且之后不能改。一旦能改,人一定会不自觉地
/// 往结果的方向修,然后得出「我判断挺准的」这个毫无价值的结论。
public struct HitPrediction: Sendable, Equatable, Identifiable {
  /// 量级档位。
  ///
  /// 用档位不用具体数字:写「大概 8000 阅读」是假精度——没人能把
  /// 阅读量估到千位,而假精度会让偏差计算变成噪声比较。
  /// 档位只问一件事:数量级对不对。
  public enum Tier: String, Sendable, Equatable, CaseIterable, Comparable {
    case quiet      // 没什么人看
    case modest     // 有人看
    case good       // 传开了
    case hit        // 爆了

    public var displayName: String {
      switch self {
      case .quiet: "没什么人看"
      case .modest: "有人看"
      case .good: "传开了"
      case .hit: "爆了"
      }
    }

    /// 相邻档位之间大约差一个数量级。具体数字由用户自己的历史决定,
    /// 所以这里只给一个参考,不写死阈值。
    public var hint: String {
      switch self {
      case .quiet: "比平时差"
      case .modest: "跟平时差不多"
      case .good: "明显比平时好"
      case .hit: "远超平时"
      }
    }

    var rank: Int {
      switch self {
      case .quiet: 0
      case .modest: 1
      case .good: 2
      case .hit: 3
      }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rank < rhs.rank }
  }

  public let id: UUID
  public let pieceID: PieceID
  /// 预测的量级。
  public let predicted: Tier
  /// 为什么这么预测。
  ///
  /// 这一栏比预测本身值钱。三天后回头看,「我以为标题够反常」和
  /// 「我以为这个话题正热」是两种完全不同的误判,而只看档位分不出来。
  public let reasoning: String
  public let predictedAtMilliseconds: Int64
  /// 实际的量级。还没录入时是 nil。
  public var actual: Tier?
  public var actualAtMilliseconds: Int64?
  /// 复盘。录入实际结果时写的。
  public var review: String

  public init(
    id: UUID = UUID(),
    pieceID: PieceID,
    predicted: Tier,
    reasoning: String,
    predictedAtMilliseconds: Int64,
    actual: Tier? = nil,
    actualAtMilliseconds: Int64? = nil,
    review: String = ""
  ) {
    self.id = id
    self.pieceID = pieceID
    self.predicted = predicted
    self.reasoning = reasoning
    self.predictedAtMilliseconds = predictedAtMilliseconds
    self.actual = actual
    self.actualAtMilliseconds = actualAtMilliseconds
    self.review = review
  }

  public var isSettled: Bool { actual != nil }

  /// 差了几档。正数表示实际比预测好,负数表示高估了。
  public var drift: Int? {
    guard let actual else { return nil }
    return actual.rank - predicted.rank
  }

  /// 猜中了。
  public var isAccurate: Bool { drift == 0 }
}

/// 一批预测的校准情况。
///
/// 这是实验室真正的产出。单看一次预测什么都说明不了——爆没爆很大程度
/// 上是运气;而十次里有七次高估,那是一个关于你自己的稳定事实。
public struct HitCalibration: Sendable, Equatable {
  public let settledCount: Int
  public let accurateCount: Int
  /// 高估的次数(以为会好,结果没有)。
  public let overestimatedCount: Int
  public let underestimatedCount: Int

  public init(predictions: [HitPrediction]) {
    let settled = predictions.filter(\.isSettled)
    settledCount = settled.count
    accurateCount = settled.filter(\.isAccurate).count
    overestimatedCount = settled.filter { ($0.drift ?? 0) < 0 }.count
    underestimatedCount = settled.filter { ($0.drift ?? 0) > 0 }.count
  }

  /// 攒够这么多次才值得下结论。
  ///
  /// 少于这个数看到的「规律」多半是运气。给一个数字而不是直接显示
  /// 「3/5 准」,是因为后者会让人立刻开始据此调整——而那是在拿噪声当信号。
  public static let minimumForConclusion = 8

  public var hasEnoughData: Bool { settledCount >= Self.minimumForConclusion }

  /// 一句话说清这批预测的偏向。数据不够时明确说不够,不给似是而非的结论。
  public var summary: String {
    guard settledCount > 0 else { return "还没有已经出结果的预测。" }
    guard hasEnoughData else {
      return "已经有 \(settledCount) 次结果，攒够 \(Self.minimumForConclusion) 次再看倾向。"
    }
    if overestimatedCount > accurateCount, overestimatedCount > underestimatedCount {
      return "\(settledCount) 次里高估了 \(overestimatedCount) 次：你觉得会传开的，多数没有。"
    }
    if underestimatedCount > accurateCount, underestimatedCount > overestimatedCount {
      return "\(settledCount) 次里低估了 \(underestimatedCount) 次：你自己看不上的，反而传开了。"
    }
    return "\(settledCount) 次里猜中 \(accurateCount) 次，没有明显的系统性偏向。"
  }
}
