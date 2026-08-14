import Foundation

public struct HistoryBatchExportProgress: Sendable, Equatable {
  public let completed: Int
  public let total: Int
  public let currentFilename: String?

  public init(completed: Int, total: Int, currentFilename: String?) {
    self.completed = completed
    self.total = total
    self.currentFilename = currentFilename
  }
}

public struct HistoryBatchExportReport: Sendable, Equatable {
  public let exportedCount: Int
  public let directoryURL: URL

  public init(exportedCount: Int, directoryURL: URL) {
    self.exportedCount = exportedCount
    self.directoryURL = directoryURL
  }
}

/// Exports every task as one Markdown file. The caller is responsible for
/// running this service away from the main actor; progress is the only UI-facing
/// work and is delivered through an async callback.
public struct HistoryBatchExporter: @unchecked Sendable {
  private let history: HistoryApplicationService
  private let fileManager: FileManager

  public init(history: HistoryApplicationService, fileManager: FileManager = .default) {
    self.history = history
    self.fileManager = fileManager
  }

  public func exportMarkdown(
    to directoryURL: URL,
    progress: @escaping @Sendable (HistoryBatchExportProgress) async -> Void = { _ in }
  ) async throws -> HistoryBatchExportReport {
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let taskIDs = try allTaskIDs()
    await progress(.init(completed: 0, total: taskIDs.count, currentFilename: nil))

    var usedNames = Set<String>()
    for (index, taskID) in taskIDs.enumerated() {
      try Task.checkCancellation()
      let projection = try history.exportProjection(taskID: taskID)
      let file = try HistoryExportRenderer.render(projection, as: .markdown)
      let filename = Self.uniqueFilename(
        suggestedFilename: file.suggestedFilename,
        usedLowercasedNames: &usedNames
      )
      let destination = directoryURL.appendingPathComponent(filename, isDirectory: false)
      try file.data.write(to: destination, options: .withoutOverwriting)
      await progress(.init(completed: index + 1, total: taskIDs.count, currentFilename: filename))
    }
    return .init(exportedCount: taskIDs.count, directoryURL: directoryURL)
  }

  /// History browsing deliberately separates captured items, notes, drafts and
  /// finished works. A full export visits all four scopes and de-duplicates IDs.
  private func allTaskIDs() throws -> [TaskID] {
    var result: [TaskID] = []
    var seen = Set<TaskID>()
    for scope in [HistoryListScope.all, .notes, .drafts, .works] {
      var cursor: HistoryPageCursor?
      repeat {
        let page = try history.historyPage(
          limit: 200,
          after: cursor,
          filter: HistoryListFilter(scope: scope)
        )
        for row in page.rows where seen.insert(row.taskID).inserted {
          result.append(row.taskID)
        }
        cursor = page.nextCursor
      } while cursor != nil
    }
    return result
  }

  public static func uniqueFilename(
    suggestedFilename: String,
    usedLowercasedNames: inout Set<String>
  ) -> String {
    let candidate = suggestedFilename.lowercased()
    if usedLowercasedNames.insert(candidate).inserted { return suggestedFilename }

    let url = URL(fileURLWithPath: suggestedFilename)
    let fileExtension = url.pathExtension
    let rawBase = url.deletingPathExtension().lastPathComponent
    var index = 2
    while true {
      let suffix = " (\(index))"
      let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
      let maximumBaseBytes = max(1, 255 - suffix.utf8.count - extensionSuffix.utf8.count)
      let base = HistoryExportRenderer.safeFilenameComponent(
        rawBase,
        maximumUTF8ByteCount: maximumBaseBytes
      )
      let value = "\(base)\(suffix)\(extensionSuffix)"
      if usedLowercasedNames.insert(value.lowercased()).inserted { return value }
      index += 1
    }
  }
}
