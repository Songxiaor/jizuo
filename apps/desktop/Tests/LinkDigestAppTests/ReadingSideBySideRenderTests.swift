import AppKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

/// 手动跑的并排对比渲染（2026-09-25）：把一份 Markdown 用阅读区组件渲染成 PNG，
/// 和对标应用的截图并排看。只在设了 LINKDIGEST_RENDER_COMPARE（源文件路径）时运行，
/// 平时跑测试直接跳过，也不碰历史库。
@MainActor
final class ReadingSideBySideRenderTests: XCTestCase {
  func testRenderMarkdownForSideBySideComparison() throws {
    let env = ProcessInfo.processInfo.environment
    guard let sourcePath = env["LINKDIGEST_RENDER_COMPARE"] else {
      throw XCTSkip("设置 LINKDIGEST_RENDER_COMPARE=<markdown 路径> 后手动运行")
    }
    // 和阅读区同一步：先去掉开头的属性区（frontmatter）。
    let source = ReadingRenderCache.paneBody(
      source: try String(contentsOfFile: sourcePath, encoding: .utf8), strippingEchoedMetadata: false)
    let output = env["LINKDIGEST_RENDER_OUTPUT"] ?? (sourcePath + ".png")
    let view = ScrollView {
      MarkdownContentView(source: source, readingFont: .sans)
        .padding(32)
        .frame(width: 760, alignment: .leading)
    }
    .frame(width: 760, height: 3200)
    .background(Color.white)
    // 流程图、公式是异步排版的，先渲染一次触发，再等一会儿取第二次。
    _ = SnapshotTestSupport.pngData(from: view, size: CGSize(width: 760, height: 3200))
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    let data = try XCTUnwrap(SnapshotTestSupport.pngData(from: view, size: CGSize(width: 760, height: 3200)))
    try data.write(to: URL(fileURLWithPath: output))
  }
}
