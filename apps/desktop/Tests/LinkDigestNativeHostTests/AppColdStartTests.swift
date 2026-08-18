import XCTest
@testable import LinkDigestNativeHost

/// 冷启动是「浏览器点发送，但 App 没开着」时唯一让内容进得来的那条路。
///
/// 它没有界面：失败时用户只看到扩展报一句错，看不出是「不许自动启动」「找不到
/// App」还是「open 失败」。所以这里逐条钉住每个分支的判断依据和副作用——尤其是
/// 「不该启动时绝不启动」，那是用户显式关掉自动启动后的唯一保障。
final class AppColdStartTests: XCTestCase {
  // MARK: 环境变量开关

  func testAutoLaunchDisabledAcceptsTheDocumentedTruthyValuesOnly() {
    // 三种写法都要认：用户不会去查我们内部认哪一个。
    for raw in ["1", "true", "yes", "TRUE", "Yes", " true ", "\n1\t"] {
      XCTAssertTrue(
        AppColdStart.autoLaunchDisabledFrom(["LINKDIGEST_DISABLE_AUTO_LAUNCH": raw]),
        "\(raw.debugDescription) 应当关闭自动启动"
      )
    }
    // 其余一律当成没关。把 "0"/"false" 误判成「关闭」会让自动启动整个失效，
    // 而症状是「点发送没反应」——没有任何提示指向这个开关。
    for raw in ["0", "false", "no", "", " ", "maybe", "2"] {
      XCTAssertFalse(
        AppColdStart.autoLaunchDisabledFrom(["LINKDIGEST_DISABLE_AUTO_LAUNCH": raw]),
        "\(raw.debugDescription) 不该被当成关闭"
      )
    }
    XCTAssertFalse(AppColdStart.autoLaunchDisabledFrom([:]), "没设这个变量时默认允许自动启动")
  }

  // MARK: 启动决策

  func testDisabledEnvironmentNeverLaunches() {
    var launched: [URL] = []
    let bundle = try! makeAppBundle()
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      hostExecutable: bundle.appendingPathComponent("Contents/MacOS/Host"),
      environment: [
        "LINKDIGEST_DISABLE_AUTO_LAUNCH": "1",
        "LINKDIGEST_APP_BUNDLE_PATH": bundle.path,
      ],
      launcher: { launched.append($0) }
    )
    XCTAssertFalse(didLaunch)
    // 返回 false 还不够：真正要保证的是**一次都没启动**。
    XCTAssertEqual(launched, [], "用户显式关掉自动启动后，绝不能拉起 App")
  }

  func testExplicitOpenIgnoresAutoLaunchDisableAndStillUsesThePeerBundle() throws {
    let bundle = try makeAppBundle()
    var launched: [URL] = []
    let didOpen = AppColdStart.openPeerApp(
      hostExecutable: bundle.appendingPathComponent("Contents/MacOS/Host"),
      environment: [
        "LINKDIGEST_DISABLE_AUTO_LAUNCH": "1",
        "LINKDIGEST_APP_BUNDLE_PATH": bundle.path,
      ],
      launcher: { launched.append($0) }
    )
    XCTAssertTrue(didOpen, "用户点「打开汲作」不能被发送时的自动启动开关挡住")
    XCTAssertEqual(launched.map(\.standardizedFileURL), [bundle.standardizedFileURL])
  }

  func testLaunchesTheResolvedPeerBundle() throws {
    let bundle = try makeAppBundle()
    var launched: [URL] = []
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      hostExecutable: bundle.appendingPathComponent("Contents/Resources/NativeHost/Host"),
      environment: [:],
      launcher: { launched.append($0) }
    )
    XCTAssertTrue(didLaunch)
    // 必须是从 host 可执行文件往上找到的那个 .app，不是别的。拉错 bundle 意味着
    // 内容送进了另一份安装，用户会以为「抓取丢了」。
    XCTAssertEqual(launched.map(\.standardizedFileURL), [bundle.standardizedFileURL])
  }

  func testUnresolvableBundleDoesNotLaunch() {
    var launched: [URL] = []
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      // 路径里没有任何 .app 祖先。
      hostExecutable: URL(fileURLWithPath: "/usr/local/bin/LinkDigestNativeHost"),
      environment: [:],
      launcher: { launched.append($0) }
    )
    XCTAssertFalse(didLaunch)
    XCTAssertEqual(launched, [])
  }

  func testMissingBundleOnDiskDoesNotLaunch() {
    var launched: [URL] = []
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("LinkDigestNativeHostTests-absent-\(UUID().uuidString).app")
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      hostExecutable: missing.appendingPathComponent("Contents/MacOS/Host"),
      environment: [:],
      launcher: { launched.append($0) }
    )
    XCTAssertFalse(didLaunch)
    // 路径解析得出来不等于东西还在：App 被删或被移走时走的就是这条。
    XCTAssertEqual(launched, [])
  }

  func testLauncherFailureIsReportedAsNotLaunched() throws {
    struct LaunchFailure: Error {}
    let bundle = try makeAppBundle()
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      hostExecutable: bundle.appendingPathComponent("Contents/MacOS/Host"),
      environment: [:],
      launcher: { _ in throw LaunchFailure() }
    )
    // `open` 失败必须回落成 false，让调用方走「App 不可用」而不是继续等一个
    // 永远不会出现的 socket。
    XCTAssertFalse(didLaunch)
  }

  /// 这条钉的是**行为**，不是某一层的实现。
  ///
  /// 「不是 .app 就不许启动」眼下有两道独立的关卡：`AppBundleLocator` 在解析
  /// override 时就拒绝，`launchPeerAppIfNeeded` 自己又查一次后缀。实测（逐条
  /// 改坏验证过）拿掉任意一道这条测试仍是绿的，两道一起拿掉才变红——所以它
  /// 保证的是「这个不变量至少还有人守着」，不保证具体是谁守。
  ///
  /// 这样写是有意的：`LINKDIGEST_APP_BUNDLE_PATH` 是演练用的开关，重构时哪一层
  /// 负责校验完全可以变，但它任何时候都不能变成「拉起任意程序」。
  func testEnvironmentOverrideMustStillPointAtAnAppBundle() throws {
    let bundle = try makeAppBundle()
    var launched: [URL] = []
    let didLaunch = AppColdStart.launchPeerAppIfNeeded(
      hostExecutable: bundle.appendingPathComponent("Contents/MacOS/Host"),
      environment: ["LINKDIGEST_APP_BUNDLE_PATH": "/usr/bin"],
      launcher: { launched.append($0) }
    )
    XCTAssertFalse(didLaunch)
    XCTAssertEqual(launched, [])
  }

  // MARK: 冷启动预算

  func testRemainingTimeoutShrinksButNeverGoesBelowTheFloor() {
    let total: TimeInterval = 25

    // 刚开始：几乎是全部预算。
    XCTAssertEqual(
      AppColdStart.remainingTimeout(since: Date(), total: total, floor: 1),
      total,
      accuracy: 0.5
    )

    // 已经花掉 10 秒：剩下的要真的变少，否则每次重试都按满额等，
    // 整体耗时会滚成预算的好几倍。
    XCTAssertEqual(
      AppColdStart.remainingTimeout(since: Date(addingSeconds: -10), total: total, floor: 1),
      15,
      accuracy: 0.5
    )

    // 预算早就花完：仍然给一个下限，而不是 0 或负数。0 会让这次发送立刻超时，
    // 于是「App 正好刚起来」也会被判成失败。
    XCTAssertEqual(
      AppColdStart.remainingTimeout(since: Date(addingSeconds: -100), total: total, floor: 0.5),
      0.5,
      accuracy: 0.01
    )
  }

  // MARK: 夹具

  func testLaunchWithOpenTargetsTheAbsoluteAppPathViaDashA() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestNativeHost/AppColdStart.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(
      source.contains("process.arguments = [\"-a\", appBundle.path]"),
      "必须用 open -a 绝对路径；裸 open linkdigest:// 会打到过期的 Launch Services 声明"
    )
  }

  /// 造一个够真实的 `.app`：`AppBundleLocator` 沿父目录往上找 `.app` 后缀，
  /// 启动前还要 `fileExists`，所以目录必须真的存在。
  private func makeAppBundle(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LinkDigestNativeHostTests-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("汲作.app", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents/Resources/NativeHost", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return bundle
  }
}

private extension Date {
  init(addingSeconds seconds: TimeInterval) {
    self = Date().addingTimeInterval(seconds)
  }
}
