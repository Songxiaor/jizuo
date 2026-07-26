import AppKit
import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestApp

final class ProviderSettingsPresentationTests: XCTestCase {
  private let providerAssets = [
    "bailian.svg", "deepinfra.svg", "deepseek.svg", "groq.svg", "ollama.svg",
    "openai.svg", "openrouter.svg", "siliconflow.svg", "stepfun.svg", "zhipu.svg",
  ]

  func testProviderCatalogMapsEveryCuratedPresetToAnExactBundledAsset() throws {
    let expected: [ProviderPreset: String] = [
      .openAI: "openai", .deepSeek: "deepseek", .deepInfra: "deepinfra",
      .openRouter: "openrouter", .groq: "groq", .siliconFlow: "siliconflow",
      .dashScope: "bailian", .zhipu: "zhipu", .stepFun: "stepfun", .ollama: "ollama",
    ]
    let directory = repositoryRoot().appendingPathComponent("apps/desktop/Assets/ProviderIcons", isDirectory: true)

    XCTAssertEqual(ProviderIconCatalog.assetDirectory, "ProviderIcons")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), providerAssets)
    for (preset, asset) in expected {
      XCTAssertEqual(ProviderIconCatalog.assetName(for: preset), asset)
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(asset + ".svg").path))
    }
    XCTAssertNil(ProviderIconCatalog.assetName(for: .custom))
  }

  func testProviderCatalogRasterizesEveryOfficialSVGAndHasStableFallbacks() throws {
    let directory = repositoryRoot().appendingPathComponent("apps/desktop/Assets/ProviderIcons", isDirectory: true)
    for name in providerAssets {
      let image = try XCTUnwrap(ProviderIconCatalog.crispenedIcon(from: directory.appendingPathComponent(name)))
      XCTAssertEqual(image.size.width, ProviderIconCatalog.displayPointSize)
      XCTAssertEqual(image.size.height, ProviderIconCatalog.displayPointSize)
    }
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: .custom), "自")
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "example provider"), "E")
    XCTAssertEqual(
      ProviderIconCatalog.fallbackColor(for: "example provider"),
      ProviderIconCatalog.fallbackColor(for: "example provider")
    )
  }

  func testProviderCatalogWritesRasterizationComparisonPNG() throws {
    let orderedNames = ["openai", "deepseek", "deepinfra", "openrouter", "groq", "siliconflow", "bailian", "zhipu", "stepfun", "ollama"]
    let directory = repositoryRoot().appendingPathComponent("apps/desktop/Assets/ProviderIcons", isDirectory: true)
    let cell: CGFloat = 64
    let padding: CGFloat = 8
    let width = Int((cell + padding) * CGFloat(orderedNames.count) + padding)
    let height = Int(cell + padding * 2)
    let rep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (index, name) in orderedNames.enumerated() {
      let icon = try XCTUnwrap(ProviderIconCatalog.crispenedIcon(from: directory.appendingPathComponent(name + ".svg")))
      icon.draw(in: NSRect(x: padding + (cell + padding) * CGFloat(index), y: padding, width: cell, height: cell))
    }
    NSGraphicsContext.restoreGraphicsState()

    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("provider-icons-rendercheck-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: output) }
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testServiceTabUsesGroupedRowsWithOneConnectionLabelPerField() throws {
    let source = try String(contentsOf: repositoryRoot().appendingPathComponent("apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"), encoding: .utf8)
    let service = section(in: source, from: "private var serviceTab", to: "// MARK: - 生成与数据")

    XCTAssertTrue(service.contains(".formStyle(.grouped)"))
    XCTAssertFalse(service.contains("LazyVGrid"))
    XCTAssertFalse(service.contains("providerTile"))
    XCTAssertFalse(service.contains("capabilityCard"))
    XCTAssertTrue(service.contains("Grid(alignment: .leading"))
    XCTAssertTrue(service.contains("Text(\"Base URL\")"))
    XCTAssertTrue(service.contains("Text(\"API Key\")"))
    XCTAssertTrue(service.contains("SecureField(\"\", text: $apiKeyInput, prompt: Text(\"输入密钥\"))"))
    XCTAssertFalse(service.contains("SecureField(\"输入 API Key\""))
    XCTAssertTrue(service.contains("model.toggleCatalogModel(name)"))
    XCTAssertTrue(service.contains("保存 \\(model.selectedCatalogModelCount) 个模型"))
    XCTAssertTrue(service.contains("assignmentPickerPopover(kind)"))
    XCTAssertTrue(service.contains("title: entry.displayName"))
    XCTAssertTrue(service.contains("detail: entry.modelName"))
    XCTAssertTrue(service.contains("model.transcriptionEntryDisplays"))
    XCTAssertTrue(service.contains("model.summaryEntryDisplays"))
    XCTAssertTrue(service.contains("Text(\"\\(entry.title) · \\(entry.modelName)\").font(.caption)"))
    XCTAssertFalse(service.contains("Text(\"\\(entry.title) · 在线转写\").tag(entry.id)"))
    XCTAssertTrue(source.contains("ProviderIconCatalog.image(for: preset)"))
  }

  func testPaperThemeSettingsSidebarKeepsNamedAccessibleButtons() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"
      ),
      encoding: .utf8
    )
    let sidebar = section(in: source, from: "private var paperSidebar", to: "// MARK: - 外观")

    XCTAssertTrue(sidebar.contains(".accessibilityLabel(tab.title)"))
    XCTAssertTrue(sidebar.contains(".accessibilityIdentifier(\"settings-tab-\\(tab.rawValue)\")"))
  }

  /// 各设置页的滚动内边距必须一致。
  ///
  /// 原断言钉的是 generationTab 单独的 `.vertical, 16`。3f9dd83 重写这个视图时把
  /// 三个 tab 统一成了 `.bottom, 24`，实现是有意的，过期的是断言——它从那以后
  /// 一直红着。钉「三个 tab 用同一个值」而不是钉某个具体数字：真正会伤到用户的
  /// 是切换 tab 时底部留白跳变，不是 24 还是 16。
  func testEverySettingsTabUsesTheSameScrollBottomMargin() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"
      ),
      encoding: .utf8
    )
    let occurrences = source.components(separatedBy: ".contentMargins(").count - 1
    XCTAssertGreaterThanOrEqual(occurrences, 3, "设置页少于三处滚动内边距，视图结构可能已变")
    XCTAssertEqual(
      source.components(separatedBy: ".contentMargins(.bottom, 24, for: .scrollContent)").count - 1,
      occurrences,
      "有 tab 用了与其它不同的滚动内边距，切换 tab 时底部留白会跳变"
    )
  }

  func testBrowserSupportSeparatesReceiverHealthFromInstallationOwnership() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/BrowserSupportSettingsView.swift"
      ),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("App 接收服务"))
    XCTAssertTrue(source.contains("下方配置提醒不等于传送失败"))
    XCTAssertTrue(source.contains("Google Chrome"))
    XCTAssertTrue(source.contains("在 Chrome 中加载扩展后即可同步"))
    XCTAssertTrue(source.contains("在 Brave 中加载扩展后即可同步"))
    XCTAssertTrue(source.contains("每个浏览器都需要单独加载扩展并同步一次"))
    XCTAssertFalse(source.contains("Chrome / Brave"))
    XCTAssertTrue(source.contains("配置已就绪"))
    XCTAssertTrue(source.contains("连接到此 App"))
    XCTAssertTrue(source.contains("打开扩展文件夹"))
    XCTAssertFalse(source.contains("备份并继续"))
    XCTAssertFalse(source.contains("安装记录待确认"))
    XCTAssertFalse(source.contains("日用 Host 与测试版 Host 不同"))
    XCTAssertFalse(source.contains("临时切换到测试版 Host"))
  }

  func testReleasePipelinesFreezeAndBindTheExactProviderIconSet() throws {
    let root = repositoryRoot()
    let release = try String(contentsOf: root.appendingPathComponent("scripts/native-host/release_unit.py"), encoding: .utf8)
    let local = try String(contentsOf: root.appendingPathComponent("scripts/native-host/local_test_release.py"), encoding: .utf8)
    let expectedTuple = "(\"bailian.svg\", \"deepinfra.svg\", \"deepseek.svg\", \"groq.svg\", \"ollama.svg\", \"openai.svg\", \"openrouter.svg\", \"siliconflow.svg\", \"stepfun.svg\", \"zhipu.svg\")"

    for source in [release, local] {
      XCTAssertTrue(source.contains("PROVIDER_ICONS_DIRECTORY = \"ProviderIcons\""))
      XCTAssertTrue(source.contains("PROVIDER_ICON_FILES = \(expectedTuple)"))
      XCTAssertTrue(source.contains("verify_provider_icons"))
      XCTAssertTrue(source.contains("providerIcons"))
    }
    XCTAssertTrue(release.contains("resources / PROVIDER_ICONS_DIRECTORY"))
    XCTAssertTrue(release.contains("PROVIDER_ICONS_DIRECTORY}:") || release.contains("PROVIDER_ICONS_DIRECTORY}"))
    XCTAssertTrue(local.contains("PROVIDER_ICON_FILES != r4a.PROVIDER_ICON_FILES"))
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    let afterStart = source.range(of: start).map { source[$0.lowerBound...] } ?? Substring()
    return afterStart.range(of: end).map { String(afterStart[..<$0.lowerBound]) } ?? String(afterStart)
  }
}
