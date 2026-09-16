import Foundation
import LinkDigestCore

enum BrowserSupportAction: String, Identifiable {
  case install
  case repair

  var id: String { rawValue }
  var title: String { self == .install ? "安装浏览器支持" : "修复浏览器支持" }
}

enum BrowserSupportResultKind: String { case installed, repaired, uninstalled, restored }

struct BrowserSupportResult: Identifiable {
  let browser: BrowserSupportBrowser
  let kind: BrowserSupportResultKind
  var id: String { "\(browser.id)-\(kind.rawValue)" }
}

struct BrowserSupportConfirmation: Identifiable {
  let action: BrowserSupportAction
  let browser: BrowserSupportBrowser
  let fingerprint: String
  var id: String { "\(action.rawValue)-\(browser.id)" }
}

/// 需要用户亲自选一次目录，macOS 才肯放行。
///
/// 不是「出错了」，是「还差一步」——所以它有自己的展示，不进错误栏。`action` 记着被挡下
/// 的到底是哪个动作，授权成功后要原样重放，不能一律当成全新安装。
struct BrowserSupportAccessRequest: Identifiable {
  let browser: BrowserSupportBrowser
  /// 需要授权的那个目录——由安装器报上来的、**真正被系统拒掉的那一段**。
  ///
  /// 不能自己拼成叶子目录（`.../NativeMessagingHosts`）：被拦下的通常是它的父目录
  /// （`.../Application Support/Microsoft Edge`）。给叶子授权不解决父目录打不开的问题，
  /// 重试还是失败，界面就会反复弹同一个框——这是实际发生过的。
  let directory: URL
  var id: String { "access-\(browser.id)" }
}

enum BrowserSupportPresentation: Identifiable {
  case confirmation(BrowserSupportConfirmation)
  case result(BrowserSupportResult)
  case accessRequest(BrowserSupportAccessRequest)

  var id: String {
    switch self {
    case let .confirmation(value): "confirmation-\(value.id)"
    case let .result(value): "result-\(value.id)"
    case let .accessRequest(value): "request-\(value.id)"
    }
  }
}

@MainActor
final class BrowserSupportViewModel: ObservableObject {
  @Published private(set) var statuses: [BrowserSupportStatus] = []
  @Published private(set) var isLoading = false
  @Published private(set) var activeBrowser: BrowserSupportBrowser?
  @Published var presentation: BrowserSupportPresentation?
  @Published private(set) var errorText: String?
  /// 每个浏览器最近一次真的把内容送进来的时间。
  ///
  /// manifest 装没装由安装器负责，那只说明「允许连接」；这一份说明「到底在不在用」。
  /// 两件事互相独立，所以不塞进 `BrowserSupportStatus`。
  @Published private(set) var lastDeliveries: [BrowserSupportBrowser: Date] = [:]

  private let installer: (any BrowserSupportInstalling)?
  private let deliveryLog: BrowserDeliveryLog?
  /// 判断浏览器 app 还在不在的搜索路径；`nil` 表示不过滤。
  ///
  /// 这一层过滤放在这里而不是安装器里：安装器的 `inspect()` 同时被 clean-room 崩溃 harness
  /// 用，那是带证据的冻结门禁，不该为一个「别显示已卸载的浏览器」的展示问题改它的语义。
  private let applicationRoots: [URL]?

  init(
    installer: (any BrowserSupportInstalling)?,
    deliveryLog: BrowserDeliveryLog? = nil,
    applicationRoots: [URL]? = nil
  ) {
    self.installer = installer
    self.deliveryLog = deliveryLog
    self.applicationRoots = applicationRoots
  }

  func lastDelivery(for browser: BrowserSupportBrowser) -> Date? {
    lastDeliveries[browser]
  }

  var isAvailable: Bool { installer != nil }

  var pendingConfirmation: BrowserSupportConfirmation? {
    guard case let .confirmation(value) = presentation else { return nil }
    return value
  }

  var result: BrowserSupportResult? {
    guard case let .result(value) = presentation else { return nil }
    return value
  }

  var pendingAccessRequest: BrowserSupportAccessRequest? {
    guard case let .accessRequest(value) = presentation else { return nil }
    return value
  }

  func cancelPendingAccessRequest() { presentation = nil }

  /// 已经为这个目录求过一次授权了。
  ///
  /// 用来兜住「授权完还是被拒」——那说明这条路对这个目录不成立（比如 App 是 ad-hoc
  /// 签名，系统认不住它的身份）。这时候必须把话说清楚，而不是把同一个框再弹一遍：
  /// 反复弹框既解决不了问题，也让人无从判断是自己点错了还是根本没用。
  private var attemptedAccessGrants: Set<String> = []

  private func presentAccessRequest(browser: BrowserSupportBrowser, deniedPath: String) {
    guard !attemptedAccessGrants.contains(deniedPath) else {
      errorText = """
        你已经授权过了，但 macOS 还是不让汲作打开这个文件夹：\(deniedPath)。\
        浏览器和你保存的内容都没有受影响。\
        请到「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里把 \(ProductDisplay.name) 加进去，再回来点一次「连接」。
        """
      return
    }
    presentation = .accessRequest(.init(browser: browser, directory: URL(fileURLWithPath: deniedPath, isDirectory: true)))
  }

  /// 用户在面板里选完目录之后，把刚才被挡下的那件事再走一遍。
  ///
  /// 走 `requestInstall` 而不是直接 `execute`：被挡下的如果是「接管已有 manifest」，
  /// 硬调安装会立刻再撞一次 confirmationRequired。重新判状态才能接着走该走的那条路。
  ///
  /// 只接受「选中的正好是那个目录」。选别的目录不会让 macOS 放行我们要写的位置，
  /// 重试只会再失败一次，而用户会以为问题出在别处。
  func completeAccessRequest(_ request: BrowserSupportAccessRequest, granted: URL?) async {
    presentation = nil
    guard let granted, granted.standardizedFileURL == request.directory.standardizedFileURL else {
      errorText = "选中的不是要授权的那个文件夹，所以这次没连上，什么都没改。请重新点「连接」，在打开的窗口里直接点右下角的按钮——要选的是 \(request.browser.displayName) 的扩展连接文件夹（NativeMessagingHosts）本身。"
      return
    }
    errorText = nil
    attemptedAccessGrants.insert(request.directory.standardizedFileURL.path)
    await requestInstall(request.browser)
  }

  func status(for browser: BrowserSupportBrowser) -> BrowserSupportStatus {
    statuses.first(where: { $0.browser == browser })
      ?? .init(browser: browser, state: installer == nil ? .unavailableArtifact : .unavailable, hasRecoverableBackup: false)
  }

  func canInstall(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && status(for: browser).state == .notInstalled
  }

  func canRepair(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable
      && [.currentAppUnverified, .drifted, .unknownManifest, .installedAppUpdated].contains(status(for: browser).state)
  }

  func canUninstall(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && [.installed, .installedAppUpdated].contains(status(for: browser).state)
  }

  func canRestore(_ browser: BrowserSupportBrowser) -> Bool {
    !isLoading && activeBrowser == nil && isAvailable && [.installed, .installedAppUpdated].contains(status(for: browser).state) && status(for: browser).hasRecoverableBackup
  }

  func load() async {
    guard !isLoading, activeBrowser == nil else { return }
    guard let installer else {
      // 工件不可用时也只列本机装着的：这里列的是「你有哪些浏览器」，跟工件在不在无关。
      statuses = presentable(
        BrowserSupportBrowser.allKnown.map {
          BrowserSupportStatus(browser: $0, state: .unavailableArtifact, hasRecoverableBackup: false)
        })
      return
    }
    isLoading = true
    await refreshStatuses(installer)
    refreshDeliveries()
    isLoading = false
  }

  /// 重读安装状态的**唯一**入口。
  ///
  /// 原来每个动作结束后各写一遍 `statuses = await installer.inspect()`，而过滤只加在了
  /// `load()` 那一处——于是点任何一个按钮，已卸载的浏览器就全回来了。同一件事写在五个
  /// 地方，就一定会漏掉其中几个，所以这里不留第二条路径。
  private func refreshStatuses(_ installer: any BrowserSupportInstalling) async {
    statuses = presentable(await installer.inspect())
  }

  /// 去掉「档案目录还在、app 已经卸载了」的浏览器。
  ///
  /// 卸载浏览器不会删 `Application Support` 下的档案目录，所以只按目录判断的话，这一页会
  /// 多出几行点开什么都不会发生的浏览器。安装器照旧认它们（收据、恢复都还要能用），只是
  /// 不摆到人眼前。
  private func presentable(_ statuses: [BrowserSupportStatus]) -> [BrowserSupportStatus] {
    guard let applicationRoots else { return statuses }
    return statuses.filter { $0.browser.isApplicationPresent(in: applicationRoots) }
  }

  /// 只重读送达记录，不碰安装器。
  ///
  /// 送达是页面开着的时候随时会发生的事——你在浏览器里点一次同步，这一行就该跟着变。
  /// 但 `load()` 会去扫三个浏览器的 NativeMessagingHosts 目录并校验收据，那是进页面
  /// 时做一次的事，不能每两秒来一遍。读一个几十字节的 JSON 才可以。
  func refreshDeliveries() {
    lastDeliveries = deliveryLog?.allDeliveries() ?? [:]
  }

  /// This entry guard deliberately mirrors the buttons.  Direct calls cannot
  /// skip confirmation or enqueue a second filesystem transaction.
  func requestInstall(_ browser: BrowserSupportBrowser) async {
    guard canInstall(browser) || canRepair(browser) else { return }
    let state = status(for: browser).state
    let action: BrowserSupportAction = state == .notInstalled ? .install : .repair
    if [.currentAppUnverified, .drifted, .unknownManifest].contains(state) {
      guard let fingerprint = status(for: browser).replacementFingerprint else { return }
      presentation = .confirmation(.init(action: action, browser: browser, fingerprint: fingerprint))
      return
    }
    await execute(action, browser: browser)
  }

  func confirmReplacement(_ confirmation: BrowserSupportConfirmation) async {
    guard activeBrowser == nil,
          confirmation.action == .repair,
          !confirmation.fingerprint.isEmpty
    else { return }
    presentation = nil
    guard let installer else { return }
    activeBrowser = confirmation.browser
    errorText = nil
    do {
      try await installer.confirmReplacement(confirmation.browser, expectedFingerprint: confirmation.fingerprint)
      presentation = .result(.init(browser: confirmation.browser, kind: .repaired))
    } catch let BrowserSupportInstallerError.directoryAccessDenied(path) {
      presentAccessRequest(browser: confirmation.browser, deniedPath: path)
    } catch {
      errorText = visibleError(for: error)
    }
    await refreshStatuses(installer)
    activeBrowser = nil
  }

  func cancelPendingReplacement() { presentation = nil }

  func uninstall(_ browser: BrowserSupportBrowser) async {
    guard canUninstall(browser), let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.uninstall(browser)
      presentation = .result(.init(browser: browser, kind: .uninstalled))
    } catch {
      errorText = visibleError(for: error)
    }
    await refreshStatuses(installer)
    activeBrowser = nil
  }

  func restore(_ browser: BrowserSupportBrowser) async {
    guard canRestore(browser), let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.restoreLatestBackup(browser)
      presentation = .result(.init(browser: browser, kind: .restored))
    } catch {
      errorText = visibleError(for: error)
    }
    await refreshStatuses(installer)
    activeBrowser = nil
  }

  private func execute(_ action: BrowserSupportAction, browser: BrowserSupportBrowser) async {
    guard activeBrowser == nil, let installer else { return }
    activeBrowser = browser
    errorText = nil
    presentation = nil
    do {
      try await installer.install(browser)
      presentation = .result(.init(browser: browser, kind: action == .install ? .installed : .repaired))
    } catch let BrowserSupportInstallerError.directoryAccessDenied(path) {
      presentAccessRequest(browser: browser, deniedPath: path)
    } catch {
      errorText = visibleError(for: error)
    }
    await refreshStatuses(installer)
    activeBrowser = nil
  }

  private func visibleError(for error: Error) -> String {
    switch error as? BrowserSupportInstallerError {
    case .browserNotDetected:
      "没有找到这个浏览器的扩展连接文件夹（NativeMessagingHosts），所以连不上。什么都没有被改动。请先把这个浏览器打开一次再点「重新检查」。"
    case .frozenArtifactUnavailable:
      "这一版汲作里没带浏览器连接文件，所以连不上。你保存的内容不受影响。请换成完整版安装包重新装一次。"
    case .confirmationRequired:
      "这个浏览器里已经有一份同名的连接配置，汲作没有直接覆盖它。你的内容和浏览器数据都没被动过。请在弹出的确认框里同意「先备份再接管」。"
    case .confirmationStale:
      "刚才那份连接配置在你确认期间变了，为安全起见没有覆盖。什么都没有被改动。请点「重新检查」看一下最新状态，再连一次。"
    case .uninstallRefused:
      "这个浏览器里的连接文件不是 \(ProductDisplay.name) 装的，所以没有删它。现有文件原样保留。请在浏览器里自行确认后再处理。"
    case .restoreRefused:
      "现在这个连接文件确认不了是 \(ProductDisplay.name) 的，所以没有覆盖它。文件原样保留。请在浏览器里自行确认后再处理。"
    case .unsafeFilesystemState:
      "这次检查发现文件夹状态不安全，汲作一个字都没往浏览器目录里写。你的内容和浏览器数据都没被动过。请重新打开汲作后再点「连接」。"
    // 这条不该出现在错误栏里——它有对应的动作（选一次目录授权），走 `.accessRequest`
    // 那条路。留在这里只是兜底，防止哪天新加的入口忘了处理。
    case .directoryAccessDenied:
      "macOS 没让 \(ProductDisplay.name) 打开这个浏览器的文件夹，所以没连上。什么都没有被改动。请重新点「连接」，按提示授权一次。"
    case .transactionFailed, .none:
      "这次连接没做完。现有文件已经保持原样或还原回去了，浏览器和你保存的内容都没受影响。请点「重新检查」后再试一次。"
    }
  }
}
