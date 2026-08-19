import Foundation

/// 一条任务的「整理排版」产物。
///
/// 和脑图一样是**衍生产物**，不是一次总结运行：它不进 `runs`（那张表的 `kind`
/// 上有 CHECK 约束，加一种类型等于整表重建），也**不进 snapshot**——原文一个字
/// 都不动，重排稿只是另一种看法，用户随时能切回去。
///
/// 一条任务只留最新一份。`userEdited` 是给用户改稿留的位：产物可以再编辑，
/// 改过之后重新生成会先问。
public struct TaskReformatRecord: Sendable, Equatable {
  public let taskID: TaskID
  public let bodyText: String
  public let userEdited: Bool
  /// 长稿会切片重排，中间几片失败时以**原文**回填。产出看起来正常，实际有几段
  /// 没重排过——必须如实告诉用户，不能吞掉。
  public let isPartial: Bool
  public let provider: String?
  public let model: String?
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let totalTokens: Int?
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64

  public init(
    taskID: TaskID,
    bodyText: String,
    userEdited: Bool = false,
    isPartial: Bool = false,
    provider: String? = nil,
    model: String? = nil,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64
  ) {
    self.taskID = taskID
    self.bodyText = bodyText
    self.userEdited = userEdited
    self.isPartial = isPartial
    self.provider = provider
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

/// 与 `MindMapStoring` 同一个理由单独成协议：`HistoryRepository` 已有一批实现
/// （含测试替身），每加一个方法都要全部跟着改。
public protocol ReformatStoring: Sendable {
  func saveReformat(_ record: TaskReformatRecord) throws
  func loadReformat(taskID: TaskID) throws -> TaskReformatRecord?
  func deleteReformat(taskID: TaskID) throws
}

extension HistoryApplicationService {
  /// nil when the underlying repository predates reformat storage.
  public var reformatStore: (any ReformatStoring)? { repositoryAsReformatStore }
}

/// 什么样的正文值得花 token 重排。
///
/// 判据不是「用户想不想」，而是「这篇有没有结构可言」——已经分好节的文章重排
/// 一遍只是把钱烧掉。阈值取自 `MarkdownOutline` 里那组实测数字：≥2000 字且标题
/// 少于 3 个。那台机器上 76% 的条目不满足，本来就不该走这条路。
public enum ArticleReformatEligibility: Sendable, Equatable {
  case eligible
  case alreadyStructured
  case tooShort
  /// 图集、转写稿这类：重排无从下手，或者已经有更合适的呈现（时间锚点）。
  case notProse

  public var userMessage: String? {
    switch self {
    case .eligible: nil
    case .alreadyStructured: "这篇已经有小标题，不需要重排。"
    case .tooShort: "正文太短，重排没有意义。"
    case .notProse: "这类内容不适合重排版面。"
    }
  }

  public var canReformat: Bool { self == .eligible }

  /// `allowsOutline` 来自排版档案：转写稿和图集是 false——前者已有时间锚点，
  /// 后者根本没有可分节的正文。
  public static func evaluate(shape: ContentShape, allowsOutline: Bool) -> ArticleReformatEligibility {
    guard allowsOutline else { return .notProse }
    guard shape.characterCount >= 2_000 else { return .tooShort }
    guard shape.headingCount < 3 else { return .alreadyStructured }
    return .eligible
  }
}
