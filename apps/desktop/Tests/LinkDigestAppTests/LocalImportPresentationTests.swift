import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 本机来源在界面上要说人话：来源行显示「语音备忘录」而不是内部 host，
/// 列表与侧栏有能认出来的图标而不是首字母方块。
final class LocalImportPresentationTests: XCTestCase {
  func testSourceBylineShowsLocalSourceName() throws {
    let voice = try CanonicalURL.localImport(source: "voicememos", identifier: "abc").value
    let file = try CanonicalURL.localImport(source: "localfiles", identifier: String(repeating: "c", count: 64)).value
    XCTAssertEqual(HistorySourceLinkPresentation.host(voice), "语音备忘录")
    XCTAssertEqual(HistorySourceLinkPresentation.host(file), "本地文件")
    XCTAssertEqual(HistorySourceLinkPresentation.host("https://www.bilibili.com/video/BV1"), "bilibili.com")
  }

  func testLocalSourcesUseSystemSymbols() {
    XCTAssertEqual(PlatformIconCatalog.localSourceSymbolName(for: "voicememos"), "waveform")
    XCTAssertEqual(PlatformIconCatalog.localSourceSymbolName(for: "localfiles"), "doc")
    XCTAssertNil(PlatformIconCatalog.localSourceSymbolName(for: "douyin.com"))
    XCTAssertNotNil(PlatformIconCatalog.image(for: "voicememos"))
  }

  /// 截图识别出的文字一行一个块，阅读页必须按行显示，不能并成一整段。
  func testImportedImageTextRendersLineByLine() {
    let body = LocalImportDocument.imageBody(
      fileName: "shot.png", reference: "linkdigest-local://localfiles/abc",
      recognizedText: "IP查询\n104.30.175.37\n152ms"
    )
    let text = body.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
    let blocks = MarkdownPresentation.blocks(from: text)
    XCTAssertEqual(blocks.count, 2)
    guard case let .heading(_, heading) = blocks.first, case let .paragraph(paragraph) = blocks.last else {
      return XCTFail("expected heading + paragraph, got \(blocks)")
    }
    XCTAssertEqual(heading, "图片里的文字")
    XCTAssertEqual(paragraph, "IP查询\n104.30.175.37\n152ms")
  }
}
