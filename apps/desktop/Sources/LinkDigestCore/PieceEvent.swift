import Foundation

/// 一件创作身上发生过的事。
///
/// 这张表是整个系统里**唯一带着你个人信息**的东西。素材是别人写的,
/// AI 的产出是模型给的,只有「你选了哪个、你把它改成了什么」是你的。
///
/// 方案里那句「越早越值钱,而且补不回来」说的就是它:今天不记,
/// 以后再想让 skill 变得像你,没有任何燃料可用。
public struct PieceEvent: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    /// AI 产出了一版。`detail` 是它写的全文。
    case drafted
    /// 你在 AI 那版之上改了。`detail` 是你改完的全文。
    ///
    /// 和 `drafted` 配对才有意义——两者的差异就是「你和它的分歧」,
    /// 那是提炼「他总是把长句拆短」这类规则的唯一原料。
    case revised
    /// 阶段变化。`detail` 是新阶段。
    case staged
    /// 素材加入或移出。`detail` 是素材标题。
    case materialAdded
    case materialRemoved
    /// 完成。
    case finished
  }

  /// `detail` 落库时的上限。
  ///
  /// `drafted` 和 `revised` 存的是**整篇稿子**,而写一次东西会产生一条起草
  /// 加若干条修订。不封顶的话,这张表会以「稿子长度 × 保存次数」的速度长,
  /// 而它是本机数据库里唯一按这个量级增长的表。
  ///
  /// 取 20000 而不是更小:提炼只读前 1500 字(`DistillPrompt.versionCharacterLimit`),
  /// 但这条记录还要供人回看「我当时改成了什么」,截在能装下绝大多数整篇稿子的
  /// 地方,才不会让回看看到半句话。
  public static let detailCharacterLimit = 20_000

  public let id: UUID
  public let pieceID: PieceID
  public let kind: Kind
  public let detail: String
  public let createdAtMilliseconds: Int64

  public init(
    id: UUID = UUID(),
    pieceID: PieceID,
    kind: Kind,
    detail: String,
    createdAtMilliseconds: Int64
  ) {
    self.id = id
    self.pieceID = pieceID
    self.kind = kind
    self.detail = detail
    self.createdAtMilliseconds = createdAtMilliseconds
  }
}

/// 「AI 写成这样、我改成了那样」的一对。
///
/// 这是判断沉淀真正要输出的东西。单看 AI 那版不知道你的偏好,
/// 单看你的终稿也分不清哪些是你改的、哪些本来就对。
public struct DraftRevisionPair: Sendable, Equatable {
  public let generated: String
  public let revised: String
  public let generatedAtMilliseconds: Int64
  public let revisedAtMilliseconds: Int64

  public init(
    generated: String, revised: String,
    generatedAtMilliseconds: Int64, revisedAtMilliseconds: Int64
  ) {
    self.generated = generated
    self.revised = revised
    self.generatedAtMilliseconds = generatedAtMilliseconds
    self.revisedAtMilliseconds = revisedAtMilliseconds
  }

  /// 改动幅度,0 到 1。
  ///
  /// 用字符级的粗略比例而不是精确 diff:这个数字的用途是
  /// 「筛出值得细看的那几篇」,不是展示逐字差异。几乎没改的不用看,
  /// 大改的才说明 AI 那版偏得远。
  public var changeRatio: Double {
    guard !generated.isEmpty else { return revised.isEmpty ? 0 : 1 }
    let a = Array(generated), b = Array(revised)
    // 从两端各自吃掉相同的部分,中间剩下的就是实际改动。
    var head = 0
    while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
    var tail = 0
    while tail < a.count - head, tail < b.count - head,
          a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
    let changed = max(a.count, b.count) - head - tail
    return min(1, max(0, Double(changed) / Double(max(a.count, b.count))))
  }

  /// 几乎没改。说明 AI 那版就是你想要的。
  public var isNearlyUntouched: Bool { changeRatio < 0.05 }
}
