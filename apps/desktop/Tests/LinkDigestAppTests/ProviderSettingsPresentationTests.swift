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
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "example provider"), "E")
    // 自定义服务商的名字就是 Base URL 的 host，而 host 几乎总是 `api.` 开头——
    // 不剥掉的话所有自定义服务商的徽标都是同一个「A」。
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "api.deepinfra.com"), "D")
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "www.opencode.ai"), "O")
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "Apidog"), "A")
    XCTAssertEqual(ProviderIconCatalog.fallbackInitial(for: "-.-"), "#")
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
  /// 真正会伤到用户的是切换 tab 时底部留白跳变，所以钉的是「每个 tab 都走
  /// 同一个入口」，不是某个具体数字。
  ///
  /// 原断言数的是 `.contentMargins(` 的出现次数。00f707a 把这几处收敛成
  /// `.settingsDetailContentMargins()` 之后它就一直红着——实现是对的，
  /// 过期的是断言。而这次实验室页确实漏接了统一入口、自己写了一份边距，
  /// 说明这条测试盯的东西仍然会坏，只是原来的数法盯不住了。
  func testEverySettingsTabUsesTheSameScrollBottomMargin() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"
      ),
      encoding: .utf8
    )
    let tabs = source.components(separatedBy: ".formStyle(.grouped)").count - 1
    XCTAssertGreaterThanOrEqual(tabs, 4, "设置页少于四个 tab，视图结构可能已变")
    XCTAssertEqual(
      source.components(separatedBy: ".settingsDetailContentMargins()").count - 1,
      tabs,
      "有 tab 没走统一的滚动内边距入口，切换 tab 时底部留白会跳变"
    )
    XCTAssertFalse(
      source.contains(".contentMargins("),
      "边距应当只在 settingsDetailContentMargins() 里定义一次"
    )
  }

  /// 浏览器支持页把「接收服务健康」和「扩展装没装」分开说。
  ///
  /// 这两件事经常同时出问题，但原因和修法完全不同：接收服务挂了要重启 App，
  /// 扩展没装要去浏览器里加载。混在一句话里说，用户只会重复试错误的那一边。
  ///
  /// 原断言逐条钉的是浏览器名和安装提示文案。9dbb4a1 把这些挪进档案表
  /// (`BrowserRegistry`) 之后它就一直红着——实现是对的，过期的是断言。
  /// 现在钉的是那次重构真正要守住的东西：**视图里不出现任何浏览器名**。
  /// 加一个浏览器应该是往档案表加一条数据，不是回来改这个视图。
  func testBrowserSupportSeparatesReceiverHealthFromInstallationOwnership() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/BrowserSupportSettingsView.swift"
      ),
      encoding: .utf8
    )

    // 接收服务的状态自己占一行，和浏览器列表分开。
    XCTAssertTrue(source.contains("receiverStatusLine"))
    XCTAssertTrue(source.contains("接收服务"))
    XCTAssertTrue(source.contains("打开扩展文件夹"))

    // 浏览器名一律来自档案表。只看代码行——注释里举例说明「Chrome、Vivaldi、Arc」
    // 是在解释设计，不是硬编码。
    let code = source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    for name in ["Google Chrome", "Brave", "Microsoft Edge", "Chrome / Brave"] {
      XCTAssertFalse(
        code.contains(name),
        "「\(name)」硬编码在视图里了；浏览器名应当来自 BrowserRegistry"
      )
    }
    XCTAssertTrue(
      source.contains("displayName"),
      "视图应当读档案表里的 displayName"
    )

    // 这些是早先版本里会误导用户的说法，删掉之后不该回来。
    for stale in ["备份并继续", "安装记录待确认", "日用 Host 与测试版 Host 不同", "临时切换到测试版 Host"] {
      XCTAssertFalse(source.contains(stale), "「\(stale)」应当已经删掉")
    }
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
  /// 设置窗口必须与主界面用同一套主题判据。
  ///
  /// 原来设置窗口判的是 `== .paper`（只有浅色主题接管），而主界面判的是
  /// `theme.isNative`（浅色和深色都接管）。后果：深色主题下设置窗口一半是令牌
  /// 画布、一半是系统灰——这是「设置页和主界面不像一家」最主要的来源，而且它
  /// 不报错、不崩溃，只有切到深色主题去看设置页才发现。
  func testSettingsWindowUsesTheSameThemeGateAsTheMainWindow() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8)

    // 主题接管相关的判据一律走 isNativeTheme，不能再用 isPaperTheme。
    for gate in [
      ".scrollContentBackground(isPaperTheme",
      ".background(isPaperTheme",
      ".toolbarBackground(isPaperTheme",
    ] {
      XCTAssertFalse(
        source.contains(gate),
        "\(gate) 用的是浅色专属判据，深色主题下设置窗口会与主界面脱节")
    }
    XCTAssertTrue(
      source.contains("private var isNativeTheme: Bool { settingsTheme.isNative }"),
      "设置窗口应当复用主界面的 isNative 判据")

    // 工具栏复用主界面那份 modifier，而不是自己再写一套判据。
    XCTAssertTrue(
      source.contains("HistoryWindowToolbarThemeModifier(theme: settingsTheme)"),
      "工具栏主题应复用主界面的 modifier，两处各写一份必然漂移")

    // 容器描边必须走令牌：`.separator` 与 `.background.opacity` 都不随主题走。
    let strokeLines = source
      .components(separatedBy: "\n")
      .filter { $0.contains(".stroke(") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    for line in strokeLines {
      XCTAssertFalse(
        line.contains(".separator"),
        "描边用了系统色而不是 settingsTheme.hairline：\(line.trimmingCharacters(in: .whitespaces))")
    }
  }

  /// 设置侧栏的选中药丸必须和主界面侧栏是同一个尺寸。
  ///
  /// 两处都是「图标 + 文字 + 圆角 6 药丸」的同构行，但设置侧栏原来用垂直 7、主界面
  /// 用垂直 3，实测药丸高 34pt vs 23.5pt。颜色令牌已经统一之后，这个 10pt 的高度差
  /// 就是并排看两个窗口时最先察觉的不一致——它不报错，只是看着不像一家。
  func testSettingsSidebarRowUsesTheSameVerticalPaddingAsTheMainSidebar() throws {
    let root = repositoryRoot()
    let settings = try String(
      contentsOf: root.appendingPathComponent("apps/desktop/Sources/LinkDigestApp/ProviderSettingsView.swift"),
      encoding: .utf8)
    let history = try String(
      contentsOf: root.appendingPathComponent("apps/desktop/Sources/LinkDigestApp/HistoryContentView.swift"),
      encoding: .utf8)

    // 主界面 navigationButton 的垂直内边距就是这套侧栏刻度的真相源。
    let mainRow = section(in: history, from: "private func navigationButton(", to: "private func countBadge(")
    let mainPadding = mainRow
      .components(separatedBy: "\n")
      .first { $0.contains(".padding(.vertical,") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    XCTAssertEqual(
      mainPadding?.contains(".padding(.vertical, 3)"), true,
      "主界面侧栏行的垂直刻度变了，设置侧栏的断言需要跟着改：\(mainPadding ?? "<未找到>")")

    let sidebar = section(in: settings, from: "private var paperSidebar: some View {", to: "private var settingsTheme")
    XCTAssertTrue(
      sidebar.contains(".padding(.vertical, 3)"),
      "设置侧栏行的垂直刻度与主界面侧栏不一致，选中药丸会明显更粗")
  }

  /// 浏览器列表的每一行必须长得一样。
  ///
  /// 浏览器名长度不同，状态词紧跟在名字后面时，状态列的起点就参差不齐——
  /// 一屏里直接可见，看上去像几种不同的东西而不是一张列表。
  ///
  /// 原断言钉的是「接收状态行 34pt 瓦片 / 浏览器行 34pt 占位」这套对齐方式。
  /// 9dbb4a1 把接收状态收成了一行 caption 文字、浏览器列表换成 `Grid`，
  /// 那两个数字整个消失了，断言从此一直红着。关注点没变，承载方式变了：
  /// 现在钉 Grid 的列对齐。
  func testBrowserRowsAlignInColumns() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "apps/desktop/Sources/LinkDigestApp/BrowserSupportSettingsView.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("Grid("), "浏览器列表不再用 Grid，多行时列会参差不齐")
    let row = section(in: source, from: "private func browserStatusRow", to: "private func browserAction")
    XCTAssertTrue(row.contains("GridRow {"), "浏览器行不在 Grid 的行结构里，列对齐不会生效")
    XCTAssertGreaterThanOrEqual(
      row.components(separatedBy: ".gridColumnAlignment(.leading)").count - 1, 2,
      "名字列和状态列都要显式左对齐，否则 Grid 会按各自内容居中")
  }
}
