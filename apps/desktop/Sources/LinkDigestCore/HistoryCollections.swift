import Foundation

/// 合集：一组要放在一起看、**有顺序**的内容（2026-09-29 第一期）。
///
/// 和标签不是一回事：标签回答「这条内容是什么」，没有顺序；合集像歌单，回答
/// 「这几条要按什么顺序一起看」，例如「Claude Code 教程 12 讲」。一条内容可以
/// 同时在好几个合集里。
///
/// 第一期只有两种来源：用户手动建的，和导入一个文件夹时自动建的（按文件夹路径
/// 认同一个合集，再导入一次只往后追加新条目）。AI 自动归类、智能合集不在这一期。
public struct CollectionID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) {
    guard UUID(uuidString: rawValue)?.uuidString.lowercased() == rawValue else { return nil }
    self.rawValue = rawValue
  }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }
}

/// 合集是怎么来的。存进库里的是 `rawValue`，改名要写迁移。
public enum HistoryCollectionOrigin: String, Codable, Sendable, CaseIterable {
  /// 用户在侧栏或菜单里新建的。
  case manual
  /// 导入一个文件夹时自动建的；同一文件夹路径再次导入时更新同一个合集。
  case importedFolder = "imported_folder"
}

public struct HistoryCollectionSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: CollectionID
  public let name: String
  public let origin: HistoryCollectionOrigin
  /// 只有导入文件夹建的合集才有。
  public let folderPath: String?
  /// 合集里**看得见**的条数：放进回收站的、稿件都不算。
  public let itemCount: Int
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64

  public init(
    id: CollectionID,
    name: String,
    origin: HistoryCollectionOrigin,
    folderPath: String?,
    itemCount: Int,
    createdAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64
  ) {
    self.id = id
    self.name = name
    self.origin = origin
    self.folderPath = folderPath
    self.itemCount = itemCount
    self.createdAtMilliseconds = createdAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

/// 合集里的一条。`position` 只在同一个合集内有意义，越小越靠前。
public struct HistoryCollectionItem: Codable, Sendable, Equatable {
  public let taskID: TaskID
  public let position: Int64
  public let addedAtMilliseconds: Int64

  public init(taskID: TaskID, position: Int64, addedAtMilliseconds: Int64) {
    self.taskID = taskID
    self.position = position
    self.addedAtMilliseconds = addedAtMilliseconds
  }
}

public enum HistoryCollectionNaming {
  /// 侧栏一行放得下、又够写「Claude Code 教程 12 讲」这种名字。
  public static let maximumCharacterCount = 60

  /// 合集名：去掉首尾空白、把换行和制表符压成一个空格。空名返回 nil；
  /// 太长的截断而不是拒绝——导入的文件夹名可能很长，不该因此建不出合集。
  public static func normalized(_ raw: String) -> String? {
    let collapsed = raw
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty,
          !collapsed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return String(collapsed.prefix(maximumCharacterCount))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 导入文件夹用的路径键：同一个文件夹换种写法（结尾斜杠、`..`）也认成同一个。
  public static func folderKey(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }
}

/// 合集的读写。
///
/// 单独成协议而不是塞进 `HistoryRepository`：理由同 `ReadingProgressStoring`——
/// 那个协议已有一批实现（含测试替身），每加一个方法都要全部跟着改。
///
/// 时间戳由实现自己取当前时间：这些都是用户手点出来的一次性动作，没有「补写历史
/// 时间」的调用方。
public protocol CollectionStoring: Sendable {
  /// 新建一个手动合集。名字不合法抛 `invalidInput`。
  func createCollection(name: String) throws -> HistoryCollectionSummary
  func renameCollection(id: CollectionID, to name: String) throws -> HistoryCollectionSummary
  /// 只删合集和它的条目关系，内容本身一条不动。
  func deleteCollection(id: CollectionID) throws
  /// 全部合集，按创建时间先后排（侧栏顺序稳定，不会因为加了一条就跳位置）。
  func collections() throws -> [HistoryCollectionSummary]
  func collection(id: CollectionID) throws -> HistoryCollectionSummary?
  /// 把一批内容追加到合集末尾，按传入顺序。已经在合集里的跳过、位置不动；
  /// 不存在的 id 跳过。返回这次真正新加进去的条数。
  @discardableResult
  func addTasks(_ taskIDs: [TaskID], toCollection id: CollectionID) throws -> Int
  /// 移出合集（内容本身不删）。返回真正移出的条数。
  @discardableResult
  func removeTasks(_ taskIDs: [TaskID], fromCollection id: CollectionID) throws -> Int
  /// 调整顺序：把 `taskIDs`（按传入顺序）挪到 `anchor` 后面；`anchor == nil` 表示挪到最前。
  /// 用「挪到谁后面」而不是整表重排，是因为列表是分页加载的、回收站里的条目也不显示——
  /// 界面手里只有一部分条目，不能要求它交出全量顺序。
  func moveTasks(_ taskIDs: [TaskID], inCollection id: CollectionID, after anchor: TaskID?) throws
  /// 按位置取条目。放进回收站的不返回。
  func collectionItems(id: CollectionID) throws -> [HistoryCollectionItem]
  /// 这条内容在哪些合集里，按合集创建时间排。
  func collections(containing taskID: TaskID) throws -> [HistoryCollectionSummary]
  /// 导入一个文件夹之后调用。同一 `folderPath` 已有合集时：已有条目顺序不动，
  /// 新条目按 `orderedTaskIDs` 的顺序追加到末尾（名字不改——用户可能改过名）；
  /// 否则新建一个。没有已有合集、也没有一条有效内容时什么都不建，返回 nil。
  @discardableResult
  func createOrUpdateImportedFolderCollection(
    name: String,
    folderPath: String,
    orderedTaskIDs: [TaskID]
  ) throws -> HistoryCollectionSummary?
}

extension HistoryApplicationService {
  /// nil when the underlying repository predates collection storage.
  public var collectionStore: (any CollectionStoring)? { repositoryAsCollectionStore }

  /// 取不到存储时统一当成「不可用」，调用方按普通存储失败处理。
  public func requireCollectionStore() throws -> any CollectionStoring {
    guard let store = collectionStore else { throw RepositoryFailure.unavailable }
    return store
  }
}
