import Foundation

/// 「这篇读到哪了」。
///
/// 值是 0...1 的比例，不是像素——换字号、换窗口大小、换主题之后还能对得上的
/// 只有比例。
///
/// 单独成协议而不是塞进 `HistoryRepository`：那个协议已经有一批实现（含测试
/// 替身），每加一个方法都要全部跟着改。与 `ReformatStoring` / `MindMapStoring`
/// 同一个理由、同一种接法。
public protocol ReadingProgressStoring: Sendable {
  /// 没读过返回 nil。返回 0 和「没读过」是两件事：前者是读到开头，后者是
  /// 没有记录，调用方要能区分才不会把「从没打开过」显示成「读了 0%」。
  func readingPosition(taskID: TaskID) throws -> Double?
  func saveReadingPosition(_ position: Double, taskID: TaskID, updatedAtMilliseconds: Int64) throws
}

extension HistoryApplicationService {
  /// nil when the underlying repository predates reading-progress storage.
  public var readingProgressStore: (any ReadingProgressStoring)? { repositoryAsReadingProgressStore }

  /// 读位置。取不到（仓库没实现、库不可用）一律当成「没读过」——
  /// 阅读位置是锦上添花，不该让详情页因为它打不开。
  public func readingPosition(taskID: TaskID) -> Double? {
    guard let store = readingProgressStore else { return nil }
    return (try? store.readingPosition(taskID: taskID)).flatMap { $0 }
  }

  public func saveReadingPosition(_ position: Double, taskID: TaskID, updatedAtMilliseconds: Int64) throws {
    guard let store = readingProgressStore else { throw RepositoryFailure.unavailable }
    try store.saveReadingPosition(
      min(max(position, 0), 1),
      taskID: taskID,
      updatedAtMilliseconds: updatedAtMilliseconds
    )
  }
}
