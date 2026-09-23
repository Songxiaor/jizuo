import CryptoKit
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

final class MaterialLayerTests: XCTestCase {
  /// 导入的图片在正文顶部以 `![名](本机地址)` 引用；阅读页要把它换成那张原图。
  func testImportedImageReferenceRendersAsImageAboveText() throws {
    let reference = "linkdigest-local://localfiles/abc"
    let hash = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
    let file = URL(fileURLWithPath: "/tmp/x/\(hash)")
    let segments = LocalMarkdownImageLayout.segments(markdown: "![截图.png](\(reference))\n\n识别出的文字", localImageURLs: [file])
    guard case let .image(url)? = segments.first else { return XCTFail("第一段应当是图片：\(segments)") }
    XCTAssertEqual(url, file)
    XCTAssertTrue(segments.contains { if case let .text(t) = $0 { return t.contains("识别出的文字") }; return false })
  }

  @MainActor
  func testQuickCaptureTitleIsFirstLine() {
    XCTAssertEqual(QuickCaptureController.title(from: "# 标题行\n第二行"), "标题行")
    XCTAssertEqual(QuickCaptureController.title(from: String(repeating: "长", count: 50)), String(repeating: "长", count: 40) + "…")
    XCTAssertEqual(QuickCaptureController.title(from: "\n\n"), UserNoteDocument.untitledTitle)
  }

  @MainActor
  func testAppleNoteBodyDropsRepeatedTitleLine() {
    XCTAssertEqual(LocalImportController.noteBody(html: "<div><h1>选题池</h1></div><div>正文</div>", title: "选题池"), "正文")
    XCTAssertEqual(LocalImportController.noteBody(html: "<div><b>选题池</b></div><div>正文</div>", title: "选题池"), "正文")
    XCTAssertEqual(LocalImportController.noteBody(html: "<div>别的开头</div>", title: "选题池"), "别的开头")
  }
}
