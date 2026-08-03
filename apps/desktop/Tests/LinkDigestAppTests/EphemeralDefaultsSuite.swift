import Foundation
import XCTest

/// 用例专用的一次性 `UserDefaults` suite，用完连域带文件一起删掉。
///
/// 光调 `removePersistentDomain` 是不够的：它只把内容清空，
/// `~/Library/Preferences/<suite>.plist` 那个 42 字节的空壳会留在盘上，
/// 于是 `defaults domains` 里越堆越多（做这件事之前攒了 455 个）。
///
/// LinkDigestAdaptersTests 里有一份同样的实现——两个测试 target 不共享代码，
/// 改这里记得改那边。
func removeEphemeralDefaultsSuite(named suiteName: String) {
  // 只用 standard 这一个实例清域：`UserDefaults(suiteName:)` 会把这个域重新
  // 注册给 cfprefsd，删完文件它在进程退出时又给刷回来。
  UserDefaults.standard.removePersistentDomain(forName: suiteName)
  // 先让 cfprefsd 把「这个域空了」落盘，域变干净之后再删文件，才不会被它重写。
  CFPreferencesAppSynchronize(suiteName as CFString)
  let plist = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Preferences/\(suiteName).plist")
  try? FileManager.default.removeItem(at: plist)
}

extension XCTestCase {
  /// 造一个只属于当前用例的 suite 名，用例结束时自动清理。
  ///
  /// `prefix` 要自带分隔符（`"linkdigest-foo-"` 或 `"com.syc.linkdigest.foo."`），
  /// 拼上去的就是原来那些字面量里的 UUID。
  func ephemeralDefaultsSuiteName(_ prefix: String) -> String {
    let suiteName = prefix + UUID().uuidString
    addTeardownBlock { removeEphemeralDefaultsSuite(named: suiteName) }
    return suiteName
  }

  /// 同上，外加一个连着该 suite 的 `UserDefaults`。
  func ephemeralDefaults(
    _ prefix: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (suite: String, defaults: UserDefaults) {
    let suiteName = ephemeralDefaultsSuiteName(prefix)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
    return (suiteName, defaults)
  }
}
