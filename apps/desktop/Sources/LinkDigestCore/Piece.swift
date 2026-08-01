import Foundation

/// 一件正在做的创作：从一个灵感到一份成品。
///
/// 它和「一条记录」不是一回事——记录是一份内容，创作是一个**跨越多天的过程**。
/// 过程有阶段、会引用多份素材、正文一直在变，而且中间人会离开又回来。
public struct PieceID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) {
    guard UUID(uuidString: rawValue)?.uuidString.lowercased() == rawValue else { return nil }
    self.rawValue = rawValue
  }
  public init(_ uuid: UUID) { self.rawValue = uuid.uuidString.lowercased() }
  public init() { self.init(UUID()) }
}

/// 一件创作此刻缺什么。
///
/// 不是流程图上的框——阶段回答的是「今天该在这件事上干什么」，
/// 所以它**可以往回退**：写到一半发现素材不够，回到收集是正常的，不是失败。
public enum PieceStage: String, Codable, Sendable, CaseIterable {
  /// 只有一句话，还没开始找东西。
  case spark
  /// 在攒素材，看这个念头撑不撑得住。
  case collect
  /// 在把素材变成有结构的文字。
  case draft
  /// 在决定能不能发出去。
  case polish
  /// 已发出。
  case done

  public var displayName: String {
    switch self {
    case .spark: "灵感"
    case .collect: "收集"
    case .draft: "起草"
    case .polish: "打磨"
    case .done: "已发出"
    }
  }

  /// 进度条上排第几个。`done` 不占位——它是终点不是第五步。
  public var trackIndex: Int? {
    switch self {
    case .spark: 0
    case .collect: 1
    case .draft: 2
    case .polish: 3
    case .done: nil
    }
  }

  /// 进度条上的四格。
  public static let track: [PieceStage] = [.spark, .collect, .draft, .polish]

  /// 根据「现在实际有什么」推断该在哪个阶段。
  ///
  /// 阶段如果全靠手动推进，它就成了填表——每件创作都要记得去点一下，
  /// 而人只会在意「东西写完没有」。所以默认推断，手动只是覆盖。
  /// 宁可推断错让人改，也不要每次都问。
  public static func inferred(
    materialCount: Int,
    bodyLength: Int,
    isFinished: Bool
  ) -> PieceStage {
    if isFinished { return .done }
    // 正文有实质内容就算在起草了。阈值取 80：一句话的灵感抄进正文不算开始写。
    if bodyLength >= 80 { return .draft }
    if materialCount > 0 { return .collect }
    return .spark
  }
}

/// 首页那张卡片要显示的东西。
public struct PieceSummary: Sendable, Equatable, Identifiable {
  public let id: PieceID
  /// 灵感原句。写到第三天很容易偏离，这句话是锚。
  public let spark: String
  /// 标题取自正文那条笔记；还没起标题时回退到灵感原句。
  public let title: String
  public let stage: PieceStage
  public let noteTaskID: TaskID
  public let materialCount: Int
  public let bodyLength: Int
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public let finishedAtMilliseconds: Int64?

  public var isFinished: Bool { finishedAtMilliseconds != nil }

  public init(
    id: PieceID,
    spark: String,
    title: String,
    stage: PieceStage,
    noteTaskID: TaskID,
    materialCount: Int,
    bodyLength: Int,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64,
    finishedAtMilliseconds: Int64?
  ) {
    self.id = id
    self.spark = spark
    self.title = title
    self.stage = stage
    self.noteTaskID = noteTaskID
    self.materialCount = materialCount
    self.bodyLength = bodyLength
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.finishedAtMilliseconds = finishedAtMilliseconds
  }
}

/// 创作引用的一份素材。
///
/// 只引用不拷贝：原素材改了这里看到的就是新的；素材被删了这里显示「已不在」，
/// 而不是留一份对不上的幽灵副本。
public struct PieceMaterial: Sendable, Equatable, Identifiable {
  public let id: TaskID
  public let title: String
  public let host: String
  public let addedAtMilliseconds: Int64
  /// 素材是否还在。原记录被删掉时为 false。
  public let isAvailable: Bool

  public init(
    id: TaskID, title: String, host: String,
    addedAtMilliseconds: Int64, isAvailable: Bool
  ) {
    self.id = id
    self.title = title
    self.host = host
    self.addedAtMilliseconds = addedAtMilliseconds
    self.isAvailable = isAvailable
  }
}

public enum PieceDocument {
  /// 新建创作时给正文笔记用的标题。
  ///
  /// 直接用灵感原句而不是「无标题」：列表里一眼能认出是哪个念头，
  /// 而真正的标题往往是写到一半才想出来的。
  public static func noteTitle(forSpark spark: String) -> String {
    let cleaned = UserNoteDocument.sanitizedTitle(spark)
    guard !cleaned.isEmpty else { return UserNoteDocument.untitledTitle }
    return cleaned.count > 120 ? String(cleaned.prefix(120)) + "…" : cleaned
  }
}
