import AppKit
import SwiftUI
import XCTest
@testable import LinkDigestApp

/// 给浏览器扩展导出工序印图片（2026-09-29 弹窗重构）。
///
/// 扩展弹窗用的印必须和 App 同一套画法（小印不许简化），所以直接拿 `SealMark` 渲染成 PNG，
/// 而不是在扩展里另画一份。平时跳过；要重新导出时：
/// `LINKDIGEST_EXPORT_SEALS=<扩展 public/seals 目录> swift test --filter ExtensionSealAssetTests`
@MainActor
final class ExtensionSealAssetTests: XCTestCase {
  func testExportSealsForBrowserExtension() throws {
    guard let path = ProcessInfo.processInfo.environment["LINKDIGEST_EXPORT_SEALS"], !path.isEmpty else {
      throw XCTSkip("只在导出扩展印图时运行")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let glyphs: [(SealMark.Glyph, String, Double)] = [
      (.external, "ji", -0.8), (.record, "record", -1.5), (.proof, "proof", 1.2), (.comments, "comments", -0.6),
      (.summary, "summary", 1.8), (.translation, "translation", -1.1), (.mindMap, "mindMap", 0.8),
    ]
    let schemes: [(ColorScheme, String, Color)] = [
      (.light, "light", Color(red: 0xB8 / 255, green: 0x32 / 255, blue: 0x1C / 255)),
      (.dark, "dark", Color(red: 0xE0 / 255, green: 0x7A / 255, blue: 0x66 / 255)),
    ]
    var written = 0
    for (glyph, name, rotation) in glyphs {
      for (scheme, schemeName, color) in schemes {
        for style in [SealMark.Style.stamped, .pending] {
          let seal = SealMark(
            glyph: glyph, size: 36,
            color: style == .pending ? color.opacity(0.75) : color,
            style: style, rotation: style == .stamped ? rotation : 0
          )
          .frame(width: 40, height: 40)
          .environment(\.colorScheme, scheme)
          let renderer = ImageRenderer(content: seal)
          renderer.scale = 3
          renderer.isOpaque = false
          let image = try XCTUnwrap(renderer.nsImage)
          let tiff = try XCTUnwrap(image.tiffRepresentation)
          let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
          let styleName = style == .stamped ? "stamped" : "pending"
          try png.write(to: directory.appendingPathComponent("\(name)-\(styleName)-\(schemeName).png"))
          written += 1
        }
      }
    }
    XCTAssertEqual(written, 28)
  }
}
