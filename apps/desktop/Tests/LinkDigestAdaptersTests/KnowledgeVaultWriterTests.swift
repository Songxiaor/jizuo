import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class KnowledgeVaultWriterTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-vault-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// 验收硬指标：第二次同步不能碰未变更的文件。
  ///
  /// 纯函数测试只能证明「计划里是 skip」，证明不了真的没写盘。这里把 mtime
  /// 拨到过去再跑一次，mtime 还在过去才算数——重写会污染上千个文件的时间戳、
  /// 触发 Obsidian 全量重建索引、在用户的 Git 仓库里制造巨量噪音。
  func testSecondSyncLeavesUnchangedFilesUntouched() throws {
    let document = document(id: idA, filename: "2026-08-05_甲.md", text: "内容甲")
    let first = KnowledgeVaultSync.plan(documents: [document], existing: [])
    let firstReport = KnowledgeVaultWriter.apply(first, in: directory)
    XCTAssertEqual(firstReport.created, 1)

    let file = directory.appendingPathComponent("2026-08-05_甲.md")
    let past = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

    let existing = try KnowledgeVaultWriter.scan(directory: directory)
    XCTAssertEqual(existing.count, 1)
    XCTAssertEqual(existing.first?.digestID, idA)

    let second = KnowledgeVaultSync.plan(documents: [document], existing: existing)
    let secondReport = KnowledgeVaultWriter.apply(second, in: directory)

    XCTAssertEqual(secondReport.skipped, 1)
    XCTAssertEqual(secondReport.touched, 0)
    let mtime = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    )
    XCTAssertEqual(mtime.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
  }

  /// 验收标准 6：目标文件的 digest_id 不匹配时跳过并报告，原文件一个字节都不变。
  func testForeignFileIsReportedAndItsBytesAreNeverModified() throws {
    let file = directory.appendingPathComponent("2026-08-05_撞名.md")
    let original = "---\ntitle: 我自己写的笔记\n---\n\n不要动我。\n"
    try Data(original.utf8).write(to: file)
    let past = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_撞名.md", text: "汲作的内容")],
      existing: try KnowledgeVaultWriter.scan(directory: directory)
    )
    let report = KnowledgeVaultWriter.apply(plan, in: directory)

    XCTAssertEqual(report.conflicts.count, 1)
    XCTAssertEqual(report.conflicts.first?.filename, "2026-08-05_撞名.md")
    XCTAssertEqual(report.touched, 0)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    let mtime = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    )
    XCTAssertEqual(mtime.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
  }

  func testChangedContentIsWrittenAndRenameMovesTheFile() throws {
    let first = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_旧标题.md", text: "第一版")],
      existing: []
    )
    _ = KnowledgeVaultWriter.apply(first, in: directory)

    let second = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_新标题.md", text: "第二版")],
      existing: try KnowledgeVaultWriter.scan(directory: directory)
    )
    let report = KnowledgeVaultWriter.apply(second, in: directory)

    XCTAssertEqual(report.renamed, 1)
    let new = directory.appendingPathComponent("2026-08-05_新标题.md")
    XCTAssertEqual(
      try String(contentsOf: new, encoding: .utf8),
      markdown(id: idA, body: "第二版")
    )
    // 改名之后不能留下旧的那一份，否则同一条内容在目录里有两个副本。
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("2026-08-05_旧标题.md").path
      )
    )
  }

  /// 目录里非 `.md`、点开头的文件和子目录都不该被当成汲作的东西读进来。
  func testScanOnlyPicksUpTopLevelMarkdown() throws {
    try Data("不是 md".utf8).write(to: directory.appendingPathComponent("readme.txt"))
    try Data("隐藏".utf8).write(to: directory.appendingPathComponent(".hidden.md"))
    let nested = directory.appendingPathComponent("子目录")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("---\ndigest_id: \"\(idA)\"\n---\n嵌套".utf8)
      .write(to: nested.appendingPathComponent("嵌套.md"))
    try Data("---\ndigest_id: \"\(idA)\"\n---\n顶层".utf8)
      .write(to: directory.appendingPathComponent("顶层.md"))

    let files = try KnowledgeVaultWriter.scan(directory: directory)

    XCTAssertEqual(files.map(\.filename), ["顶层.md"])
  }

  /// 文件名里带路径分隔符时必须拒绝，不能写到目录外面去。
  func testWritesOutsideTheDirectoryAreRefused() throws {
    let plan = KnowledgeVaultPlan(actions: [
      .create(filename: "../逃逸.md", text: "不该写出去"),
      .create(filename: "子目录/内部.md", text: "不该写出去"),
    ])
    let report = KnowledgeVaultWriter.apply(plan, in: directory)

    XCTAssertEqual(report.created, 0)
    XCTAssertEqual(report.failures.count, 2)
    let parent = directory.deletingLastPathComponent().appendingPathComponent("逃逸.md")
    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
  }

  private let idA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  private func document(id: String, filename: String, text: String) -> KnowledgeVaultDocument {
    .init(digestID: TaskID(id)!, filename: filename, text: markdown(id: id, body: text))
  }

  /// 认亲全靠正文里的 frontmatter，所以夹具必须是真实形状——渲染器产出的
  /// 每一份都带 `digest_id`，拿裸文本当夹具测出来的是另一回事。
  private func markdown(id: String, body: String) -> String {
    "---\ntype: digest\ndigest_id: \"\(id)\"\n---\n\n\(body)\n"
  }
}
