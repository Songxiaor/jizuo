import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestApp
import LinkDigestCore
@testable import LinkDigestPersistence

/// 真实资料库副本导出 harness：走和界面**完全相同**的导出代码路径，
/// 把指定 task 导出成 .md / .txt / .pdf / .docx，供人工逐个检查
/// （时间码、小标题、图片、题跋/印章）。
///
/// 默认跳过。运行方式：
///
///   JIZUO_EXPORT_HARNESS_DB=/tmp/jizuo-1004/db/history.sqlite \
///   JIZUO_EXPORT_HARNESS_TASKS=<逗号分隔 task id> \
///   JIZUO_EXPORT_HARNESS_OUT=/tmp/jizuo-1004/exports \
///   swift test --filter RealLibraryExportHarnessTests
///
/// 安全边界：
/// - DB 副本**只读**打开（`openWritable` 抛错，只走 `openReadOnly`），
///   绝不写 `~/Library/Application Support/LinkDigest/`。
/// - 图片媒体只读：App 会把缓存图片根目录解析为
///   `<Application Support>/LinkDigest/GitHubREADMEImages/<task>/<snapshot>/`，
///   可通过 `JIZUO_EXPORT_HARNESS_APP_SUPPORT` 指向真实的 Application Support
///   根（默认 `~/Library/Application Support`），只用于读图。
@MainActor
final class RealLibraryExportHarnessTests: XCTestCase {

  func testExportRealLibrarySamples() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let dbPath = environment["JIZUO_EXPORT_HARNESS_DB"], !dbPath.isEmpty else {
      throw XCTSkip("JIZUO_EXPORT_HARNESS_DB 未设置：这是手动运行的真实库导出 harness")
    }
    let outRoot = environment["JIZUO_EXPORT_HARNESS_OUT"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("jizuo-export-harness-\(UUID().uuidString)", isDirectory: true)
    let taskIDs = (environment["JIZUO_EXPORT_HARNESS_TASKS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    XCTAssertFalse(taskIDs.isEmpty, "JIZUO_EXPORT_HARNESS_TASKS 至少要给一个 task id")

    // 只读打开：替换 openWritable，万一路径走到了写连接也立刻抛错，绝不碰副本。
    // 注意：写连接抛错后 `LocalDatabase.open` 会按 storageUnavailable 降级成只读，
    // 后续读路径不受影响——这正是我们想要的最终状态。
    var dependencies = PersistenceDependencies.live
    dependencies.openWritable = { _, _ in throw CocoaError(.featureUnsupported) }
    let repository = try GRDBHistoryRepository.open(
      at: .init(directoryURL: URL(fileURLWithPath: dbPath).deletingLastPathComponent()),
      dependencies: dependencies
    )
    defer { try? repository.database.close() }

    // 与 App 相同的图片缓存解析（只读目录枚举）。
    let appSupportRoot = environment["JIZUO_EXPORT_HARNESS_APP_SUPPORT"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    let imageCache = GitHubREADMEImageCache(applicationSupportRoot: appSupportRoot)

    // App 默认阅读字体：阅读偏好「跟随主题」+ 主题走编辑排版 + 默认 15pt
    // （`AppearanceTheme.usesEditorialReadingTypography == true`，所有主题恒真）。
    let readingFont = ReadingFontSelection(storedValue: ReadingFontSelection.defaultStoredValue)
      .resolved(
        usesEditorialReadingTypography: AppearanceTheme.paper.usesEditorialReadingTypography,
        bodySize: ReadingFontSize.default
      )

    let model = HistoryViewModel(imageCache: imageCache)
    model.configure(
      history: HistoryApplicationService(repository: repository),
      isReadOnly: true,
      unavailableCode: nil
    )

    try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

    for rawID in taskIDs {
      guard let taskID = TaskID(rawID) else {
        XCTFail("非法 task id：\(rawID)")
        continue
      }
      model.reveal(taskID: taskID)
      await waitUntil(timeout: .seconds(30)) {
        model.detail?.task.id == taskID && model.detailState == .loaded
      }
      let composed = try XCTUnwrap(model.composeExportMarkdown(), "composeExportMarkdown 失败：\(rawID)")
      let detail = try XCTUnwrap(model.detail)

      // 与 HistoryContentView 完全相同的拼装入口。
      let context = ReadingDocumentExport.ExportColophonContext(
        detail: detail,
        mindMap: model.mindMapRecord
      )

      let taskOut = outRoot.appendingPathComponent(String(rawID.prefix(8)), isDirectory: true)
      try FileManager.default.createDirectory(at: taskOut, withIntermediateDirectories: true)

      // .md / .txt：exportCleanText 同一函数。
      for (format, ext) in [(HistoryExportFormat.markdown, "md"), (HistoryExportFormat.plainText, "txt")] {
        let text = ReadingDocumentExport.cleanTextExport(
          composedMarkdown: composed.markdown,
          format: format,
          context: context
        )
        try text.data(using: .utf8)?.write(
          to: taskOut.appendingPathComponent("\(composed.baseFilename).\(ext)")
        )
      }

      // .pdf / .docx：exportStyledDocument 同一函数。
      let attributed = ReadingDocumentExport.styledDocument(
        composedMarkdown: composed.markdown,
        context: context,
        readingFont: readingFont,
        localImageURLs: model.localImageURLs
      )
      let pdf = try XCTUnwrap(ReadingDocumentExport.pdfData(from: attributed), "pdfData 失败：\(rawID)")
      try pdf.write(to: taskOut.appendingPathComponent("\(composed.baseFilename).pdf"))
      let docx = try ReadingDocumentExport.docxData(from: attributed)
      try docx.write(to: taskOut.appendingPathComponent("\(composed.baseFilename).docx"))

      // 机器可读摘要，便于自查图片数 / 题跋有无。
      let summary = """
      task: \(rawID)
      title: \(detail.snapshots.last?.title ?? detail.snapshots.first?.title ?? "")
      url: \(detail.task.canonicalURL)
      snapshots: \(detail.snapshots.count)
      localImageURLs: \(model.localImageURLs.count)
      isOwnWriting: \(context.isOwnWriting)
      colophonLine: \(context.colophonLine ?? "(无)")
      records: \(context.records.map { $0.step.rawValue }.joined(separator: ","))
      baseFilename: \(composed.baseFilename)
      """
      try summary.write(
        to: taskOut.appendingPathComponent("harness-summary.txt"),
        atomically: true,
        encoding: .utf8
      )
      FileHandle.standardOutput.write(("[harness] exported \(rawID) → \(taskOut.path)\n").data(using: .utf8)!)
    }
  }

  private func waitUntil(
    timeout: Duration,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}
