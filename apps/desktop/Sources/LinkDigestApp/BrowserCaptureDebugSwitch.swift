import Foundation

/// 仅调试用：把指定网站的抓取直接交给浏览器代抓。
///
/// 真机上「App 直读」和「App 内置渲染」通常至少有一条能成功（知乎 403 页也能被
/// `rendered_dom` 救回），代抓成功路径因此很难用真实链接走到。需要验证时代码：
///
///     defaults write com.syc.linkdigest LinkDigestForceBrowserRelayHosts -array zhihu.com
///     defaults delete com.syc.linkdigest LinkDigestForceBrowserRelayHosts
///
/// 不进界面、默认空；命中的 host（含子域）跳过直读，按「汲作自己读不到」处理。
struct BrowserCaptureDebugSwitch {
  static let defaultsKey = "LinkDigestForceBrowserRelayHosts"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 这些 host 上没有空写、没有隐藏 UI：只有懂这个键的人才会去写它。
  var forcedHosts: [String] {
    (defaults.array(forKey: Self.defaultsKey) as? [String])?
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty } ?? []
  }

  func forcesRelay(_ urlString: String) -> Bool {
    guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
    return forcedHosts.contains { entry in
      host == entry || host.hasSuffix(".\(entry)")
    }
  }
}
