import Foundation

/// 一个 Chromium 内核浏览器。
///
/// 这里原来是 `enum { chrome, brave, edge }`——写死三个。但 Chromium 内核的浏览器远
/// 不止三个（Chromium、Vivaldi、Opera、Arc、各种 Beta/Canary 通道都是），而三份
/// Native Messaging manifest 模板**字节完全相同**：manifest 里只有 host 名、可执行文件
/// 路径和扩展 origin，没有一个字段跟浏览器有关。
///
/// 也就是说，浏览器之间唯一的差别只有**档案目录在哪**。既然如此，加一个浏览器就应该是
/// 往这张表里加一条数据，而不是改代码、改枚举、再补一份一模一样的模板和哈希。
///
/// `id` 会被写进收据 `receipt-v1.json`，所以它是稳定键，不能改：`chrome` / `brave` /
/// `edge` 这三个沿用原枚举的 rawValue，旧收据照样解得开。
public struct BrowserSupportBrowser: Sendable, Hashable, Identifiable {
  public let id: String
  public let displayName: String
  /// `~/Library/Application Support/` 下面的档案根，`NativeMessagingHosts` 在它下面。
  ///
  /// 不是每个浏览器都是「一层目录」：Brave 在 `BraveSoftware/Brave-Browser`，Arc 还要
  /// 多一层 `User Data`。所以存的是相对路径，不是名字。
  public let supportDirectoryRelativePath: String
  /// `.app` 包名，不带扩展名（`Google Chrome` 而不是 `Google Chrome.app`）。
  ///
  /// 两个地方要用：判断本机装没装（档案目录会在卸载后留下，app 包不会），以及 native host
  /// 从父进程路径认出自己是被谁拉起来的。这两件事都不能用档案目录名代替——档案目录名和
  /// app 包名对不上（`com.operasoftware.Opera` 对 `Opera`，`Arc/User Data` 对 `Arc`）。
  public let appBundleName: String

  public init(
    id: String, displayName: String, supportDirectoryRelativePath: String, appBundleName: String
  ) {
    self.id = id
    self.displayName = displayName
    self.supportDirectoryRelativePath = supportDirectoryRelativePath
    self.appBundleName = appBundleName
  }

  public var nativeMessagingRelativePath: String {
    "Library/Application Support/\(supportDirectoryRelativePath)/NativeMessagingHosts"
  }
}

extension BrowserSupportBrowser {
  public static let chrome = Self(
    id: "chrome", displayName: "Google Chrome", supportDirectoryRelativePath: "Google/Chrome",
    appBundleName: "Google Chrome")
  public static let brave = Self(
    id: "brave", displayName: "Brave", supportDirectoryRelativePath: "BraveSoftware/Brave-Browser",
    appBundleName: "Brave Browser")
  public static let edge = Self(
    id: "edge", displayName: "Microsoft Edge", supportDirectoryRelativePath: "Microsoft Edge",
    appBundleName: "Microsoft Edge")

  /// 当前支持的浏览器。
  ///
  /// 只有 Chrome。加一个浏览器仍然只是往这张表里加一条数据——manifest 模板字节完全相同，
  /// 没有一个字段跟浏览器有关。真正要付出的是每加一个都得**真的去验**一遍。
  ///
  /// Edge 是被 macOS 挡在门外的：它的档案目录第一段就是 app 名 `Microsoft Edge`，写入时
  /// 逐段打开目录会被系统拒（EPERM，且不弹授权框），让用户在文件面板里授权也不管用。
  /// Chrome 走的是 `Google/Chrome`——第一段是厂商目录，不在那条保护规则里。这不是我们
  /// 做对了什么，是目录命名的运气。
  public static let allKnown: [BrowserSupportBrowser] = [.chrome]

  /// 曾经支持、现在不再提供的浏览器。
  ///
  /// 不列出来（`allKnown` 才是列表和送达认领的依据），但必须**解析得出**：真人的收据里
  /// 已经写着 `brave` 条目，而收据里的目标要靠 `known(id:)` 反查它的目录。解析不出来的
  /// 后果不是「少一行」——是一次中断过的旧事务会被恢复到 `Application Support/brave/`
  /// 这种根本不存在的路径上去。
  public static let legacy: [BrowserSupportBrowser] = [.brave, .edge]

  public static func known(id: String) -> BrowserSupportBrowser? {
    (allKnown + legacy).first { $0.id == id }
  }

  /// `NativeMessagingHosts` 目录在的浏览器——安装器能对它动手的全集。
  ///
  /// 安装器拒绝为不存在的浏览器创建目录，所以这就是「装得上」的判据。注意它只回答
  /// 「装得上」，不回答「现在还装着」：卸载浏览器不会删掉档案目录，所以残留目录也在里面。
  /// 要给人看的列表用 `installed(under:applicationRoots:)`。
  public static func installedProfiles(
    under homeRoot: URL, among candidates: [BrowserSupportBrowser] = allKnown
  ) -> [BrowserSupportBrowser] {
    candidates.filter {
      isDirectory(homeRoot.appendingPathComponent($0.nativeMessagingRelativePath, isDirectory: true))
    }
  }

  /// app 包还在不在。
  ///
  /// 档案目录回答不了这个问题：卸载浏览器**不会**删掉 `Application Support` 下的档案目录。
  /// 这台开发机上就有 5 个这样的残留（Chromium、Vivaldi、Opera、Arc、Chrome Canary 的目录
  /// 都在，app 早没了）。列表只按目录判断的话，会多出几行点开什么都不会发生的浏览器。
  ///
  /// `applicationRoots` 不给默认值是故意的：给了默认值，测试就会在无人察觉的情况下依赖
  /// 真机 `/Applications` 里装了什么，换台机器才发现挂了。
  public func isApplicationPresent(in applicationRoots: [URL]) -> Bool {
    applicationRoots.contains { root in
      Self.isDirectory(root.appendingPathComponent("\(appBundleName).app", isDirectory: true))
    }
  }

  /// macOS 上浏览器只可能装在这两处之一。
  public static func systemApplicationRoots(homeRoot: URL) -> [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      homeRoot.appendingPathComponent("Applications", isDirectory: true),
    ]
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }
    return isDirectory.boolValue
  }
}

/// 收据里存的就是 `id` 字符串，所以编解码直接走它——旧收据里的 `chrome` / `brave` /
/// `edge` 不用迁移。认不出的 id 也**不能丢**：那多半是更新的版本写的，丢掉等于把别人的
/// 收据条目悄悄抹掉。
extension BrowserSupportBrowser: Codable {
  public init(from decoder: Decoder) throws {
    let id = try decoder.singleValueContainer().decode(String.self)
    self =
      Self.known(id: id)
      ?? Self(id: id, displayName: id, supportDirectoryRelativePath: id, appBundleName: id)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(id)
  }
}
