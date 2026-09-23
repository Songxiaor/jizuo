import Foundation
import XCTest
@testable import LinkDigestCore

final class MaterialCatalogTests: XCTestCase {
  func testMaterialTypesAreTheAgreedSix() {
    XCTAssertEqual(MaterialCatalog.typeTagNames, ["灵感", "观点", "案例", "金句", "数据", "选题"])
    for name in MaterialCatalog.typeTagNames + [MaterialCatalog.usedTagName] {
      XCTAssertNotNil(HistoryTagNormalizer.normalized(name), "\(name) 必须是合法标签名")
    }
  }

  func testUsageLineNamesTheTarget() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    XCTAssertEqual(MaterialCatalog.usageLine(usedIn: "AI 素材库怎么搭", at: date, calendar: calendar), "- 2026-09-21 已用于《AI 素材库怎么搭》")
    XCTAssertEqual(MaterialCatalog.usageLine(usedIn: "  ", at: date, calendar: calendar), "- 2026-09-21 已被创作系统使用")
  }

  func testUsageIsAppendedUnderOneHeadingWithoutDuplicates() {
    let first = MaterialCatalog.appendingUsage("- 2026-09-22 已用于《A》", to: "我的批注")
    XCTAssertEqual(first, "我的批注\n\n## 使用记录\n\n- 2026-09-22 已用于《A》")
    let second = MaterialCatalog.appendingUsage("- 2026-09-23 已用于《B》", to: first)
    XCTAssertEqual(second, first + "\n- 2026-09-23 已用于《B》")
    XCTAssertEqual(MaterialCatalog.appendingUsage("- 2026-09-23 已用于《B》", to: second), second)
    XCTAssertEqual(MaterialCatalog.appendingUsage("- x", to: nil), "## 使用记录\n\n- x")
  }

  func testAppleNoteKeepsFolderAndCreationTimeAsProperties() throws {
    let created = Date(timeIntervalSince1970: 1_790_000_000)
    let document = try LocalImportDocument.appleNote(
      noteID: "x-coredata://ABC/ICNote/p12", title: "选题池", folder: "工作", createdAt: created, text: "- 素材库\n- 转写"
    )
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document))
    XCTAssertEqual(document.platform, "applenotes")
    let frontmatter = MarkdownNoteFrontmatter.parse(document.text)
    XCTAssertEqual(frontmatter.author, "工作")
    XCTAssertNotNil(frontmatter.published)
    XCTAssertEqual(frontmatter.body.trimmingCharacters(in: .whitespacesAndNewlines), "- 素材库\n- 转写")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "applenotes"), "备忘录")
    // 同一条备忘录每次同步落回同一个条目。
    let again = try LocalImportDocument.appleNote(noteID: "x-coredata://ABC/ICNote/p12", title: "改名了", folder: nil, createdAt: nil, text: "新正文")
    XCTAssertEqual(document.url, again.url)
    XCTAssertNotEqual(document.url, try LocalImportDocument.appleNote(noteID: "x-coredata://ABC/ICNote/p13", title: nil, folder: nil, createdAt: nil, text: "x").url)
  }

  func testEmptyAppleNoteStillImportsWithExplanation() throws {
    let document = try LocalImportDocument.appleNote(noteID: "id", title: nil, folder: nil, createdAt: nil, text: "  ")
    XCTAssertEqual(document.title, "无标题备忘录")
    XCTAssertTrue(document.text.contains("没有文字内容"))
  }

  func testVoiceMemoShowsRecordingTimeInsteadOfImportTime() throws {
    let recorded = Date(timeIntervalSince1970: 1_780_000_000)
    let document = try LocalImportDocument.voiceMemo(recordingID: "R", title: "晨会", recordedAt: recorded, durationSeconds: 10)
    XCTAssertNotNil(MarkdownNoteFrontmatter.parse(document.text).published)
  }
}
