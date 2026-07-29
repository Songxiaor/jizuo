import Foundation
import XCTest
@testable import LinkDigestCore

/// 支持哪些浏览器是一张数据表，不是一段代码。
///
/// 改之前这里是 `enum { chrome, brave, edge }`——写死三个，加一个浏览器要改代码、改枚举、
/// 再补一份一模一样的模板和哈希。现在是数据：`allKnown` 里放几条就支持几个。
///
/// 当前有意只放 Chrome 和 Edge。这不是技术限制——是每加一个都得真的验一遍扩展、native
/// host 和送达记录，没验过的支持不算支持。
final class BrowserRegistryTests: XCTestCase {
  /// `id` 会被写进收据。改一个就等于让旧收据里的那条认不出来。
  func testStableIDs() {
    XCTAssertEqual(BrowserSupportBrowser.chrome.id, "chrome")
    XCTAssertEqual(BrowserSupportBrowser.edge.id, "edge")
    XCTAssertEqual(BrowserSupportBrowser.brave.id, "brave")
  }

  /// 支持面只有 Chrome。这条不是为了锁死数量，是为了让「悄悄多支持了一个」必须显式改
  /// 测试——支持一个浏览器意味着验过它，不是把名字列进表里。
  func testOnlyChromeIsOffered() {
    XCTAssertEqual(BrowserSupportBrowser.allKnown.map(\.id), ["chrome"])
  }

  /// Edge 不是「忘了加」，是被 macOS 挡住的：它的档案目录第一段就是 app 名，写入时逐段
  /// 打开目录会被系统拒，让用户在文件面板里授权也不生效。Chrome 走 `Google/Chrome`，
  /// 第一段是厂商目录，不在那条规则里。这个差别写在目录路径上，所以这里钉住它。
  func testEdgeIsShapedLikeAnAppDataDirectoryAndChromeIsNot() {
    XCTAssertEqual(BrowserSupportBrowser.edge.supportDirectoryRelativePath, "Microsoft Edge")
    XCTAssertEqual(BrowserSupportBrowser.edge.appBundleName, "Microsoft Edge")
    XCTAssertNotEqual(
      BrowserSupportBrowser.chrome.supportDirectoryRelativePath.split(separator: "/").first.map(String.init),
      BrowserSupportBrowser.chrome.appBundleName)
  }

  /// Brave 不再提供，但必须仍然解析得出。
  ///
  /// 「不列出来」和「认不出来」是两件事。真人的收据里已经写着 `brave` 条目，而收据里的
  /// 目标要靠 `known(id:)` 反查目录——解析不出来的后果不是少一行，是一次中断过的旧事务
  /// 会被恢复到 `Application Support/brave/` 这种根本不存在的路径上。
  func testLegacyBrowsersAreNotOfferedButStillResolve() {
    for browser in [BrowserSupportBrowser.brave, .edge] {
      XCTAssertFalse(BrowserSupportBrowser.allKnown.contains(browser), "\(browser.id) 不该被提供")
      XCTAssertEqual(BrowserSupportBrowser.known(id: browser.id), browser, "\(browser.id) 必须解析得出")
    }
    XCTAssertEqual(
      BrowserSupportBrowser.known(id: "brave")?.nativeMessagingRelativePath,
      "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts")
  }

  func testIDsAreUnique() {
    let ids = BrowserSupportBrowser.allKnown.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  /// 目录不是「名字加一层」：Chrome 在 `Google/` 下面，Brave 还要 `BraveSoftware/`。
  func testNativeMessagingPathsFollowEachBrowsersRealLayout() {
    XCTAssertEqual(
      BrowserSupportBrowser.chrome.nativeMessagingRelativePath,
      "Library/Application Support/Google/Chrome/NativeMessagingHosts")
    XCTAssertEqual(
      BrowserSupportBrowser.edge.nativeMessagingRelativePath,
      "Library/Application Support/Microsoft Edge/NativeMessagingHosts")
  }

  /// 每个浏览器必须指向自己的目录。Chrome 和 Brave 曾经共用 Chrome 的目录，于是设置页上
  /// Brave 那一行显示的其实是 Chrome 的状态——两行永远一样。
  func testEachBrowserOwnsItsOwnDirectory() {
    let paths = BrowserSupportBrowser.allKnown.map(\.nativeMessagingRelativePath)
    XCTAssertEqual(Set(paths).count, paths.count)
  }

  /// 认不出的 id 不能丢：那多半是更新的版本写的收据，丢掉等于把别人的条目悄悄抹掉。
  func testUnknownIDSurvivesCodableRoundTrip() throws {
    let data = Data("\"some-future-browser\"".utf8)
    let decoded = try JSONDecoder().decode(BrowserSupportBrowser.self, from: data)
    XCTAssertEqual(decoded.id, "some-future-browser")
    XCTAssertEqual(try JSONEncoder().encode(decoded), data)
  }

  func testKnownIDDecodesToTheRegistryEntry() throws {
    let decoded = try JSONDecoder().decode(BrowserSupportBrowser.self, from: Data("\"edge\"".utf8))
    XCTAssertEqual(decoded, .edge)
    XCTAssertEqual(decoded.displayName, "Microsoft Edge")
  }

  /// 收据里 `brave` 这类不再提供的 id 必须原样存活，而且要解析成真正的 Brave，
  /// 不是一个只剩 id 的占位——占位的目录路径是错的。
  func testLegacyIDDecodesToTheRealEntry() throws {
    let data = Data("\"brave\"".utf8)
    let decoded = try JSONDecoder().decode(BrowserSupportBrowser.self, from: data)
    XCTAssertEqual(decoded, .brave)
    XCTAssertEqual(decoded.supportDirectoryRelativePath, "BraveSoftware/Brave-Browser")
    XCTAssertEqual(try JSONEncoder().encode(decoded), data)
  }

  /// 安装器能动手的全集：判据是 `NativeMessagingHosts` 目录在不在，不是名字。
  func testInstalledProfilesDetectsOnlyBrowsersWithANativeMessagingDirectory() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("linkdigest-registry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(BrowserSupportBrowser.chrome.nativeMessagingRelativePath),
      withIntermediateDirectories: true)
    // 只建到档案根、没有 NativeMessagingHosts：安装器不会为它创建目录，所以不算装了。
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Library/Application Support/Microsoft Edge"),
      withIntermediateDirectories: true)

    XCTAssertEqual(
      BrowserSupportBrowser.installedProfiles(under: root, among: [.chrome, .edge]).map(\.id),
      ["chrome"])
  }

  /// 卸载浏览器不会删档案目录，所以「目录在」不等于「现在还装着」。这台开发机上就有
  /// 5 个这样的残留；只按目录判断的话，设置页会多出 5 行点开什么都不会发生的浏览器。
  func testApplicationPresenceIsSeparateFromTheProfileDirectory() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("linkdigest-registry-apps-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Brave Browser.app"), withIntermediateDirectories: true)

    XCTAssertTrue(BrowserSupportBrowser.brave.isApplicationPresent(in: [root]))
    XCTAssertFalse(BrowserSupportBrowser.chrome.isApplicationPresent(in: [root]))
    XCTAssertFalse(BrowserSupportBrowser.brave.isApplicationPresent(in: []))
  }

  /// app 包名和档案目录名对不上，不能互相顶替：Chrome 的档案目录在 `Google/` 下面，
  /// app 却叫 `Google Chrome.app`；Brave 的目录是 `BraveSoftware/Brave-Browser`。
  func testAppBundleNamesAreNotProfileDirectoryNames() {
    XCTAssertEqual(BrowserSupportBrowser.chrome.appBundleName, "Google Chrome")
    XCTAssertEqual(BrowserSupportBrowser.chrome.supportDirectoryRelativePath, "Google/Chrome")
    XCTAssertEqual(BrowserSupportBrowser.brave.appBundleName, "Brave Browser")
    XCTAssertEqual(
      BrowserSupportBrowser.brave.supportDirectoryRelativePath, "BraveSoftware/Brave-Browser")
  }

  func testSystemApplicationRootsCoverBothMacOSLocations() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    XCTAssertEqual(
      BrowserSupportBrowser.systemApplicationRoots(homeRoot: home).map(\.path),
      ["/Applications", "/Users/fixture/Applications"])
  }
}
