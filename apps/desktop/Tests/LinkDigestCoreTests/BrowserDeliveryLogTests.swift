import Foundation
import XCTest
@testable import LinkDigestCore

/// 「这个浏览器在不在用」只能靠既成事实回答。
///
/// 之前这一行报的是 Native Messaging manifest 装没装——那由 App 自己写，浏览器里没有
/// 这个扩展、或者刚被删掉，它都不会变，于是一直显示「已配置」。改读浏览器档案那条路
/// 也走不通：macOS 不许 App 读其它 App 的数据目录，正常启动的 App 拿到 `EPERM` 且不弹
/// 授权框。所以只留下 native host 自己记的送达时间。
final class BrowserDeliveryLogTests: XCTestCase {
  private func withRoot(_ body: (URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("linkdigest-delivery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  func testNoRecordYetReadsAsNil() throws {
    try withRoot { root in
      XCTAssertNil(BrowserDeliveryLog(root: root).lastDelivery(for: .chrome))
      XCTAssertTrue(BrowserDeliveryLog(root: root).allDeliveries().isEmpty)
    }
  }

  func testRecordRoundTripsToTheSecond() throws {
    try withRoot { root in
      let log = BrowserDeliveryLog(root: root)
      let when = Date(timeIntervalSince1970: 1_785_000_000)
      log.record(.chrome, at: when)
      let read = try XCTUnwrap(BrowserDeliveryLog(root: root).lastDelivery(for: .chrome))
      // ISO8601 不带小数秒，所以只保证到秒——这一行显示的粒度也只到分钟。
      XCTAssertEqual(read.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
    }
  }

  /// 所有浏览器共用一份记录。整份覆盖会把别人的时间抹掉，所以必须读-改-写。
  func testRecordingOneBrowserKeepsTheOthers() throws {
    try withRoot { root in
      let log = BrowserDeliveryLog(root: root)
      log.record(.chrome, at: Date(timeIntervalSince1970: 1_785_000_000))
      log.record(.edge, at: Date(timeIntervalSince1970: 1_785_000_500))
      let all = BrowserDeliveryLog(root: root).allDeliveries()
      XCTAssertEqual(Set(all.keys), [.chrome, .edge])
      XCTAssertEqual(
        all[.chrome]?.timeIntervalSince1970 ?? 0, 1_785_000_000, accuracy: 1)
    }
  }

  func testLaterRecordReplacesEarlierOne() throws {
    try withRoot { root in
      let log = BrowserDeliveryLog(root: root)
      log.record(.chrome, at: Date(timeIntervalSince1970: 1_785_000_000))
      log.record(.chrome, at: Date(timeIntervalSince1970: 1_785_009_999))
      let read = try XCTUnwrap(BrowserDeliveryLog(root: root).lastDelivery(for: .chrome))
      XCTAssertEqual(read.timeIntervalSince1970, 1_785_009_999, accuracy: 1)
    }
  }

  /// 记录文件坏掉时读成「没同步过」，不能崩，也不能把旧值当真。
  func testCorruptFileReadsAsEmptyInsteadOfCrashing() throws {
    try withRoot { root in
      let directory = root.appendingPathComponent(
        "Library/Application Support/LinkDigest/BrowserSupport", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("not json".utf8).write(to: directory.appendingPathComponent("last-delivery-v1.json"))
      XCTAssertTrue(BrowserDeliveryLog(root: root).allDeliveries().isEmpty)
    }
  }

  /// 认不出的浏览器名不能混进结果里——它会被当成一个不存在的行。
  func testUnknownBrowserKeyIsIgnored() throws {
    try withRoot { root in
      let directory = root.appendingPathComponent(
        "Library/Application Support/LinkDigest/BrowserSupport", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let payload = ["firefox": "2026-07-29T10:00:00Z", "chrome": "2026-07-29T11:00:00Z"]
      try JSONEncoder().encode(payload)
        .write(to: directory.appendingPathComponent("last-delivery-v1.json"))
      XCTAssertEqual(Set(BrowserDeliveryLog(root: root).allDeliveries().keys), [.chrome])
    }
  }

  /// native host 靠父进程路径认浏览器。认错了整行就报到别的浏览器名下。
  func testBrowserIsIdentifiedFromExecutablePath() {
    XCTAssertEqual(
      BrowserSupportBrowser.identify(
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
      .chrome)
    XCTAssertNil(
      BrowserSupportBrowser.identify(
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"))
  }

  /// 档案表里的浏览器都要认得出来，不能只认最早那三个——认不出的就永远显示「未同步」，
  /// 而用户看不出为什么明明同步了这一行不动。
  func testEveryKnownBrowserIsIdentifiedFromItsOwnBundle() {
    for browser in BrowserSupportBrowser.allKnown {
      XCTAssertEqual(
        BrowserSupportBrowser.identify(
          executablePath: "/Applications/\(browser.appBundleName).app/Contents/MacOS/x"),
        browser,
        "认不出 \(browser.displayName)")
    }
  }

  /// 子串匹配会把 Canary 记到正式版 Chrome 名下。Canary 现在不在支持面里，所以正确答案
  /// 是「认不出」——而不是「算作 Chrome」。记错比不记更糟：这一行的全部意义就是说清楚
  /// 哪个浏览器在用。
  func testChannelBuildsAreNotMistakenForTheStableBuild() {
    XCTAssertNil(
      BrowserSupportBrowser.identify(
        executablePath:
          "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"))
    XCTAssertNil(
      BrowserSupportBrowser.identify(
        executablePath: "/Applications/Microsoft Edge Beta.app/Contents/MacOS/Microsoft Edge Beta"))
  }

  /// 不再提供的浏览器送来的内容照样收（manifest 可能还留在它目录里），只是不记时间——
  /// 记了也没有哪一行会显示它。
  func testLegacyBrowsersAreNotIdentified() {
    XCTAssertNil(
      BrowserSupportBrowser.identify(
        executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"))
    XCTAssertNil(
      BrowserSupportBrowser.identify(
        executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"))
  }

  /// native host 未必由浏览器主进程 spawn，父进程可能是嵌在浏览器包里的 Helper。取最外层
  /// 的 `.app` 才能还原成浏览器本身；取最内层会得到 `Google Chrome Helper`，谁也认不出。
  func testHelperProcessResolvesToTheEnclosingBrowser() {
    XCTAssertEqual(
      BrowserSupportBrowser.identify(
        executablePath:
          "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
      .chrome)
  }

  func testPathWithoutAnAppBundleIsNotIdentified() {
    XCTAssertNil(BrowserSupportBrowser.identify(executablePath: "/usr/bin/curl"))
    XCTAssertNil(BrowserSupportBrowser.identify(executablePath: ""))
  }
}
