import Foundation

/// 定位 SwiftPM 为 `LinkDigestCore` 生成的资源包。
///
/// ## 为什么不直接用 `Bundle.module`
///
/// SwiftPM 生成的访问器只认两个位置：`.app` 的**根目录**
/// （`Bundle.main.bundleURL/<包名>`），以及一条**编译时写死的本机 `.build` 绝对路径**。
/// 而打包器把资源包放在 `Contents/Resources/`——那是正确、可密封、能通过
/// `codesign --verify --strict` 的位置，问题从来不是"放错了"，是代码没去找对地方。
///
/// 后果：`.app` 只能在打包它的那台机器上跑，靠 `.build` 那条绝对路径兜底；换到任何
/// 没有该路径的机器，启动即 `Fatal error: could not load resource bundle`。这影响
/// `release/` 下所有 DMG，长期没暴露是因为发布自动化从不启动 App
/// （`local_test_release_check.py` 有一条护栏明确禁止 `open`/`osascript`/`launchctl`）。
///
/// 2026-07-27 把 `.build` 改名后运行已部署的 `.app`，实测复现了这个 fatal error。
///
/// ## 两个必须守住的实现约束
///
/// 1. **`Bundle.module` 绝不能出现在会被生产路径求值的位置**，尤其是默认参数——
///    Swift 的默认参数是「每次调用时求值」，不是惰性的。第一版修复把
///    `moduleResourceURL: URL? = Bundle.module.resourceURL` 写成默认参数，结果哪怕走
///    `.app` 分支，`Bundle.module` 也已经在进入函数体前被求值，照样 fatal error。
///    所以它只能关在 `moduleBundle()` 里，由 test 分支**调用**。
/// 2. **单元测试抓不到第 1 条**——测试进程里 `Bundle.module` 本来就是好的。唯一可靠的
///    验证是把 `.build` 改名后运行打包出的 `.app`。源码级护栏见
///    `CoreResourceBundleTests`。
enum CoreResourceBundle {
  /// 与 `CaptureWireContractSchema.resourceBundleName` 指的是同一个包，一致性由测试钉住。
  static let bundleName = "LinkDigest_LinkDigestCore.bundle"

  /// 按运行环境解析资源包。
  ///
  /// 判据照抄 `CaptureWireContractSchema.runtimeLocator()`——那套逻辑已经在生产跑了很久
  /// （抓取解码链每天在用），这里不发明新设计。
  static func resolved(
    mainBundle: Bundle = .main,
    executableURL: URL? = Bundle.main.executableURL
  ) -> Bundle? {
    if mainBundle.bundleURL.pathExtension == "app" {
      // 打包产物：Contents/Resources/<包名>
      return mainBundle.resourceURL.flatMap(bundle(inDirectory:))
    }
    if mainBundle.bundleURL.pathExtension == "xctest" || NSClassFromString("XCTestCase") != nil {
      // 只有 XCTest 允许退回编译期的模块资源包；标准 .app 永远走不到这里。
      return moduleBundle()
    }
    // 裸可执行文件（`swift run`）：资源包与可执行文件同级。
    return executableURL
      .map { $0.deletingLastPathComponent() }
      .flatMap(bundle(inDirectory:))
  }

  /// 资源包有**两种**磁盘布局，取决于是单架构还是 universal 构建：
  ///
  /// - 单架构：扁平包，`<包>/Resources/xxx.json`。包里没有 `Info.plist`，
  ///   `Bundle(url:)` 把包根当资源根，`url(forResource:)` 直接命中。
  /// - universal（`--arch arm64 --arch x86_64`）：SwiftPM 改用标准 macOS 包，
  ///   变成 `<包>/Contents/Resources/**Resources**/xxx.json`。资源根是
  ///   `Contents/Resources`，而文件又被套进里面一层同名的 `Resources/`，
  ///   于是 `url(forResource:)` 在资源根找不到任何东西。
  ///
  /// 后者会让 `ProductDisplay.values` 的 `preconditionFailure` 在 SwiftUI 取
  /// `App.body` 时立刻触发——**App 启动即崩，且崩在任何窗口出现之前**。
  ///
  /// 所以内层目录存在时优先把它当资源包：那一层没有 `Info.plist`，`Bundle(url:)`
  /// 同样会把它当扁平包，于是两种构建走到同一套查找语义。
  static func bundle(inDirectory directory: URL) -> Bundle? {
    let packageRoot = directory.appendingPathComponent(bundleName, isDirectory: true)
    let nested = packageRoot.appendingPathComponent("Contents/Resources/Resources", isDirectory: true)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory),
       isDirectory.boolValue,
       let nestedBundle = Bundle(url: nested) {
      return nestedBundle
    }
    return Bundle(url: packageRoot)
  }

  /// 唯一允许触碰 `Bundle.module` 的地方；单独成函数是为了**推迟求值**，见类型注释第 1 条。
  static func moduleBundle(_ module: Bundle = .module) -> Bundle { module }
}
