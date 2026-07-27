import XCTest
@testable import LinkDigestCore

/// 「App 只能在打包它的机器上跑」那个缺陷的回归护栏。
///
/// 背景见 `CoreResourceBundle` 的类型注释。这里要守两件事：解析结果落在
/// `Contents/Resources`（而不是编译期 `.build` 路径），以及 `Bundle.module` 不出现在任何
/// 会被生产路径求值的位置。
///
/// **这些测试不能替代实测**：测试进程里 `Bundle.module` 永远是好的，第二件事只能靠读
/// 源码断言。唯一可靠的端到端验证是把 `.build` 改名后运行打包出的 `.app`。
final class CoreResourceBundleTests: XCTestCase {
  /// `.app` 场景必须解析到 `Contents/Resources/<包名>`——打包器真实放置的位置。
  func testApplicationBundleResolvesInsideContentsResources() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("linkdigest-resourcebundle-\(UUID().uuidString)", isDirectory: true)
    let appURL = root.appendingPathComponent("LinkDigest.app", isDirectory: true)
    let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let bundleURL = resources.appendingPathComponent(CoreResourceBundle.bundleName, isDirectory: true)
    // 资源包本身没有 Info.plist，只有 Resources/——照搬真实结构。
    try FileManager.default.createDirectory(
      at: bundleURL.appendingPathComponent("Resources", isDirectory: true),
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(#"{"a":1}"#.utf8).write(
      to: bundleURL.appendingPathComponent("Resources/probe.json"))
    // Bundle(path:) 只认有 Info.plist 的 .app，否则 mainBundle.resourceURL 会是 nil。
    try Data("{}".utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    let mainBundle = try XCTUnwrap(Bundle(path: appURL.path))

    let resolved = try XCTUnwrap(
      CoreResourceBundle.resolved(mainBundle: mainBundle, executableURL: nil),
      "`.app` 场景没能解析出资源包，换机启动会 fatal error")

    XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, bundleURL.standardizedFileURL.path)
    XCTAssertFalse(
      resolved.bundleURL.path.contains(".build/"),
      "解析结果落在编译期 .build 路径上，等于又回到只能在本机跑的状态")
    // 关键：无 Info.plist 的 SwiftPM 资源包，url(forResource:) 也要能在 Resources/ 下找到。
    XCTAssertNotNil(
      resolved.url(forResource: "probe", withExtension: "json"),
      "Bundle(url:) 加载后取不到资源，说明这种包结构不能这样访问")
  }

  /// 裸可执行文件场景（`swift run`）：资源包与可执行文件同级。
  ///
  /// 只能测拼接、测不到分支选择——XCTest 进程里 `NSClassFromString("XCTestCase")` 恒非空，
  /// `resolved(...)` 的判断会先落进 test 分支。
  func testExecutableLayoutPutsTheBundleNextToTheBinary() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("linkdigest-exec-\(UUID().uuidString)", isDirectory: true)
    let bundleURL = root.appendingPathComponent(CoreResourceBundle.bundleName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundleURL.appendingPathComponent("Resources", isDirectory: true),
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = try XCTUnwrap(CoreResourceBundle.bundle(inDirectory: root))
    XCTAssertEqual(resolved.bundleURL.standardizedFileURL.path, bundleURL.standardizedFileURL.path)
  }

  /// `Bundle.module` 只允许出现在 `moduleBundle()` 这一行里。
  ///
  /// 只能靠读源码断言：Swift 的默认参数每次调用都求值，写在别处的 `Bundle.module` 会在
  /// 进入函数体之前就触发 SwiftPM 访问器的 fatalError，哪怕根本走不到 test 分支。
  /// **单元测试永远抓不到它**——测试进程里 `Bundle.module` 是好的。第一版修复就是这么写
  /// 的，跑完全绿，把 .build 改名再运行 .app 才发现报错和修复前一模一样。
  func testModuleBundleIsOnlyReachableThroughTheDeferredHelper() throws {
    let source = try String(
      contentsOf: sourcesDirectory.appendingPathComponent("CoreResourceBundle.swift"),
      encoding: .utf8)

    let codeMentions = source
      .components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .filter { $0.contains(".module") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
    XCTAssertEqual(
      codeMentions, ["static func moduleBundle(_ module: Bundle = .module) -> Bundle { module }"],
      "Bundle.module 出现在了 moduleBundle 之外的代码里，生产路径会被求值并 fatal error")
  }

  /// 生产代码里不许再有裸的 `.module`——所有调用点都必须走 `CoreResourceBundle`。
  ///
  /// 第一轮修复漏掉了 `BrowserSupportInstaller`：它写的是简写 `.module` 而不是
  /// `Bundle.module`，grep 没命中，改完再实测仍然崩在同一个地方。
  func testNoProductionCodeReachesForModuleBundleDirectly() throws {
    // CoreResourceBundle 是唯一入口；JSONSchema 有自己等价且已验证的 testLocator 结构。
    let exempt: Set<String> = ["CoreResourceBundle.swift", "JSONSchema.swift"]
    var offenders: [String] = []

    let enumerator = FileManager.default.enumerator(
      at: sourcesDirectory, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift", !exempt.contains(url.lastPathComponent) else { continue }
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(".module"), !trimmed.hasPrefix("//") else { continue }
        offenders.append("\(url.lastPathComponent): \(trimmed)")
      }
    }

    XCTAssertEqual(offenders, [], "这些地方直接用了模块资源包，换机会 fatal error")
  }

  private var sourcesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestCore")
  }
}
