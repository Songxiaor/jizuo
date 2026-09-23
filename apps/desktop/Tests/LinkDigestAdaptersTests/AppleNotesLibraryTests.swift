import AppKit
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 备忘录的读取需要用户在系统弹窗里授权，测试只验证「拿到结果之后」的每一步。
final class AppleNotesLibraryTests: XCTestCase {
  func testNoteHTMLBecomesStructuredMarkdown() {
    let html = """
    <div><h1>选题池</h1></div><div>第一段 &amp; 说明</div><div><br></div>\
    <ul><li>素材库</li><li><b>转写</b></li></ul><div><img src="data:image/png;base64,AAAA"></div>\
    <div>&#20013;&#x6587;&nbsp;实体</div>
    """
    XCTAssertEqual(AppleNoteHTML.markdown(from: html), """
    # 选题池

    第一段 & 说明

    - 素材库
    - **转写**

    [图片]

    中文 实体
    """)
  }

  func testDecodesScriptOutputWithFractionalDates() throws {
    let json = #"[{"id":"x-coredata://A/ICNote/p1","name":"选题","folder":"灵感","body":"<div>x</div>","createdAt":"2026-09-01T01:02:03.000Z","modifiedAt":null,"locked":false},{"id":"p2","name":"密","folder":null,"body":null,"createdAt":null,"modifiedAt":null,"locked":true}]"#
    let notes = try AppleNotesLibrary.decode(Data(json.utf8))
    XCTAssertEqual(notes.count, 2)
    XCTAssertEqual(notes[0].folder, "灵感")
    XCTAssertEqual(notes[0].createdAt, ISO8601DateFormatter().date(from: "2026-09-01T01:02:03Z")!.addingTimeInterval(0))
    XCTAssertTrue(notes[1].locked)
    XCTAssertNil(notes[1].body)
  }

  func testGarbageOutputIsExplained() {
    XCTAssertThrowsError(try AppleNotesLibrary.decode(Data("not json".utf8))) { error in
      guard case .failed = error as? AppleNotesLibraryError else { return XCTFail("\(error)") }
    }
  }

  func testPermissionErrorsAreRecognized() {
    XCTAssertEqual(AppleNotesLibrary.error(fromStderr: "execution error: Not authorized to send Apple events to Notes. (-1743)"), .permissionDenied)
    XCTAssertEqual(AppleNotesLibrary.error(fromStderr: "error -1744"), .permissionDenied)
    XCTAssertEqual(AppleNotesLibrary.error(fromStderr: "execution error: Error: Error: AppleEvent timed out. (-1712)"), .timedOut)
    guard case let .failed(detail) = AppleNotesLibrary.error(fromStderr: "line1\nsomething else broke") else { return XCTFail() }
    XCTAssertEqual(detail, "something else broke")
  }

  /// 图片导入保留原图，识别文字作为附带正文；没识别到字也不算失败。
  func testImageKeepsOriginalBytes() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let url = workspace.appendingPathComponent("blank.png")
    let image = NSImage(size: NSSize(width: 40, height: 40))
    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); image.unlockFocus()
    let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
    try data.write(to: url)
    let content = try await LocalFileImportReader().read(url)
    guard case let .image(stored, _) = content else { return XCTFail("应当读成图片：\(content)") }
    XCTAssertEqual(stored, data)
  }

  func testLocalImageIsStoredWhereTheReaderFindsIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = GitHubREADMEImageCache(applicationSupportRoot: root)
    let task = TaskID(), snapshot = ContentSnapshotID()
    try cache.storeLocalImage(Data([1, 2, 3]), reference: "linkdigest-local://localfiles/abc", taskID: task, snapshotID: snapshot)
    try cache.storeLocalImage(Data([1, 2, 3]), reference: "linkdigest-local://localfiles/abc", taskID: task, snapshotID: snapshot)
    let urls = cache.localImageURLs(taskID: task, snapshotID: snapshot)
    XCTAssertEqual(urls.count, 1)
    XCTAssertEqual(cache.firstLocalImageURL(taskID: task), urls.first)
  }
}
