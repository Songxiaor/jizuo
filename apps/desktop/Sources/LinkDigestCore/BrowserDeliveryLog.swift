import Foundation

/// 每个浏览器最近一次把内容送到 App 的时间。
///
/// 这一页需要回答的是「这个浏览器到底在不在用」。原来它只报 Native Messaging manifest
/// 装没装——那由 App 自己写，不需要浏览器配合，所以永远是「已配置」，扩展删掉了也不变。
///
/// 直接读浏览器档案判断扩展在不在这条路走不通：macOS 不许 App 读其它 App 的数据目录，
/// 正常启动的 App 拿到的是 `EPERM`，而且**不弹授权框**。（从终端启动能读，那是继承了
/// 终端的完全磁盘访问，不代表装到别人机器上能用。）
///
/// 所以改用我们自己拥有的证据：native host 是被浏览器拉起来的，它知道自己的父进程是谁，
/// 也知道这次有没有真的把内容送进 App。这条记录不需要任何权限，而且它陈述的是既成事实
/// （「最近一次同步是什么时候」），不会像状态推断那样过期成谎话。
public struct BrowserDeliveryLog: Sendable {
  private let fileURL: URL

  /// `root` 可注入：测试写 `/private/tmp` 的干净目录，不碰真人的记录。
  public init(root: URL) {
    self.fileURL = root
      .appendingPathComponent("Library/Application Support/LinkDigest/BrowserSupport", isDirectory: true)
      .appendingPathComponent("last-delivery-v1.json", isDirectory: false)
  }

  public static func standard() -> BrowserDeliveryLog {
    .init(root: FileManager.default.homeDirectoryForCurrentUser)
  }

  public func lastDelivery(for browser: BrowserSupportBrowser) -> Date? {
    read()[browser.id]
  }

  public func allDeliveries() -> [BrowserSupportBrowser: Date] {
    let raw = read()
    return raw.reduce(into: [:]) { result, pair in
      guard let browser = BrowserSupportBrowser.known(id: pair.key) else { return }
      result[browser] = pair.value
    }
  }

  /// 记录一次成功送达。
  ///
  /// 读-改-写而不是整份覆盖：三个浏览器共用一份记录，直接覆盖会把别人的时间抹掉。
  /// 两个 host 同时写最坏是丢一条时间戳——这是个展示用的事实，不值得为它上锁。
  public func record(_ browser: BrowserSupportBrowser, at date: Date = Date()) {
    var entries = read()
    entries[browser.id] = date
    write(entries)
  }

  private func read() -> [String: Date] {
    guard
      let data = try? Data(contentsOf: fileURL),
      let raw = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    let formatter = ISO8601DateFormatter()
    return raw.reduce(into: [:]) { result, pair in
      guard let date = formatter.date(from: pair.value) else { return }
      result[pair.key] = date
    }
  }

  private func write(_ entries: [String: Date]) {
    let formatter = ISO8601DateFormatter()
    let raw = entries.mapValues { formatter.string(from: $0) }
    guard let data = try? JSONEncoder().encode(raw) else { return }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: fileURL, options: .atomic)
  }
}

extension BrowserSupportBrowser {
  /// 从可执行文件路径认出是哪个浏览器。
  ///
  /// native host 永远由浏览器拉起，所以父进程就是浏览器本身——这是我们能拿到的、
  /// 不需要任何权限的浏览器身份。
  /// 走**最外层** `.app` 包名精确匹配，不做子串包含。两件事都靠它：
  ///
  /// - 子串会认错。`Google Chrome Canary` 的路径含 `Google Chrome`，按子串判断会把 Canary
  ///   的同步时间记到正式版 Chrome 名下——这一行的全部意义就是「哪个浏览器在用」，记错了
  ///   比不记更糟。
  /// - 取最外层而不是最内层，是因为 Chromium 的 native host 未必由主进程 spawn，父进程可能
  ///   是 `.../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/...`。
  ///   Helper 嵌在浏览器包里面，取最外层正好还原成浏览器本身。
  public static func identify(executablePath: String) -> BrowserSupportBrowser? {
    guard let bundleName = outermostAppBundleName(in: executablePath) else { return nil }
    return allKnown.first { $0.appBundleName == bundleName }
  }

  private static func outermostAppBundleName(in path: String) -> String? {
    for component in path.split(separator: "/") where component.hasSuffix(".app") {
      return String(component.dropLast(".app".count))
    }
    return nil
  }
}
